#!/bin/bash
# Test GPU passthrough WITHOUT P2P NVMe to isolate the issue

set -e

QEMU_BIN="/opt/qemu-10.1.2-amd-p2p/bin/qemu-system-x86_64"
VM_IMAGE="/home/stebates/Projects/qemu-minimal/images/rocm-axiio.qcow2"
GPU_PCI="10:00.0"

echo "========================================"
echo "GPU-Only Passthrough Test"
echo "========================================"
echo ""
echo "GPU: 0000:$GPU_PCI"
echo "VM Image: $VM_IMAGE"
echo ""
echo "Testing GPU compute WITHOUT P2P NVMe"
echo ""
echo "Press Ctrl+A then X to exit QEMU"
echo ""
sleep 3

# Launch QEMU with ONLY GPU passthrough (no P2P NVMe)
exec sudo $QEMU_BIN \
  -name "GPU-Only-Test" \
  -machine q35,accel=kvm,kernel-irqchip=split \
  -cpu host \
  -smp 4 \
  -m 8G \
  \
  -device intel-iommu,intremap=on,caching-mode=on \
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

