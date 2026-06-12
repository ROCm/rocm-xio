#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# QID delete/create stress test with a SUSTAINED POST-CREATE HAMMER.
#
# Purpose: prove that the rocm-xio queue-resurrect path leaves a
# re-created kernel-owned NVMe queue fully usable under LOTS of sustained
# kernel I/O -- not just for the single first I/O. This isolates the
# queue-lifecycle + host ring-pointer-reset logic (the fix in
# rocm_xio_resurrect_work_fn) with PURE KERNEL I/O only: there is NO
# rocm-xio hijack / PRP1 injection on the hammer path. All I/O below is
# ordinary kernel block I/O to /dev/nvmeXn1.
#
# Relationship to test-qid8-ring-wrap-stress.sh:
#   That sibling test proves the FIRST post-resurrect I/O completes. This
#   test goes further: after the same delete + resurrect cycle it runs a
#   sustained, heavy I/O hammer on the recreated queue that wraps the
#   depth-1024 ring MANY times. A queue that is subtly desynced (e.g. a
#   missing host ring-pointer reset) wedges: the hammer hangs and the
#   kernel times out QID 8 / resets the controller. We catch that as a
#   FAIL via a generous timeout on the hammer plus windowed dmesg.
#
# Each iteration:
#   1. Controller reset so the module re-captures a clean snapshot and
#      the ring starts fresh; stamp a windowed dmesg marker.
#   2. Pre-wrap: pin to CPU $CPU, drive an ODD number of half-ring-wraps
#      of direct reads so cq_phase flips to 0 (off the device-fresh
#      state). Pure kernel I/O, no rocm-xio.
#   3. DELETE_SQ + DELETE_CQ for QID $QID via `nvme admin-passthru` --
#      the identical admin commands xio-tester issues on exit; they
#      destroy the device-side queue while the host nvme_queue is left
#      intact (the wedge).
#   4. Resurrect: trigger the module's REAL rocm_xio_resurrect_work_fn
#      via the test-only ROCM_XIO_DEBUG_RESURRECT_QID ioctl (helper:
#      resurrect-qid). Runs production CREATE_CQ + CREATE_SQ AND, with
#      the fix, the host ring-pointer reset -- the code under test.
#      sleep 1 to let the 250ms delayed work fire.
#   5. POST-CREATE HAMMER: sustained heavy I/O on CPU $CPU to the
#      recreated queue -- many ring wraps. fio if present, else a big
#      looped dd. ALL hammer I/O must complete inside a generous
#      timeout; a hang/timeout = FAIL.
#   6. Final integrity check: write a known random pattern to a high LBA
#      on CPU $CPU, read it back, cmp. Mismatch = FAIL.
#   7. dmesg_bad_since must be empty (no QID timeout / controller reset /
#      oops). Non-empty = FAIL.
#
# Env:
#   ROCXIO_NVME_DEVICE   controller node, default /dev/nvme2
#   ROCXIO_NVME_BDEV     block device,    default <ctrl>n1
#   STRESS_ITERS         iterations,      default 5
#   STRESS_CPU           pin CPU,         default 7 (-> QID 8, 8 vCPU)
#   STRESS_QID           NVMe I/O QID,    default CPU+1
#   STRESS_HALF_WRAPS    odd # of half-ring-wraps for pre-wrap, default 3
#   QUEUE_LENGTH         NVMe SQ/CQ depth, default 1024
#   POST_HAMMER_MB       MiB to move in the post-create hammer, default
#                        256 (>> depth*lba so the ring wraps many times)
#   FIRST_IO_TIMEOUT_S   max seconds for the final verify I/O before
#                        declaring a hang, default 8
#   RESURRECT_HELPER     path to resurrect-qid helper, default search of
#                        ./build, ., /tmp
#   STRESS_VERIFY_BYTES  verify transfer size, default 256 KiB
#   NVME_CMD             nvme-cli binary, default nvme

set -u

# shellcheck source=lib-qid-stress.sh
. "$(dirname "$0")/lib-qid-stress.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

NVME_CTRL="${ROCXIO_NVME_DEVICE:-/dev/nvme2}"
NVME_BDEV="${ROCXIO_NVME_BDEV:-${NVME_CTRL}n1}"
ITERS="${STRESS_ITERS:-5}"
CPU="${STRESS_CPU:-7}"
QID="${STRESS_QID:-$((CPU + 1))}"
HALF_WRAPS="${STRESS_HALF_WRAPS:-3}"
QUEUE_LENGTH="${QUEUE_LENGTH:-1024}"
POST_HAMMER_MB="${POST_HAMMER_MB:-256}"
FIRST_IO_TIMEOUT_S="${FIRST_IO_TIMEOUT_S:-8}"
NVME_CMD="${NVME_CMD:-nvme}"
export NVME_CMD

