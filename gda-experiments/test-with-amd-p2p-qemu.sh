#!/bin/bash
# Test with AMD P2P Patched QEMU

set -e

echo "=========================================="
echo "Testing with AMD P2P Patched QEMU"
echo "=========================================="
echo ""

QEMU_BIN="/opt/qemu-10.1.2-amd-p2p/bin/qemu-system-x86_64"
GPU_BDF="0000:10:00.0"
NVME_BDF="0000:c2:00.0"

# Kill any running QEMU
echo "Stopping any running VM..."
sudo pkill -f "qemu.*$GPU_BDF" || true
sleep 2

echo "Launching VM with AMD P2P clique support..."
echo ""
echo "Configuration:"
echo "  GPU:  $GPU_BDF (clique 1)"
echo "  NVMe: $NVME_BDF (clique 1)"
echo ""

$QEMU_BIN \
  -machine q35,accel=kvm,kernel-irqchip=split \
  -cpu host \
  -smp 4 \
  -m 8192 \
  -device intel-iommu,intremap=on \
  -drive if=virtio,format=qcow2,file=/home/stebates/Projects/qemu-minimal/images/rocm-axiio.qcow2 \
  -device vfio-pci,host=$GPU_BDF,x-amd-gpudirect-clique=1 \
  -device vfio-pci,host=$NVME_BDF,x-amd-gpudirect-clique=1 \
  -virtfs local,path=/home/stebates/Projects/rocm-axiio,mount_tag=hostfs,security_model=passthrough,id=hostfs \
  -nographic \
  -serial mon:stdio

echo ""
echo "VM terminated"

