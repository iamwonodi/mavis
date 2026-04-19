#!/usr/bin/env python3
"""
Mavis — Real-Time AI Voice Conversion Bridge
SRT In → w-okada Voice Changer (Socket.IO) → SRT Out

Architecture:
  - GStreamer srtsrc (port 6000) receives live audio from Larix
  - Audio decoded and downsampled to 40000Hz (w-okada's native rate)
  - Sent to w-okada via Socket.IO (port 18888)
  - w-okada performs RVC voice conversion and returns 40000Hz audio
  - No Python resampling — pipeline runs at 40000Hz end to end
  - Output encoded as AAC/MPEG-TS and sent via SRT (port 6001) to OBS

Timestamp approach:
  - Uses sample counting for egress buffer timestamps
  - PTS = cumulative_samples * Gst.SECOND // SAMPLE_RATE
  - Always monotonically increasing — eliminates DTS going backward

Reconnection:
  - srtsrc caller-removed signal detects exact TCP disconnection
  - Silence never triggers a restart
  - asyncio.run_coroutine_threadsafe used for safe cross-thread scheduling
"""

import gi
import asyncio
import socketio
import signal
import sys
import numpy as np

gi.require_version('Gst', '1.0')
gi.require_version('GstApp', '1.0')
from gi.repository import Gst, GstApp, GLib

# ── CONFIGURATION ──────────────────────────────────────────────────────────────
SRT_INGRESS_URL  = "srt://0.0.0.0:6000?mode=listener&latency=100"
SRT_EGRESS_URL   = "srt://0.0.0.0:6001?mode=listener&latency=100"
WOKADA_HTTP_URL  = "http://localhost:18888"
WOKADA_NAMESPACE = "/test"

SAMPLE_RATE = 40000
AUDIO_CAPS  = "audio/x-raw,format=S16LE,rate=40000,channels=1,layout=interleaved"

CHUNK_BYTES = 6400  # 3200 samples * 2 bytes at 40000Hz = 80ms per chunk
Gst.init(None)


