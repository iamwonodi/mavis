#!/usr/bin/env bash
# /opt/mavis/update.sh
# Called by GitHub Actions over SSH on every successful ECR push.
# Pulls the new image, stops the old container gracefully, starts the new one.
#
# Usage: ./update.sh <ecr-registry/repo> <version-tag> <aws-region>
# Example: ./update.sh 123456789012.dkr.ecr.us-east-1.amazonaws.com/mavis v0.1.5 us-east-1

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

command -v docker      >/dev/null 2>&1 || { log "ERROR: docker not installed";    exit 1; }
command -v aws         >/dev/null 2>&1 || { log "ERROR: aws CLI not installed";   exit 1; }
command -v nvidia-smi  >/dev/null 2>&1 || { log "WARNING: nvidia-smi not found — GPU may not be available"; }

# ── ECR Authentication ─────────────────────────────────────────────────────────
# The instance IAM role (attached at TensorDock provisioning time) provides
# credentials automatically — no keys needed on disk.
log "Authenticating with ECR..."
ECR_REGISTRY=$(echo "$FULL_REPO" | cut -d'/' -f1)
aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# ── Pull new image ─────────────────────────────────────────────────────────────
log "Pulling image: ${IMAGE_URI}"
docker pull "$IMAGE_URI"

# ── Graceful stop of running container ────────────────────────────────────────
if docker ps -q --filter "name=^${CONTAINER_NAME}$" | grep -q .; then
    log "Stopping existing container '${CONTAINER_NAME}' (30s grace period)..."
    docker stop --time 30 "$CONTAINER_NAME" || true
    docker rm "$CONTAINER_NAME" || true
    log "Old container stopped and removed."
else
    log "No running container named '${CONTAINER_NAME}' found. Starting fresh."
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
    "$IMAGE_URI"

# ── Health check ──────────────────────────────────────────────────────────────
log "Waiting 15s for container to initialise..."
sleep 15

if docker ps -q --filter "name=^${CONTAINER_NAME}$" | grep -q .; then
    log "✅ Container '${CONTAINER_NAME}' is running on version ${VERSION}."
else
    log "❌ Container failed to stay running. Showing last 50 log lines:"
    docker logs --tail 50 "$CONTAINER_NAME" 2>&1 | tee -a "$LOG_FILE" || true
    exit 1
fi

# ── Clean up old images (keep last 3 versions to allow quick rollback) ─────────
log "Pruning old images (keeping last 3)..."
docker images "$FULL_REPO" --format "{{.Tag}}\t{{.ID}}" \
    | grep -v "latest\|buildcache\|${VERSION}" \
    | sort -rV \
    | tail -n +4 \
    | awk '{print $2}' \
    | xargs -r docker rmi --force 2>/dev/null || true

log "=== Update complete: ${VERSION} is live ==="
