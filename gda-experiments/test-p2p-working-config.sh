#!/bin/bash
# Test P2P with the working run-vm configuration style

set -e

QEMU_BIN="/opt/qemu-10.1.2-amd-p2p/bin/qemu-system-x86_64"
VM_IMAGE="/home/stebates/Projects/qemu-minimal/images/rocm-axiio.qcow2"
NVME_IMAGE="/home/stebates/Projects/qemu-minimal/images/rocm-axiio-nvme1.qcow2"
GPU_PCI="10:00.0"

echo "========================================"
echo "P2P Test with Working GPU Configuration"
echo "========================================"
echo ""
echo "Using: run-vm style config + P2P QEMU"
echo "  -cpu EPYC (not host)"
echo "  No intel-iommu"
echo "  PCIe root ports"
echo "  P2P-enabled QEMU with lazy init"
echo ""
sleep 2

# Create NVMe image if it doesn't exist
if [ ! -f "$NVME_IMAGE" ]; then
    qemu-img create -f qcow2 "$NVME_IMAGE" 10G
fi

# Launch with P2P-enabled QEMU using run-vm style config
exec sudo $QEMU_BIN \
  -machine q35,accel=kvm \
  -cpu EPYC \
  -smp 2 \
  -m 4G \
  \
  -object memory-backend-memfd,id=mem,size=2G \
  -virtfs local,path=/home/stebates/Projects,security_model=passthrough,mount_tag=hostfs \
  \
  -device pcie-root-port,id=rp_nvme1,chassis=1,slot=1 \
  -device pcie-root-port,id=rp_host2,chassis=2,slot=2 \
  \
  -drive file=$NVME_IMAGE,format=qcow2,if=none,id=nvme-1 \
  -device nvme,id=nvme0,serial=p2ptest01,drive=nvme-1,bus=rp_nvme1,p2p-gpu=gpu0 \
  \
  -device vfio-pci,id=gpu0,host=$GPU_PCI,bus=rp_host2 \
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

