#!/bin/bash
# =============================================================================
# Mavis startup script
# Runs inside the Docker container as the CMD entrypoint.
# Order: kill old w-okada → start w-okada → wait → load model → run main.py
# =============================================================================

set -euo pipefail

# ── CONFIGURATION ──────────────────────────────────────────────────────────────
WOKADA_DIR="/workspace/voice-changer/server"
WOKADA_LOG="/workspace/mavis/wokada.log"
MAIN_SCRIPT="/workspace/mavis/scripts/main.py"
WOKADA_PORT=18888

WOKADA_ARGS=(
    "--server_mode" "true"
    "--f0_detector"  "fcpe"
    "--chunk_size"   "3200"
    "--extra_time"   "2.0"
    "--port"         "$WOKADA_PORT"
    "--host"         "0.0.0.0"
)

# ── HELPERS ────────────────────────────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ── Kill any leftover w-okada processes ───────────────────────────────────────
kill_old_wokada() {
    log "Killing any existing w-okada instances..."
    pkill -f "MMVCServerSIO.py" || true
    sleep 1
}

# ── Start w-okada in background ───────────────────────────────────────────────
start_wokada() {
    log "Starting w-okada server (background)..."
    cd "$WOKADA_DIR" || { log "ERROR: Cannot cd to $WOKADA_DIR"; exit 1; }
    nohup python3 MMVCServerSIO.py "${WOKADA_ARGS[@]}" > "$WOKADA_LOG" 2>&1 &
    local pid=$!
    log "w-okada launched (PID ${pid}). Waiting 20s for model load..."
    sleep 20
}

# ── Wait for w-okada to be ready on port 18888 ────────────────────────────────
wait_for_wokada() {
    log "Verifying w-okada WebSocket is reachable on port $WOKADA_PORT..."
    local retries=23
    while [ $retries -gt 0 ]; do
        if (echo > /dev/tcp/localhost/$WOKADA_PORT) 2>/dev/null; then
            log "w-okada is ready on port $WOKADA_PORT."
            return 0
        fi
        log "Waiting for w-okada... ($retries retries left)"
        sleep 5
        retries=$((retries - 1))
    done
    log "WARNING: w-okada did not respond in time. Continuing anyway..."
}

