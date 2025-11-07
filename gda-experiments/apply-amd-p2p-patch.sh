#!/bin/bash
# Apply AMD P2P patch to QEMU and rebuild

set -e

QEMU_SOURCE="/home/stebates/Projects/qemu"
QEMU_BUILD="/opt/qemu-10.1.2-amd-p2p"
PATCH_FILE="/home/stebates/Projects/rocm-axiio/gda-experiments/qemu-amd-p2p.patch"

echo "=========================================="
echo "AMD GPUDirect P2P Patch for QEMU"
echo "=========================================="
echo ""

# Check if running as root for install
if [ "$EUID" -ne 0 ]; then
    echo "NOTE: Will need sudo for installation step"
fi

# Check QEMU source exists
if [ ! -d "$QEMU_SOURCE" ]; then
    echo "ERROR: QEMU source not found at $QEMU_SOURCE"
    exit 1
fi

cd "$QEMU_SOURCE"

# Check if already patched
if grep -q "amd_gpudirect_clique" hw/vfio/pci.h 2>/dev/null; then
    echo "⚠️  Patch appears to already be applied!"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create a backup
echo "Creating backup..."
git stash push -m "Before AMD P2P patch" || true

# Apply the patch
echo ""
echo "Applying AMD P2P patch..."
echo ""

if patch -p1 --dry-run < "$PATCH_FILE"; then
    echo "Patch looks good, applying..."
    patch -p1 < "$PATCH_FILE"
    echo "✓ Patch applied successfully"
else
    echo "✗ Patch failed to apply cleanly"
    echo ""
    echo "Manual steps needed:"
    echo "1. Review the patch file: $PATCH_FILE"
    echo "2. Manually edit hw/vfio/pci-quirks.c, pci.c, and pci.h"
    echo "3. Add the AMD GPUDirect code after the NVIDIA version"
    exit 1
fi

echo ""
echo "Building QEMU with AMD P2P support..."
echo ""

# Configure
./configure --prefix="$QEMU_BUILD" \
    --target-list=x86_64-softmmu \
    --enable-kvm \
    --enable-vfio \
    --enable-virtfs

# Build
echo ""
echo "Compiling... (this may take a while)"
make -j$(nproc)

# Install
echo ""
echo "Installing to $QEMU_BUILD..."
sudo make install

echo ""
echo "=========================================="
echo "✓ QEMU with AMD P2P support installed!"
echo "=========================================="
echo ""
echo "Installation: $QEMU_BUILD"
echo ""
echo "To use:"
echo "  $QEMU_BUILD/bin/qemu-system-x86_64 \\"
echo "    -device vfio-pci,host=10:00.0,x-amd-gpudirect-clique=1 \\"
echo "    -device vfio-pci,host=c2:00.0,x-amd-gpudirect-clique=1"
echo ""
echo "Both devices will now be in the same P2P clique!"
echo ""

