#!/bin/bash
# NVMe I/O Testing Script with Data Verification
# This script performs actual NVMe write and read operations and verifies data integrity

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
NVME_DEVICE="${NVME_DEVICE:-/dev/nvme0}"
NVME_NS="${NVME_NS:-${NVME_DEVICE}n1}"
NAMESPACE_ID="${NAMESPACE_ID:-1}"
START_LBA="${START_LBA:-0}"
NUM_BLOCKS="${NUM_BLOCKS:-8}"
BLOCK_SIZE="${BLOCK_SIZE:-4096}"
TEST_PATTERN="${TEST_PATTERN:-random}"
VERIFY_MODE="${VERIFY_MODE:-strict}"
ITERATIONS="${ITERATIONS:-1}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}NVMe I/O Data Verification Test${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script requires root privileges${NC}"
    echo "Run with: sudo $0"
    exit 1
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n)
            NAMESPACE_ID="$2"
            shift 2
            ;;
        --start-lba|-s)
            START_LBA="$2"
            shift 2
            ;;
        --num-blocks|-b)
            NUM_BLOCKS="$2"
            shift 2
            ;;
        --block-size|-z)
            BLOCK_SIZE="$2"
            shift 2
            ;;
        --pattern|-p)
            TEST_PATTERN="$2"
            shift 2
            ;;
        --iterations|-i)
            ITERATIONS="$2"
            shift 2
            ;;
        --help|-h)
            cat << EOF
Usage: $0 [OPTIONS]

NVMe I/O testing with data verification. Writes test patterns to an NVMe
device, reads them back, and verifies data integrity.

Options:
  -n, --namespace <id>      Namespace ID (default: 1)
  -s, --start-lba <lba>     Starting LBA (default: 0)
  -b, --num-blocks <n>      Number of blocks to test (default: 8)
  -z, --block-size <bytes>  Block size in bytes (default: 4096)
  -p, --pattern <type>      Test pattern: random, sequential, zeros, ones
                            (default: random)
  -i, --iterations <n>      Number of test iterations (default: 1)
  -h, --help                Show this help message

Environment Variables:
  NVME_DEVICE              NVMe device (default: /dev/nvme0)
  NVME_NS                  Namespace device (default: /dev/nvme0n1)

Examples:
  # Basic test with default parameters:
  sudo $0

  # Test 16 blocks starting at LBA 1000:
  sudo $0 --start-lba 1000 --num-blocks 16

  # Multiple iterations with sequential pattern:
  sudo $0 --pattern sequential --iterations 10

  # Test specific namespace:
  sudo $0 --namespace 2 --start-lba 0 --num-blocks 32

Safety Warning:
  ⚠️  This script WRITES DATA to the NVMe device!
  ⚠️  Ensure the target LBAs do not contain important data!
  ⚠️  Use a dedicated test device or test namespace!

EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Safety check
if [ ! -b "$NVME_NS" ]; then
    echo -e "${RED}Error: Namespace device $NVME_NS not found${NC}"
    echo "Available namespaces:"
    ls -l ${NVME_DEVICE}n* 2>/dev/null || echo "  None found"
    exit 1
fi

# Query actual NVMe LBA size from device
NVME_NS_INFO=$(nvme id-ns "$NVME_NS" -n $NAMESPACE_ID 2>/dev/null)
FLBAS=$(echo "$NVME_NS_INFO" | grep "^flbas" | awk '{print $3}')
FORMAT_IDX=$((FLBAS & 0x0F))
LBADS=$(echo "$NVME_NS_INFO" | grep "^lbaf *${FORMAT_IDX}" | grep -oP 'lbads:\K[0-9]+' || echo "9")
NVME_LBA_SIZE=$((2**LBADS))

# Display configuration
echo -e "${CYAN}Device Information:${NC}"
echo "  Device: $NVME_DEVICE"
echo "  Namespace: $NVME_NS (ID: $NAMESPACE_ID)"
echo "  NVMe LBA Size: $NVME_LBA_SIZE bytes (detected from device)"
echo ""

