#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# QID 8 ring-wrap stress test.
#
# Purpose: prove that the rocm-xio queue-resurrect path correctly resets
# the kernel HOST-side NVMe ring pointers (sq_tail, last_sq_tail,
# cq_head, cq_phase) after it re-creates a queue that was deleted on the
# device side. This is the fix in rocm_xio_resurrect_work_fn.
#
# Why the existing nvme-verify-seq-host-mem ctest can't catch this:
# it drives only 4 writes, far too few to move QID 8's depth-1024 ring
# away from its fresh state, so it passes even when the host-pointer
# reset is missing (false green). This test deliberately advances the
# queue by an ODD number of half-ring-wraps so cq_phase flips to 0 (away
# from the device's fresh phase 1) BEFORE the queue is deleted and
# resurrected. With a correct resurrect, the host pointers are reset to
# match the controller's fresh queue and the next CPU-7 I/O completes
# immediately. WITHOUT the reset, the host keeps cq_phase=0 while the
# device writes phase-1 CQEs, so the host never sees the completion: the
# I/O hangs ~30s, times out, and the kernel resets the controller (which
# then self-heals, masking the bug on later I/O). We catch the failure
# on the first post-resurrect I/O via both wall-clock latency and dmesg.
#
# === How the wedge is driven ===
# The faithful end-to-end trigger is xio-tester's GPU workload, which
# hijacks QID 8 and issues DELETE_SQ/DELETE_CQ on exit (the module's
# kprobe then schedules the resurrect). On hosts where that path is
# available, set STRESS_USE_XIO_TESTER=1. However, on the Navi 21 /
# gfx1030 passthrough host the AMD GPU reset bug can wedge the GPU's
# peer-DMA/HSA path (a guest reboot does NOT recover it; the PSP fails
# to reload firmware -- only a host power-cycle does), making xio-tester
# crash with HSA_STATUS_ERROR_EXCEPTION before it can be used as a test
# driver. For that reason the DEFAULT driver here is GPU-free and
# reproduces the EXACT same wedge + resurrect the module performs:
#   1. DELETE_SQ + DELETE_CQ for QID 8 via `nvme admin-passthru` --
#      these are the identical admin commands xio-tester issues on exit;
#      they destroy the device-side queue while the host nvme_queue is
#      left intact (the wedge).
#   2. Trigger the module's REAL rocm_xio_resurrect_work_fn via the
#      test-only ROCM_XIO_DEBUG_RESURRECT_QID ioctl (helper:
#      resurrect-qid). This runs the production CREATE_CQ + CREATE_SQ
#      from the captured snapshot AND, with the fix, the host
#      ring-pointer reset -- the very code under test.
# Either way the queue is recreated fresh on the device and the test
# verifies the host can use it.
#
# Each iteration:
#   1. Controller reset so the module re-captures a clean QID 8
#      snapshot (the resurrect path needs it) and the ring starts fresh.
#   2. Pre-wrap: pin to CPU 7, drive an ODD number of half-wraps of
#      direct I/O so cq_phase flips to 0.
#   3. Delete the device-side queue (admin-passthru) and resurrect it
#      (debug ioctl, or xio-tester if STRESS_USE_XIO_TESTER=1).
#   4. Verify on CPU 7: write a known pattern, read it back, compare.
#      Time the first post-resurrect I/O; multi-second latency == hang.
#   5. Inspect dmesg for QID-8 timeout / controller reset / oops.
#
# Any mismatch, timeout, hang, oops, or QID-8 reset = FAIL.
#
# Env:
#   ROCXIO_NVME_DEVICE   controller node, default /dev/nvme2
#   ROCXIO_NVME_BDEV     block device,    default <ctrl>n1
#   STRESS_ITERS         iterations,      default 5
#   STRESS_CPU           pin CPU,         default 7 (-> QID 8, 8 vCPU)
#   STRESS_QID           NVMe I/O QID,    default CPU+1
#   STRESS_HALF_WRAPS    odd # of half-ring-wraps for pre-wrap, default 3
#   STRESS_USE_XIO_TESTER 1 = drive wedge via xio-tester (needs GPU),
#                        default 0 (GPU-free admin-passthru + debug ioctl)
#   RESURRECT_HELPER     path to resurrect-qid helper, default
#                        ./build/resurrect-qid or /tmp/resurrect-qid
#   FIRST_IO_TIMEOUT_S   max seconds for first post-resurrect I/O before
#                        declaring a hang, default 8
#   XIO_TESTER           xio-tester path (xio-tester mode only)

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

