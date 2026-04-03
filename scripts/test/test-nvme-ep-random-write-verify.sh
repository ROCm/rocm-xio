#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Write random LBAs via xio-tester nvme-ep, then read each
# back with dd and verify the data matches the expected LFSR
# pattern.
#
# The LFSR seed controls both the data pattern and the LBA
# sequence (via getRandomLba in nvme-ep.hip).

set -e

NVME_DEVICE=""
LFSR_SEED="${LFSR_SEED:-0x1234}"
BASE_LBA="${BASE_LBA:-0}"
NUM_WRITES="${NUM_WRITES:-64}"
MEMORY_MODE="${MEMORY_MODE:-0}"
QUEUE_LENGTH="${QUEUE_LENGTH:-128}"

XIO_TESTER="${XIO_TESTER:-./build/xio-tester}"
TEMP_DIR="${TEMP_DIR:-/tmp/nvme-ep-rw-verify}"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <nvme-controller>"
    echo ""
    echo "Environment variables:"
    echo "  LFSR_SEED     Seed for pattern + LBA sequence"
    echo "  BASE_LBA      Starting LBA (default: 0)"
    echo "  NUM_WRITES    Number of writes (default: 64)"
    echo "  MEMORY_MODE   Memory mode (default: 0)"
    echo "  XIO_TESTER    Path to xio-tester binary"
    exit 1
fi

NVME_DEVICE="$1"
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --seed|-s) LFSR_SEED="$2"; shift 2 ;;
        --base-lba|-b) BASE_LBA="$2"; shift 2 ;;
        --num-writes|-n) NUM_WRITES="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 <nvme-controller>"
            echo "Options:"
            echo "  --seed, -s        LFSR seed"
            echo "  --base-lba, -b    Starting LBA"
            echo "  --num-writes, -n  Number of writes"
            exit 0 ;;
        *) echo "Error: Unknown option $1"
           exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    echo "Error: requires root"
    exit 1
fi

if [ ! -e "$NVME_DEVICE" ]; then
    echo "Error: $NVME_DEVICE not found"
    exit 1
fi

if [ ! -f "$XIO_TESTER" ]; then
    echo "Error: xio-tester not found at $XIO_TESTER"
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 not found"
    exit 1
fi

NS="${NVME_DEVICE}n1"
if [ ! -e "$NS" ]; then
    echo "Error: namespace $NS not found"
    exit 1
fi

mkdir -p "$TEMP_DIR"

LBA_SIZE=$(blockdev --getss "$NS")
NS_BYTES=$(blockdev --getsize64 "$NS")
NS_CAPACITY=$((NS_BYTES / LBA_SIZE))

echo "========================================"
echo "Random write-verify test"
echo "========================================"
echo "Controller:    $NVME_DEVICE"
echo "Namespace:     $NS"
echo "LFSR seed:     $LFSR_SEED"
echo "Base LBA:      $BASE_LBA"
echo "Num writes:    $NUM_WRITES"
echo "Memory mode:   $MEMORY_MODE"
echo "LBA size:      $LBA_SIZE bytes"
echo "NS capacity:   $NS_CAPACITY LBAs"
echo ""

echo "Step 1: Writing $NUM_WRITES random LBAs..."
write_cmd="$XIO_TESTER nvme-ep"
write_cmd="$write_cmd --write-io ${NUM_WRITES}"
write_cmd="$write_cmd --controller $NVME_DEVICE"
write_cmd="$write_cmd --access-pattern random"
write_cmd="$write_cmd --lbas-per-io 1"
write_cmd="$write_cmd --lfsr-seed $LFSR_SEED"
write_cmd="$write_cmd --base-lba $BASE_LBA"
write_cmd="$write_cmd --queue-length $QUEUE_LENGTH"
write_cmd="$write_cmd -m $MEMORY_MODE"