# ── Load voice model ──────────────────────────────────────────────────────────
# Volume mount: /home/user/wokada-models → upload_dir inside container
#
# Model priority:
#   1. main_*.pth   — custom pth model, highest priority
#   2. main_*.onnx  — custom onnx model, second priority
#   3. default_*.pth — default pth model
#   4. default_*.onnx — default onnx model
#   5. Download TheAnimeMan as last resort if volume is empty
#
# Index file (.index) is automatically paired with .pth if present
# Index improves voice similarity quality significantly
#
# To swap voices: place main_yourmodel.pth + main_yourmodel.index
#   in /home/user/wokada-models/ and restart container
# To revert to default: remove main_* files and restart container
load_model() {
    log "Loading voice model into w-okada slot 0..."
    cd "$WOKADA_DIR" || return

    mkdir -p upload_dir

    # Priority 1 — custom pth model placed by user in volume
    MODEL_FILE=$(find upload_dir -maxdepth 1 -name "main_*.pth" 2>/dev/null | head -1)
    INDEX_FILE=$(find upload_dir -maxdepth 1 -name "main_*.index" 2>/dev/null | head -1)


    # Priority 2 — default pth model
    if [ -z "$MODEL_FILE" ]; then
        MODEL_FILE=$(find upload_dir -maxdepth 1 -name "default_*.pth" 2>/dev/null | head -1)
        INDEX_FILE=$(find upload_dir -maxdepth 1 -name "default_*.index" 2>/dev/null | head -1)
    fi

    # Priority 3 — custom onnx model placed by user in volume
    if [ -z "$MODEL_FILE" ]; then
        MODEL_FILE=$(find upload_dir -maxdepth 1 -name "main_*.onnx" 2>/dev/null | head -1)
    fi

    # Priority 4 — default onnx model
    if [ -z "$MODEL_FILE" ]; then
        MODEL_FILE=$(find upload_dir -maxdepth 1 -name "default_*.onnx" 2>/dev/null | head -1)
    fi

    # Priority 5 — nothing in volume, download TheAnimeMan as default
    # TheAnimeMan is RVC V2 40k — compatible with our 40000Hz pipeline
    # Comes with both .pth and .index for best quality output
    if [ -z "$MODEL_FILE" ]; then
        log "No model found in upload_dir. Downloading default TheAnimeMan model..."
        wget -q \
            "https://huggingface.co/0x3e9/TheAnimeMan_RVC/resolve/main/theanimeman.zip" \
            -O /tmp/theanimeman.zip \
            && log "Default model downloaded." \
            || { log "WARNING: Model download failed. Voice conversion unavailable."; cd - > /dev/null; return; }

        unzip -o /tmp/theanimeman.zip -d upload_dir/ > /dev/null 2>&1

        # Rename to default_ prefix so priority system works correctly
        mv upload_dir/theanimeman.pth upload_dir/default_theanimeman.pth 2>/dev/null || true
        mv upload_dir/*.index upload_dir/default_theanimeman.index 2>/dev/null || true
        rm -f /tmp/theanimeman.zip

        MODEL_FILE="upload_dir/default_theanimeman.pth"
        INDEX_FILE="upload_dir/default_theanimeman.index"
    fi

    MODEL_NAME=$(basename "$MODEL_FILE")
    INDEX_NAME=$(basename "$INDEX_FILE" 2>/dev/null || echo "")

    log "Loading model: $MODEL_NAME"

    # Build load_model params
    # Include index file if present — improves voice similarity significantly
    # w-okada moves files from upload_dir to model_dir/0/ internally after loading
    if [ -n "$INDEX_NAME" ] && [ -f "upload_dir/$INDEX_NAME" ]; then
        log "Loading with index: $INDEX_NAME"
        PARAMS="{\"voiceChangerType\":\"RVC\",\"slot\":0,\"isSampleMode\":false,\"sampleId\":\"\",\"files\":[{\"name\":\"$MODEL_NAME\",\"kind\":\"rvcModel\",\"dir\":\"\"},{\"name\":\"$INDEX_NAME\",\"kind\":\"rvcIndex\",\"dir\":\"\"}],\"params\":{}}"
    else
        PARAMS="{\"voiceChangerType\":\"RVC\",\"slot\":0,\"isSampleMode\":false,\"sampleId\":\"\",\"files\":[{\"name\":\"$MODEL_NAME\",\"kind\":\"rvcModel\",\"dir\":\"\"}],\"params\":{}}"
    fi

    # Load model into slot 0
    # w-okada moves the file from upload_dir to model_dir/0/ internally
    curl -s -X POST "http://localhost:$WOKADA_PORT/load_model" \
        -F "slot=0" \
        -F "isHalf=false" \
        -F "params=$PARAMS" \
        > /dev/null 2>&1

    sleep 3

    # Activate model on GPU slot 0
    curl -s -X POST "http://localhost:$WOKADA_PORT/update_settings" \
        -F "key=modelSlotIndex" -F "val=0" > /dev/null 2>&1

    # Use RTX 3090 (GPU id 0)
    curl -s -X POST "http://localhost:$WOKADA_PORT/update_settings" \
        -F "key=gpu" -F "val=0" > /dev/null 2>&1

    # Use FCPE pitch detector for highest quality real-time conversion
    curl -s -X POST "http://localhost:$WOKADA_PORT/update_settings" \
        -F "key=f0Detector" -F "val=fcpe" > /dev/null 2>&1

    # Full crossfade coverage — eliminates gaps at chunk boundaries
    curl -s -X POST "http://localhost:$WOKADA_PORT/update_settings" \
        -F "key=crossFadeOffsetRate" -F "val=0.0" > /dev/null 2>&1

    curl -s -X POST "http://localhost:$WOKADA_PORT/update_settings" \
        -F "key=crossFadeEndRate" -F "val=1.0" > /dev/null 2>&1

    log "Model loaded and activated: $MODEL_NAME"
    cd - > /dev/null
}

show_gpu() {
    log "GPU status:"
    nvidia-smi || log "nvidia-smi not found — ensure NVIDIA drivers are accessible."
    echo "────────────────────────────────────────────"
}

# ── Show recent wokada log ─────────────────────────────────────────────────────
show_wokada_logs() {
    echo "────────────────────────────────────────────"
    log "Last 30 lines of wokada.log:"
    echo "────────────────────────────────────────────"
    tail -n 30 "$WOKADA_LOG" 2>/dev/null || log "(Log not available yet)"
    echo "────────────────────────────────────────────"
}

# ── Launch main.py GStreamer pipeline ─────────────────────────────────────────
run_main() {
    log "Launching main.py GStreamer pipeline (foreground)..."
    cd /workspace/mavis || exit 1
    python3 "$MAIN_SCRIPT"
}

# ── MAIN ───────────────────────────────────────────────────────────────────────
log "=== Mavis Startup ==="
kill_old_wokada
start_wokada
show_gpu
show_wokada_logs
wait_for_wokada
load_model
run_main

log "=== Mavis Exited ==="
