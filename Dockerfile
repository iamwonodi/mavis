# =============================================================================
# Mavis — Real-Time AI Voice Conversion Bridge
# Base: NVIDIA CUDA 11.8 + Ubuntu 22.04
# =============================================================================

FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV GST_DEBUG=2

# ── System dependencies ────────────────────────────────────────────────────────
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-dev \
    git wget curl nano lsof build-essential pkg-config \
    ffmpeg libportaudio2 portaudio19-dev \
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
    psmisc \
    && rm -rf /var/lib/apt/lists/*

# ── Python base ────────────────────────────────────────────────────────────────
RUN pip3 install --upgrade pip setuptools wheel

# PyTorch + CUDA 11.8
RUN pip3 install --no-cache-dir \
    torch==2.0.1+cu118 \
    torchvision==0.15.2+cu118 \
    torchaudio==2.0.2+cu118 \
    --index-url https://download.pytorch.org/whl/cu118

# Pin numpy immediately after PyTorch before anything else can change it
RUN pip3 install --no-cache-dir "numpy==1.23.5"

# ONNX Runtime GPU
RUN pip3 install --no-cache-dir onnxruntime-gpu==1.13.1

# Core application and w-okada Python dependencies
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
    starlette \
    "fastapi<0.100.0" \
    uvicorn \
    python-multipart \
    "pydantic<2.0" \
    "pyOpenSSL==21.0.0" \
    "cryptography==38.0.4"

# python-socketio with asyncio_client extra — required by main.py
RUN pip3 install --no-cache-dir "python-socketio[asyncio_client]"

# ── Clone w-okada ──────────────────────────────────────────────────────────────
WORKDIR /workspace
RUN git clone https://github.com/w-okada/voice-changer.git /workspace/voice-changer

# ── w-okada Python dependencies ───────────────────────────────────────────────

# Step 1: Install without deps to respect pinned versions
RUN pip3 install --no-cache-dir --no-deps \
    -r /workspace/voice-changer/server/requirements.txt || true

# Step 2: Install with deps to fill transitive requirements
RUN pip3 install --no-cache-dir \
    -r /workspace/voice-changer/server/requirements.txt || true

# Step 3a: Lazy-loaded dependencies
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

# Step 3b: torchfcpe pinned to 0.0.3 — last stable version
# DO NOT upgrade to 0.0.4 — it introduced f02midi which is not
# properly packaged and causes ModuleNotFoundError at w-okada startup
RUN pip3 install --no-cache-dir "torchfcpe==0.0.3" \
    && echo "torchfcpe 0.0.3 installed successfully"

# Step 4: fairseq from source with --no-deps to avoid version conflicts
RUN pip3 install --no-cache-dir --no-deps \
    git+https://github.com/facebookresearch/fairseq.git@main \
    && echo "fairseq installed successfully" \
    || echo "WARNING: fairseq GitHub install failed"

# fairseq manual runtime deps
RUN pip3 install --no-cache-dir \
    sacrebleu \
    bitarray \
    cython \
    "PyYAML>=5.1" \
    "omegaconf==2.1.1" \
    "hydra-core==1.1.2" \
    && echo "fairseq runtime deps installed"

# Re-pin numpy after all installs to ensure nothing pulled a newer version
RUN pip3 install --no-cache-dir "numpy==1.23.5" \
    && echo "numpy re-pinned to 1.23.5"

# ── Bake in w-okada pretrain models ───────────────────────────────────────────
# Downloading these at build time means w-okada starts instantly with no
# network downloads at container startup. These are the neural network
# weights required for voice feature extraction and pitch detection.
# Without them w-okada cannot process any audio regardless of which
# voice model is loaded.
RUN mkdir -p /workspace/voice-changer/server/pretrain && \
    cd /workspace/voice-changer/server/pretrain && \
    echo "Downloading hubert_base.pt (voice feature extractor)..." && \
    wget -q "https://huggingface.co/lj1995/VoiceConversionWebUI/resolve/main/hubert_base.pt" \
        -O hubert_base.pt && \
    echo "Downloading rmvpe.pt (pitch detector)..." && \
    wget -q "https://huggingface.co/lj1995/VoiceConversionWebUI/resolve/main/rmvpe.pt" \
        -O rmvpe.pt && \
    echo "Downloading rmvpe.onnx (pitch detector ONNX)..." && \
    wget -q "https://huggingface.co/lj1995/VoiceConversionWebUI/resolve/main/rmvpe.onnx" \
        -O rmvpe.onnx && \
    echo "Downloading content_vec_500.onnx (content vector)..." && \
    wget -q "https://huggingface.co/lj1995/VoiceConversionWebUI/resolve/main/content_vec_500.onnx" \
        -O content_vec_500.onnx && \
    echo "All pretrain models downloaded." && \
    ls -lh .

# ── Build-time import verification ────────────────────────────────────────────
# These checks fail the build immediately if any critical package is broken
# so we never push a broken image to ECR
RUN python3 -c "import torch; print('torch OK:', torch.__version__)"
RUN python3 -c "import numpy; print('numpy OK:', numpy.__version__)"
RUN python3 -c "import librosa; print('librosa OK')"
RUN python3 -c "import fairseq; print('fairseq OK')" \
    || echo "WARNING: fairseq not importable — check build logs"
RUN python3 -c "import pyworld; print('pyworld OK')"
RUN python3 -c "import torchcrepe; print('torchcrepe OK')"
RUN python3 -c "import torchfcpe; print('torchfcpe OK')"
RUN python3 -c "import socketio; print('socketio OK')"

# ── Copy Mavis application files ──────────────────────────────────────────────
WORKDIR /workspace/mavis

# FIX: Correct COPY paths with subdirectory prefixes
COPY app/main.py             ./scripts/main.py
COPY app/startup.sh          ./startup.sh
COPY app/smart-cleanup.sh ./scripts/smart-cleanup.sh

RUN chmod +x ./startup.sh ./scripts/smart-cleanup.sh

# ── Ports ──────────────────────────────────────────────────────────────────────
EXPOSE 6000/udp
EXPOSE 6001/udp
EXPOSE 18888/tcp

# ── Entrypoint ─────────────────────────────────────────────────────────────────
CMD ["/bin/bash", "/workspace/mavis/startup.sh"]
