#!/usr/bin/env bash
# =============================================================================
# provision.sh — Idempotent one-time setup for Mavis on TensorDock KVM
# Safe to run multiple times — skips anything already installed.
# Tested on Ubuntu 22.04 with NVIDIA GPU passthrough.
# =============================================================================

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${GREEN}[PROVISION]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
skip()    { echo -e "${CYAN}[SKIP]${NC} $1 — already installed."; }
divider() { echo "─────────────────────────────────────────────────────────────"; }

# ── Must run as root ───────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root. Try: sudo bash provision.sh"
fi

# ── Detect the actual non-root user who will run Docker ───────────────────────
# When running via sudo, SUDO_USER is the original user.
# Falls back to 'user' which is the default TensorDock SSH username.
ACTUAL_USER="${SUDO_USER:-user}"
REBOOT_REQUIRED=false
log "Configuring for user: ${ACTUAL_USER}"

divider
log "Starting idempotent Mavis provisioning..."
divider

# =============================================================================
# STEP 1 — System update and base packages (includes tmux)
# =============================================================================
log "Checking base packages..."

REQUIRED_PKGS=(curl wget git unzip gnupg ca-certificates lsb-release
               software-properties-common apt-transport-https psmisc nano tmux)

MISSING_PKGS=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -eq 0 ]; then
    skip "All base packages"
else
    log "Installing missing packages: ${MISSING_PKGS[*]}"
    apt-get update -y
    apt-get install -y "${MISSING_PKGS[@]}"
fi

log "Base packages ready."
divider

# =============================================================================
# STEP 2 — NVIDIA Drivers + nvidia-smi
# Auto-detects recommended driver. Skips if already present.
# =============================================================================
log "Checking NVIDIA drivers..."

if command -v nvidia-smi >/dev/null 2>&1; then
    skip "NVIDIA drivers"
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
else
    log "NVIDIA drivers not found. Detecting and installing..."

    apt-get install -y ubuntu-drivers-common

    RECOMMENDED=$(ubuntu-drivers devices 2>/dev/null \
        | grep recommended \
        | awk '{print $3}' \
        | head -1)

    if [ -z "$RECOMMENDED" ]; then
        warn "Could not auto-detect driver. Falling back to nvidia-driver-525."
        RECOMMENDED="nvidia-driver-525"
    fi

    log "Installing: ${RECOMMENDED}"
    apt-get install -y "$RECOMMENDED"

    # Install matching nvidia-utils so nvidia-smi is available
    UTILS_PKG=$(echo "$RECOMMENDED" | sed 's/nvidia-driver/nvidia-utils/')
    apt-get install -y "$UTILS_PKG" || apt-get install -y nvidia-utils-525

    log "NVIDIA drivers installed."
    REBOOT_REQUIRED=true
fi
divider

# =============================================================================
# STEP 3 — Docker (official repo, not distro package)
# =============================================================================
log "Checking Docker..."

if command -v docker >/dev/null 2>&1; then
    skip "Docker ($(docker --version))"
else
    log "Installing Docker from official repository..."

    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    docker --version || error "Docker installation failed."
    log "Docker installed."
fi

# Always ensure ACTUAL_USER is in docker group — idempotent
if groups "$ACTUAL_USER" 2>/dev/null | grep -q docker; then
    skip "User ${ACTUAL_USER} already in docker group"
else
    log "Adding ${ACTUAL_USER} to docker group..."
    usermod -aG docker "$ACTUAL_USER"
    log "Done."
fi
divider

# =============================================================================
# STEP 4 — NVIDIA Container Toolkit
# =============================================================================
log "Checking NVIDIA Container Toolkit..."

if dpkg -l nvidia-container-toolkit 2>/dev/null | grep -q "^ii"; then
    skip "NVIDIA Container Toolkit"
else
    log "Installing NVIDIA Container Toolkit..."

    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update -y
    apt-get install -y nvidia-container-toolkit

    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker

    log "NVIDIA Container Toolkit installed."
fi
divider

# =============================================================================
# STEP 5 — AWS CLI v2
# =============================================================================
log "Checking AWS CLI..."

if command -v aws >/dev/null 2>&1; then
    skip "AWS CLI ($(aws --version 2>&1 | head -1))"
else
    log "Installing AWS CLI v2..."
    cd /tmp
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
        -o "awscliv2.zip"
    unzip -q awscliv2.zip
    ./aws/install --update
    rm -rf awscliv2.zip aws/
    cd -
    aws --version || error "AWS CLI installation failed."
    log "AWS CLI v2 installed."
fi
divider

# =============================================================================
# STEP 6 — AWS credentials
# Skips if credentials file already exists and has content.
# =============================================================================
log "Checking AWS credentials..."

AWS_CREDS_FILE="/home/${ACTUAL_USER}/.aws/credentials"

if [ -f "$AWS_CREDS_FILE" ] && grep -q "aws_access_key_id" "$AWS_CREDS_FILE"; then
    skip "AWS credentials already configured for ${ACTUAL_USER}"
else
    log "AWS credentials not found for ${ACTUAL_USER}."
    warn "You will now be prompted to enter your ECR pull-only IAM credentials."
    warn "Enter the Access Key ID and Secret Access Key for tensordock-mavis."
    echo ""
    sudo -u "$ACTUAL_USER" aws configure
    log "AWS credentials configured."
fi
divider

# =============================================================================
# STEP 7 — Mavis deployment infrastructure
# =============================================================================
log "Checking Mavis deployment infrastructure..."

[ -d "/opt/mavis" ] && skip "/opt/mavis directory" || { mkdir -p /opt/mavis; log "Created /opt/mavis"; }

if [ ! -f "/var/log/mavis-deploy.log" ]; then
    touch /var/log/mavis-deploy.log
    log "Created /var/log/mavis-deploy.log"
else
    skip "/var/log/mavis-deploy.log"
fi

# Always enforce correct permissions
chmod 666 /var/log/mavis-deploy.log

# Copy update.sh from alongside this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/update.sh" ]; then
    cp "${SCRIPT_DIR}/update.sh" /opt/mavis/update.sh
    chmod +x /opt/mavis/update.sh
    log "update.sh deployed to /opt/mavis/update.sh"
else
    warn "update.sh not found next to provision.sh — copy it manually."
fi
divider

# =============================================================================
# FINAL SUMMARY
# =============================================================================
divider
log "Provisioning complete. Summary:"
echo ""
echo "  tmux:            $(tmux -V 2>/dev/null || echo 'NOT FOUND')"
echo "  Docker:          $(docker --version 2>/dev/null || echo 'NOT FOUND')"
echo "  AWS CLI:         $(aws --version 2>&1 | head -1 || echo 'NOT FOUND')"
echo "  nvidia-smi:      $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo 'NOT AVAILABLE — reboot required if just installed')"
echo "  update.sh:       $([ -f /opt/mavis/update.sh ] && echo 'present at /opt/mavis/update.sh' || echo 'MISSING')"
echo "  Log file:        $([ -f /var/log/mavis-deploy.log ] && echo 'present and writable' || echo 'MISSING')"
echo "  Docker group:    $(groups $ACTUAL_USER 2>/dev/null | grep -q docker && echo "${ACTUAL_USER} is in docker group" || echo "NOT SET — re-login required")"
echo ""

if [ "$REBOOT_REQUIRED" = "true" ]; then
    warn "NVIDIA drivers were just installed. Reboot the instance to activate them:"
    warn "  sudo reboot"
    warn "After reboot run: nvidia-smi"
    warn "Then re-run this script to verify everything is clean."
else
    log "No reboot required. Instance is fully ready."
fi
divider
