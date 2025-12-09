#!/bin/bash
# Test NVMe real I/O using axiio-tester with actual data buffers

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
NVME_DEVICE="${NVME_DEVICE:-/dev/nvme0}"
NAMESPACE_ID="${NAMESPACE_ID:-1}"
QUEUE_SIZE="${QUEUE_SIZE:-16}"
NUM_BLOCKS="${NUM_BLOCKS:-8}"
BLOCK_SIZE="${BLOCK_SIZE:-4096}"
TEST_ITERATIONS="${TEST_ITERATIONS:-10}"
VERBOSE="${VERBOSE:-0}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}NVMe Real I/O Test with axiio-tester${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script requires root privileges${NC}"
    exit 1
fi

# Check prerequisites
if [ ! -e "$NVME_DEVICE" ]; then
    echo -e "${RED}Error: NVMe device $NVME_DEVICE not found${NC}"
    exit 1
fi

if [ ! -f bin/axiio-tester ]; then
    echo -e "${RED}Error: axiio-tester not found. Build first with 'make all'${NC}"
    exit 1
fi

echo -e "${CYAN}Test Configuration:${NC}"
echo "  Device: $NVME_DEVICE"
echo "  Namespace ID: $NAMESPACE_ID"
echo "  Queue Size: $QUEUE_SIZE"
echo "  Num Blocks: $NUM_BLOCKS"
echo "  Block Size: $BLOCK_SIZE bytes"
echo "  Buffer Size: $((NUM_BLOCKS * BLOCK_SIZE)) bytes"
echo "  Iterations: $TEST_ITERATIONS"
echo ""