class AudioBridge:
    def __init__(self):
        self.loop: asyncio.AbstractEventLoop | None = None
        self.queue: asyncio.Queue | None = None
        self.response_queue: asyncio.Queue | None = None

        self.ingress_pipeline = None
        self.egress_pipeline  = None

        self.sio: socketio.AsyncClient | None = None
        self.sio_connected = False

        self._timestamp = 0
        self._sample_count = 0
        self._restarting = False
        self._caller_ever_connected = False

    # ── Socket.IO ──────────────────────────────────────────────────────────────

    async def connect_socketio(self):
        self.sio = socketio.AsyncClient(
            logger=False,
            engineio_logger=False,
            reconnection=True,
            reconnection_attempts=0,
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
            try:
                if isinstance(msg, list) and len(msg) >= 2:
                    bin_data = msg[1]
                    if isinstance(bin_data, (bytes, bytearray)) and len(bin_data) > 0:
                        await self.response_queue.put(bytes(bin_data))
                    else:
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
        sample = appsink.emit("pull-sample")
        if sample:
            buf = sample.get_buffer()
            result, map_info = buf.map(Gst.MapFlags.READ)
            if result:
                data = bytes(map_info.data)
                buf.unmap(map_info)
                if self.loop and not self.loop.is_closed():
                    self.loop.call_soon_threadsafe(self._safe_put, data)
        return Gst.FlowReturn.OK

    def _safe_put(self, data):
        try:
            self.queue.put_nowait(data)
        except asyncio.QueueFull:
            pass

    # ── SRT caller signals ─────────────────────────────────────────────────────

    def on_caller_added(self, element, socket, unused):
        """Fires on GStreamer thread when Larix connects."""
        self._caller_ever_connected = True
        print("[SRT] Caller connected. Audio conversion active.")

    def on_caller_removed(self, element, socket, unused):
        """
        Fires on GStreamer thread when Larix disconnects.
        Uses asyncio.run_coroutine_threadsafe — the only correct way
        to schedule a coroutine from a non-asyncio thread.
        """
        print("[SRT] Caller disconnected. Restarting ingress...")
        if self.loop and not self.loop.is_closed():
            asyncio.run_coroutine_threadsafe(
                self.restart_ingress(), self.loop
            )

    # ── Audio processing ───────────────────────────────────────────────────────

    async def process_loop(self):
        print("[BRIDGE] Processing loop active.")
        audio_buffer = b""
        while True:
            data = await self.queue.get()
            audio_buffer += data
            while len(audio_buffer) >= CHUNK_BYTES:
                chunk = audio_buffer[:CHUNK_BYTES]
                audio_buffer = audio_buffer[CHUNK_BYTES:]
                await self.send_to_wokada(chunk)

    # ── Moving AUdio Chuncks To W-Okada For Transformation ───────────────────────────────────────────────────────

    async def send_to_wokada(self, chunk: bytes):
        arr = np.frombuffer(chunk, dtype=np.int16)
        # Pass silence through without processing — eliminates robotic artifactsThe Send To WOkada
        if np.max(np.abs(arr)) < 200:
            self.push_to_egress(chunk)
            return
        
        if self.sio_connected and self.sio:
            try:
                self._timestamp += 1
                ts = self._timestamp

                while not self.response_queue.empty():
                    try:
                        self.response_queue.get_nowait()
                    except asyncio.QueueEmpty:
                        break

                await self.sio.emit(
                    "request_message",
                    [ts, chunk],
                    namespace=WOKADA_NAMESPACE
                )

                try:
                    response = await asyncio.wait_for(
                        self.response_queue.get(),
                        timeout=1.0
                    )
                    if response is not None and len(response) > 0:
                        self.push_to_egress(response)
                        print(f"[BRIDGE] Converted chunk {ts} pushed to egress.")
                    else:
                        print("[BRIDGE] w-okada returned empty. Is a model loaded?")
                        self.push_to_egress(chunk)
                except asyncio.TimeoutError:
                    print("[BRIDGE] w-okada timeout. Bypassing.")
                    self.push_to_egress(chunk)

            except Exception as e:
                print(f"[SIO ERROR] {e}. Bypassing.")
                self.push_to_egress(chunk)
        else:
            self.push_to_egress(chunk)

    # ── Egress push ────────────────────────────────────────────────────────────

    def push_to_egress(self, data: bytes):
        """
        Push audio to egress pipeline using sample count timestamps.
        Guarantees monotonically increasing PTS regardless of latency.
        """
        appsrc = self.egress_pipeline.get_by_name("source_out")
        if not appsrc:
            return

        n_samples = len(data) // 2
        if n_samples == 0:
            return

        duration = (n_samples * Gst.SECOND) // SAMPLE_RATE

        buf = Gst.Buffer.new_allocate(None, len(data), None)
        buf.fill(0, data)
        buf.pts      = (self._sample_count * Gst.SECOND) // SAMPLE_RATE
        buf.dts      = buf.pts
        buf.duration = duration

        self._sample_count += n_samples

        ret = appsrc.emit("push-buffer", buf)
        if ret != Gst.FlowReturn.OK:
            print(f"[GST EGRESS] push-buffer returned: {ret}")

    # ── Pipeline construction ──────────────────────────────────────────────────

    def build_pipelines(self):
        ingress_str = (
            f"srtsrc name=srtsrc0 uri=\"{SRT_INGRESS_URL}\" "
            "wait-for-connection=true "
            "poll-timeout=100 "
            "do-timestamp=true ! "
            "decodebin ! "
            "audioconvert ! "
            "audioresample ! "
            "queue max-size-buffers=10 max-size-time=0 max-size-bytes=0 ! "
            f"{AUDIO_CAPS} ! "
            "appsink name=sink_in emit-signals=true sync=false "
            "max-buffers=2 drop=true"
        )

        # Key fixes vs previous versions:
        # 1. No trailing space after srtsink URI — corrupted GStreamer parse
        # 2. No queue before srtsink — caused SRT handshake buffering issues
        # 3. wait-for-connection=true — srtsink waits for OBS before accepting data
        egress_str = (
            f"appsrc name=source_out format=time is-live=true "
            f"caps=\"{AUDIO_CAPS}\" ! "
            "queue max-size-buffers=10 max-size-time=0 max-size-bytes=0 ! "
            "audioconvert ! "
            "audioresample ! "
            "voaacenc bitrate=128000 ! "
            "aacparse ! "
            "mpegtsmux ! "
            f"srtsink uri=\"{SRT_EGRESS_URL}\""
        )

        self.ingress_pipeline = Gst.parse_launch(ingress_str)
        self.egress_pipeline  = Gst.parse_launch(egress_str)

        appsink = self.ingress_pipeline.get_by_name("sink_in")
        appsink.connect("new-sample", self.on_new_sample)

        self._wire_srtsrc_signals()

        for pipeline in [self.ingress_pipeline, self.egress_pipeline]:
            bus = pipeline.get_bus()
            bus.add_signal_watch()
            bus.connect("message::error", self.on_pipeline_error)
            bus.connect("message::eos",   self.on_pipeline_eos)

    def _wire_srtsrc_signals(self):
        srtsrc = self.ingress_pipeline.get_by_name("srtsrc0")
        if srtsrc:
            srtsrc.connect("caller-added",   self.on_caller_added)
            srtsrc.connect("caller-removed", self.on_caller_removed)
        else:
            print("[WARN] srtsrc0 not found — caller signals not wired.")

    # ── Pipeline event handlers ────────────────────────────────────────────────

    def on_pipeline_error(self, bus, message):
        err, debug = message.parse_error()
        print(f"[GST ERROR] {err.message}")
        if self.loop and not self.loop.is_closed():
            asyncio.run_coroutine_threadsafe(
                self.restart_ingress(), self.loop
            )

    def on_pipeline_eos(self, bus, message):
        print("[GST] End of stream.")
        if self.loop and not self.loop.is_closed():
            asyncio.run_coroutine_threadsafe(
                self.restart_ingress(), self.loop
            )

    async def restart_ingress(self):
        if self._restarting:
            return
        self._restarting = True
        try:
            print("[GST] Restarting ingress pipeline...")
            if self.ingress_pipeline:
                self.ingress_pipeline.set_state(Gst.State.NULL)
                await asyncio.sleep(1)
                self._sample_count = 0
                self._wire_srtsrc_signals()
                self.ingress_pipeline.set_state(Gst.State.PLAYING)
                print("[GST] Ingress PLAYING. Waiting for new caller...")
        finally:
            self._restarting = False

    async def watchdog_loop(self):
        await asyncio.sleep(30)
        while True:
            await asyncio.sleep(10)
            if self.ingress_pipeline and self._caller_ever_connected:
                state = self.ingress_pipeline.get_state(0)[1]
                if state != Gst.State.PLAYING:
                    print("[WATCHDOG] Ingress not PLAYING. Restarting...")
                    await self.restart_ingress()

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    async def start(self):
        self.loop           = asyncio.get_running_loop()
        self.queue          = asyncio.Queue(maxsize=200)
        self.response_queue = asyncio.Queue(maxsize=10)

        self.build_pipelines()
        await self.connect_socketio()

        self.ingress_pipeline.set_state(Gst.State.PLAYING)
        self.egress_pipeline.set_state(Gst.State.PLAYING)

        print("[GST] Both pipelines are PLAYING.")
        print(f"[GST] Listening for SRT on:        {SRT_INGRESS_URL}")
        print(f"[GST] Sending processed audio to:  {SRT_EGRESS_URL}")
        print(f"[SIO] w-okada at:                  {WOKADA_HTTP_URL}{WOKADA_NAMESPACE}")

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
            asyncio.run_coroutine_threadsafe(
                self.sio.disconnect(), self.loop
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
