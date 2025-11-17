#!/bin/bash
# Test AMD P2P Capability Injection in QEMU
# This script launches a VM with AMD P2P clique support

set -e

QEMU_BIN="/opt/qemu-10.1.2-amd-p2p/bin/qemu-system-x86_64"
VM_IMAGE="/home/stebates/Projects/qemu-minimal/images/rocm-axiio.qcow2"
VERIFY_SCRIPT="/home/stebates/Projects/rocm-axiio/gda-experiments/verify-p2p-capability.sh"

echo "========================================"
echo "AMD P2P Capability Injection Test"
echo "========================================"
echo ""

# Check if custom QEMU exists
if [ ! -f "$QEMU_BIN" ]; then
    echo "ERROR: Custom QEMU not found at $QEMU_BIN"
    exit 1
fi

# Check if VM image exists
if [ ! -f "$VM_IMAGE" ]; then
    echo "ERROR: VM image not found at $VM_IMAGE"
    exit 1
fi

echo "Configuration:"
echo "  QEMU: $QEMU_BIN"
echo "  VM Image: $VM_IMAGE"
echo "  GPU: 0000:10:00.0"
echo "  Clique ID: 1"
echo ""

echo "This will:"
echo "  1. Launch VM with GPU passed through"
echo "  2. Inject P2P capability with signature 'P2P' (0x50 0x32 0x50)"
echo "  3. Assign GPU to clique ID 1"
echo ""
echo "=========================================="
echo "INSIDE THE VM, run these commands:"
echo "=========================================="
echo ""
echo "# Quick check (any user):"
echo "  lspci -vvv | grep -A 5 'Vendor Specific'"
echo ""
echo "# Detailed verification (requires root):"
echo "  wget http://HOST_IP/verify-p2p-capability.sh"
echo "  sudo bash verify-p2p-capability.sh"
echo ""
echo "# Or manually check:"
echo "  GPU_ADDR=\$(lspci | grep -i AMD | head -1 | cut -d' ' -f1)"
echo "  sudo setpci -s \$GPU_ADDR c8.8"
echo "  # Should show: 09 00 08 50 32 50 08 00"
echo "  #              │  │  │  └──┴──┴── 'P2P' signature"
echo "  #              │  │  └────────── Length (8)"
echo "  #              │  └───────────── Next (0)"
echo "  #              └──────────────── Vendor cap (9)"
echo ""
echo "=========================================="
echo ""
echo "Starting VM in 5 seconds (Ctrl+C to cancel)..."
sleep 5

# Launch QEMU with AMD P2P clique
exec $QEMU_BIN \
  -machine q35,accel=kvm,kernel-irqchip=split \
  -cpu host \
  -smp 8 \
  -m 16G \
  -device intel-iommu,intremap=on,device-iotlb=on \
  -device vfio-pci,host=0000:10:00.0,x-amd-gpudirect-clique=1 \
  -drive if=virtio,format=qcow2,file=$VM_IMAGE \
  -nographic \
  -serial mon:stdio

