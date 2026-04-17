#!/usr/bin/env bash
# =============================================================================
# /opt/mavis/update.sh
# Called by GitHub Actions over SSH on every successful ECR push.
# Pulls the latest image, stops the old container gracefully, starts the new one.
#
# Usage: bash update.sh <ecr-registry/repo> <version-tag> <aws-region>
# =============================================================================

set -euo pipefail

# ── Arguments ──────────────────────────────────────────────────────────────────
FULL_REPO="${1:?Usage: update.sh <ecr-registry/repo> <version> <aws-region>}"
VERSION="${2:?Missing version argument}"
AWS_REGION="${3:?Missing AWS region argument}"

IMAGE_URI="${FULL_REPO}:${VERSION}"
CONTAINER_NAME="mavis"
LOG_FILE="/var/log/mavis-deploy.log"

# ── Logging ────────────────────────────────────────────────────────────────────
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# ── Pre-flight checks ──────────────────────────────────────────────────────────
log "=== Mavis Update: ${VERSION} ==="

command -v docker >/dev/null 2>&1 || { log "ERROR: docker not installed"; exit 1; }
command -v aws    >/dev/null 2>&1 || { log "ERROR: aws CLI not installed"; exit 1; }

# nvidia-smi check is informational only — never fails the script
if command -v nvidia-smi >/dev/null 2>&1; then
    log "GPU detected: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null)"
else
    log "WARNING: nvidia-smi not found — GPU may not be available"
fi

# ── ECR Authentication ─────────────────────────────────────────────────────────
log "Authenticating with ECR..."
ECR_REGISTRY=$(echo "$FULL_REPO" | cut -d'/' -f1)
aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY" 2>&1 \
    | grep -v "WARNING" \
    || { log "ERROR: ECR authentication failed"; exit 1; }
log "ECR authentication successful."

# ── Pull new image ─────────────────────────────────────────────────────────────
log "Pulling image: ${IMAGE_URI}"
docker pull "$IMAGE_URI" || { log "ERROR: docker pull failed"; exit 1; }
log "Image pull complete."

# ── Graceful stop of existing container ───────────────────────────────────────
# FIX: Use || true on the entire block so set -e never triggers here
# even when no container exists.
log "Checking for existing container..."
RUNNING=$(docker ps -q --filter "name=^${CONTAINER_NAME}$" 2>/dev/null || true)
STOPPED=$(docker ps -aq --filter "name=^${CONTAINER_NAME}$" 2>/dev/null || true)

if [ -n "$RUNNING" ]; then
    log "Stopping running container '${CONTAINER_NAME}'..."
    docker stop --time 30 "$CONTAINER_NAME" || true
    docker rm "$CONTAINER_NAME" || true
    log "Old container stopped and removed."
elif [ -n "$STOPPED" ]; then
    log "Removing stopped container '${CONTAINER_NAME}'..."
    docker rm "$CONTAINER_NAME" || true
    log "Old container removed."
else
    log "No existing container found. Starting fresh."
fi

# ── Start new container ────────────────────────────────────────────────────────
log "Starting new container: ${IMAGE_URI}"
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --gpus all \
    --network host \
    --log-driver json-file \
    --log-opt max-size=50m \
    --log-opt max-file=3 \
    -v /home/user/wokada-models:/workspace/voice-changer/server/upload_dir \
    -v /home/user/wokada-pretrain:/workspace/voice-changer/server/pretrain \
    "$IMAGE_URI"

# ── Health check ──────────────────────────────────────────────────────────────
log "Waiting 15s for container to initialise..."
sleep 15

HEALTH=$(docker ps -q --filter "name=^${CONTAINER_NAME}$" 2>/dev/null || true)
if [ -n "$HEALTH" ]; then
    log "✅ Container '${CONTAINER_NAME}' is running on version ${VERSION}."
else
    log "❌ Container failed to stay running. Last 50 log lines:"
    docker logs --tail 50 "$CONTAINER_NAME" 2>&1 | tee -a "$LOG_FILE" || true
    exit 1
fi

# ── Clean up old images (keep last 3 for rollback) ────────────────────────────
log "Pruning old images (keeping last 3)..."
docker images "$FULL_REPO" --format "{{.Tag}}\t{{.ID}}" \
    | grep -v "latest\|buildcache\|${VERSION}" \
    | sort -rV \
    | tail -n +4 \
    | awk '{print $2}' \
    | xargs -r docker rmi --force 2>/dev/null || true

log "=== Update complete: ${VERSION} is live ==="
