#!/usr/bin/env python3
"""
Mavis — Real-Time AI Voice Conversion Bridge
SRT In → w-okada Voice Changer (WebSocket) → SRT Out

Bug fixes applied vs original:
  1. Fixed typo in WOKADA_WS_URL ("s://" → "ws://")
  2. Split the GStreamer pipeline into two separate Gst.Pipeline objects
     (parse_launch cannot handle two disconnected source chains)
  3. Fixed asyncio event loop reference: captured inside start() not __init__
  4. Fixed appsrc buffer timestamps to avoid encoder drift/drops
  5. Fixed stop() to use loop.call_soon_threadsafe for async cleanup
"""

import gi
import asyncio
import aiohttp
import signal
import sys
import time
import os

gi.require_version('Gst', '1.0')
gi.require_version('GstApp', '1.0')
from gi.repository import Gst, GstApp, GLib

# ── CONFIGURATION ──────────────────────────────────────────────────────────────
SRT_INGRESS_URL = "srt://0.0.0.0:6000?mode=listener&latency=200"
SRT_EGRESS_URL = "srt://0.0.0.0:6001?mode=listener&latency=200"

# FIX #1: Was "s://..." (missing the 'w'). This caused a connection error on every start.
WOKADA_WS_URL   = "ws://localhost:18888/socket.io/?EIO=4&transport=websocket"

# Audio format shared between both pipelines
AUDIO_CAPS = "audio/x-raw,format=S16LE,rate=48000,channels=1,layout=interleaved"
SAMPLE_RATE = 48000

Gst.init(None)