NVME_CTRL="${ROCXIO_NVME_DEVICE:-/dev/nvme2}"
NVME_BDEV="${ROCXIO_NVME_BDEV:-${NVME_CTRL}n1}"
ITERS="${STRESS_ITERS:-5}"
CPU="${STRESS_CPU:-7}"
QID="${STRESS_QID:-$((CPU + 1))}"
HALF_WRAPS="${STRESS_HALF_WRAPS:-3}"
USE_XIO="${STRESS_USE_XIO_TESTER:-0}"
FIRST_IO_TIMEOUT_S="${FIRST_IO_TIMEOUT_S:-8}"
NVME_CMD="${NVME_CMD:-nvme}"
XIO_TESTER="${XIO_TESTER:-./build/xio-tester}"

LFSR_SEED="${LFSR_SEED:-0x1234}"
WRITE_IO="${WRITE_IO:-4}"
BLOCKS_PER_CMD="${BLOCKS_PER_CMD:-8}"
QUEUE_LENGTH="${QUEUE_LENGTH:-1024}"

# Locate resurrect helper (GPU-free mode).
RESURRECT_HELPER="${RESURRECT_HELPER:-}"
if [ -z "$RESURRECT_HELPER" ]; then
    for c in ./build/resurrect-qid ./resurrect-qid /tmp/resurrect-qid; do
        [ -x "$c" ] && RESURRECT_HELPER="$c" && break
    done
fi

TMP="$(mktemp -d /tmp/qid8-stress.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: must run as root${NC}"; exit 2
fi
[ -e "$NVME_CTRL" ] || { echo -e "${RED}Error: $NVME_CTRL not found${NC}"; exit 2; }
[ -b "$NVME_BDEV" ] || { echo -e "${RED}Error: $NVME_BDEV not a block dev${NC}"; exit 2; }

# Resolve the controller BDF (0xBBDD form) for the resurrect ioctl.
CTRL_NAME="$(basename "$NVME_CTRL")"
PCI_BDF_FULL="$(basename "$(readlink -f "/sys/class/nvme/$CTRL_NAME/device")")"
# e.g. 0000:05:00.0 -> bus=05 devfn=00 -> 0x0500
PCI_BUS="0x$(echo "$PCI_BDF_FULL" | cut -d: -f2)"
PCI_SLOT="$(echo "$PCI_BDF_FULL" | cut -d: -f3 | cut -d. -f1)"
PCI_FUNC="$(echo "$PCI_BDF_FULL" | cut -d. -f2)"
DEVFN=$(( (0x$PCI_SLOT << 3) | PCI_FUNC ))
BDF=$(printf "0x%02x%02x" "$PCI_BUS" "$DEVFN")

if [ "$USE_XIO" != "1" ]; then
    if [ -z "$RESURRECT_HELPER" ] || [ ! -x "$RESURRECT_HELPER" ]; then
        echo -e "${RED}Error: GPU-free mode needs resurrect-qid helper.${NC}"
        echo "  Build it: cc -O2 -o /tmp/resurrect-qid <repo>/scripts/test/resurrect-qid.c"
        echo "  or set RESURRECT_HELPER=/path/to/resurrect-qid"
        exit 2
    fi
fi

QCOUNT="$(cat "/sys/class/nvme/$CTRL_NAME/queue_count" 2>/dev/null || echo 0)"

echo "================ QID $QID ring-wrap stress test ================"
echo "controller=$NVME_CTRL ($PCI_BDF_FULL, bdf=$BDF) bdev=$NVME_BDEV"
echo "cpu=$CPU  qid=$QID  queue_count=$QCOUNT  half-wraps=$HALF_WRAPS"
echo "iterations=$ITERS  first-IO timeout=${FIRST_IO_TIMEOUT_S}s"
if [ "$USE_XIO" = "1" ]; then
    echo "wedge driver: xio-tester ($XIO_TESTER)  [needs working GPU]"
