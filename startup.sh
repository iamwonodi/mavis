#!/usr/bin/env bash
# startup.sh — Mavis container entrypoint
# Starts w-okada voice changer, then launches the GStreamer bridge pipeline.
# w-okada runs in the background; main.py runs in the foreground.

set -euo pipefail

# ── CONFIGURATION ──────────────────────────────────────────────────────────────
WOKADA_DIR="/workspace/voice-changer/server"
LOG_FILE="/workspace/mavis/wokada.log"
MAIN_SCRIPT="/workspace/mavis/scripts/main.py"

WOKADA_ARGS=(
    "--server_mode" "true"
    "--f0_detector"  "fcpe"
    "--chunk_size"   "128"
    "--extra_time"   "2.0"
    "--port"         "18888"
    "--host"         "0.0.0.0"
)

# ── HELPERS ────────────────────────────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

kill_old_wokada() {
    log "Killing any existing w-okada instances..."
    pkill -f "MMVCServerSIO.py" || true
    sleep 1
}

start_wokada() {
    log "Starting w-okada server (background)..."
    cd "$WOKADA_DIR" || { log "ERROR: Cannot cd to $WOKADA_DIR"; exit 1; }
    nohup python3 MMVCServerSIO.py "${WOKADA_ARGS[@]}" > "$LOG_FILE" 2>&1 &
    local pid=$!
    log "w-okada launched (PID ${pid}). Waiting 20s for model load..."
    sleep 20
}

wait_for_wokada() {
    log "Verifying w-okada WebSocket is reachable on port 18888..."
    local retries=24
    while ! curl -sf http://localhost:18888/ > /dev/null 2>&1; do
        retries=$((retries - 1))
        if [ "$retries" -le 0 ]; then
            log "WARNING: w-okada did not respond in time. main.py will use bypass mode."
            break
        fi
        log "Waiting for w-okada... ($retries retries left)"
        sleep 5
    done
}

load_model() {
    log "Loading voice model into w-okada slot 0..."
    cd "$WOKADA_DIR" || return

    mkdir -p upload_dir

    # Only download if not already present in upload_dir
    if [ ! -f "upload_dir/kikoto_mahiro_v2_40k_simple.onnx" ]; then
        log "Downloading kikoto_mahiro model..."
        wget -q "https://huggingface.co/wok000/vcclient_model/resolve/main/rvc_v2_alpha/kikoto_mahiro/kikoto_mahiro_v2_40k_simple.onnx" \
            -O upload_dir/kikoto_mahiro_v2_40k_simple.onnx \
            && log "Model downloaded." \
            || { log "WARNING: Model download failed."; return; }
    else
        log "Model already in upload_dir. Skipping download."
    fi

    curl -s -X POST http://localhost:18888/load_model \
        -F "slot=0" \
        -F "isHalf=false" \
        -F 'params={"voiceChangerType":"RVC","slot":0,"isSampleMode":false,"sampleId":"","files":[{"name":"kikoto_mahiro_v2_40k_simple.onnx","kind":"rvcModel","dir":""}],"params":{}}' \
        > /dev/null 2>&1

    curl -s -X POST http://localhost:18888/update_settings \
        -F "key=modelSlotIndex" -F "val=0" > /dev/null 2>&1

    curl -s -X POST http://localhost:18888/update_settings \
        -F "key=gpu" -F "val=0" > /dev/null 2>&1

    log "Voice model loaded and activated."
    cd - > /dev/null
}

show_gpu() {
    log "GPU status:"
    nvidia-smi || log "nvidia-smi not found — ensure NVIDIA drivers are accessible."
    echo "────────────────────────────────────────────"
}

show_wokada_logs() {
    log "Last 30 lines of wokada.log:"
    echo "────────────────────────────────────────────"
    tail -n 30 "$LOG_FILE" 2>/dev/null || log "(Log not available yet)"
    echo "────────────────────────────────────────────"
}

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
