#!/bin/bash
# smart-cleanup.sh — Container-safe process cleanup
# Only kills w-okada and clears its ports. Never touches main.py (python3 pipeline).

log() { echo "[CLEANUP] $1"; }

# Kill ONLY w-okada — matched by its specific script name, not generic 'python3'
if pgrep -f "MMVCServerSIO.py" > /dev/null; then
    log "Stopping w-okada (MMVCServerSIO.py)..."
    pkill -9 -f "MMVCServerSIO.py"
fi

# Clear w-okada's port only
log "Freeing port 18888..."
fuser -k 18888/tcp 2>/dev/null || true

log "Done. SRT pipeline (main.py) is still running."