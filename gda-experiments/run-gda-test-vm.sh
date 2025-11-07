#!/bin/bash
# Launch VM for GDA Testing with GPU, Real NVMe, and Emulated NVMe

set -e

echo "========================================="
echo "  GDA Test VM Launcher"
echo "========================================="
echo

# Find Radeon GPU
echo "Finding Radeon GPU..."
GPU_PCI=$(lspci -nn | grep -i "VGA.*AMD\|Display.*AMD\|Radeon" | head -1 | awk '{print $1}')
if [ -z "$GPU_PCI" ]; then
    echo "ERROR: No AMD/Radeon GPU found!"
    exit 1
fi
echo "  Found GPU at: $GPU_PCI"

# Find NVMe device
echo "Finding NVMe device..."
NVME_PCI=$(lspci -nn | grep "Non-Volatile memory controller" | head -1 | awk '{print $1}')
if [ -z "$NVME_PCI" ]; then
    echo "ERROR: No NVMe device found!"
    exit 1
fi
echo "  Found NVMe at: $NVME_PCI"

# Convert short format to full format if needed (e.g., 10:00.0 -> 0000:10:00.0)
if [[ ! $GPU_PCI =~ ^[0-9a-fA-F]{4}: ]]; then
    GPU_PCI="0000:$GPU_PCI"
fi
if [[ ! $NVME_PCI =~ ^[0-9a-fA-F]{4}: ]]; then
    NVME_PCI="0000:$NVME_PCI"
fi

echo
echo "Configuration:"
echo "  GPU PCI:   $GPU_PCI"
echo "  NVMe PCI:  $NVME_PCI"
echo "  QEMU:      /opt/qemu-10.1.2"
echo "  FS Mount:  $(pwd)"
echo

# Check if devices are bound to vfio-pci
echo "Checking vfio-pci bindings..."

check_and_bind_vfio() {
    local pci_addr=$1
    local dev_type=$2
    
    # Check current driver
    current_driver=$(lspci -k -s $pci_addr | grep "Kernel driver in use:" | awk '{print $5}')
    
    if [ "$current_driver" == "vfio-pci" ]; then
        echo "  $dev_type already bound to vfio-pci"
        return 0
    fi
    
    echo "  $dev_type bound to: ${current_driver:-none}, rebinding to vfio-pci..."
    
    # Get vendor and device IDs
    ids=$(lspci -n -s $pci_addr | awk '{print $3}')
    vendor_id=$(echo $ids | cut -d: -f1)
    device_id=$(echo $ids | cut -d: -f2)
    
    # Unbind from current driver if any
    if [ ! -z "$current_driver" ] && [ "$current_driver" != "vfio-pci" ]; then
        echo "$pci_addr" | sudo tee /sys/bus/pci/drivers/$current_driver/unbind > /dev/null 2>&1 || true
    fi
    
    # Bind to vfio-pci
    sudo modprobe vfio-pci
    echo "$vendor_id $device_id" | sudo tee /sys/bus/pci/drivers/vfio-pci/new_id > /dev/null 2>&1 || true
    echo "$pci_addr" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind > /dev/null 2>&1 || true
    
    sleep 1
    
    # Verify
    new_driver=$(lspci -k -s $pci_addr | grep "Kernel driver in use:" | awk '{print $5}')
    if [ "$new_driver" == "vfio-pci" ]; then
        echo "  ✓ Successfully bound to vfio-pci"
        return 0
    else
        echo "  ✗ Failed to bind to vfio-pci"
        return 1
    fi
}

# Bind GPU to vfio-pci
check_and_bind_vfio "$GPU_PCI" "GPU"

# Bind NVMe to vfio-pci
check_and_bind_vfio "$NVME_PCI" "NVMe"

echo
echo "Launching VM..."
echo "  - 1 Emulated NVMe with NVME_TRACE=all"
echo "  - GPU passthrough: $GPU_PCI"
echo "  - Real NVMe passthrough: $NVME_PCI"
echo "  - Filesystem: $(pwd)"
echo
echo "Press Ctrl-A then X to exit QEMU"
echo "========================================="
echo

cd /home/stebates/Projects/qemu-minimal/qemu

# Launch VM with:
# - /opt/qemu-10.1.2 QEMU
# - 1 emulated NVMe with full tracing
# - GPU and real NVMe as PCI passthrough
# - gda-experiments directory mounted
QEMU_PATH=/opt/qemu-10.1.2/bin/ \
VM_NAME=rocm-axiio \
VCPUS=4 \
VMEM=8192 \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
NVME=1 \
NVME_TRACE=all \
NVME_TRACE_FILE=/tmp/nvme-gda-trace.log \
PCI_HOSTDEV=${GPU_PCI},${NVME_PCI} \
./run-vm 2>&1 | tee ~/gda-test-vm.log

