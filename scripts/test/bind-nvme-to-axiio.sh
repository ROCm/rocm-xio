#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Unbind NVMe device from kernel driver and bind to nvme_axiio driver
#
# Usage:
#   ./bind-nvme-to-axiio.sh <nvme-device>
#   ./bind-nvme-to-axiio.sh /dev/nvme1
#   ./bind-nvme-to-axiio.sh 0000:01:00.0
#   ./bind-nvme-to-axiio.sh --list
#   ./bind-nvme-to-axiio.sh --unbind-all

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

KERNEL_NVME_DRIVER="/sys/bus/pci/drivers/nvme"
AXIIO_DRIVER="/sys/bus/pci/drivers/nvme_axiio"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# List all NVMe devices
list_nvme_devices() {
    echo "=== Available NVMe Devices ==="
    echo ""
    
    for dev in /sys/class/nvme/nvme*/device; do
        if [ -L "$dev" ]; then
            pci_addr=$(basename $(readlink -f "$dev"))
            nvme_dev=$(basename $(dirname "$dev"))
            
            # Get device info
            model=""
            if [ -f "/sys/class/nvme/$nvme_dev/model" ]; then
                model=$(cat "/sys/class/nvme/$nvme_dev/model" | tr -d ' ')
            fi
            
            # Check current driver
            driver="none"
            if [ -L "$dev/driver" ]; then
                driver=$(basename $(readlink -f "$dev/driver"))
            fi
            
            # Check if it's a boot device (has mounted partitions)
            is_boot="no"
            for part in /sys/block/${nvme_dev}n*/holders/*; do
                if [ -e "$part" ]; then
                    is_boot="yes (mounted)"
                    break
                fi
            done
            
            # Check for mounted filesystems
            if mount | grep -q "^/dev/${nvme_dev}n"; then
                is_boot="yes (mounted)"
            fi
            
            echo "Device: $nvme_dev"
            echo "  PCI Address: $pci_addr"
            echo "  Model: ${model:-Unknown}"
            echo "  Driver: $driver"
            echo "  Boot/Mounted: $is_boot"
            echo ""
        fi
    done
}

# Convert /dev/nvmeX to PCI address
nvme_to_pci() {
    local nvme_dev="$1"
    
    # Remove /dev/ prefix if present
    nvme_dev="${nvme_dev#/dev/}"
    
    # If already a PCI address, return it
    if [[ "$nvme_dev" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]$ ]]; then
        echo "$nvme_dev"
        return 0
    fi
    
    # Convert nvmeX to PCI address
    if [ -L "/sys/class/nvme/$nvme_dev/device" ]; then
        pci_addr=$(basename $(readlink -f "/sys/class/nvme/$nvme_dev/device"))
        echo "$pci_addr"
        return 0
    fi
    
    print_error "Could not find PCI address for $nvme_dev"
    return 1
}

# Check if device is safe to unbind (not boot device)
check_safe_to_unbind() {
    local nvme_dev="$1"
    
    # Remove /dev/ prefix if present
    nvme_dev="${nvme_dev#/dev/}"
    
    # Check for mounted partitions
    if mount | grep -q "^/dev/${nvme_dev}n"; then
        print_error "Device $nvme_dev has mounted partitions!"
        print_error "This may be your root filesystem. Unbinding would cause system failure!"
        mount | grep "^/dev/${nvme_dev}n"
        return 1
    fi
    
    # Check for active swap
    if swapon --show | grep -q "/dev/${nvme_dev}n"; then
        print_warn "Device $nvme_dev is used for swap"
        return 1
    fi
    
    return 0
}

# Unbind device from kernel driver
unbind_from_kernel() {
    local pci_addr="$1"
    
    print_info "Unbinding $pci_addr from kernel nvme driver..."
    
    # Check if bound to nvme driver
    if [ ! -L "$KERNEL_NVME_DRIVER/$pci_addr" ]; then
        print_warn "Device $pci_addr is not bound to kernel nvme driver"
        return 0
    fi
    
    # Unbind
    echo "$pci_addr" | sudo tee "$KERNEL_NVME_DRIVER/unbind" > /dev/null
    
    if [ $? -eq 0 ]; then
        print_info "✓ Unbound $pci_addr from kernel driver"
        return 0
    else
        print_error "Failed to unbind $pci_addr"
        return 1
    fi
}

# Bind device to axiio driver
bind_to_axiio() {
    local pci_addr="$1"
    
    print_info "Binding $pci_addr to nvme_axiio driver..."
    
    # Check if axiio driver exists
    if [ ! -d "$AXIIO_DRIVER" ]; then
        print_error "nvme_axiio driver not loaded!"
        print_info "Load it with: sudo insmod kernel-module/nvme_axiio.ko"
        return 1
    fi
    
    # Bind
    echo "$pci_addr" | sudo tee "$AXIIO_DRIVER/bind" > /dev/null
    
    if [ $? -eq 0 ]; then
        print_info "✓ Bound $pci_addr to nvme_axiio driver"
        return 0
    else
        print_error "Failed to bind $pci_addr to nvme_axiio"
        return 1
    fi
}

# Main bind operation
bind_device() {
    local device="$1"
    
    print_info "Target device: $device"
    
    # Convert to PCI address
    pci_addr=$(nvme_to_pci "$device")
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    print_info "PCI address: $pci_addr"
    
    # Safety check
    nvme_dev="${device#/dev/}"
    if ! [[ "$nvme_dev" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]$ ]]; then
        if ! check_safe_to_unbind "$nvme_dev"; then
            print_error "Refusing to unbind device for safety"
            print_info "Use --force to override (DANGEROUS!)"
            return 1
        fi
    fi
    
    # Unbind from kernel driver
    if ! unbind_from_kernel "$pci_addr"; then
        return 1
    fi
    
    sleep 1
    
    # Bind to axiio driver
    if ! bind_to_axiio "$pci_addr"; then
        print_warn "Bind failed, rebinding to kernel driver..."
        echo "$pci_addr" | sudo tee "$KERNEL_NVME_DRIVER/bind" > /dev/null
        return 1
    fi
    
    print_info "✓ Device $device is now controlled by nvme_axiio driver"
    print_info "  Access via /dev/nvme-axiio"
    return 0
}

# Unbind from axiio and return to kernel driver
unbind_device() {
    local device="$1"
    
    print_info "Returning $device to kernel driver..."
    
    # Convert to PCI address
    pci_addr=$(nvme_to_pci "$device")
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Unbind from axiio
    if [ -L "$AXIIO_DRIVER/$pci_addr" ]; then
        echo "$pci_addr" | sudo tee "$AXIIO_DRIVER/unbind" > /dev/null
        print_info "✓ Unbound from nvme_axiio"
    fi
    
    sleep 1
    
    # Rebind to kernel driver
    if [ -d "$KERNEL_NVME_DRIVER" ]; then
        echo "$pci_addr" | sudo tee "$KERNEL_NVME_DRIVER/bind" > /dev/null
        print_info "✓ Rebound to kernel nvme driver"
    fi
    
    return 0
}

# Show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] <device>

Unbind NVMe device from kernel driver and bind to nvme_axiio for GPU-direct I/O.

OPTIONS:
    --list              List all NVMe devices and their status
    --unbind <device>   Return device to kernel driver
    --force             Skip safety checks (DANGEROUS!)
    --help              Show this help message

ARGUMENTS:
    device              NVMe device (/dev/nvme1) or PCI address (0000:01:00.0)

EXAMPLES:
    # List all NVMe devices
    $0 --list
    
    # Bind nvme1 to nvme_axiio driver
    $0 /dev/nvme1
    
    # Unbind and return to kernel driver
    $0 --unbind /dev/nvme1
    
    # Use PCI address directly
    $0 0000:01:00.0

SAFETY:
    - Script checks for mounted filesystems before unbinding
    - Will refuse to unbind boot/root devices
    - Use --force to override (NOT RECOMMENDED)

NOTES:
    - Requires nvme_axiio.ko to be loaded
    - Device will be inaccessible to kernel after binding
    - Use --unbind to restore normal operation

EOF
}

# Parse arguments
FORCE=0
ACTION="bind"
DEVICE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --list)
            list_nvme_devices
            exit 0
            ;;
        --unbind)
            ACTION="unbind"
            shift
            DEVICE="$1"
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            DEVICE="$1"
            shift
            ;;
    esac
done

# Check for root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root"
    print_info "Try: sudo $0 $@"
    exit 1
fi

# Require device argument
if [ -z "$DEVICE" ]; then
    print_error "No device specified"
    usage
    exit 1
fi

# Execute action
if [ "$ACTION" = "bind" ]; then
    bind_device "$DEVICE"
elif [ "$ACTION" = "unbind" ]; then
    unbind_device "$DEVICE"
fi

exit $?

