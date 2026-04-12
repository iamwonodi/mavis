#!/usr/bin/env python3
"""
Mavis — Real-Time AI Voice Conversion Bridge
SRT In → w-okada Voice Changer (Socket.IO) → SRT Out

Key fix in this version:
  Previous versions used raw aiohttp WebSocket to send audio bytes directly
  to w-okada. This caused ValueError in w-okada's Socket.IO packet parser
  because it received raw PCM bytes instead of properly framed Socket.IO
  messages. w-okada never processed any audio — every chunk timed out and
  was bypassed, giving unmodified audio.

  This version uses python-socketio AsyncClient which correctly frames all
  messages in the Socket.IO protocol. The event name and message format are
  taken directly from w-okada's MMVC_Namespace.py:

    Send:    emit("request_message", [timestamp, raw_bytes])
    Receive: on("response")  →  [timestamp, bin, perf]
             where bin = struct.pack("<Nh", ...) of int16 audio samples
"""

import gi
import asyncio
import socketio
import struct
import signal
import sys
import time

gi.require_version('Gst', '1.0')
gi.require_version('GstApp', '1.0')
from gi.repository import Gst, GstApp, GLib

# ── CONFIGURATION ──────────────────────────────────────────────────────────────
SRT_INGRESS_URL  = "srt://0.0.0.0:6000?mode=listener&latency=200"
SRT_EGRESS_URL   = "srt://0.0.0.0:6001?mode=listener&latency=200"
WOKADA_HTTP_URL  = "http://localhost:18888"
WOKADA_NAMESPACE = "/test"   # w-okada registers its namespace as "/test"

AUDIO_CAPS  = "audio/x-raw,format=S16LE,rate=48000,channels=1,layout=interleaved"
SAMPLE_RATE = 48000

Gst.init(None)


