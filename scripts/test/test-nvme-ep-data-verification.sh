#!/bin/bash
#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Test nvme-ep against an NVMe device (real or emulated)
# Verifies that written data matches expected LFSR pattern for given seed
# The program auto-detects if the device is emulated or passthrough

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Parse command line arguments
NVME_DEVICE=""
LFSR_SEED="${LFSR_SEED:-0x1234}"
BASE_LBA="${BASE_LBA:-0}"
READ_IO="${READ_IO:-0}"
WRITE_IO="${WRITE_IO:-4}"
BLOCKS_PER_CMD="${BLOCKS_PER_CMD:-8}"
QUEUE_LENGTH="${QUEUE_LENGTH:-1024}"
DATA_BUFFER_SIZE="${DATA_BUFFER_SIZE:-1048576}"  # 1MB
MEMORY_MODE="${MEMORY_MODE:-0}"
USE_PCI_MMIO_BRIDGE="${USE_PCI_MMIO_BRIDGE:-1}"  # Default: use PCI MMIO bridge

# Paths
XIO_TESTER="${XIO_TESTER:-./build/xio-tester}"
TEMP_DIR="${TEMP_DIR:-/tmp/nvme-ep-test}"
NVME_CMD="${NVME_CMD:-nvme}"

# Parse arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <nvme-controller> [OPTIONS]"
    echo ""
    echo "Arguments:"
    echo "  <nvme-controller>   NVMe controller device (e.g., /dev/nvme0)"
    echo ""
    echo "Environment variables:"
    echo "  LFSR_SEED          LFSR seed (default: 0x1234)"
    echo "  BASE_LBA           Starting LBA (default: 0)"
    echo "  READ_IO            Number of read I/O operations (default: 0)"
    echo "  WRITE_IO           Number of write I/O operations (default: 4)"
    echo "  MEMORY_MODE        Memory mode: 0=host, 8=device (default: 0)"
    echo "  USE_PCI_MMIO_BRIDGE Use PCI MMIO bridge: 0=no, 1=yes (default: 1)"
    echo ""
    exit 1
fi

NVME_DEVICE="$1"
shift

# Parse remaining options
while [[ $# -gt 0 ]]; do
    case $1 in
        --seed|-s)
            LFSR_SEED="$2"
            shift 2
            ;;
        --base-lba|-b)
            BASE_LBA="$2"
            shift 2
            ;;
        --read-io|-r)
            READ_IO="$2"
            shift 2
            ;;
        --write-io|-w)
            WRITE_IO="$2"
            shift 2
            ;;
        --iterations|-i)
            # Legacy support: map to write-io
            WRITE_IO="$2"
            shift 2
            ;;
        --no-pci-mmio-bridge)
            USE_PCI_MMIO_BRIDGE="0"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 <nvme-controller> [OPTIONS]"
            echo ""
            echo "Arguments:"
            echo "  <nvme-controller>   NVMe controller device (e.g., /dev/nvme0)"
            echo ""
            echo "Options:"
            echo "  --seed, -s <seed>       LFSR seed (default: 0x1234)"
            echo "  --base-lba, -b <lba>    Starting LBA (default: 0)"
            echo "  --read-io, -r <num>     Number of read I/O operations (default: 0)"
            echo "  --write-io, -w <num>    Number of write I/O operations (default: 4)"
            echo "  --iterations, -i <num>  Legacy: maps to --write-io (default: 4)"
            echo "  --no-pci-mmio-bridge   Disable PCI MMIO bridge mode"
            echo ""
            echo "Environment variables:"
            echo "  READ_IO                Number of read I/O operations (default: 0)"
            echo "  WRITE_IO               Number of write I/O operations (default: 4)"
            echo "  MEMORY_MODE            Memory mode: 0=host, 8=device (default: 0)"
            echo "  USE_PCI_MMIO_BRIDGE    Use PCI MMIO bridge: 0=no, 1=yes (default: 1)"
            echo ""
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option $1${NC}"
            exit 1
            ;;
    esac
done

# Create temp directory for logs
mkdir -p "$TEMP_DIR"
TEST_LOG="$TEMP_DIR/test.log"

# Redirect all verbose output to log file
exec 3>&1 4>&2
exec 1>"$TEST_LOG" 2>&1

