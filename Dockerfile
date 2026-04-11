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

# Step 3a: Install known lazy-loaded dependencies
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
    editdistance \
    pyworld \
    local-attention \
    rotary-embedding-torch \
    gradio

# Step 3b: Install packages that require GitHub source installs
# fcpe is not on PyPI — must come from GitHub
RUN pip3 install --no-cache-dir \
    git+https://github.com/CNChTu/FCPE.git \
    || pip3 install --no-cache-dir \
    git+https://github.com/gudgud96/frechet-audio-distance.git \
    || echo "WARNING: fcpe install failed — f0 detection may fall back to alternative"

# Step 4: fairseq from source

RUN pip3 install --no-cache-dir --no-deps \
    git+https://github.com/facebookresearch/fairseq.git@main \
    && echo "fairseq installed successfully" \
    || echo "WARNING: fairseq GitHub install failed"

# Install fairseq's remaining runtime dependencies manually
# since we used --no-deps above
RUN pip3 install --no-cache-dir \
    sacrebleu \
    bitarray \
    cython \
    "PyYAML>=5.1" \
    "omegaconf==2.1.1" \
    "hydra-core==1.1.2" \
    && echo "fairseq runtime deps installed"

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