else
    echo "wedge driver: GPU-free (nvme admin-passthru DELETE + debug-resurrect ioctl)"
    echo "  resurrect helper: $RESURRECT_HELPER"
fi
if [ $((HALF_WRAPS % 2)) -eq 0 ]; then
    echo -e "${YELLOW}WARN: STRESS_HALF_WRAPS is EVEN; cq_phase ends at 1 (fresh),${NC}"
    echo -e "${YELLOW}      which does NOT expose the desync. Use an ODD value.${NC}"
fi
echo "==============================================================="

# LBA size.
LBADS="$($NVME_CMD id-ns "$NVME_BDEV" 2>/dev/null | grep -E '^lbaf' \
    | grep 'in use' | head -1 | sed -E 's/.*lbads:([0-9]+).*/\1/')"
[ -z "$LBADS" ] && LBADS=9
LBA_SIZE=$((1 << LBADS))

# Pre-wrap count: HALF_WRAPS * (queue_depth/2) single-block completions.
# queue_depth here is the NVMe SQ/CQ depth (QUEUE_LENGTH). An odd number
# of half-wraps lands cq_phase at 0.
PREWRAP_CMDS=$(( HALF_WRAPS * QUEUE_LENGTH / 2 ))
echo "LBA size: $LBA_SIZE bytes; pre-wrap reads/iter: $PREWRAP_CMDS"

# Verify region well clear of LBA 0 (xio-tester writes at base_lba 0).
# Keep the transfer under the controller MDTS (max data transfer size):
# a single nvme-cli write/read must fit in one command. 256 KiB is well
# under typical MDTS (this controller's MDTS=7 -> 512 KiB cap).
VERIFY_BYTES="${STRESS_VERIFY_BYTES:-$((256 * 1024))}"
VERIFY_BLOCKS=$((VERIFY_BYTES / LBA_SIZE))
# nvme-cli --block-count is ZERO-BASED (the NLB field), i.e. blocks - 1.
VERIFY_NLB=$((VERIFY_BLOCKS - 1))
VERIFY_LBA=$((256 * 1024 * 1024 / LBA_SIZE))
PATTERN="$TMP/pattern.bin"
head -c "$VERIFY_BYTES" /dev/urandom > "$PATTERN"

delete_device_queue() {
    # DELETE_SQ (opcode 0x00) then DELETE_CQ (opcode 0x04), cdw10 = qid.
    $NVME_CMD admin-passthru "$NVME_CTRL" --opcode=0x00 --cdw10="$QID" \
        >/dev/null 2>&1
    $NVME_CMD admin-passthru "$NVME_CTRL" --opcode=0x04 --cdw10="$QID" \
        >/dev/null 2>&1
}

run_xio_tester() {
    "$XIO_TESTER" nvme-ep -v --write-io "$WRITE_IO" \
        --controller "$NVME_CTRL" --queue-length "$QUEUE_LENGTH" \
        --lfsr-seed "$LFSR_SEED" --base-lba 0 \
        --lbas-per-io "$BLOCKS_PER_CMD" --access-pattern sequential \
        --batch-size 0 -m 0 > "$TMP/xio.log" 2>&1
}

timed_io() {  # $1=write|read  -> echoes latency, returns nonzero on fail/timeout
    local op="$1" t0 t1
    t0=$(date +%s.%N)
    if [ "$op" = write ]; then
        timeout "$FIRST_IO_TIMEOUT_S" taskset -c "$CPU" "$NVME_CMD" write \
            "$NVME_BDEV" --start-block="$VERIFY_LBA" \
            --block-count="$VERIFY_NLB" --data-size="$VERIFY_BYTES" \
            --data="$PATTERN" >/dev/null 2>&1
    else
        timeout "$FIRST_IO_TIMEOUT_S" taskset -c "$CPU" "$NVME_CMD" read \
            "$NVME_BDEV" --start-block="$VERIFY_LBA" \
            --block-count="$VERIFY_NLB" --data-size="$VERIFY_BYTES" \
            --data="$TMP/readback.bin" >/dev/null 2>&1
    fi
    local rc=$?
    t1=$(date +%s.%N)
    awk "BEGIN{printf \"%.2f\", $t1-$t0}"
    return $rc
}