echo "Command: $write_cmd"
WRITE_LOG="$TEMP_DIR/write.log"
if ! $write_cmd > "$WRITE_LOG" 2>&1; then
    echo "Write FAILED - xio-tester output:"
    cat "$WRITE_LOG"
    exit 1
fi

echo "Write completed"
echo ""

echo "Step 2: Computing LBAs and verifying..."

python3 << PYEOF
import sys, os

lfsr_seed_str = '${LFSR_SEED}'
if lfsr_seed_str.startswith('0x') or \
   lfsr_seed_str.startswith('0X'):
    lfsr_seed = int(lfsr_seed_str, 16)
else:
    lfsr_seed = int(lfsr_seed_str)

num_writes = ${NUM_WRITES}
base_lba = ${BASE_LBA}
lba_size = ${LBA_SIZE}
ns_capacity = ${NS_CAPACITY}
ns_dev = '${NS}'


def get_random_lba(op_index, cmd_id,
                   lfsr_seed, base_lba,
                   lba_range):
    """Reproduces getRandomLba() from nvme-ep.hip."""
    M64 = 0xFFFFFFFFFFFFFFFF
    M32 = 0xFFFFFFFF
    seed = (op_index * 0x9e3779b9
            + ((cmd_id * 0x85ebca6b) & M32)
            + lfsr_seed) & M64
    seed = (seed ^ (seed >> 16)) & M64
    seed = (seed * 0xc2b2ae35) & M64
    seed = (seed ^ (seed >> 13)) & M64
    seed = (seed * 0x9e3779b9) & M64
    seed = (seed ^ (seed >> 16)) & M64
    return base_lba + (seed % lba_range)


def generate_expected_block(lba_size, lfsr_seed):
    """Reproduces dataPattern() from nvme-ep.h.

    With batch-size 1 (default), buffer_offset=0 for
    all writes, so offset=0 => lba=0, base_seed=0,
    seed=lfsr_seed.
    """
    M32 = 0xFFFFFFFF
    pattern = bytearray(lba_size)
    for j in range(lba_size):
        rng = (lfsr_seed + j) & M32
        rng ^= rng >> 16
        rng = (rng * 0x85ebca6b) & M32
        rng ^= rng >> 13
        rng = (rng * 0xc2b2ae35) & M32
        rng ^= rng >> 16
        pattern[j] = rng & 0xFF
    return bytes(pattern)


written_lbas = set()
for i in range(num_writes):
    cmd_id = (i % 65535) + 1
    lba = get_random_lba(
        i, cmd_id, lfsr_seed, base_lba, ns_capacity)
    written_lbas.add(lba)

unique_lbas = sorted(written_lbas)
print(f"Unique LBAs written: {len(unique_lbas)}"
      f" (from {num_writes} ops)")

expected = generate_expected_block(lba_size, lfsr_seed)
print(f"Expected pattern ({lba_size} bytes):"
      f" first 8 = {expected[:8].hex()}")

fail_count = 0
ok_count = 0

with open(ns_dev, 'rb') as dev:
    for lba in unique_lbas:
        dev.seek(lba * lba_size)
        actual = dev.read(lba_size)

        if actual != expected:
            print(f"FAIL: LBA {lba} mismatch"
                  f" (got {len(actual)} bytes,"
                  f" first 8 = {actual[:8].hex()})")
            fail_count += 1
            if fail_count <= 3:
                for j in range(min(len(actual),
                                   len(expected))):
                    if actual[j] != expected[j]:
                        print(
                            f"  first diff at byte"
                            f" {j}:"
                            f" got 0x{actual[j]:02x}"
                            f" expected"
                            f" 0x{expected[j]:02x}")
                        break
        else:
            ok_count += 1

print(f"Results: {ok_count} OK, {fail_count} FAIL"
      f" / {len(unique_lbas)} LBAs")

if fail_count == 0:
    print("All LBAs verified OK")
    sys.exit(0)
else:
    print("Data verification FAILED")
    sys.exit(1)
PYEOF
