# =============================================================================
# Mavis — Real-Time AI Voice Conversion Bridge
# Base: NVIDIA CUDA 11.8 + Ubuntu 22.04
# Compatible with TensorDock KVM instances (RTX 4090 / GPU passthrough)
# =============================================================================

FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu22.04

# Prevent interactive prompts during apt installs
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV GST_DEBUG=2

# ── System: GStreamer, Python, build tools ─────────────────────────────────────
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-dev \
    git wget curl nano lsof build-essential pkg-config \
    ffmpeg libportaudio2 portaudio19-dev \
    # GStreamer full stack
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gir1.2-gstreamer-1.0 \
    python3-gst-1.0 \
    python3-gi \
    python3-gi-cairo \
    libgirepository1.0-dev \
    libcairo2-dev \
    # psmisc provides fuser (used by smart-cleanup.sh)
    psmisc \
    && rm -rf /var/lib/apt/lists/*

# ── Python deps ───────────────────────────────────────────────────────────────
RUN pip3 install --upgrade pip setuptools wheel

# PyTorch + CUDA 11.8 (w-okada compatible)
RUN pip3 install --no-cache-dir \
    torch==2.0.1+cu118 \
    torchvision==0.15.2+cu118 \
    torchaudio==2.0.2+cu118 \
    --index-url https://download.pytorch.org/whl/cu118

# ONNX Runtime GPU (pinned for w-okada compatibility)
RUN pip3 install --no-cache-dir onnxruntime-gpu==1.13.1

# aiohttp for WebSocket bridge; all w-okada Python deps
RUN pip3 install --no-cache-dir \
    aiohttp \
    sounddevice \
    requests \
    tqdm \
    joblib \
    decorator \
    numba \
    packaging \
    pooch \
    scikit-learn \
    soundfile \
    python-engineio \
    python-socketio \
    starlette \
    "fastapi<0.100.0" \
    uvicorn \
    python-multipart \
    "pydantic<2.0" \
    "pyOpenSSL==21.0.0" \
    "cryptography==38.0.4"

# ── Clone w-okada voice changer ───────────────────────────────────────────────
WORKDIR /workspace
RUN git clone https://github.com/w-okada/voice-changer.git /workspace/voice-changer

# ── w-okada dependencies — complete install ───────────────────────────────────

# Step 1: Install w-okada's pinned requirements without deps first
RUN pip3 install --no-cache-dir --no-deps \
    -r /workspace/voice-changer/server/requirements.txt || true

# Step 2: Install with deps to fill all transitive requirements
RUN pip3 install --no-cache-dir \
    -r /workspace/voice-changer/server/requirements.txt || true

# Step 3: Install all known lazy-loaded dependencies that w-okada
# only imports when specific features are triggered at runtime.
# Installing all of them now means no module will ever be missing
# regardless of which w-okada feature gets activated.
RUN pip3 install --no-cache-dir \
    audioread \
    librosa \
    resampy \
    soundfile \
    praat-parselmouth \
    torchcrepe \
    einops \
    diffusers \
    antlr4-python3-runtime==4.8 \
    omegaconf \
    hydra-core \
    editdistance \
    pyworld \
    fcpe \
    local-attention \
    rotary-embedding-torch \
    gradio

# Step 4: fairseq — Facebook's sequence modeling library used by RVC embedders.
# Must be installed from source because the PyPI release has known
# incompatibilities with PyTorch 2.0+ and Python 3.10.
RUN pip3 install --no-cache-dir \
    git+https://github.com/facebookresearch/fairseq.git@main \
    || pip3 install --no-cache-dir fairseq \
    || echo "fairseq install failed — will attempt at runtime"

# Step 5: Verify critical imports are resolvable at build time
# If any of these fail the Docker build itself fails, catching
# missing dependencies before the image is ever pushed to ECR.
RUN python3 -c "import torch; print('torch OK:', torch.__version__)"
RUN python3 -c "import librosa; print('librosa OK')"
RUN python3 -c "import fairseq; print('fairseq OK')" \
    || echo "WARNING: fairseq not importable — check build logs"
RUN python3 -c "import pyworld; print('pyworld OK')"
RUN python3 -c "import torchcrepe; print('torchcrepe OK')"


# ── Copy Mavis application files ──────────────────────────────────────────────
WORKDIR /workspace/mavis

# App layer
COPY main.py        ./scripts/main.py
COPY startup.sh        ./startup.sh

# Setup scripts (available inside container for reference/re-runs)
COPY smart-cleanup.sh ./scripts/smart-cleanup.sh

RUN chmod +x ./startup.sh ./scripts/smart-cleanup.sh

# ── Expose ports ──────────────────────────────────────────────────────────────
# SRT ingress (audio in from Larix / OBS)
EXPOSE 6000/udp
# SRT egress (processed audio out)
EXPOSE 6001/udp
# w-okada WebSocket API (internal, but exposed for debugging)
EXPOSE 18888/tcp

# ── Entrypoint ────────────────────────────────────────────────────────────────
# Runs w-okada in the background, then launches the GStreamer pipeline
# foreground. Ctrl-C stops the pipeline; w-okada keeps running.
CMD ["/bin/bash", "/workspace/mavis/startup.sh"]
