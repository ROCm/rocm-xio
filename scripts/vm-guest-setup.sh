#!/bin/bash
# Run this script INSIDE the VM to set up development environment

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=== ROCm-AXIIO VM Guest Setup ===${NC}"
echo

if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}Error: Do not run as root${NC}"
    echo "Run as regular user (script will use sudo when needed)"
    exit 1
fi

# Update system
echo -e "${YELLOW}[1/7] Updating system packages...${NC}"
sudo apt update
sudo apt upgrade -y

# Install build essentials
echo -e "${YELLOW}[2/7] Installing build tools...${NC}"
sudo apt install -y \
    build-essential \
    cmake \
    git \
    pkg-config \
    libcli11-dev \
    linux-headers-$(uname -r) \
    vim \
    wget \
    curl \
    htop

# Install NVMe utilities
echo -e "${YELLOW}[3/7] Installing NVMe utilities...${NC}"
sudo apt install -y nvme-cli

# Install ROCm
echo -e "${YELLOW}[4/7] Installing ROCm...${NC}"
echo "This may take several minutes..."

# Add ROCm repository
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | \
    gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] \
https://repo.radeon.com/rocm/apt/6.2 $(lsb_release -cs) main" | \
    sudo tee /etc/apt/sources.list.d/rocm.list

sudo apt update
sudo apt install -y rocm-hip-sdk rocminfo || {
    echo -e "${YELLOW}⚠ ROCm installation had issues (OK if no GPU in VM)${NC}"
}

# Set environment variables
echo -e "${YELLOW}[5/7] Configuring environment...${NC}"

# Check if already added to bashrc
if ! grep -q "ROCm-AXIIO environment" ~/.bashrc; then
    cat >> ~/.bashrc << 'EOF'

# ROCm-AXIIO environment
export HSA_FORCE_FINE_GRAIN_PCIE=1
export PATH=/opt/rocm/bin:$PATH
export LD_LIBRARY_PATH=/opt/rocm/lib:$LD_LIBRARY_PATH

# Helpful aliases
alias ll='ls -lah'
alias axiio='cd ~/rocm-axiio'
alias build='make clean && make all'
alias nvmes='sudo nvme list'
EOF
    echo "✓ Environment variables added to ~/.bashrc"
else
    echo "✓ Environment already configured"
fi

# Mount shared folder
echo -e "${YELLOW}[6/7] Setting up shared folder...${NC}"
sudo mkdir -p /mnt/host

# Check if already in fstab
if ! grep -q "host0.*9p" /etc/fstab; then
    echo 'host0 /mnt/host 9p trans=virtio,version=9p2000.L,_netdev 0 0' | \
        sudo tee -a /etc/fstab > /dev/null
    echo "✓ Added to /etc/fstab"
else
    echo "✓ Already in /etc/fstab"
fi

# Try to mount now
if sudo mount -a 2>/dev/null; then
    echo "✓ Shared folder mounted at /mnt/host"
elif sudo mount -t 9p -o trans=virtio host0 /mnt/host 2>/dev/null; then
    echo "✓ Shared folder mounted at /mnt/host"
else
    echo "⚠ Shared folder will mount after reboot"
fi

# Clone/link rocm-axiio
echo -e "${YELLOW}[7/7] Setting up rocm-axiio...${NC}"

if [ -d /mnt/host/bin ] && [ -f /mnt/host/Makefile ]; then
    # Host project is available via shared folder
    if [ ! -L ~/rocm-axiio ]; then
        ln -sf /mnt/host ~/rocm-axiio
        echo "✓ Linked ~/rocm-axiio to host project"
    else
        echo "✓ Link already exists"
    fi
else
    echo "⚠ Host project not visible at /mnt/host"
    echo "You can:"
    echo "  1. Reboot and the mount should work"
    echo "  2. Clone the project: git clone <repo-url> ~/rocm-axiio"
    echo "  3. Copy files manually"
fi

echo
echo -e "${GREEN}=== Setup Complete ===${NC}"
echo
echo "Installed:"
echo "  ✓ Build tools (gcc, make, cmake)"
echo "  ✓ NVMe utilities (nvme-cli)"
echo "  ✓ ROCm runtime (hipcc)"
echo "  ✓ Development libraries"
echo
echo "Next steps:"
echo
echo "1. Reboot to apply all changes:"
echo "   ${YELLOW}sudo reboot${NC}"
echo
echo "2. After reboot, SSH back in and check:"
echo "   ${YELLOW}ssh -p 2222 <user>@localhost${NC}"
echo
echo "3. Verify shared folder:"
echo "   ${YELLOW}ls -la ~/rocm-axiio${NC}"
echo
echo "4. Build the project:"
echo "   ${YELLOW}cd ~/rocm-axiio${NC}"
echo "   ${YELLOW}make all${NC}"
echo
echo "5. Check NVMe device:"
echo "   ${YELLOW}sudo nvme list${NC}"
echo "   ${YELLOW}ls -la /dev/nvme*${NC}"
echo
echo "6. Run basic test:"
echo "   ${YELLOW}sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 10 --verbose${NC}"
echo

