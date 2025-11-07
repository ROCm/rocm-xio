#!/bin/bash
# Comprehensive P2P Capability Verification Script
# Run this INSIDE the VM to verify AMD P2P capability injection

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================"
echo "AMD P2P Capability Verification"
echo "========================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}WARNING: Not running as root. Some checks will be limited.${NC}"
    echo "For full verification, run: sudo $0"
    echo ""
fi

# Find GPU device
echo -e "${BLUE}[1/5] Detecting GPU...${NC}"
GPU_ADDR=$(lspci | grep -i "VGA\|Display\|AMD\|ATI" | head -1 | cut -d' ' -f1)

if [ -z "$GPU_ADDR" ]; then
    echo -e "${RED}ERROR: No GPU found in VM${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found GPU at: $GPU_ADDR${NC}"
GPU_INFO=$(lspci -s "$GPU_ADDR" | cut -d' ' -f2-)
echo "  Device: $GPU_INFO"
echo ""

# Show PCI device details
echo -e "${BLUE}[2/5] PCI Device Information...${NC}"
lspci -vv -s "$GPU_ADDR" | head -15
echo ""

# Scan for vendor-specific capabilities
echo -e "${BLUE}[3/5] Scanning for Vendor-Specific Capabilities...${NC}"
VENDOR_CAPS=$(lspci -vvv -s "$GPU_ADDR" 2>/dev/null | grep -A 2 "Vendor Specific" || echo "")

if [ -z "$VENDOR_CAPS" ]; then
    echo -e "${YELLOW}⚠ No vendor-specific capabilities visible with lspci${NC}"
    echo "  (This is normal - capability may not be displayed by default)"
else
    echo "$VENDOR_CAPS"
fi
echo ""

# Try to read capability directly (requires root)
echo -e "${BLUE}[4/5] Reading P2P Capability Structure...${NC}"