# Locate resurrect helper.
RESURRECT_HELPER="${RESURRECT_HELPER:-}"
if [ -z "$RESURRECT_HELPER" ]; then
    for c in ./build/resurrect-qid ./resurrect-qid /tmp/resurrect-qid; do
        [ -x "$c" ] && RESURRECT_HELPER="$c" && break
    done
fi

TMP="$(mktemp -d /tmp/qid-recreate-stress.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- preconditions ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: must run as root${NC}"; exit 2
fi
[ -e "$NVME_CTRL" ] || { echo -e "${RED}Error: $NVME_CTRL not found${NC}"; exit 2; }
[ -b "$NVME_BDEV" ] || { echo -e "${RED}Error: $NVME_BDEV not a block dev${NC}"; exit 2; }
if [ -z "$RESURRECT_HELPER" ] || [ ! -x "$RESURRECT_HELPER" ]; then
    echo -e "${RED}Error: needs resurrect-qid helper.${NC}"
    echo "  Build it: cc -O2 -o /tmp/resurrect-qid <repo>/scripts/test/resurrect-qid.c"
    echo "  or set RESURRECT_HELPER=/path/to/resurrect-qid"
    exit 2
fi

CTRL_NAME="$(basename "$NVME_CTRL")"
PCI_BDF_FULL="$(basename "$(readlink -f "/sys/class/nvme/$CTRL_NAME/device")")"
BDF="$(resolve_bdf "$NVME_CTRL")"
QCOUNT="$(cat "/sys/class/nvme/$CTRL_NAME/queue_count" 2>/dev/null || echo 0)"

# Hammer driver: prefer fio (sustained, iodepth, verify), else dd.
if command -v fio >/dev/null 2>&1; then
    HAMMER_DRIVER="fio"
else
    HAMMER_DRIVER="dd"
fi

echo "============ QID $QID delete/create stress test (post-create hammer) ============"
echo "controller=$NVME_CTRL ($PCI_BDF_FULL, bdf=$BDF) bdev=$NVME_BDEV"
echo "cpu=$CPU  qid=$QID  queue_count=$QCOUNT  half-wraps=$HALF_WRAPS  qlen=$QUEUE_LENGTH"
echo "iterations=$ITERS  post-hammer=${POST_HAMMER_MB}MiB  hammer-driver=$HAMMER_DRIVER"
echo "resurrect helper: $RESURRECT_HELPER  first-IO timeout=${FIRST_IO_TIMEOUT_S}s"
if [ $((HALF_WRAPS % 2)) -eq 0 ]; then
    echo -e "${YELLOW}WARN: STRESS_HALF_WRAPS is EVEN; cq_phase ends at 1 (fresh),${NC}"
    echo -e "${YELLOW}      which does NOT expose the desync. Use an ODD value.${NC}"
fi
echo "================================================================================"

LBA_SIZE="$(lba_size "$NVME_BDEV")"

# Pre-wrap count: HALF_WRAPS * (qlen/2) single-block completions.
PREWRAP_CMDS=$(( HALF_WRAPS * QUEUE_LENGTH / 2 ))

# Hammer region: a window well clear of LBA 0 and clear of the pre-wrap
# read region (which reads from LBA 0 upward). Place the hammer at 1 GiB.
HAMMER_BYTES=$(( POST_HAMMER_MB * 1024 * 1024 ))
HAMMER_OFFSET=$(( 1024 * 1024 * 1024 ))          # 1 GiB
# fio operates over a region (size). Keep it modest but large enough to
# require many ring wraps when transferring POST_HAMMER_MB total.
HAMMER_REGION_BYTES=$(( 64 * 1024 * 1024 ))      # 64 MiB working set
# dd fallback chunk geometry.
HAMMER_BS=$(( 64 * 1024 ))                        # 64 KiB transfers
HAMMER_CMDS=$(( HAMMER_BYTES / HAMMER_BS ))
HAMMER_SKIP_BLOCKS=$(( HAMMER_OFFSET / HAMMER_BS ))
# Generous timeout: enough to move POST_HAMMER_MB even on a slow emulated
# controller, but bounded so a wedge is caught. ~POST_HAMMER_MB seconds
# (>= 1 MiB/s worst case) with a 30s floor.
HAMMER_TIMEOUT_S=$(( POST_HAMMER_MB > 30 ? POST_HAMMER_MB : 30 ))

