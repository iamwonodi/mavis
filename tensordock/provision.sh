#!/usr/bin/env bash
# =============================================================================
# provision.sh — One-time setup for Mavis on a TensorDock KVM instance
# Run this once immediately after provisioning your instance.
# Tested on Ubuntu 22.04 with NVIDIA GPU passthrough.
# =============================================================================

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No colour

log()     { echo -e "${GREEN}[PROVISION]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
divider() { echo "─────────────────────────────────────────────────────────────"; }

# ── Must run as root ───────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root. Try: sudo bash provision.sh"
fi

divider
log "Starting Mavis instance provisioning..."
divider

# =============================================================================
# STEP 1 — System update
# =============================================================================
log "Updating system packages..."
apt-get update -y
apt-get upgrade -y
apt-get install -y \
    curl \
    wget \
    git \
    unzip \
    gnupg \
    ca-certificates \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    psmisc \
    nano
log "System packages updated."
divider

# =============================================================================
# STEP 2 — Docker
# Installs Docker Engine via the official Docker apt repository.
# This is the correct method — NOT snap, NOT distro Docker (outdated).
# =============================================================================
log "Installing Docker..."

# Remove any old or distro-packaged Docker versions first
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker's official apt repository
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

# Enable and start Docker
systemctl enable docker
systemctl start docker

# Verify
docker --version || error "Docker installation failed."
log "Docker installed successfully."
divider

# =============================================================================
# STEP 3 — NVIDIA Container Toolkit
# Allows Docker to access the GPU via --gpus all.
# Without this, the container cannot see the RTX 4090.
# =============================================================================
log "Installing NVIDIA Container Toolkit..."

# Add NVIDIA's official apt repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update -y
apt-get install -y nvidia-container-toolkit

# Configure Docker to use the NVIDIA runtime
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# Verify GPU is visible to Docker
log "Verifying GPU access inside Docker..."
docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi \
    || warn "GPU test failed. Verify NVIDIA drivers are installed on the host."

log "NVIDIA Container Toolkit installed."
divider

# =============================================================================
# STEP 4 — AWS CLI v2
# Installs the official AWS CLI v2 binary.
# The apt package (awscli) installs v1 which is outdated — we want v2.
# =============================================================================
log "Installing AWS CLI v2..."

# Download and install
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
    -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install --update
rm -rf awscliv2.zip aws/
cd -

# Verify
aws --version || error "AWS CLI installation failed."
log "AWS CLI v2 installed."
divider

# =============================================================================
# STEP 5 — Configure AWS credentials for ECR pull
# This sets up the read-only IAM credentials so the instance can pull
# images from your private ECR registry.
# You will be prompted to enter your credentials interactively.
# =============================================================================
log "Configuring AWS credentials..."
warn "You will now be prompted to enter your AWS credentials."
warn "Use the Access Key ID and Secret Access Key from the read-only"
warn "IAM user you created in the AWS dashboard setup (MavisInstanceRole)."
echo ""
aws configure
log "AWS credentials configured."
divider

# =============================================================================
# STEP 6 — Create the Mavis update script directory and log file
# =============================================================================
log "Setting up Mavis deployment infrastructure..."

mkdir -p /opt/mavis
touch /var/log/mavis-deploy.log
chmod 644 /var/log/mavis-deploy.log

log "Mavis directories created."
divider

# =============================================================================
# STEP 7 — Copy update.sh into place
# update.sh must exist in the same directory as this script when you run it,
# OR you can paste its content manually after provisioning.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${SCRIPT_DIR}/update.sh" ]; then
    cp "${SCRIPT_DIR}/update.sh" /opt/mavis/update.sh
    chmod +x /opt/mavis/update.sh
    log "update.sh copied to /opt/mavis/update.sh"
else
    warn "update.sh not found next to provision.sh."
    warn "Copy it manually: cp update.sh /opt/mavis/update.sh && chmod +x /opt/mavis/update.sh"
fi
divider

# =============================================================================
# STEP 8 — Final verification summary
# =============================================================================
divider
log "Provisioning complete. Verification summary:"
echo ""
echo "  Docker:      $(docker --version)"
echo "  AWS CLI:     $(aws --version)"
echo "  nvidia-smi:  $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo 'not available')"
echo "  update.sh:   $([ -f /opt/mavis/update.sh ] && echo 'present at /opt/mavis/update.sh' || echo 'MISSING — copy manually')"
echo "  Log file:    $([ -f /var/log/mavis-deploy.log ] && echo 'present' || echo 'MISSING')"
echo ""
log "Your instance is ready. Push to main on GitHub to trigger your first deployment."
divider
