#!/bin/bash
# Simple VM launcher - uses already-bound devices, no rebinding

set -e

echo "========================================="
echo "  GDA Test VM - Simple Launcher"
echo "========================================="
echo
echo "Configuration:"
echo "  GPU:        0000:10:00.0 (already bound to vfio-pci)"
echo "  NVMe:       0000:c2:00.0 (already bound to vfio-pci)"
echo "  QEMU:       /opt/qemu-10.1.2"
echo "  Emulated:   1 NVMe with NVME_TRACE=all"
echo "  Filesystem: /home/stebates/Projects/rocm-axiio"
echo
echo "Starting VM..."
echo "========================================="
echo

cd /home/stebates/Projects/qemu-minimal/qemu

QEMU_PATH=/opt/qemu-10.1.2/bin/ \
VM_NAME=rocm-axiio \
VCPUS=4 \
VMEM=8192 \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
NVME=1 \
NVME_TRACE=all \
NVME_TRACE_FILE=/tmp/nvme-gda-trace.log \
PCI_HOSTDEV=10:00.0,c2:00.0 \
./run-vm 2>&1 | tee ~/gda-test-vm.log

