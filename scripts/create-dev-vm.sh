#!/bin/bash
# Create a development VM for rocm-axiio testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_DIR="$PROJECT_DIR/vm-images"
VM_NAME="rocm-axiio-dev"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== ROCm-AXIIO Development VM Setup ===${NC}"
echo

# Create directories
mkdir -p "$VM_DIR"
cd "$VM_DIR"

# Check for Ubuntu ISO
UBUNTU_ISO="ubuntu-24.04-server-amd64.iso"
UBUNTU_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.1-live-server-amd64.iso"

if [ ! -f "$UBUNTU_ISO" ]; then
    echo -e "${YELLOW}Ubuntu 24.04 ISO not found${NC}"
    echo "You can download it from:"
    echo "  $UBUNTU_URL"
    echo
    read -p "Download now? (y/n): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Downloading Ubuntu 24.04 ISO (2.6GB)...${NC}"
        echo "This may take 10-20 minutes depending on connection speed"
        wget "$UBUNTU_URL" -O "$UBUNTU_ISO" || {
            echo "Download failed. You can manually download and place it in: $VM_DIR/$UBUNTU_ISO"
            exit 1
        }
        echo -e "${GREEN}✓ ISO downloaded${NC}"
    else
        echo "Please download manually and place in: $VM_DIR/$UBUNTU_ISO"
        exit 0
    fi
else
    echo -e "${GREEN}✓ Using existing ISO: $UBUNTU_ISO${NC}"
fi

# Create VM disk (50GB)
VM_DISK="${VM_NAME}.qcow2"
if [ ! -f "$VM_DISK" ]; then
    echo -e "${YELLOW}Creating VM disk (50GB, thin-provisioned)...${NC}"
    qemu-img create -f qcow2 "$VM_DISK" 50G
    echo -e "${GREEN}✓ VM disk created${NC}"
else
    echo -e "${GREEN}✓ Using existing VM disk${NC}"
fi

# Create emulated NVMe disk (10GB)
NVME_DISK="${VM_NAME}-nvme.img"
if [ ! -f "$NVME_DISK" ]; then
    echo -e "${YELLOW}Creating emulated NVMe disk (10GB)...${NC}"
    qemu-img create -f raw "$NVME_DISK" 10G
    echo -e "${GREEN}✓ NVMe disk created${NC}"
else
    echo -e "${GREEN}✓ Using existing NVMe disk${NC}"
fi

echo
echo -e "${GREEN}=== VM Setup Complete ===${NC}"
echo
echo "VM Configuration:"
echo "  Name: $VM_NAME"
echo "  Disk: $VM_DISK (50GB)"
echo "  NVMe: $NVME_DISK (10GB)"
echo "  Memory: 8GB"
echo "  CPUs: 4 cores"
echo
echo "Next step: Install Ubuntu"
echo
echo "Option 1: Graphical installer (recommended):"
echo -e "  ${YELLOW}sudo qemu-system-x86_64 \\${NC}"
echo -e "    ${YELLOW}-enable-kvm -cpu host -m 8G -smp 4 \\${NC}"
echo -e "    ${YELLOW}-drive file=$VM_DIR/$VM_DISK,format=qcow2,if=virtio \\${NC}"
echo -e "    ${YELLOW}-cdrom $VM_DIR/$UBUNTU_ISO \\${NC}"
echo -e "    ${YELLOW}-boot d \\${NC}"
echo -e "    ${YELLOW}-net nic,model=virtio -net user \\${NC}"
echo -e "    ${YELLOW}-vnc :0${NC}"
echo
echo "  Then connect VNC viewer to: localhost:5900"
echo
echo "Option 2: Text installer:"
echo -e "  ${YELLOW}sudo qemu-system-x86_64 \\${NC}"
echo -e "    ${YELLOW}-enable-kvm -cpu host -m 8G -smp 4 \\${NC}"
echo -e "    ${YELLOW}-drive file=$VM_DIR/$VM_DISK,format=qcow2,if=virtio \\${NC}"
echo -e "    ${YELLOW}-cdrom $VM_DIR/$UBUNTU_ISO \\${NC}"
echo -e "    ${YELLOW}-boot d \\${NC}"
echo -e "    ${YELLOW}-net nic,model=virtio -net user \\${NC}"
echo -e "    ${YELLOW}-nographic${NC}"
echo
echo "After installation, boot with:"
echo "  ./scripts/boot-dev-vm.sh"
echo