# Get device information
PCI_ADDR=$(readlink -f /sys/class/nvme/${NVME_DEVICE##*/}/device | xargs basename)
echo "  PCI Address: $PCI_ADDR"

# Get BAR0 address
BAR0_ADDR=$(cat /sys/class/nvme/${NVME_DEVICE##*/}/device/resource | head -1 | awk '{print $1}')
echo "  BAR0 Address: $BAR0_ADDR"

# Calculate doorbell base (BAR0 + 0x1000)
DB_BASE=$((BAR0_ADDR + 0x1000))
printf "  Doorbell Base: 0x%x\n" $DB_BASE

# Create temporary directory
TMPDIR="/tmp/nvme-real-io-$$"
mkdir -p "$TMPDIR"

cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    if [ -n "$HELPER_PID" ]; then
        echo "quit" > /dev/stdin 2>/dev/null || true
        kill $HELPER_PID 2>/dev/null || true
    fi
    rm -rf "$TMPDIR"
    echo -e "${GREEN}✓ Cleanup complete${NC}"
}
trap cleanup EXIT INT TERM

echo ""
echo -e "${YELLOW}Allocating data buffers...${NC}"

# Calculate buffer size (for both read and write buffers)
BUFFER_SIZE=$((NUM_BLOCKS * BLOCK_SIZE))
echo "  Buffer size: $BUFFER_SIZE bytes"

# Create helper program to allocate buffers and get physical addresses
cat > "$TMPDIR/alloc_buffers.c" << 'EOFC'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <stdint.h>

uint64_t virt_to_phys(void* virt_addr) {
    int fd = open("/proc/self/pagemap", O_RDONLY);
    if (fd < 0) return 0;
    
    long page_size = sysconf(_SC_PAGE_SIZE);
    uint64_t offset = ((uint64_t)virt_addr / page_size) * sizeof(uint64_t);
    
    if (lseek(fd, offset, SEEK_SET) != offset) {
        close(fd);
        return 0;
    }
    
    uint64_t page_info;
    if (read(fd, &page_info, sizeof(uint64_t)) != sizeof(uint64_t)) {
        close(fd);
        return 0;
    }
    
    close(fd);
    
    if (!(page_info & (1ULL << 63))) {
        return 0;
    }
    
    uint64_t pfn = page_info & ((1ULL << 55) - 1);
    return (pfn * page_size) + ((uint64_t)virt_addr % page_size);
}

int main(int argc, char** argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <buffer_size>\n", argv[0]);
        return 1;
    }
    
    size_t size = atoi(argv[1]);
    
    // Allocate read and write buffers
    void* read_buf = mmap(NULL, size, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_LOCKED, -1, 0);
    void* write_buf = mmap(NULL, size, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANONYMOUS | MAP_LOCKED, -1, 0);
    
    if (read_buf == MAP_FAILED || write_buf == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    
    // Initialize write buffer with pattern
    memset(write_buf, 0xAA, size);
    memset(read_buf, 0x00, size);
    
    // Force pages to be mapped
    for (size_t i = 0; i < size; i += 4096) {
        ((volatile char*)read_buf)[i] = 0;
        ((volatile char*)write_buf)[i] = 0xAA;
    }
    
    // Get physical addresses
    uint64_t read_phys = virt_to_phys(read_buf);
    uint64_t write_phys = virt_to_phys(write_buf);
    
    printf("READ_BUF_VIRT=0x%lx\n", (unsigned long)read_buf);
    printf("READ_BUF_PHYS=0x%lx\n", (unsigned long)read_phys);
    printf("WRITE_BUF_VIRT=0x%lx\n", (unsigned long)write_buf);
    printf("WRITE_BUF_PHYS=0x%lx\n", (unsigned long)write_phys);
    printf("READY\n");
    fflush(stdout);
    
    // Keep buffers alive
    char buffer[256];
    fgets(buffer, sizeof(buffer), stdin);
    
    munmap(read_buf, size);
    munmap(write_buf, size);
    
    return 0;
}
EOFC

# Compile helper
gcc -o "$TMPDIR/alloc_buffers" "$TMPDIR/alloc_buffers.c" 2>/dev/null || {
    echo -e "${RED}Error: Failed to compile buffer allocation helper${NC}"
    exit 1
}

# Run helper and capture addresses
"$TMPDIR/alloc_buffers" $BUFFER_SIZE > "$TMPDIR/addrs.txt" &
HELPER_PID=$!

# Wait for READY
timeout 5 bash -c "while ! grep -q READY '$TMPDIR/addrs.txt' 2>/dev/null; do sleep 0.1; done" || {
    echo -e "${RED}Error: Helper program timeout${NC}"
    exit 1
}

# Parse addresses
READ_BUF_PHYS=$(grep READ_BUF_PHYS "$TMPDIR/addrs.txt" | cut -d= -f2)
WRITE_BUF_PHYS=$(grep WRITE_BUF_PHYS "$TMPDIR/addrs.txt" | cut -d= -f2)

echo -e "${GREEN}✓ Buffers allocated${NC}"
printf "  Read buffer:  %s\n" "$READ_BUF_PHYS"
printf "  Write buffer: %s\n" "$WRITE_BUF_PHYS"

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Running axiio-tester with real NVMe I/O${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# For now, we'll allocate queue memory as before
# (The axiio-tester will handle queue setup)
SQ_SIZE=$((QUEUE_SIZE * 64))  # 64 bytes per SQE
CQ_SIZE=$((QUEUE_SIZE * 16))  # 16 bytes per CQE

# Allocate queue buffers
cat > "$TMPDIR/alloc_queues.c" << 'EOFC'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <stdint.h>

uint64_t virt_to_phys(void* virt_addr) {
    int fd = open("/proc/self/pagemap", O_RDONLY);
    if (fd < 0) return 0;
    
    long page_size = sysconf(_SC_PAGE_SIZE);
    uint64_t offset = ((uint64_t)virt_addr / page_size) * sizeof(uint64_t);
    
    if (lseek(fd, offset, SEEK_SET) != offset) {
        close(fd);
        return 0;
    }
    
    uint64_t page_info;
    if (read(fd, &page_info, sizeof(uint64_t)) != sizeof(uint64_t)) {
        close(fd);
        return 0;
    }
    
    close(fd);
    
    if (!(page_info & (1ULL << 63))) return 0;
    
    uint64_t pfn = page_info & ((1ULL << 55) - 1);
    return (pfn * page_size) + ((uint64_t)virt_addr % page_size);
}

int main(int argc, char** argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <sq_size> <cq_size>\n", argv[0]);
        return 1;
    }
    
    size_t sq_size = atoi(argv[1]);
    size_t cq_size = atoi(argv[2]);
    
    void* sq_mem = mmap(NULL, sq_size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_LOCKED, -1, 0);
    void* cq_mem = mmap(NULL, cq_size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_LOCKED, -1, 0);
    
    if (sq_mem == MAP_FAILED || cq_mem == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    
    memset(sq_mem, 0, sq_size);
    memset(cq_mem, 0, cq_size);
    
    for (size_t i = 0; i < sq_size; i += 4096) ((volatile char*)sq_mem)[i] = 0;
    for (size_t i = 0; i < cq_size; i += 4096) ((volatile char*)cq_mem)[i] = 0;
    
    uint64_t sq_phys = virt_to_phys(sq_mem);
    uint64_t cq_phys = virt_to_phys(cq_mem);
    
    printf("SQ_PHYS=0x%lx\n", (unsigned long)sq_phys);
    printf("CQ_PHYS=0x%lx\n", (unsigned long)cq_phys);
    printf("READY\n");
    fflush(stdout);
    
    char buffer[256];
    fgets(buffer, sizeof(buffer), stdin);
    
    munmap(sq_mem, sq_size);
    munmap(cq_mem, cq_size);
    
    return 0;
}
EOFC

gcc -o "$TMPDIR/alloc_queues" "$TMPDIR/alloc_queues.c" 2>/dev/null || {
    echo -e "${RED}Error: Failed to compile queue allocation helper${NC}"
    exit 1
}

"$TMPDIR/alloc_queues" $SQ_SIZE $CQ_SIZE > "$TMPDIR/queue_addrs.txt" &
QUEUE_HELPER_PID=$!

timeout 5 bash -c "while ! grep -q READY '$TMPDIR/queue_addrs.txt' 2>/dev/null; do sleep 0.1; done" || {
    echo -e "${RED}Error: Queue helper timeout${NC}"
    exit 1
}

SQ_PHYS=$(grep SQ_PHYS "$TMPDIR/queue_addrs.txt" | cut -d= -f2)
CQ_PHYS=$(grep CQ_PHYS "$TMPDIR/queue_addrs.txt" | cut -d= -f2)

echo "Queue addresses:"
printf "  SQ: %s\n" "$SQ_PHYS"
printf "  CQ: %s\n" "$CQ_PHYS"

# Run axiio-tester
TESTER_CMD="bin/axiio-tester \
    --real-hardware \
    --endpoint nvme-ep \
    --nvme-doorbell $DB_BASE \
    --nvme-sq-base $SQ_PHYS \
    --nvme-cq-base $CQ_PHYS \
    --nvme-sq-size $SQ_SIZE \
    --nvme-cq-size $CQ_SIZE \
    --submit-queue-len $QUEUE_SIZE \
    --complete-queue-len $QUEUE_SIZE \
    --iterations $TEST_ITERATIONS"

[ "$VERBOSE" = "1" ] && TESTER_CMD="$TESTER_CMD --verbose"

echo ""
echo "Command: $TESTER_CMD"
echo ""

# Run test
set +e
eval $TESTER_CMD
TEST_RESULT=$?
set -e

# Stop helpers
echo "quit" > /dev/stdin 2>/dev/null || true
kill $QUEUE_HELPER_PID 2>/dev/null || true

echo ""
if [ $TEST_RESULT -eq 0 ]; then
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✓ Test completed successfully!${NC}"
    echo -e "${GREEN}========================================${NC}"
else
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}✗ Test failed with exit code $TEST_RESULT${NC}"
    echo -e "${RED}========================================${NC}"
fi

echo ""
echo -e "${CYAN}Note: This test submits real NVMe commands${NC}"
echo -e "${CYAN}with fake data buffers. Data is not verified.${NC}"

exit $TEST_RESULT

