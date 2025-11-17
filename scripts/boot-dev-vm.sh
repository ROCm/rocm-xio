#!/bin/bash
# Boot the development VM with NVMe emulation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_DIR="$PROJECT_DIR/vm-images"
VM_NAME="rocm-axiio-dev"

VM_DISK="$VM_DIR/${VM_NAME}.qcow2"
NVME_DISK="$VM_DIR/${VM_NAME}-nvme.img"

# Configuration (can be overridden by environment variables)
MEMORY="${VM_MEMORY:-8G}"
CPUS="${VM_CPUS:-4}"
SSH_PORT="${VM_SSH_PORT:-2222}"

# Check if VM disk exists
if [ ! -f "$VM_DISK" ]; then
    echo "Error: VM disk not found: $VM_DISK"
    echo "Run ./scripts/create-dev-vm.sh first"
    exit 1
fi

echo "=== Booting ROCm-AXIIO Development VM ==="
echo
echo "Configuration:"
echo "  Memory: $MEMORY"
echo "  CPUs: $CPUS"
echo "  VM Disk: $VM_DISK"
echo "  NVMe Disk: $NVME_DISK"
echo
echo "Access:"
echo "  SSH: ssh -p $SSH_PORT <user>@localhost"
echo "  Serial console: Ctrl+A, X to quit"
echo
echo "Environment variables to customize:"
echo "  VM_MEMORY=16G    - Set RAM (default: 8G)"
echo "  VM_CPUS=8        - Set CPUs (default: 4)"
echo "  VM_SSH_PORT=2223 - Set SSH port (default: 2222)"
echo "  VM_USE_VNC=1     - Enable VNC display"
echo
echo "Starting VM in 3 seconds..."
sleep 3

# Build QEMU command
QEMU_CMD=(
    qemu-system-x86_64
    -enable-kvm
    -cpu host
    -m "$MEMORY"
    -smp "$CPUS"
)

# Add main disk
QEMU_CMD+=(
    -drive "file=$VM_DISK,format=qcow2,if=virtio,cache=writeback"
)

# Add emulated NVMe
if [ -f "$NVME_DISK" ]; then
    QEMU_CMD+=(
        -drive "file=$NVME_DISK,if=none,id=nvm0,format=raw"
        -device "nvme,serial=axiiodev001,drive=nvm0"
    )
    echo "✓ NVMe device will be available as /dev/nvme0"
fi

# Network with SSH port forwarding
QEMU_CMD+=(
    -net nic,model=virtio
    -net "user,hostfwd=tcp::${SSH_PORT}-:22"
)

# Shared folder (host project directory -> guest /mnt/host)
if [ -d "$PROJECT_DIR" ]; then
    QEMU_CMD+=(
        -virtfs "local,path=$PROJECT_DIR,mount_tag=host0,security_model=passthrough,id=host0"
    )
    echo "✓ Shared folder: $PROJECT_DIR -> /mnt/host"
fi

# Display (serial console by default, VNC optional)
if [ -n "${VM_USE_VNC:-}" ]; then
    QEMU_CMD+=(-vnc ":0")
    echo "✓ VNC enabled on localhost:5900"
else
    QEMU_CMD+=(-nographic)
fi

echo
echo "Starting VM..."
echo

# Check if we need sudo for KVM access
if [ -w /dev/kvm ]; then
    exec "${QEMU_CMD[@]}"
else
    echo "Note: Running with sudo for /dev/kvm access"
    exec sudo "${QEMU_CMD[@]}"
fi