# Function to print to console (for PASS/FAIL messages)
print_console() {
    echo "$@" >&3
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script requires root privileges${NC}"
    echo "Run with: sudo $0"
    exit 1
fi

# Check if device exists
if [ ! -e "$NVME_DEVICE" ]; then
    echo -e "${RED}Error: NVMe device $NVME_DEVICE not found${NC}"
    exit 1
fi

# Check if xio-tester exists
if [ ! -f "$XIO_TESTER" ]; then
    echo -e "${RED}Error: xio-tester not found at $XIO_TESTER${NC}"
    echo "Build it first with: make"
    exit 1
fi

# Check if nvme command is available
if ! command -v "$NVME_CMD" &> /dev/null; then
    echo -e "${RED}Error: nvme command not found${NC}"
    echo "Install nvme-cli package"
    exit 1
fi

# Temp directory already created above

# Function to get LBA size from device
get_lba_size() {
    local device=$1
    local ns="${device}n1"
    
    # Try to get LBA size from identify namespace
    # nvme-cli output format: "lbaf  0 : ms:0   lbads:9  rp:0x2 (in use)"
    # We need to match format entries (starting with "lbaf"), not "nlbaf"
    # Find the format marked "(in use)" and extract lbads value
    local lbaf_line=$($NVME_CMD id-ns "$ns" 2>/dev/null | grep "^lbaf" | grep "in use" | head -1)
    if [ -n "$lbaf_line" ]; then
        # Extract lbads field (field 5 contains "lbads:9")
        local lbads_str=$(echo "$lbaf_line" | awk '{print $5}')
        if [ -n "$lbads_str" ]; then
            # Extract number after colon: "lbads:9" -> "9"
            local lbads=$(echo "$lbads_str" | cut -d: -f2)
            if [ -n "$lbads" ] && [ "$lbads" -ge 0 ] 2>/dev/null; then
                # LBA size = 2^lbads bytes
                echo $((1 << lbads))
                return
            fi
        fi
    fi
    
    # Fallback: try to get any format entry (first one)
    local lbaf_line=$($NVME_CMD id-ns "$ns" 2>/dev/null | grep "^lbaf" | head -1)
    if [ -n "$lbaf_line" ]; then
        local lbads_str=$(echo "$lbaf_line" | awk '{print $5}')
        if [ -n "$lbads_str" ]; then
            local lbads=$(echo "$lbads_str" | cut -d: -f2)
            if [ -n "$lbads" ] && [ "$lbads" -ge 0 ] 2>/dev/null; then
                echo $((1 << lbads))
                return
            fi
        fi
    fi
    
    # Default to 512 bytes if all else fails
    echo 512
}

# Function to generate expected pattern for what was written to device
# The pattern generation uses actual LBA size: lba = offset / lba_size
# Pattern is generated once for entire buffer with offset=0
# Each write command i uses buffer[i*transfer_size..(i+1)*transfer_size-1] 
# and writes it to device LBA base_lba + i*blocks
# So we need to map device LBAs back to buffer offsets to get the pattern
generate_expected_pattern() {
    local total_size=$1
    local lba_size=$2
    local seed=$3
    local output_file=$4
    local base_lba=$5
    local blocks_per_cmd=$6
    local num_iterations=$7
    
    # Use Python to generate the pattern (matches C++ algorithm)
    # Pass seed as string to ensure proper hex conversion
    # Use single quotes around seed to prevent bash arithmetic expansion
    python3 << EOF > "$output_file"
import struct
import sys

total_size = $total_size
lba_size = $lba_size
seed_str = '${seed}'
base_lba = $base_lba
blocks_per_cmd = $blocks_per_cmd
num_iterations = $num_iterations

# Convert hex seed
if seed_str.startswith('0x') or seed_str.startswith('0X'):
    seed = int(seed_str, 16)
elif seed_str.startswith('0') and len(seed_str) > 1:
    # Handle octal (though we use hex)
    seed = int(seed_str, 8)
else:
    seed = int(seed_str)

# Pattern generation: nvme_generate_pattern(writeBuffer, bufferSize, 0, lbaSize, lfsr_seed)
# The function calculates: lba = offset / lbaSize = 0 / lbaSize = 0 (calculated ONCE)
# Then for each byte i in the buffer: rng = (lba * 0x9e3779b9 + seed + i)
# So pattern at buffer byte i uses: lba=0, byte_index=i

# Each write command i:
#   - Uses buffer[i * transfer_size .. (i+1) * transfer_size - 1]
#   - Writes to device LBA base_lba + i * blocks_per_cmd
#   - transfer_size = blocks_per_cmd * lba_size

transfer_size = blocks_per_cmd * lba_size
pattern = bytearray()

# Generate pattern for what was written to each device byte
# For device byte at position 'pos' (0..total_size-1):
#   - Device LBA = base_lba + (pos // lba_size)
#   - Which write iteration = (device_lba - base_lba) // blocks_per_cmd
#   - Buffer byte index = iteration * transfer_size + (pos % transfer_size)
#   - Pattern uses: lba=0 (from offset=0), byte_index=buffer_byte_index

for pos in range(total_size):
    device_lba = base_lba + (pos // lba_size)
    
    # Find which iteration wrote this LBA
    lba_offset_from_base = device_lba - base_lba
    iteration = lba_offset_from_base // blocks_per_cmd
    lba_within_iteration = lba_offset_from_base % blocks_per_cmd
    byte_offset_within_lba = pos % lba_size
    
    # Calculate buffer byte index for this device byte
    # Buffer offset = iteration * transfer_size + lba_within_iteration * lba_size + byte_offset_within_lba
    buffer_byte_index = iteration * transfer_size + lba_within_iteration * lba_size + byte_offset_within_lba
    
    # Pattern generation uses: lba = 0 (from offset=0), byte_index = buffer_byte_index
    pattern_lba = 0  # Always 0 because offset=0
    
    base_seed = (pattern_lba * 0x12345678) & 0xFFFFFFFF
    combined_seed = (base_seed ^ seed) & 0xFFFFFFFF
    
    # Use buffer_byte_index as the 'i' parameter in pattern generation
    rng = (pattern_lba * 0x9e3779b9 + combined_seed + buffer_byte_index) & 0xFFFFFFFF
    rng ^= rng >> 16
    rng = (rng * 0x85ebca6b) & 0xFFFFFFFF
    rng ^= rng >> 13
    rng = (rng * 0xc2b2ae35) & 0xFFFFFFFF
    rng ^= rng >> 16
    pattern.append(rng & 0xFF)

sys.stdout.buffer.write(pattern)
EOF
}

# Function to test a device
test_device() {
    local device=$1
    local ns="${device}n1"
    local device_name=$(basename "$device")
    
    echo "========================================"
    echo "Testing NVMe: $device"
    echo "========================================"
    
    # Get LBA size
    local lba_size=$(get_lba_size "$device")
    echo "LBA size: $lba_size bytes"
    
    # Calculate total data written
    local total_blocks=$((WRITE_IO * BLOCKS_PER_CMD))
    local total_bytes=$((total_blocks * lba_size))
    echo "Total data: $total_blocks blocks ($total_bytes bytes)"
    
    # Step 1: Write data using nvme-ep
    echo ""
    echo "Step 1: Writing data with nvme-ep..."
    
    local write_cmd="$XIO_TESTER nvme-ep -v"
    if [ "$READ_IO" -gt 0 ]; then
        write_cmd="$write_cmd --read-io $READ_IO"
    fi
    if [ "$WRITE_IO" -gt 0 ]; then
        write_cmd="$write_cmd --write-io $WRITE_IO"
    fi
    write_cmd="$write_cmd --controller $device"
    if [ "$USE_PCI_MMIO_BRIDGE" = "1" ]; then
        write_cmd="$write_cmd --pci-mmio-bridge"
    fi
    write_cmd="$write_cmd --queue-length $QUEUE_LENGTH"
    write_cmd="$write_cmd --lfsr-seed $LFSR_SEED"
    write_cmd="$write_cmd --base-lba $BASE_LBA"
    write_cmd="$write_cmd --lbas-per-io $BLOCKS_PER_CMD"
    write_cmd="$write_cmd --access-pattern sequential"
    write_cmd="$write_cmd -m $MEMORY_MODE"
    
    echo "Command: $write_cmd"
    
    if ! sudo $write_cmd > "$TEMP_DIR/${device_name}_write.log" 2>&1; then
        echo "✗ Write failed - check log: $TEMP_DIR/${device_name}_write.log"
        return 1
    fi
    
    # Extract LBA size from C++ output to verify it matches
    local detected_lba_size=$(grep -i "Selected LBA size" "$TEMP_DIR/${device_name}_write.log" | grep -oE "[0-9]+" | head -1)
    if [ -n "$detected_lba_size" ] && [ "$detected_lba_size" != "$lba_size" ]; then
        echo "Warning: LBA size mismatch - using C++ detected size: $detected_lba_size bytes"
        lba_size=$detected_lba_size
        total_bytes=$((total_blocks * lba_size))
    fi
    
    echo "✓ Write completed"
    
    # Step 2: Read data back using nvme command
    echo ""
    echo "Step 2: Reading data back..."
    
    local read_file="$TEMP_DIR/${device_name}_read.bin"
    local expected_file="$TEMP_DIR/${device_name}_expected.bin"
    
    # Read back the data
    if ! $NVME_CMD read "$ns" --start-block=$BASE_LBA --block-count=$total_blocks \
         --data-size=$total_bytes --data="$read_file" > /dev/null 2>&1; then
        echo "✗ Read failed"
        return 1
    fi
    
    echo "✓ Read completed"
    
    # Step 3: Generate expected pattern and verify
    echo ""
    echo "Step 3: Verifying data pattern..."
    
    generate_expected_pattern $total_bytes $lba_size "$LFSR_SEED" "$expected_file" \
        $BASE_LBA $BLOCKS_PER_CMD $WRITE_IO
    
    # Check each iteration separately for better error reporting
    local offset=0
    local all_match=true
    
    for ((i=0; i<WRITE_IO; i++)); do
        local lba=$((BASE_LBA + i * BLOCKS_PER_CMD))
        local block_size=$((BLOCKS_PER_CMD * lba_size))
        
        local expected_block="$TEMP_DIR/${device_name}_expected_block_${i}.bin"
        local read_block="$TEMP_DIR/${device_name}_read_block_${i}.bin"
        
        # Extract blocks from expected and read files
        dd if="$expected_file" of="$expected_block" bs=1 skip=$offset count=$block_size 2>/dev/null
        dd if="$read_file" of="$read_block" bs=1 skip=$offset count=$block_size 2>/dev/null
        
        if ! cmp -s "$read_block" "$expected_block"; then
            echo "✗ Iteration $i (LBA $lba-$((lba + BLOCKS_PER_CMD - 1))) mismatch"
            echo "  First differences:" >> "$TEMP_DIR/${device_name}_mismatches.log"
            cmp -l "$read_block" "$expected_block" 2>/dev/null | head -10 >> "$TEMP_DIR/${device_name}_mismatches.log" || true
            all_match=false
        fi
        
        offset=$((offset + block_size))
    done
    
    if [ "$all_match" = true ]; then
        echo "✓ All data verified successfully!"
        return 0
    else
        echo "✗ Data verification failed - see $TEMP_DIR/${device_name}_mismatches.log"
        return 1
    fi
}

# Run test and capture result
test_result=0
test_device "$NVME_DEVICE" || test_result=$?

# Restore stdout/stderr
exec 1>&3 2>&4
exec 3>&- 4>&-

# Generate test summary line
pci_mmio_status=$([ "$USE_PCI_MMIO_BRIDGE" = "1" ] && echo "pci-mmio" || echo "direct")
mem_mode_status=$([ "$MEMORY_MODE" = "8" ] && echo "device-mem" || echo "host-mem")
test_params="seed=$LFSR_SEED base_lba=$BASE_LBA read=$READ_IO write=$WRITE_IO blocks=$BLOCKS_PER_CMD $pci_mmio_status $mem_mode_status"

# Print result to stderr (so it shows even when stdout is redirected)
if [ $test_result -eq 0 ]; then
    echo -e "${GREEN}PASS${NC}: $test_params" >&2
    exit 0
else
    echo -e "${RED}FAIL${NC}: $test_params" >&2
    exit 1
fi

