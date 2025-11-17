#!/bin/bash
# Script to run inside the VM to test GDA with emulated NVMe

set -e

echo "========================================="
echo "  GDA Testing Inside VM"
echo "========================================="
echo

# Mount host filesystem if not already mounted
if ! mount | grep -q hostfs; then
    echo "Mounting host filesystem..."
    sudo mkdir -p /mnt/host
    sudo mount -t 9p -o trans=virtio,version=9p2000.L hostfs /mnt/host
    echo "✓ Mounted at /mnt/host"
fi

cd /mnt/host/gda-experiments

echo
echo "System Information:"
echo "-------------------"
echo "Kernel: $(uname -r)"
rocminfo | grep "Name:" | head -3 || echo "ROCm not found"
echo

echo "Available NVMe devices:"
lspci | grep -i nvme
echo

# Find emulated and real NVMe
echo "Identifying NVMe devices..."
EMULATED_NVME=$(lspci -nn | grep "Non-Volatile.*1b36:0010" | head -1 | awk '{print $1}')
REAL_NVME=$(lspci -nn | grep "Non-Volatile" | grep -v "1b36:0010" | head -1 | awk '{print $1}')

if [ -z "$EMULATED_NVME" ]; then
    echo "ERROR: No emulated NVMe found!"
    exit 1
fi

echo "  Emulated NVMe: $EMULATED_NVME (QEMU)"
if [ ! -z "$REAL_NVME" ]; then
    echo "  Real NVMe: $REAL_NVME"
fi

# Convert to full format if needed
if [[ ! $EMULATED_NVME =~ ^[0-9a-fA-F]{4}: ]]; then
    EMULATED_NVME="0000:$EMULATED_NVME"
fi

echo
echo "========================================="
echo "Phase 1: Build GDA Driver and Tests"
echo "========================================="

cd nvme-gda

# Build kernel driver
echo
echo "Building kernel driver..."
cd nvme_gda_driver
make clean
make
if [ ! -f nvme_gda.ko ]; then
    echo "ERROR: Failed to build kernel driver"
    exit 1
fi
echo "✓ Kernel driver built: nvme_gda.ko"

# Build userspace
echo
echo "Building userspace library and tests..."
cd ..
rm -rf build
mkdir build && cd build
cmake ..
make -j4

if [ ! -f test_basic_doorbell ] || [ ! -f test_gpu_io ]; then
    echo "ERROR: Failed to build tests"
    exit 1
fi
echo "✓ Tests built successfully"

echo
echo "========================================="
echo "Phase 2: Unbind and Load GDA Driver"
echo "========================================="

cd ../nvme_gda_driver

echo
echo "Unbinding emulated NVMe from nvme driver..."
# Check if bound to nvme
if lspci -k -s $EMULATED_NVME | grep -q "nvme"; then
    echo "$EMULATED_NVME" | sudo tee /sys/bus/pci/drivers/nvme/unbind > /dev/null
    echo "✓ Unbound from nvme driver"
else
    echo "  (Not bound to nvme driver)"
fi

# Remove existing nvme_gda if loaded
if lsmod | grep -q nvme_gda; then
    echo "Removing existing nvme_gda module..."
    sudo rmmod nvme_gda || true
fi

echo
echo "Loading nvme_gda driver for emulated NVMe..."
sudo insmod nvme_gda.ko nvme_pci_dev=$EMULATED_NVME

sleep 1

# Check if loaded
if ! lsmod | grep -q nvme_gda; then
    echo "ERROR: Failed to load nvme_gda module"
    sudo dmesg | tail -20
    exit 1
fi

echo "✓ Driver loaded"

# Check device creation
if [ ! -e /dev/nvme_gda0 ]; then
    echo "WARNING: /dev/nvme_gda0 not created automatically"
    echo "Creating device node manually..."
    MAJOR=$(awk '$2=="nvme_gda" {print $1}' /proc/devices)
    sudo mknod /dev/nvme_gda0 c $MAJOR 0
    sudo chmod 666 /dev/nvme_gda0
fi

if [ -e /dev/nvme_gda0 ]; then
    echo "✓ Device node: /dev/nvme_gda0"
    ls -l /dev/nvme_gda0
else
    echo "ERROR: Failed to create /dev/nvme_gda0"
    exit 1
fi

echo
echo "Driver loaded successfully!"
echo
echo "Kernel messages:"
echo "-------------------"
sudo dmesg | grep -i gda | tail -15

echo
echo "========================================="
echo "Phase 3: Test Basic Doorbell Access"
echo "========================================="

cd ../build

echo
echo "Running basic doorbell test..."
echo "-------------------"
./test_basic_doorbell /dev/nvme_gda0

TEST_RESULT=$?

echo
echo "========================================="
echo "Phase 4: Check NVMe Traces"
echo "========================================="

echo
echo "Checking for NVMe traces..."
if [ -f /tmp/nvme-gda-trace.log ]; then
    echo
    echo "Recent doorbell traces:"
    echo "-------------------"
    grep -i "doorbell" /tmp/nvme-gda-trace.log | tail -20 || echo "(No doorbell traces yet)"
    
    echo
    echo "Recent NVMe events:"
    echo "-------------------"
    tail -30 /tmp/nvme-gda-trace.log
    
    echo
    echo "Full trace saved to: /tmp/nvme-gda-trace.log"
    echo "Lines in trace: $(wc -l < /tmp/nvme-gda-trace.log)"
else
    echo "WARNING: No trace file found at /tmp/nvme-gda-trace.log"
    echo "Check if NVME_TRACE was enabled in VM launch"
fi

echo
echo "========================================="
echo "Phase 5: Analysis"
echo "========================================="

echo
echo "Summary:"
echo "-------------------"
echo "Emulated NVMe PCI: $EMULATED_NVME"
echo "GDA Driver: $(lsmod | grep nvme_gda | awk '{print $1}')"
echo "Device Node: /dev/nvme_gda0"
echo "Test Result: $([[ $TEST_RESULT -eq 0 ]] && echo "PASSED ✓" || echo "FAILED ✗")"

if [ $TEST_RESULT -eq 0 ]; then
    echo
    echo "✓✓✓ SUCCESS! ✓✓✓"
    echo
    echo "The GPU successfully accessed the emulated NVMe doorbell!"
    echo
    echo "Next steps:"
    echo "1. Review trace file: /tmp/nvme-gda-trace.log"
    echo "2. Run full I/O test: ./test_gpu_io /dev/nvme_gda0 1 0x1000"
    echo "3. Compare with CPU-initiated I/O patterns"
else
    echo
    echo "✗✗✗ TEST FAILED ✗✗✗"
    echo
    echo "Check:"
    echo "1. Kernel logs: sudo dmesg | grep -E '(nvme_gda|error)'"
    echo "2. Device permissions: ls -l /dev/nvme_gda0"
    echo "3. PCIe topology: lspci -tv"
fi

echo
echo "========================================="
echo "Complete!"
echo "========================================="

exit $TEST_RESULT