class AudioBridge:
    def __init__(self):
        self.loop: asyncio.AbstractEventLoop | None = None
        self.queue: asyncio.Queue | None = None

        self.ingress_pipeline = None
        self.egress_pipeline  = None

        # Socket.IO client — replaces raw aiohttp WebSocket
        self.sio: socketio.AsyncClient | None = None
        self.sio_connected = False

        # Response queue: w-okada sends back converted audio asynchronously
        # We need to match responses to requests by timestamp
        self.response_queue: asyncio.Queue | None = None

        # Timestamp counter for matching requests to responses
        self._timestamp = 0

        # GStreamer buffer timing
        self._pts = 0
        self._duration_per_chunk = 0

    # ── Socket.IO connection ───────────────────────────────────────────────────

    async def connect_socketio(self):
        """Connect to w-okada using proper Socket.IO protocol."""
        self.sio = socketio.AsyncClient(
            logger=False,
            engineio_logger=False,
            reconnection=True,
            reconnection_attempts=0,   # retry forever
            reconnection_delay=2,
        )

        @self.sio.on("connect", namespace=WOKADA_NAMESPACE)
        async def on_connect():
            self.sio_connected = True
            print("[SIO] Connected to w-okada!")

        @self.sio.on("disconnect", namespace=WOKADA_NAMESPACE)
        async def on_disconnect():
            self.sio_connected = False
            print("[SIO] Disconnected from w-okada. Reconnecting...")

        @self.sio.on("response", namespace=WOKADA_NAMESPACE)
        async def on_response(msg):
            """
            w-okada emits: ["response", [timestamp, bin, perf]]
            msg here is the data argument: [timestamp, bin, perf]
            bin is struct-packed int16 audio samples.
            """
            try:
                if isinstance(msg, list) and len(msg) >= 2:
                    bin_data = msg[1]
                    if isinstance(bin_data, (bytes, bytearray)) and len(bin_data) > 0:
                        await self.response_queue.put(bytes(bin_data))
                    else:
                        # w-okada returned empty/zero audio (no model loaded)
                        await self.response_queue.put(None)
                else:
                    await self.response_queue.put(None)
            except Exception as e:
                print(f"[SIO] Response handler error: {e}")
                await self.response_queue.put(None)

        while True:
            try:
                print(f"[SIO] Connecting to {WOKADA_HTTP_URL} namespace={WOKADA_NAMESPACE}...")
                await self.sio.connect(
                    WOKADA_HTTP_URL,
                    namespaces=[WOKADA_NAMESPACE],
                    socketio_path="/socket.io/",
                    transports=["websocket"],
                )
                print("[SIO] Connected!")
                return
            except Exception as e:
                print(f"[SIO] Connection failed: {e}. Retrying in 2s...")
                await asyncio.sleep(2)

    # ── GStreamer callbacks ────────────────────────────────────────────────────

    def on_new_sample(self, appsink):
        """Called on GStreamer thread when decoded audio chunk arrives."""
        sample = appsink.emit("pull-sample")
        if sample:
            buf = sample.get_buffer()
            result, map_info = buf.map(Gst.MapFlags.READ)
            if result:
                data = bytes(map_info.data)
                n_samples = len(data) // 2
                self._duration_per_chunk = (n_samples * Gst.SECOND) // SAMPLE_RATE
                buf.unmap(map_info)
                if self.loop and not self.loop.is_closed():
                    self.loop.call_soon_threadsafe(self._safe_put, data)
        return Gst.FlowReturn.OK

    def _safe_put(self, data):
        """Thread-safe queue put that silently drops if full."""
        try:
            self.queue.put_nowait(data)
        except asyncio.QueueFull:
            pass

    # ── Audio processing loop ──────────────────────────────────────────────────

    async def process_loop(self):
        """
        Dequeues PCM audio chunks, sends to w-okada via Socket.IO,
        receives converted audio, pushes to egress pipeline.

        Protocol (from MMVC_Namespace.py):
          Send:    emit("request_message", [timestamp, raw_bytes], namespace="/test")
          Receive: on("response") → [timestamp, bin, perf]
                   where bin = struct-packed int16 samples of converted audio
        """
        print("[BRIDGE] Processing loop active.")
        while True:
            chunk = await self.queue.get()

            if self.sio_connected and self.sio:
                try:
                    self._timestamp += 1
                    ts = self._timestamp

                    # Clear any stale responses before sending
                    while not self.response_queue.empty():
                        try:
                            self.response_queue.get_nowait()
                        except asyncio.QueueEmpty:
                            break

                    # Send to w-okada using correct Socket.IO event and format
                    await self.sio.emit(
                        "request_message",
                        [ts, chunk],
                        namespace=WOKADA_NAMESPACE
                    )

                    # Wait for response with timeout
                    try:
                        response = await asyncio.wait_for(
                            self.response_queue.get(),
                            timeout=1.0
                        )
                        if response is not None and len(response) > 0:
                            self.push_to_egress(response)
                            print(f"[BRIDGE] Converted chunk {ts} pushed to egress.")
                        else:
                            # w-okada returned empty — no model active, bypass
                            print("[BRIDGE] w-okada returned empty. Is a model loaded and started?")
                            self.push_to_egress(chunk)
                    except asyncio.TimeoutError:
                        print("[BRIDGE] w-okada timeout. Bypassing.")
                        self.push_to_egress(chunk)

                except Exception as e:
                    print(f"[SIO ERROR] {e}. Bypassing.")
                    self.push_to_egress(chunk)
            else:
                # Bypass if not connected to w-okada
                self.push_to_egress(chunk)

    # ── Egress push ────────────────────────────────────────────────────────────

    def push_to_egress(self, data: bytes):
        """Push audio bytes into the egress GStreamer pipeline."""
        appsrc = self.egress_pipeline.get_by_name("source_out")
        if appsrc:
            buf = Gst.Buffer.new_allocate(None, len(data), None)
            buf.fill(0, data)
            buf.pts      = self._pts
            buf.duration = self._duration_per_chunk
            self._pts   += self._duration_per_chunk
            ret = appsrc.emit("push-buffer", buf)
            if ret != Gst.FlowReturn.OK:
                print(f"[GST EGRESS] push-buffer returned: {ret}")

    # ── Pipeline construction ──────────────────────────────────────────────────

    def build_pipelines(self):
        ingress_str = (
            f"srtsrc uri=\"{SRT_INGRESS_URL}\" "
            "wait-for-connection=true "
            "poll-timeout=100 "
            "do-timestamp=true ! "
            "decodebin ! "
            "audioconvert ! audioresample ! "
            "queue max-size-buffers=10 max-size-time=0 max-size-bytes=0 ! "
            f"{AUDIO_CAPS} ! "
            "appsink name=sink_in emit-signals=true sync=false "
            "max-buffers=2 drop=true"
        )

        egress_str = (
            f"appsrc name=source_out format=time is-live=true "
            f"caps=\"{AUDIO_CAPS}\" ! "
            "queue max-size-buffers=10 max-size-time=0 max-size-bytes=0 ! "
            "audioconvert ! "
            "queue max-size-buffers=10 max-size-time=0 max-size-bytes=0 ! "
            "avenc_aac bitrate=128000 ! "
            "queue max-size-buffers=10 max-size-time=0 max-size-bytes=0 ! "
            "mpegtsmux ! "
            f"srtsink uri=\"{SRT_EGRESS_URL}\""
        )

        self.ingress_pipeline = Gst.parse_launch(ingress_str)
        self.egress_pipeline  = Gst.parse_launch(egress_str)

        appsink = self.ingress_pipeline.get_by_name("sink_in")
        appsink.connect("new-sample", self.on_new_sample)

        # Watch for pipeline errors and EOS to handle Larix reconnects
        for pipeline in [self.ingress_pipeline, self.egress_pipeline]:
            bus = pipeline.get_bus()
            bus.add_signal_watch()
            bus.connect("message::error", self.on_pipeline_error)
            bus.connect("message::eos",   self.on_pipeline_eos)

    # ── Pipeline event handlers ────────────────────────────────────────────────

    def on_pipeline_error(self, bus, message):
        err, debug = message.parse_error()
        print(f"[GST ERROR] {err.message}. Restarting ingress...")
        if self.loop and not self.loop.is_closed():
            self.loop.call_soon_threadsafe(
                self.loop.create_task, self.restart_ingress()
            )

    def on_pipeline_eos(self, bus, message):
        print("[GST] End of stream. Restarting ingress...")
        if self.loop and not self.loop.is_closed():
            self.loop.call_soon_threadsafe(
                self.loop.create_task, self.restart_ingress()
            )

    async def restart_ingress(self):
        print("[GST] Restarting ingress pipeline...")
        if self.ingress_pipeline:
            self.ingress_pipeline.set_state(Gst.State.NULL)
            await asyncio.sleep(1)
            self.ingress_pipeline.set_state(Gst.State.PLAYING)
            print("[GST] Ingress pipeline restarted. Waiting for Larix...")

    async def watchdog_loop(self):
        """Periodically checks ingress state and restarts if stalled."""
        while True:
            await asyncio.sleep(15)
            if self.ingress_pipeline:
                state = self.ingress_pipeline.get_state(0)[1]
                if state != Gst.State.PLAYING:
                    print("[WATCHDOG] Ingress not PLAYING. Restarting...")
                    await self.restart_ingress()

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    async def start(self):
        self.loop          = asyncio.get_running_loop()
        self.queue         = asyncio.Queue(maxsize=200)
        self.response_queue = asyncio.Queue(maxsize=10)

        self.build_pipelines()
        await self.connect_socketio()

        self.ingress_pipeline.set_state(Gst.State.PLAYING)
        self.egress_pipeline.set_state(Gst.State.PLAYING)
        print("[GST] Both pipelines are PLAYING.")
        print(f"[GST] Listening for SRT on:        {SRT_INGRESS_URL}")
        print(f"[GST] Sending processed audio to:  {SRT_EGRESS_URL}")
        print(f"[SIO] Sending audio to w-okada at: {WOKADA_HTTP_URL}{WOKADA_NAMESPACE}")

        await asyncio.gather(
            self.process_loop(),
            self.watchdog_loop(),
        )

    def stop(self):
        print("[MAVIS] Stopping...")
        if self.ingress_pipeline:
            self.ingress_pipeline.set_state(Gst.State.NULL)
        if self.egress_pipeline:
            self.egress_pipeline.set_state(Gst.State.NULL)
        if self.sio and self.loop and not self.loop.is_closed():
            self.loop.call_soon_threadsafe(
                self.loop.create_task, self.sio.disconnect()
            )


# ── Entry point ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    bridge = AudioBridge()

    def signal_handler(sig, frame):
        print("\n[MAVIS] Shutdown signal received.")
        bridge.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT,  signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        asyncio.run(bridge.start())
    except KeyboardInterrupt:
        bridge.stop()
