#!/bin/bash
# Check if AMD P2P capability is present in VM

echo "=========================================="
echo "Checking AMD P2P Capability in Guest"
echo "=========================================="
echo ""

GPU_BDF="10:00.0"
NVME_BDF="c2:00.0"

echo "GPU Device ($GPU_BDF):"
echo "======================"
sudo lspci -vvv -s $GPU_BDF | grep -A20 "Capabilities:" | head -30

echo ""
echo ""
echo "NVMe Device ($NVME_BDF):"
echo "========================"
sudo lspci -vvv -s $NVME_BDF | grep -A20 "Capabilities:" | head -30

echo ""
echo ""
echo "Looking for vendor capabilities with 'AP2' signature..."
echo ""

# Check GPU for vendor capabilities
echo "GPU Vendor Capabilities:"
sudo lspci -xxx -s $GPU_BDF | grep -E "^c0:|^d0:" | head -2

echo ""
echo "NVMe Vendor Capabilities:"
sudo lspci -xxx -s $NVME_BDF | grep -E "^c0:|^d0:" | head -2

echo ""
echo "If you see vendor capability (09) at offset C8 or D4,"
echo "the next bytes should show: 08 41 50 32 XX"
echo "  08 = length"
echo "  41 = 'A'"
echo "  50 = 'P'"
echo "  32 = '2'"
echo "  XX = clique ID (should be 08 for clique 1)"