echo -e "${CYAN}Test Configuration:${NC}"
echo "  Start LBA: $START_LBA"
echo "  Test Blocks (application-level): $NUM_BLOCKS"
echo "  Block Size (application-level): $BLOCK_SIZE bytes"
echo "  Total Data Size: $((NUM_BLOCKS * BLOCK_SIZE)) bytes"
echo "  NVMe LBAs Required: $(((NUM_BLOCKS * BLOCK_SIZE) / NVME_LBA_SIZE))"
echo "  Test Pattern: $TEST_PATTERN"
echo "  Iterations: $ITERATIONS"
echo ""

# Check for mounted filesystems
if mount | grep -q "$NVME_NS"; then
    echo -e "${RED}Error: Namespace $NVME_NS has mounted filesystem!${NC}"
    mount | grep "$NVME_NS"
    echo ""
    echo "Unmount the filesystem first or choose a different namespace/LBA range."
    exit 1
fi

echo -e "${YELLOW}Safety Check:${NC}"
echo "  ⚠️  This test will WRITE to LBAs $START_LBA through $((START_LBA + NUM_BLOCKS - 1))"
echo "  ⚠️  Existing data in this range will be OVERWRITTEN"
echo ""
read -p "Continue? (yes/no): " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Test cancelled."
    exit 0
fi

# Create temporary directory for test data
TMPDIR="/tmp/nvme-io-test-$$"
mkdir -p "$TMPDIR"

# Cleanup handler
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    rm -rf "$TMPDIR"
    echo -e "${GREEN}✓ Cleanup complete${NC}"
}
trap cleanup EXIT INT TERM

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Generating Test Pattern${NC}"
echo -e "${BLUE}========================================${NC}"

# Generate test data based on pattern
WRITE_FILE="$TMPDIR/write_data.bin"
READ_FILE="$TMPDIR/read_data.bin"
TOTAL_SIZE=$((NUM_BLOCKS * BLOCK_SIZE))

case $TEST_PATTERN in
    random)
        echo "Generating random data..."
        dd if=/dev/urandom of="$WRITE_FILE" bs=$BLOCK_SIZE count=$NUM_BLOCKS 2>/dev/null
        ;;
    sequential)
        echo "Generating sequential pattern..."
        for i in $(seq 0 $((NUM_BLOCKS - 1))); do
            # Create a block with incrementing bytes
            perl -e "print pack('C*', map { (\$_ + $i * 256) % 256 } (0..4095))" >> "$WRITE_FILE"
        done
        ;;
    zeros)
        echo "Generating zeros..."
        dd if=/dev/zero of="$WRITE_FILE" bs=$BLOCK_SIZE count=$NUM_BLOCKS 2>/dev/null
        ;;
    ones)
        echo "Generating ones (0xFF pattern)..."
        tr '\0' '\377' < /dev/zero | dd of="$WRITE_FILE" bs=$BLOCK_SIZE count=$NUM_BLOCKS 2>/dev/null
        ;;
    *)
        echo -e "${RED}Error: Unknown pattern: $TEST_PATTERN${NC}"
        exit 1
        ;;
esac

# Calculate checksum of write data
WRITE_MD5=$(md5sum "$WRITE_FILE" | awk '{print $1}')
echo "  Write data MD5: $WRITE_MD5"
echo "  Size: $(stat -c%s "$WRITE_FILE") bytes"

# Run test iterations
PASS_COUNT=0
FAIL_COUNT=0