# Final integrity verify region: distinct from both the pre-wrap read
# region (LBA 0..) and the hammer region (1 GiB..1 GiB+region). Place at
# 2 GiB, well clear of LBA 0.
VERIFY_BYTES="${STRESS_VERIFY_BYTES:-$((256 * 1024))}"
VERIFY_BLOCKS=$(( VERIFY_BYTES / LBA_SIZE ))
VERIFY_NLB=$(( VERIFY_BLOCKS - 1 ))             # nvme-cli block-count is zero-based
VERIFY_LBA=$(( 2 * 1024 * 1024 * 1024 / LBA_SIZE ))
PATTERN="$TMP/pattern.bin"
head -c "$VERIFY_BYTES" /dev/urandom > "$PATTERN"

echo "LBA size: $LBA_SIZE bytes; pre-wrap reads/iter: $PREWRAP_CMDS"
echo "hammer region: ${HAMMER_REGION_BYTES} bytes @ offset ${HAMMER_OFFSET} (clear of LBA 0)"
echo "verify: ${VERIFY_BYTES} bytes @ LBA ${VERIFY_LBA}  (hammer timeout=${HAMMER_TIMEOUT_S}s)"

delete_device_queue() {
    # DELETE_SQ (opcode 0x00) then DELETE_CQ (opcode 0x04), cdw10 = qid.
    $NVME_CMD admin-passthru "$NVME_CTRL" --opcode=0x00 --cdw10="$QID" \
        >/dev/null 2>&1
    $NVME_CMD admin-passthru "$NVME_CTRL" --opcode=0x04 --cdw10="$QID" \
        >/dev/null 2>&1
}

# post_create_hammer  -> echoes wall-clock latency (s,2dp); returns
# nonzero on timeout/failure. Pure kernel I/O pinned to CPU $CPU, sized
# to wrap the depth-$QUEUE_LENGTH ring many times.
post_create_hammer() {
    local t0 t1 rc
    t0=$(date +%s.%N)
    if [ "$HAMMER_DRIVER" = fio ]; then
        # randrw with verify (crc32c) over a 64 MiB window at 1 GiB.
        # io_size caps total bytes to POST_HAMMER_MB so runtime is
        # bounded by data, not time; iodepth=64 keeps the ring busy.
        timeout "$HAMMER_TIMEOUT_S" fio \
            --name=hammer \
            --filename="$NVME_BDEV" \
            --rw=randrw --bs=4k --iodepth=64 --numjobs=1 \
            --cpus_allowed="$CPU" --ioengine=libaio --direct=1 \
            --offset="$HAMMER_OFFSET" --size="$HAMMER_REGION_BYTES" \
            --io_size="$HAMMER_BYTES" --verify=crc32c \
            --verify_fatal=1 --verify_state_save=0 --group_reporting \
            >"$TMP/fio.log" 2>&1
        rc=$?
    else
        # dd fallback: a big direct read+write loop, then explicit
        # verify write/read/cmp over the hammer window.
        timeout "$HAMMER_TIMEOUT_S" taskset -c "$CPU" dd if="$NVME_BDEV" \
            of=/dev/null bs="$HAMMER_BS" count="$HAMMER_CMDS" \
            skip="$HAMMER_SKIP_BLOCKS" iflag=direct >/dev/null 2>&1
        rc=$?
        if [ $rc -eq 0 ]; then
            local hpat="$TMP/hammer-pat.bin" hrb="$TMP/hammer-rb.bin"
            head -c "$HAMMER_BS" /dev/urandom > "$hpat"
            timeout "$HAMMER_TIMEOUT_S" taskset -c "$CPU" dd if="$hpat" \
                of="$NVME_BDEV" bs="$HAMMER_BS" count=1 \
                seek="$HAMMER_SKIP_BLOCKS" oflag=direct conv=fsync \
                >/dev/null 2>&1 && \
            timeout "$HAMMER_TIMEOUT_S" taskset -c "$CPU" dd if="$NVME_BDEV" \
                of="$hrb" bs="$HAMMER_BS" count=1 \
                skip="$HAMMER_SKIP_BLOCKS" iflag=direct >/dev/null 2>&1
            rc=$?
            if [ $rc -eq 0 ] && ! cmp -s "$hpat" "$hrb"; then
                rc=99   # data mismatch in hammer verify
            fi
        fi
    fi
    t1=$(date +%s.%N)
    awk "BEGIN{printf \"%.2f\", $t1-$t0}"
    return $rc
}

PASS=0; FAIL=0; FAIL_REASONS=""
MARKER="$TMP/dmesg.marker"