if [ "$EUID" -eq 0 ]; then
    FOUND_P2P=false
    
    # Try common offsets: 0xC8 and 0xD4
    for offset in c8 d4; do
        echo -n "  Checking offset 0x$offset: "
        
        # Read 8 bytes of capability data
        DATA=$(setpci -s "$GPU_ADDR" ${offset}.8 2>/dev/null || echo "")
        
        if [ -z "$DATA" ]; then
            echo -e "${YELLOW}Cannot read${NC}"
            continue
        fi
        
        echo "$DATA"
        
        # Parse the capability
        IFS=' ' read -r -a BYTES <<< "$DATA"
        
        if [ "${BYTES[0]}" == "09" ]; then
            echo -e "    ${GREEN}✓ Vendor-Specific Capability ID (0x09)${NC}"
            
            CAP_LEN="${BYTES[2]}"
            SIG_BYTE1="${BYTES[3]}"
            SIG_BYTE2="${BYTES[4]}"
            SIG_BYTE3="${BYTES[5]}"
            CLIQUE_BYTE="${BYTES[6]}"
            
            # Decode signature
            SIG_CHAR1=$(printf "\x$SIG_BYTE1")
            SIG_CHAR2=$(printf "\x$SIG_BYTE2")
            SIG_CHAR3=$(printf "\x$SIG_BYTE3")
            SIGNATURE="$SIG_CHAR1$SIG_CHAR2$SIG_CHAR3"
            
            echo "    Capability Length: 0x$CAP_LEN ($(printf "%d" 0x$CAP_LEN) bytes)"
            echo "    Signature Bytes: 0x$SIG_BYTE1 0x$SIG_BYTE2 0x$SIG_BYTE3"
            echo "    Signature String: '$SIGNATURE'"
            
            # Check if it's the P2P signature
            if [ "$SIG_BYTE1" == "50" ] && [ "$SIG_BYTE2" == "32" ] && [ "$SIG_BYTE3" == "50" ]; then
                echo -e "    ${GREEN}✓✓✓ P2P SIGNATURE VERIFIED! ✓✓✓${NC}"
                FOUND_P2P=true
                
                # Decode clique ID
                CLIQUE_BYTE_DEC=$((16#$CLIQUE_BYTE))
                CLIQUE_ID=$(( ($CLIQUE_BYTE_DEC >> 3) & 0x0F ))
                VERSION=$(( $CLIQUE_BYTE_DEC & 0x07 ))
                
                echo "    Clique Data Byte: 0x$CLIQUE_BYTE (binary: $(printf "%08d" $(echo "obase=2; 16#$CLIQUE_BYTE" | bc)))"
                echo -e "    ${GREEN}Clique ID: $CLIQUE_ID${NC}"
                echo "    Version: $VERSION"
                
            elif [ "$SIG_BYTE1" == "41" ] && [ "$SIG_BYTE2" == "50" ] && [ "$SIG_BYTE3" == "32" ]; then
                echo -e "    ${RED}✗✗✗ WRONG SIGNATURE: 'AP2' ✗✗✗${NC}"
                echo -e "    ${RED}This is the OLD incorrect signature!${NC}"
                echo -e "    ${RED}Expected: 'P2P' (0x50 0x32 0x50)${NC}"
                echo -e "    ${RED}Got:      'AP2' (0x41 0x50 0x32)${NC}"
                echo ""
                echo -e "    ${YELLOW}QEMU needs to be rebuilt with the corrected signature.${NC}"
                
            else
                echo -e "    ${YELLOW}⚠ Unknown signature: '$SIGNATURE'${NC}"
                echo "    Expected 'P2P' for GPUDirect P2P capability"
            fi
            echo ""
        fi
    done
    
    if [ "$FOUND_P2P" = true ]; then
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}SUCCESS! P2P Capability Properly Injected!${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo ""
        echo "Summary:"
        echo "  ✓ Vendor-specific capability found"
        echo "  ✓ Signature: 'P2P' (0x50 0x32 0x50) - CORRECT!"
        echo "  ✓ Clique ID: $CLIQUE_ID"
        echo "  ✓ Guest drivers will recognize this device for P2P"
        echo ""
    else
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}P2P CAPABILITY NOT FOUND${NC}"
        echo -e "${RED}========================================${NC}"
        echo ""
        echo "Possible causes:"
        echo "  1. GPU not passed through with x-amd-gpudirect-clique parameter"
        echo "  2. QEMU not built with AMD P2P patch"
        echo "  3. Capability at non-standard offset"
        echo ""
        echo "Expected QEMU command:"
        echo "  -device vfio-pci,host=XX:XX.X,x-amd-gpudirect-clique=N"
        echo ""
    fi
    
else
    echo -e "${YELLOW}⚠ Root access required for direct capability reading${NC}"
    echo "  Run with sudo to verify P2P signature"
    echo ""
fi

# Additional diagnostics
echo -e "${BLUE}[5/5] Additional Diagnostics...${NC}"

# Check PCI config space size
if [ "$EUID" -eq 0 ]; then
    CONFIG_SIZE=$(lspci -xxx -s "$GPU_ADDR" 2>/dev/null | wc -l)
    echo "  PCI config space lines: $CONFIG_SIZE"
    
    # Show capability list pointer
    CAP_PTR=$(setpci -s "$GPU_ADDR" 34.b 2>/dev/null || echo "")
    if [ -n "$CAP_PTR" ]; then
        echo "  Capability list starts at: 0x$CAP_PTR"
    fi
fi

# Show all capabilities
echo ""
echo "  All PCI Capabilities:"
lspci -vvv -s "$GPU_ADDR" 2>/dev/null | grep "Capabilities:" -A 50 | grep -E "^\s+Capabilities:" | head -10

echo ""
echo -e "${BLUE}========================================${NC}"
echo "Verification Complete!"
echo ""
echo "Manual verification commands:"
echo "  lspci -vvv -s $GPU_ADDR"
echo "  sudo setpci -s $GPU_ADDR c8.8"
echo "  sudo setpci -s $GPU_ADDR d4.8"
echo -e "${BLUE}========================================${NC}"