for iter in $(seq 1 $ITERATIONS); do
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Iteration $iter of $ITERATIONS${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    # Step 1: Write data
    echo ""
    echo -e "${YELLOW}Step 1: Writing test data to NVMe...${NC}"
    START_TIME=$(date +%s.%N)
    
    # Calculate NVMe block count (nvme-cli uses -c for "count-1", so 0 = 1 block)
    NVME_BLOCK_COUNT=$(((TOTAL_SIZE / NVME_LBA_SIZE) - 1))
    
    # Use nvme write command (short options for compatibility)
    if ! nvme write "$NVME_NS" \
        -s $START_LBA \
        -c $NVME_BLOCK_COUNT \
        -z $TOTAL_SIZE \
        -d "$WRITE_FILE" \
        -n $NAMESPACE_ID 2>&1 | grep -qv "^$"; then
        echo -e "${RED}✗ Write failed${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    
    # Flush to ensure data persistence
    nvme flush "$NVME_NS" -n $NAMESPACE_ID >/dev/null 2>&1
    
    WRITE_TIME=$(date +%s.%N)
    WRITE_DURATION=$(echo "$WRITE_TIME - $START_TIME" | bc)
    WRITE_BW=$(echo "scale=2; ($TOTAL_SIZE / 1048576) / $WRITE_DURATION" | bc)
    
    echo -e "${GREEN}✓ Write completed${NC}"
    echo "  Duration: ${WRITE_DURATION}s"
    echo "  Bandwidth: ${WRITE_BW} MB/s"
    
    # Step 2: Read data back
    echo ""
    echo -e "${YELLOW}Step 2: Reading data back from NVMe...${NC}"
    
    if ! nvme read "$NVME_NS" \
        -s $START_LBA \
        -c $NVME_BLOCK_COUNT \
        -z $TOTAL_SIZE \
        -d "$READ_FILE" \
        -n $NAMESPACE_ID 2>&1 | grep -qv "^$"; then
        echo -e "${RED}✗ Read failed${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    
    READ_TIME=$(date +%s.%N)
    READ_DURATION=$(echo "$READ_TIME - $WRITE_TIME" | bc)
    READ_BW=$(echo "scale=2; ($TOTAL_SIZE / 1048576) / $READ_DURATION" | bc)
    
    echo -e "${GREEN}✓ Read completed${NC}"
    echo "  Duration: ${READ_DURATION}s"
    echo "  Bandwidth: ${READ_BW} MB/s"
    
    # Step 3: Verify data
    echo ""
    echo -e "${YELLOW}Step 3: Verifying data integrity...${NC}"
    
    READ_MD5=$(md5sum "$READ_FILE" | awk '{print $1}')
    echo "  Read data MD5:  $READ_MD5"
    echo "  Write data MD5: $WRITE_MD5"
    
    if [ "$READ_MD5" = "$WRITE_MD5" ]; then
        echo -e "${GREEN}✓ Data verification PASSED${NC}"
        echo "  All $NUM_BLOCKS blocks verified successfully"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "${RED}✗ Data verification FAILED${NC}"
        echo "  Data mismatch detected!"
        
        # Show differences
        if command -v cmp &> /dev/null; then
            echo ""
            echo "First difference:"
            cmp -l "$WRITE_FILE" "$READ_FILE" | head -5
        fi
        
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    
    # Step 4: Performance summary
    TOTAL_DURATION=$(echo "$READ_TIME - $START_TIME" | bc)
    AVG_BW=$(echo "scale=2; ($TOTAL_SIZE * 2 / 1048576) / $TOTAL_DURATION" | bc)
    
    echo ""
    echo -e "${CYAN}Iteration $iter Summary:${NC}"
    echo "  Total Duration: ${TOTAL_DURATION}s"
    echo "  Average Bandwidth: ${AVG_BW} MB/s (combined read+write)"
    echo "  Status: $([ $READ_MD5 = $WRITE_MD5 ] && echo -e "${GREEN}PASS${NC}" || echo -e "${RED}FAIL${NC}")"
done

# Final summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo "  Total Iterations: $ITERATIONS"
echo "  Passed: ${GREEN}$PASS_COUNT${NC}"
echo "  Failed: $([ $FAIL_COUNT -gt 0 ] && echo -e "${RED}$FAIL_COUNT${NC}" || echo "$FAIL_COUNT")"
echo "  Success Rate: $(echo "scale=1; ($PASS_COUNT * 100) / $ITERATIONS" | bc)%"
echo ""
echo "  Device: $NVME_NS"
echo "  LBA Range: $START_LBA - $((START_LBA + NUM_BLOCKS - 1))"
echo "  Total Data: $((TOTAL_SIZE * ITERATIONS)) bytes ($((TOTAL_SIZE * ITERATIONS / 1048576)) MB)"
echo -e "${BLUE}========================================${NC}"

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed${NC}"
    exit 1
fi