for ((it=1; it<=ITERS; it++)); do
    echo ""
    echo "---- iteration $it/$ITERS ----"

    # 1. Controller reset -> fresh ring + re-captured snapshot; mark dmesg.
    echo "  [1] controller reset (fresh queue + snapshot)..."
    controller_reset_fresh "$CTRL_NAME"
    dmesg_mark "$MARKER"

    # 2. Pre-wrap to flip cq_phase to 0.
    echo "  [2] pre-wrap: $PREWRAP_CMDS direct reads on CPU $CPU (QID $QID)..."
    prewrap_ring "$CPU" "$NVME_BDEV" "$HALF_WRAPS" "$QUEUE_LENGTH" "$LBA_SIZE"

    # 3. Wedge: delete device-side queue.
    echo "  [3] DELETE_SQ+DELETE_CQ (admin-passthru) for QID $QID..."
    delete_device_queue

    # 4. Resurrect via real work fn.
    echo "  [4] resurrect (debug ioctl -> CREATE_CQ+CREATE_SQ + ring reset)..."
    if ! "$RESURRECT_HELPER" "$BDF" "$QID" >/dev/null 2>&1; then
        echo -e "  ${RED}resurrect helper failed${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:resurrect-ioctl-failed"
        sleep 35; continue
    fi
    sleep 1   # let the 250ms delayed resurrect work fire

    # 5. POST-CREATE HAMMER: sustained heavy I/O on the recreated queue.
    echo "  [5] post-create hammer ($HAMMER_DRIVER, ${POST_HAMMER_MB}MiB) on CPU $CPU..."
    hdt="$(post_create_hammer)"; hrc=$?
    if [ $hrc -ne 0 ]; then
        if [ $hrc -eq 99 ]; then
            echo -e "  ${RED}HAMMER data mismatch after ${hdt}s${NC}"
            FAIL_REASONS="$FAIL_REASONS iter$it:hammer-data-mismatch"
        else
            echo -e "  ${RED}HAMMER hung/failed/timed out after ${hdt}s (rc=$hrc)${NC}"
            FAIL_REASONS="$FAIL_REASONS iter$it:hammer-timeout(${hdt}s)"
            [ "$HAMMER_DRIVER" = fio ] && tail -4 "$TMP/fio.log" | sed 's/^/      FIO: /'
        fi
        FAIL=$((FAIL+1))
        sleep 35
        dmesg_bad_since "$MARKER" "$QID" | tail -4 | sed 's/^/      DMESG: /'
        continue
    fi
    echo "      hammer ok (${hdt}s)"

    # 6. Final integrity check on CPU $CPU (distinct high LBA).
    echo "  [6] final verify on CPU $CPU (write/read/compare @ LBA $VERIFY_LBA)..."
    wdt="$(timed_io write "$CPU" "$NVME_BDEV" "$VERIFY_LBA" "$VERIFY_BYTES" "$PATTERN" "$FIRST_IO_TIMEOUT_S")"
    wrc=$?
    if [ $wrc -ne 0 ]; then
        echo -e "  ${RED}verify WRITE hung/timed out after ${wdt}s${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:verify-write-timeout(${wdt}s)"
        sleep 35
        dmesg_bad_since "$MARKER" "$QID" | tail -4 | sed 's/^/      DMESG: /'
        continue
    fi
    rdt="$(timed_io read "$CPU" "$NVME_BDEV" "$VERIFY_LBA" "$VERIFY_BYTES" "$TMP/readback.bin" "$FIRST_IO_TIMEOUT_S")"
    rrc=$?
    if [ $rrc -ne 0 ]; then
        echo -e "  ${RED}verify READ hung/timed out after ${rdt}s${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:verify-read-timeout(${rdt}s)"
        sleep 35
        dmesg_bad_since "$MARKER" "$QID" | tail -4 | sed 's/^/      DMESG: /'
        continue
    fi
    if ! cmp -s "$PATTERN" "$TMP/readback.bin"; then
        echo -e "  ${RED}DATA MISMATCH on final verify${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:verify-data-mismatch"
        continue
    fi

    # 7. dmesg windowed scan for queue/controller errors.
    DMESG_BAD="$(dmesg_bad_since "$MARKER" "$QID")"
    if [ -n "$DMESG_BAD" ]; then
        echo -e "  ${RED}dmesg shows queue/controller error:${NC}"
        echo "$DMESG_BAD" | tail -6 | sed 's/^/      /'
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:dmesg-error"
        continue
    fi

    echo -e "  ${GREEN}PASS${NC} (hammer=${hdt}s verify-write=${wdt}s read=${rdt}s, data ok, dmesg clean)"
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
