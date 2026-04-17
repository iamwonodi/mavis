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
    "--chunk_size"   "128"
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
    nohup python3 MMVCServerSIO.py "${WOKADA_ARGS[@]}" > "$LOG_FILE" 2>&1 &
    local pid=$!
    log "w-okada launched (PID ${pid}). Waiting 20s for model load..."
    sleep 20
}

# ── Wait for w-okada to be ready on port 18888 ────────────────────────────────
wait_for_wokada() {
    log "Verifying w-okada WebSocket is reachable on port $WOKADA_PORT..."
    local retries=23
    while [ $retries -gt 0 ]; do
        if nc -z localhost "$WOKADA_PORT" 2>/dev/null; then
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
#   1. main_*.onnx  — custom model, takes priority when present
#   2. default_*.onnx — fallback model, always present
#   3. Download kikoto_mahiro as last resort if volume is empty
#
# To swap voices: place main_yourmodel.onnx in /home/user/wokada-models/
# To revert to default: remove the main_*.onnx file and restart container
load_model() {
    log "Loading voice model into w-okada slot 0..."
    cd "$WOKADA_DIR" || return

    mkdir -p upload_dir

    # Priority 1: custom model
    MODEL_FILE=$(find upload_dir -maxdepth 1 -name "main_*.onnx" 2>/dev/null | head -1)

    # Priority 2: default model
    if [ -z "$MODEL_FILE" ]; then
        MODEL_FILE=$(find upload_dir -maxdepth 1 -name "default_*.onnx" 2>/dev/null | head -1)
    fi

    # Priority 3: nothing in volume — download fallback
    if [ -z "$MODEL_FILE" ]; then
        log "No model found in upload_dir. Downloading default model..."
        wget -q \
            "https://huggingface.co/wok000/vcclient_model/resolve/main/rvc_v2_alpha/kikoto_mahiro/kikoto_mahiro_v2_40k_simple.onnx" \
            -O "upload_dir/default_kikoto_mahiro.onnx" \
            && log "Default model downloaded." \
            || { log "WARNING: Model download failed. Voice conversion unavailable."; cd - > /dev/null; return; }
        MODEL_FILE="upload_dir/default_kikoto_mahiro.onnx"
    fi

    MODEL_NAME=$(basename "$MODEL_FILE")
    log "Loading model: $MODEL_NAME"

    # Load model into slot 0
    # w-okada moves the file from upload_dir to model_dir/0/ internally
    curl -s -X POST "http://localhost:$WOKADA_PORT/load_model" \
        -F "slot=0" \
        -F "isHalf=false" \
        -F "params={\"voiceChangerType\":\"RVC\",\"slot\":0,\"isSampleMode\":false,\"sampleId\":\"\",\"files\":[{\"name\":\"$MODEL_NAME\",\"kind\":\"rvcModel\",\"dir\":\"\"}],\"params\":{}}" \
        > /dev/null 2>&1

    sleep 3

    # Activate model on GPU slot 0
    curl -s -X POST "http://localhost:$WOKADA_PORT/update_settings" \
        -F "key=modelSlotIndex" -F "val=0" > /dev/null 2>&1

    # Use RTX 3090 (GPU id 0)
    curl -s -X POST "http://localhost:$WOKADA_PORT/update_settings" \
        -F "key=gpu" -F "val=0" > /dev/null 2>&1

    # Use FCPE pitch detector for highest quality conversion
    curl -s -X POST "http://localhost:$WOKADA_PORT/update_settings" \
        -F "key=f0Detector" -F "val=fcpe" > /dev/null 2>&1

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
