#!/bin/bash
# Test GPU passthrough WITHOUT IOMMU emulation

set -e

QEMU_BIN="/opt/qemu-10.1.2-amd-p2p/bin/qemu-system-x86_64"
VM_IMAGE="/home/stebates/Projects/qemu-minimal/images/rocm-axiio.qcow2"
GPU_PCI="10:00.0"

echo "========================================"
echo "GPU Test WITHOUT IOMMU Emulation"
echo "========================================"
echo ""
echo "Testing if intel-iommu,caching-mode=on is causing issues"
echo ""
sleep 2

# Launch QEMU WITHOUT intel-iommu device
exec sudo $QEMU_BIN \
  -name "GPU-No-IOMMU-Test" \
  -machine q35,accel=kvm \
  -cpu host \
  -smp 4 \
  -m 8G \
  \
  -device vfio-pci,id=gpu0,host=$GPU_PCI \
  \
  -drive if=virtio,format=qcow2,file=$VM_IMAGE \
  \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  \
  -nographic \
  -serial mon:stdio

