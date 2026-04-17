#!/usr/bin/env python3
"""
Mavis — Real-Time AI Voice Conversion Bridge
SRT In → w-okada Voice Changer (Socket.IO) → SRT Out

Architecture:
  - GStreamer srtsrc (port 6000) receives live audio from Larix/OBS
  - Audio is decoded and sent to w-okada via Socket.IO (port 18888)
  - w-okada performs RVC voice conversion and returns converted audio
  - Converted audio is resampled from 40000Hz to 48000Hz
  - Output is encoded as AAC/MPEG-TS and sent via SRT (port 6001) to OBS

Reconnection:
  - Uses srtsrc caller-added/caller-removed GStreamer signals for exact
    connection state detection — no polling, no silence false positives
  - Ingress restarts only when the SRT TCP connection is actually severed
  - Silence during speech never triggers a restart
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
SRT_INGRESS_URL  = "srt://0.0.0.0:6000?mode=listener&latency=200"
SRT_EGRESS_URL   = "srt://0.0.0.0:6001?mode=listener&latency=200"
WOKADA_HTTP_URL  = "http://localhost:18888"
WOKADA_NAMESPACE = "/test"

AUDIO_CAPS  = "audio/x-raw,format=S16LE,rate=48000,channels=1,layout=interleaved"
SAMPLE_RATE = 48000

# w-okada RVC model native output rate — must match the loaded model
# kikoto_mahiro and all default sample models output at 40000Hz
WOKADA_SAMPLE_RATE = 40000

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
        self._pts = 0
        self._duration_per_chunk = 0

        # Prevent concurrent restarts
        self._restarting = False

    # ── Socket.IO connection ───────────────────────────────────────────────────

    async def connect_socketio(self):
        """Connect to w-okada using proper Socket.IO protocol."""
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
            """
            w-okada response format: [timestamp, bin, perf]
            bin = struct-packed int16 audio at WOKADA_SAMPLE_RATE
            Returns integer 0 when no model is loaded.
            """
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
        """Thread-safe queue put — silently drops if full."""
        try:
            self.queue.put_nowait(data)
        except asyncio.QueueFull:
            pass

    # ── SRT caller signal handlers ─────────────────────────────────────────────

    def on_caller_added(self, element, socket):
        """
        Fires the instant an SRT caller connects.
        GStreamer signal — fires on GStreamer thread.
        """
        print("[SRT] Caller connected. Audio conversion active.")

    def on_caller_removed(self, element, socket):
        """
        Fires the instant an SRT caller disconnects.
        GStreamer signal — fires on GStreamer thread.
        Silence never triggers this — only actual TCP disconnection does.
        Schedules ingress restart so the server accepts the next caller.
        """
        print("[SRT] Caller disconnected. Scheduling ingress restart...")
        if self.loop and not self.loop.is_closed():
            self.loop.call_soon_threadsafe(
                self.loop.create_task, self.restart_ingress()
            )

    # ── Audio processing loop ──────────────────────────────────────────────────

    async def process_loop(self):
        """
        Dequeues PCM audio chunks, sends to w-okada via Socket.IO,
        receives converted audio, resamples, and pushes to egress.
        """
        print("[BRIDGE] Processing loop active.")
        while True:
            chunk = await self.queue.get()

            if self.sio_connected and self.sio:
                try:
                    self._timestamp += 1
                    ts = self._timestamp

                    # Clear stale responses before sending new chunk
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
                            resampled = self.resample_response(
                                response, WOKADA_SAMPLE_RATE, SAMPLE_RATE
                            )
                            self.push_to_egress(resampled)
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

    # ── Audio resampling ───────────────────────────────────────────────────────

    def resample_response(self, data: bytes, from_rate: int, to_rate: int) -> bytes:
        """
        Resample int16 PCM audio from from_rate to to_rate using
        linear interpolation. w-okada returns audio at the model's
        native rate (40000Hz). The egress pipeline expects 48000Hz.
        Without resampling, audio plays at wrong speed and pitch.
        """
        if from_rate == to_rate:
            return data
        n_samples = len(data) // 2
        samples = np.frombuffer(data, dtype=np.int16).astype(np.float32)
        new_n_samples = int(n_samples * to_rate / from_rate)
        indices = np.linspace(0, n_samples - 1, new_n_samples)
        resampled = np.interp(indices, np.arange(n_samples), samples)
        return resampled.astype(np.int16).tobytes()

    # ── Egress push ────────────────────────────────────────────────────────────

    def push_to_egress(self, data: bytes):
        """Push audio bytes into the egress GStreamer pipeline."""
        appsrc = self.egress_pipeline.get_by_name("source_out")
        if appsrc:
            buf = Gst.Buffer.new_allocate(None, len(data), None)
            buf.fill(0, data)
            if self._duration_per_chunk > 0:
                buf.pts      = self._pts
                buf.duration = self._duration_per_chunk
                self._pts   += self._duration_per_chunk
            else:
                buf.pts      = Gst.CLOCK_TIME_NONE
                buf.duration = Gst.CLOCK_TIME_NONE
            ret = appsrc.emit("push-buffer", buf)
            if ret != Gst.FlowReturn.OK:
                print(f"[GST EGRESS] push-buffer returned: {ret}")

    # ── Pipeline construction ──────────────────────────────────────────────────

    def build_pipelines(self):
        """
        Builds two separate GStreamer pipelines.

        Ingress: srtsrc → decodebin → audioconvert → audioresample → appsink
        Egress:  appsrc → audioconvert → avenc_aac → mpegtsmux → srtsink

        srtsrc is named 'srtsrc0' explicitly so we can retrieve it
        to wire the caller-added and caller-removed signals.
        """
        ingress_str = (
            f"srtsrc name=srtsrc0 uri=\"{SRT_INGRESS_URL}\" "
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

        self._wire_srtsrc_signals()

        for pipeline in [self.ingress_pipeline, self.egress_pipeline]:
            bus = pipeline.get_bus()
            bus.add_signal_watch()
            bus.connect("message::error", self.on_pipeline_error)
            bus.connect("message::eos",   self.on_pipeline_eos)

    def _wire_srtsrc_signals(self):
        """Wire caller-added and caller-removed signals on srtsrc0."""
        srtsrc = self.ingress_pipeline.get_by_name("srtsrc0")
        if srtsrc:
            srtsrc.connect("caller-added",   self.on_caller_added)
            srtsrc.connect("caller-removed", self.on_caller_removed)
        else:
            print("[WARN] Could not find srtsrc0 — caller signals not wired.")

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
        """
        Restarts the ingress pipeline to accept a new SRT connection.
        Protected against concurrent calls with _restarting flag.
        Re-wires srtsrc signals after restart so disconnection
        detection continues working for all subsequent connections.
        """
        if self._restarting:
            return
        self._restarting = True
        try:
            print("[GST] Restarting ingress pipeline...")
            if self.ingress_pipeline:
                self.ingress_pipeline.set_state(Gst.State.NULL)
                await asyncio.sleep(1)

                # Reset timestamps so egress timeline starts clean
                self._pts = 0
                self._duration_per_chunk = 0

                # Re-wire caller signals — lost when pipeline goes NULL
                self._wire_srtsrc_signals()

                self.ingress_pipeline.set_state(Gst.State.PLAYING)
                print("[GST] Ingress PLAYING. Waiting for new caller...")
        finally:
            self._restarting = False

    async def watchdog_loop(self):
        """
        Fallback watchdog — only fires if pipeline leaves PLAYING state
        for reasons other than normal caller disconnection.
        Normal disconnections are handled by the caller-removed signal.
        Runs every 10 seconds as a light safety net only.
        """
        while True:
            await asyncio.sleep(10)
            if self.ingress_pipeline:
                state = self.ingress_pipeline.get_state(0)[1]
                if state != Gst.State.PLAYING:
                    print("[WATCHDOG] Ingress not PLAYING unexpectedly. Restarting...")
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
