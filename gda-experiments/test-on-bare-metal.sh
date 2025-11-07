#!/bin/bash
# Test NVMe GDA on Bare Metal Host
# This avoids all VFIO/VM complexity

set -e

echo "=========================================="
echo "NVMe GDA Test on Bare Metal"
echo "=========================================="
echo ""

GPU_BDF="0000:10:00.0"
NVME_BDF="0000:c2:00.0"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root (sudo)"
    exit 1
fi

# Check if VM is running
if pgrep -f "qemu.*$GPU_BDF" > /dev/null; then
    echo "WARNING: QEMU appears to be running with GPU passthrough"
    echo "Please shut down the VM first:"
    echo "  1. SSH to VM and run: sudo shutdown -h now"
    echo "  2. Or kill QEMU from host"
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "Step 1: Unbind devices from current drivers"
echo "============================================="

# Unbind GPU from vfio-pci
if [ -e "/sys/bus/pci/devices/$GPU_BDF/driver" ]; then
    GPU_DRIVER=$(readlink /sys/bus/pci/devices/$GPU_BDF/driver | xargs basename)
    echo "GPU currently on: $GPU_DRIVER"
    
    if [ "$GPU_DRIVER" = "vfio-pci" ]; then
        echo "Unbinding GPU from vfio-pci..."
        echo "$GPU_BDF" > /sys/bus/pci/drivers/vfio-pci/unbind
        sleep 1
    fi
fi

# Unbind NVMe from current driver
if [ -e "/sys/bus/pci/devices/$NVME_BDF/driver" ]; then
    NVME_DRIVER=$(readlink /sys/bus/pci/devices/$NVME_BDF/driver | xargs basename)
    echo "NVMe currently on: $NVME_DRIVER"
    
    if [ "$NVME_DRIVER" = "vfio-pci" ] || [ "$NVME_DRIVER" = "nvme" ]; then
        echo "Unbinding NVMe from $NVME_DRIVER..."
        echo "$NVME_BDF" > /sys/bus/pci/drivers/$NVME_DRIVER/unbind
        sleep 1
    fi
fi

echo "✓ Devices unbound"
echo ""

echo "Step 2: Load GPU driver (amdgpu)"
echo "================================="

# Check if amdgpu is loaded
if ! lsmod | grep -q "^amdgpu "; then
    echo "Loading amdgpu module..."
    modprobe amdgpu
    sleep 2
fi

# Bind GPU to amdgpu
if [ ! -e "/sys/bus/pci/devices/$GPU_BDF/driver" ]; then
    echo "Binding GPU to amdgpu..."
    echo "$GPU_BDF" > /sys/bus/pci/drivers/amdgpu/bind
    sleep 2
fi

GPU_DRIVER=$(readlink /sys/bus/pci/devices/$GPU_BDF/driver 2>/dev/null | xargs basename)
if [ "$GPU_DRIVER" = "amdgpu" ]; then
    echo "✓ GPU on amdgpu driver"
else
    echo "✗ Failed to bind GPU to amdgpu"
    echo "  Current driver: $GPU_DRIVER"
    exit 1
fi
echo ""

echo "Step 3: Build and load nvme_gda driver"
echo "======================================="

cd /home/stebates/Projects/rocm-axiio/gda-experiments/nvme-gda/nvme_gda_driver

# Build if needed
if [ ! -f "nvme_gda.ko" ] || [ "nvme_gda.c" -nt "nvme_gda.ko" ]; then
    echo "Building nvme_gda driver..."
    make clean
    make
fi

# Unload if already loaded
if lsmod | grep -q "^nvme_gda "; then
    echo "Unloading old nvme_gda module..."
    rmmod nvme_gda || true
fi

# Load the driver
echo "Loading nvme_gda driver..."
insmod nvme_gda.ko

if ! lsmod | grep -q "^nvme_gda "; then
    echo "✗ Failed to load nvme_gda driver"
    exit 1
fi

echo "✓ nvme_gda driver loaded"
echo ""

echo "Step 4: Bind NVMe to nvme_gda"
echo "=============================="

# Get NVMe vendor/device ID
VENDOR=$(cat /sys/bus/pci/devices/$NVME_BDF/vendor | sed 's/0x//')
DEVICE=$(cat /sys/bus/pci/devices/$NVME_BDF/device | sed 's/0x//')
echo "NVMe IDs: $VENDOR:$DEVICE"

# Tell nvme_gda to handle this device
echo "$VENDOR $DEVICE" > /sys/bus/pci/drivers/nvme_gda/new_id
sleep 1

# Check if it bound
if [ -e "/dev/nvme_gda0" ]; then
    echo "✓ NVMe bound to nvme_gda"
    echo "✓ /dev/nvme_gda0 created"
else
    echo "✗ /dev/nvme_gda0 not found"
    echo "Check dmesg for errors:"
    dmesg | tail -20
    exit 1
fi

# Fix permissions
chmod 666 /dev/nvme_gda0

echo ""

echo "Step 5: Check system configuration"
echo "===================================="

echo "GPU IOMMU group:"
ls -l /sys/bus/pci/devices/$GPU_BDF/iommu_group

echo ""
echo "NVMe IOMMU group:"
ls -l /sys/bus/pci/devices/$NVME_BDF/iommu_group

echo ""
echo "IOMMU mode:"
dmesg | grep -i "iommu.*domain" | head -3

echo ""
echo "Kernel P2P config:"
grep CONFIG_HSA_AMD_P2P /boot/config-$(uname -r) || echo "Not configured"

echo ""

echo "Step 6: Build test programs"
echo "============================"

cd /home/stebates/Projects/rocm-axiio/gda-experiments/nvme-gda

if [ ! -d "build" ]; then
    mkdir build
fi

cd build

echo "Running cmake..."
cmake .. -DCMAKE_BUILD_TYPE=Release

echo "Building..."
make -j$(nproc)

if [ ! -f "tests/test_basic_doorbell" ]; then
    echo "✗ Failed to build test_basic_doorbell"
    exit 1
fi

echo "✓ Tests built"
echo ""

echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "System Configuration:"
echo "  GPU:  $GPU_BDF → amdgpu driver"
echo "  NVMe: $NVME_BDF → nvme_gda driver"
echo "  Device: /dev/nvme_gda0"
echo ""
echo "Ready to test!"
echo ""
echo "Run tests:"
echo "  sudo ./tests/test_basic_doorbell /dev/nvme_gda0"
echo ""
echo "Expected result: GPU doorbell write should work!"
echo ""

# Offer to run the test
read -p "Run test now? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "=========================================="
    echo "Running GPU Doorbell Test"
    echo "=========================================="
    echo ""
    ./tests/test_basic_doorbell /dev/nvme_gda0
fi

