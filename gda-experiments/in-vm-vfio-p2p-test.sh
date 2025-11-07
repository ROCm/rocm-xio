#!/bin/bash
# Test VFIO P2P inside the VM
# Run this script INSIDE the VM

set -e

echo "================================"
echo "VFIO P2P Test for NVMe GDA"
echo "================================"
echo ""

# Check we're in the VM
if [ ! -e "/dev/vfio/vfio" ]; then
    echo "ERROR: /dev/vfio/vfio not found"
    echo "Are you running inside the VM with passthrough devices?"
    exit 1
fi

# Check devices are present
if [ ! -e "/sys/bus/pci/devices/0000:10:00.0" ]; then
    echo "ERROR: GPU (0000:10:00.0) not found"
    exit 1
fi

if [ ! -e "/sys/bus/pci/devices/0000:c2:00.0" ]; then
    echo "ERROR: NVMe (0000:c2:00.0) not found"
    exit 1
fi

echo "✓ Devices present"
echo ""

# Check both are bound to vfio-pci
GPU_DRIVER=$(readlink /sys/bus/pci/devices/0000:10:00.0/driver | xargs basename)
NVME_DRIVER=$(readlink /sys/bus/pci/devices/0000:c2:00.0/driver | xargs basename)

echo "GPU driver: $GPU_DRIVER"
echo "NVMe driver: $NVME_DRIVER"
echo ""

if [ "$GPU_DRIVER" != "vfio-pci" ]; then
    echo "WARNING: GPU not on vfio-pci driver"
fi

if [ "$NVME_DRIVER" != "vfio-pci" ]; then
    echo "WARNING: NVMe not on vfio-pci driver"
fi

# Compile VFIO P2P setup tool
echo "Compiling VFIO P2P setup tool..."
cd /mnt/hostfs/gda-experiments
gcc -o vfio_p2p_setup vfio_p2p_setup.c
echo "✓ Compiled"
echo ""

# Run VFIO P2P setup
echo "================================"
echo "Running VFIO P2P setup..."
echo "================================"
echo ""

sudo ./vfio_p2p_setup

if [ $? -ne 0 ]; then
    echo ""
    echo "✗ VFIO P2P setup failed!"
    echo ""
    echo "This could mean:"
    echo "  1. Devices are not in compatible IOMMU groups"
    echo "  2. Platform doesn't support P2P"
    echo "  3. QEMU configuration issue"
    echo ""
    exit 1
fi

echo ""
echo "================================"
echo "P2P Setup Complete!"
echo "================================"
echo ""
echo "The NVMe BAR is now mapped for GPU access."
echo "GPU can perform P2P writes to NVMe doorbells."
echo ""
echo "However, there's still a problem:"
echo "Our nvme_gda driver is not loaded because NVMe is on vfio-pci."
echo ""
echo "Options:"
echo "  1. Write a test that uses VFIO directly (no nvme_gda driver)"
echo "  2. Unbind from vfio-pci and use nvme_gda driver"
echo "  3. Test on host instead (recommended)"
echo ""
echo "For now, let's check if the mapping worked..."

# Try to access the IOMMU mapping info
echo ""
echo "IOMMU Groups:"
ls -la /sys/kernel/iommu_groups/*/devices/

echo ""
echo "VFIO devices:"
ls -la /dev/vfio/

echo ""
echo "================================"
echo "Next Steps"
echo "================================"
echo ""
echo "The VFIO P2P mapping is set up, but we need to either:"
echo ""
echo "Option A: Write a VFIO-based test (no driver needed)"
echo "  - Use VFIO APIs directly"
echo "  - Access NVMe via VFIO_DEVICE_GET_REGION_INFO"
echo "  - More complex but works with vfio-pci"
echo ""
echo "Option B: Switch to nvme_gda driver"
echo "  - Unbind NVMe from vfio-pci"
echo "  - Load nvme_gda driver"
echo "  - Use existing tests"
echo "  - Simpler but changes VM config"
echo ""
echo "Option C: Test on host (RECOMMENDED)"
echo "  - Both devices on native drivers"
echo "  - No VFIO complexity"
echo "  - Should work immediately"
echo ""