PASS=0; FAIL=0; FAIL_REASONS=""

for ((it=1; it<=ITERS; it++)); do
    echo ""
    echo "---- iteration $it/$ITERS ----"

    # 1. Controller reset -> fresh ring + re-captured snapshot.
    echo "  [1] controller reset (fresh queue + snapshot)..."
    echo 1 > "/sys/class/nvme/$CTRL_NAME/reset_controller" 2>/dev/null
    sleep 4
    dmesg -C >/dev/null 2>&1

    # 2. Pre-wrap to flip cq_phase to 0.
    echo "  [2] pre-wrap: $PREWRAP_CMDS direct reads on CPU $CPU (QID $QID)..."
    taskset -c "$CPU" dd if="$NVME_BDEV" of=/dev/null bs="$LBA_SIZE" \
        count="$PREWRAP_CMDS" iflag=direct >/dev/null 2>&1

    # 3. Wedge (delete device queue) + resurrect.
    if [ "$USE_XIO" = "1" ]; then
        echo "  [3] xio-tester hijack of QID $QID + module resurrect..."
        run_xio_tester || {
            echo -e "  ${YELLOW}xio-tester returned nonzero; tail:${NC}"
            tail -3 "$TMP/xio.log" | sed 's/^/      /'
            # xio-tester may GPU-crash AFTER issuing DELETE; the
            # resurrect still fires. Continue to the verify step.
        }
    else
        echo "  [3] DELETE_SQ+DELETE_CQ (admin-passthru) + resurrect (debug ioctl)..."
        delete_device_queue
        "$RESURRECT_HELPER" "$BDF" "$QID" >/dev/null 2>&1 || {
            echo -e "  ${RED}resurrect helper failed${NC}"
            FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:resurrect-ioctl-failed"
            sleep 35; continue
        }
    fi
    sleep 1   # let the 250ms delayed resurrect work fire

    # 4. First post-resurrect I/O on CPU $CPU.
    echo "  [4] post-resurrect verify on CPU $CPU (write/read/compare)..."
    wdt="$(timed_io write)"; wrc=$?
    if [ $wrc -ne 0 ]; then
        echo -e "  ${RED}WRITE hung/timed out after ${wdt}s${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:write-timeout(${wdt}s)"
        sleep 35
        dmesg | grep -iE "QID $QID timeout|reset controller|invalid|oops|BUG" \
            | tail -4 | sed 's/^/      DMESG: /'
        continue
    fi
    rdt="$(timed_io read)"; rrc=$?
    if [ $rrc -ne 0 ]; then
        echo -e "  ${RED}READ hung/timed out after ${rdt}s${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:read-timeout(${rdt}s)"
        sleep 35
        dmesg | grep -iE "QID $QID timeout|reset controller|invalid|oops|BUG" \
            | tail -4 | sed 's/^/      DMESG: /'
        continue
    fi

    # 4a. Data integrity.
    if ! cmp -s "$PATTERN" "$TMP/readback.bin"; then
        echo -e "  ${RED}DATA MISMATCH after resurrect${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:data-mismatch"
        continue
    fi

    # 4b. dmesg corruption / timeout signatures.
    DMESG_BAD="$(dmesg | grep -iE "QID $QID timeout|reset controller|Oops|kernel BUG|Invalid SQE|invalid queue|general protection" || true)"
    if [ -n "$DMESG_BAD" ]; then
        echo -e "  ${RED}dmesg shows queue/controller error:${NC}"
        echo "$DMESG_BAD" | tail -6 | sed 's/^/      /'
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:dmesg-error"
        continue
    fi

    echo -e "  ${GREEN}PASS${NC} (write=${wdt}s read=${rdt}s, data ok, dmesg clean)"
    PASS=$((PASS+1))
done

echo ""
echo "================ SUMMARY ================"
echo "iterations: $ITERS   PASS: $PASS   FAIL: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    echo "fail reasons:$FAIL_REASONS"
    echo -e "${RED}OVERALL: FAIL${NC}"
    exit 1
fi
echo -e "${GREEN}OVERALL: PASS${NC}"
exit 0
