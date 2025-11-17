#!/bin/bash
# Test QEMU NVMe P2P IOVA Mapping

set -e

QEMU_BIN="/opt/qemu-10.1.2-amd-p2p/bin/qemu-system-x86_64"
VM_IMAGE="/home/stebates/Projects/qemu-minimal/images/rocm-axiio.qcow2"
GPU_PCI="0000:10:00.0"

echo "========================================"
echo "QEMU NVMe P2P Test"
echo "========================================"
echo ""

# Check QEMU
if [ ! -f "$QEMU_BIN" ]; then
    echo "ERROR: QEMU not found at $QEMU_BIN"
    exit 1
fi

# Check VM image
if [ ! -f "$VM_IMAGE" ]; then
    echo "ERROR: VM image not found at $VM_IMAGE"
    exit 1
fi

# Check GPU
if [ ! -e "/sys/bus/pci/devices/$GPU_PCI" ]; then
    echo "ERROR: GPU not found at $GPU_PCI"
    exit 1
fi

# Check GPU driver
GPU_DRIVER=$(basename $(readlink "/sys/bus/pci/devices/$GPU_PCI/driver" 2>/dev/null) 2>/dev/null || echo "none")
echo "GPU: $GPU_PCI"
echo "Driver: $GPU_DRIVER"

if [ "$GPU_DRIVER" != "vfio-pci" ]; then
    echo ""
    echo "WARNING: GPU not bound to vfio-pci (currently: $GPU_DRIVER)"
    echo "Do you want to bind it now? (requires root)"
    read -p "Bind GPU to vfio-pci? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Get GPU vendor/device IDs
        GPU_VENDOR=$(cat /sys/bus/pci/devices/$GPU_PCI/vendor)
        GPU_DEVICE=$(cat /sys/bus/pci/devices/$GPU_PCI/device)
        
        echo "Unbinding from current driver..."
        echo "$GPU_PCI" | sudo tee /sys/bus/pci/drivers/$GPU_DRIVER/unbind 2>/dev/null || true
        
        echo "Binding to vfio-pci..."
        echo "$GPU_VENDOR $GPU_DEVICE" | sudo tee /sys/bus/pci/drivers/vfio-pci/new_id
        echo "$GPU_PCI" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind
        
        echo "Done!"
    else
        echo "Cannot proceed without vfio-pci. Exiting."
        exit 1
    fi
fi

echo ""
echo "Configuration:"
echo "  QEMU: $QEMU_BIN"
echo "  VM Image: $VM_IMAGE"
echo "  GPU: $GPU_PCI (driver: vfio-pci)"
echo ""

echo "Starting VM with NVMe P2P enabled..."
echo ""
echo "=========================================="
echo "Look for these messages:"
echo "=========================================="
echo "  NVMe P2P: Enabled for GPU 'gpu0'"
echo "  SQE IOVA:      0x0000001000000000"
echo "  CQE IOVA:      0x0000001000010000"
echo "  Doorbell IOVA: 0x0000001000020000"
echo "=========================================="
echo ""
echo "Press Ctrl+A then X to exit QEMU"
echo ""
sleep 3

# Launch QEMU with P2P parameters and NVMe tracing
exec sudo $QEMU_BIN \
  -name "NVMe-P2P-Test" \
  -machine q35,accel=kvm,kernel-irqchip=split \
  -cpu host \
  -smp 4 \
  -m 8G \
  \
  -device intel-iommu,intremap=on,caching-mode=on \
  \
  -device vfio-pci,id=gpu0,host=$GPU_PCI \
  -device nvme,id=nvme0,serial=p2ptest01,p2p-gpu=gpu0 \
  \
  -drive if=virtio,format=qcow2,file=$VM_IMAGE \
  \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  \
  -trace enable=pci_nvme* \
  \
  -nographic \
  -serial mon:stdio