class AudioBridge:
    def __init__(self):
        # FIX #3: Do NOT capture the event loop here.
        # asyncio.run() creates a brand new loop; self.loop must be set
        # inside start() after that loop is running.
        self.loop: asyncio.AbstractEventLoop | None = None
        self.queue: asyncio.Queue | None = None

        self.ingress_pipeline = None   # srtsrc → appsink
        self.egress_pipeline  = None   # appsrc → srtclientsink

        self.ws_session = None
        self.ws = None

        # FIX #4: Track running timestamp for egress buffer PTS
        self._pts = 0
        self._duration_per_chunk = 0  # set after first chunk arrives

    # ── WebSocket ──────────────────────────────────────────────────────────────

    async def connect_websocket(self):
        """Maintains connection to the w-okada voice changer WebSocket."""
        if self.ws_session is None:
            self.ws_session = aiohttp.ClientSession()
        while True:
            try:
                print(f"[WS] Connecting to {WOKADA_WS_URL}...")
                self.ws = await self.ws_session.ws_connect(WOKADA_WS_URL)
                print("[WS] Connected!")
                return
            except Exception as e:
                print(f"[WS] Connection failed: {e}. Retrying in 2s...")
                await asyncio.sleep(2)

    # ── GStreamer callbacks ────────────────────────────────────────────────────

    def on_new_sample(self, appsink):
        """
        Called on GStreamer's internal thread when a decoded audio chunk arrives.
        Places data on the asyncio queue in a thread-safe way.
        """
        sample = appsink.emit("pull-sample")
        if sample:
            buf = sample.get_buffer()
            result, map_info = buf.map(Gst.MapFlags.READ)
            if result:
                data = bytes(map_info.data)  # copy bytes before unmap

                # FIX #4: Compute duration from actual chunk length
                # S16LE = 2 bytes per sample, 1 channel
                n_samples = len(data) // 2
                self._duration_per_chunk = (n_samples * Gst.SECOND) // SAMPLE_RATE

                buf.unmap(map_info)

                # FIX #3: Use self.loop (set in start()) — safe cross-thread call
                if self.loop and not self.loop.is_closed():
                    # Use call_soon_threadsafe with a lambda that silently
                # drops if full — never raises QueueFull
                    self.loop.call_soon_threadsafe(
                        self._safe_put, data
                )
        return Gst.FlowReturn.OK
    
    def _safe_put(self, data):
        """Put data on queue, silently drop if full. Never raises."""
        try:
            self.queue.put_nowait(data)
        except asyncio.QueueFull:
            pass  # Drop oldest chunks under load — latency over correctness

    # ── Audio processing loop ──────────────────────────────────────────────────

    async def process_loop(self):
        """Dequeues audio chunks, sends to w-okada, pushes result to egress."""
        print("[BRIDGE] Processing loop active.")
        while True:
            chunk = await self.queue.get()
            if self.ws and not self.ws.closed:
                try:
                    await self.ws.send_bytes(chunk)
                    msg = await asyncio.wait_for(self.ws.receive(), timeout=1.0)
                    if msg.type == aiohttp.WSMsgType.BINARY:
                        self.push_to_egress(msg.data)
                    else:
                        # Non-binary response (e.g. ping/text) — bypass
                        self.push_to_egress(chunk)
                except asyncio.TimeoutError:
                    print("[WS] Timeout waiting for w-okada response. Bypassing.")
                    self.push_to_egress(chunk)
                except Exception as e:
                    print(f"[WS ERROR] {e}. Reconnecting...")
                    self.push_to_egress(chunk)
                    await self.connect_websocket()
            else:
                # Fallback: bypass w-okada if WebSocket is down
                self.push_to_egress(chunk)

    # ── Egress push ────────────────────────────────────────────────────────────

    def push_to_egress(self, data: bytes):
        """Pushes processed audio into the egress GStreamer pipeline."""
        appsrc = self.egress_pipeline.get_by_name("source_out")
        if appsrc:
            buf = Gst.Buffer.new_allocate(None, len(data), None)
            buf.fill(0, data)

            # FIX #4: Assign correct PTS and duration so the AAC encoder
            # doesn't drift, produce glitches, or silently drop frames.
            buf.pts      = self._pts
            buf.duration = self._duration_per_chunk
            self._pts   += self._duration_per_chunk

            ret = appsrc.emit("push-buffer", buf)
            if ret != Gst.FlowReturn.OK:
                print(f"[GST EGRESS] push-buffer returned: {ret}")

    # ── Pipeline construction ──────────────────────────────────────────────────

    def build_pipelines(self):
        """
        FIX #2: Two separate pipelines instead of one malformed parse_launch string.

        Gst.parse_launch() cannot manage two disconnected source chains in a
        single string. The original code joined them with a space, which GStreamer
        treats as a link operator — creating an invalid graph that fails silently
        or raises a parse error at runtime.

        Pipeline A (ingress): srtsrc → MPEG-TS demux → AAC decode → appsink
        Pipeline B (egress):  appsrc → AAC encode → MPEG-TS mux → srtclientsink
        """

        ingress_str = (
            f"srtsrc uri=\"{SRT_INGRESS_URL}\" ! "
            "tsdemux ! aacparse ! avdec_aac ! "
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

        # Wire the appsink callback
        appsink = self.ingress_pipeline.get_by_name("sink_in")
        appsink.connect("new-sample", self.on_new_sample)

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    async def start(self):
        # FIX #3: Capture the running loop HERE, not in __init__
        self.loop  = asyncio.get_running_loop()
        # Increased from 20 to 200 — prevents QueueFull exceptions
        # during w-okada processing bursts
        self.queue = asyncio.Queue(maxsize=200)

        self.build_pipelines()
        await self.connect_websocket()

        self.ingress_pipeline.set_state(Gst.State.PLAYING)
        self.egress_pipeline.set_state(Gst.State.PLAYING)
        print("[GST] Both pipelines are PLAYING.")
        print(f"[GST] Listening for SRT on: {SRT_INGRESS_URL}")
        print(f"[GST] Sending processed audio to: {SRT_EGRESS_URL}")

        await self.process_loop()

    def stop(self):
        print("[MAVIS] Stopping pipelines...")
        if self.ingress_pipeline:
            self.ingress_pipeline.set_state(Gst.State.NULL)
        if self.egress_pipeline:
            self.egress_pipeline.set_state(Gst.State.NULL)

        # FIX #5: Cannot call asyncio.create_task() from a signal handler.
        # Use call_soon_threadsafe to schedule coroutine cleanup safely.
        if self.ws_session and self.loop and not self.loop.is_closed():
            self.loop.call_soon_threadsafe(
                self.loop.create_task,
                self.ws_session.close()
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
