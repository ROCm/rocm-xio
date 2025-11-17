#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Script to test axiio-tester with QEMU-emulated NVMe SSD
#
# This script demonstrates how to:
# 1. Create a virtual NVMe device with QEMU
# 2. Extract NVMe queue addresses from the guest
# 3. Run axiio-tester with real hardware addresses
#
# Prerequisites:
# - QEMU with NVMe support (qemu-system-x86_64)
# - Root/sudo access for /dev/mem access
# - Linux kernel with NVMe support

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}QEMU NVMe Testing Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check for QEMU
if ! command -v qemu-system-x86_64 &> /dev/null; then
    echo -e "${RED}Error: qemu-system-x86_64 not found${NC}"
    echo "Install QEMU: sudo apt-get install qemu-system-x86"
    exit 1
fi

# Check for root privileges (needed for /dev/mem access)
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}Warning: This script needs root privileges for /dev/mem access${NC}"
    echo "Please run with sudo or as root"
    echo ""
    echo "Usage: sudo $0"
    exit 1
fi

# Configuration
NVME_IMAGE="${PROJECT_DIR}/nvme-test.img"
NVME_SIZE="1G"
QEMU_MEMORY="2G"
QEMU_CPUS="2"

echo -e "${GREEN}Step 1: Creating NVMe test image${NC}"
echo "----------------------------------------"
if [ ! -f "$NVME_IMAGE" ]; then
    echo "Creating $NVME_SIZE NVMe image at $NVME_IMAGE"
    qemu-img create -f raw "$NVME_IMAGE" "$NVME_SIZE"
else
    echo "Using existing image: $NVME_IMAGE"
fi
echo ""

echo -e "${GREEN}Step 2: Extracting NVMe addresses (Manual Process)${NC}"
echo "----------------------------------------"
echo "To test with real NVMe hardware, you need to:"
echo ""
echo "1. Find the NVMe device PCI BAR addresses:"
echo "   sudo lspci -vvv | grep -A 20 'Non-Volatile memory controller'"
echo ""
echo "2. Identify the NVMe admin queue addresses:"
echo "   - Admin Submission Queue Base Address (ASQ)"
echo "   - Admin Completion Queue Base Address (ACQ)"
echo "   - Doorbell registers (starting at BAR0 + 0x1000)"
echo ""
echo "3. For QEMU, NVMe device typically uses:"
echo "   - PCI device: 00:04.0 (adjust based on your QEMU config)"
echo "   - BAR0: Check with 'sudo lspci -vvv -s 00:04.0'"
echo ""
echo "Example addresses (these are system-specific!):"
echo "  NVMe BAR0:    0xfeb00000"
echo "  SQ Base:      0xfeb10000 (example)"
echo "  CQ Base:      0xfeb20000 (example)"
echo "  Doorbell:     0xfeb01000 (BAR0 + 0x1000)"
echo ""

# Example command for reference
cat << 'EXAMPLE_CMD'
Example axiio-tester command with real hardware:
================================================

sudo ./bin/axiio-tester \
  --endpoint nvme-ep \
  --real-hardware \
  --nvme-doorbell 0xfeb01000 \
  --nvme-sq-base 0xfeb10000 \
  --nvme-cq-base 0xfeb20000 \
  --nvme-sq-size 4096 \
  --nvme-cq-size 4096 \
  --iterations 10 \
  --verbose

Note: Replace addresses with actual values from your system!
EXAMPLE_CMD

echo ""
echo -e "${GREEN}Step 3: NVMe Address Discovery Script${NC}"
echo "----------------------------------------"

# Create a helper script to discover NVMe addresses
DISCOVER_SCRIPT="${PROJECT_DIR}/scripts/discover-nvme-addresses.sh"
cat > "$DISCOVER_SCRIPT" << 'DISCOVER_EOF'
#!/bin/bash
# Script to help discover NVMe addresses for testing

echo "=== NVMe Device Discovery ==="
echo ""

# Find NVMe controllers
echo "NVMe Controllers:"
lspci | grep -i "Non-Volatile memory controller"
echo ""

# Get detailed info for first NVMe controller
NVME_PCI=$(lspci | grep -i "Non-Volatile memory controller" | head -1 | cut -d' ' -f1)

if [ -z "$NVME_PCI" ]; then
    echo "No NVMe controller found!"
    exit 1
fi

echo "Selected NVMe Controller: $NVME_PCI"
echo ""

# Get BAR addresses
echo "=== PCI BAR Addresses ==="
lspci -vvv -s "$NVME_PCI" | grep -A 5 "Memory at"
echo ""

# Get NVMe queue information from sysfs
NVME_DEV=$(ls /sys/class/nvme/ | head -1)
if [ -n "$NVME_DEV" ]; then
    echo "=== NVMe Device Information ==="
    echo "Device: $NVME_DEV"
    
    # Try to read NVMe registers (requires root)
    if [ -e "/sys/class/nvme/$NVME_DEV/device/resource0" ]; then
        echo "Resource file: /sys/class/nvme/$NVME_DEV/device/resource0"
    fi
fi
echo ""

echo "=== Important Notes ==="
echo "1. NVMe doorbells are at BAR0 + 0x1000"
echo "2. Admin queues are configured via NVMe controller registers"
echo "3. I/O queues may have different addresses than admin queues"
echo "4. Queue sizes must match what's configured in the controller"
echo ""
echo "To find actual queue addresses, you may need to:"
echo "- Parse NVMe controller capability registers"
echo "- Read ASQ/ACQ registers (offsets 0x28 and 0x30)"
echo "- Calculate queue physical addresses from these values"
echo ""
DISCOVER_EOF

chmod +x "$DISCOVER_SCRIPT"
echo "Created NVMe discovery script: $DISCOVER_SCRIPT"
echo "Run it with: sudo $DISCOVER_SCRIPT"
echo ""

echo -e "${GREEN}Step 4: Testing Instructions${NC}"
echo "----------------------------------------"
echo "To test axiio-tester with QEMU NVMe:"
echo ""
echo "1. Boot a VM with NVMe device (or use existing system)"
echo ""
echo "2. Discover NVMe addresses:"
echo "   sudo $DISCOVER_SCRIPT"
echo ""
echo "3. Build axiio-tester (if not already built):"
echo "   cd $PROJECT_DIR && make all"
echo ""
echo "4. Run axiio-tester with discovered addresses:"
echo "   sudo ./bin/axiio-tester --endpoint nvme-ep --real-hardware \\"
echo "     --nvme-doorbell <ADDR> --nvme-sq-base <ADDR> --nvme-cq-base <ADDR> \\"
echo "     --nvme-sq-size <SIZE> --nvme-cq-size <SIZE> --iterations 10 -v"
echo ""

echo -e "${YELLOW}Important Warnings:${NC}"
echo "- Direct hardware access via /dev/mem can be dangerous"
echo "- Wrong addresses can cause system crashes"
echo "- Test in a VM first before running on real hardware"
echo "- Ensure NVMe queue addresses are correct and not in use"
echo "- This is experimental and for testing purposes only"
echo ""

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Setup Complete${NC}"
echo -e "${BLUE}========================================${NC}"

