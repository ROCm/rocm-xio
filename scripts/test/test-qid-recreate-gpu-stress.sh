#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# GPU-driven QID delete/create stress test (gated behind STRESS_USE_GPU=1).
#
# Purpose: the faithful end-to-end version of test-qid-recreate-stress.sh.
# Instead of synthesising the wedge with `nvme admin-passthru` DELETE +
# the test-only resurrect ioctl, this test drives the REAL rocm-xio GPU
# path: xio-tester's nvme-ep GPU workload hijacks a kernel-owned NVMe
# queue (its kprobe rewrites PRP1 so the device queue points at GPU
# memory), runs I/O, then exits -- which issues DELETE_SQ/DELETE_CQ and
# makes the module's kprobe schedule rocm_xio_resurrect_work_fn
# (CREATE_CQ + CREATE_SQ at the snapshotted DMA addrs + host ring-pointer
# reset). After that automatic resurrect, this test hammers the recreated
# queue with sustained PURE KERNEL I/O and verifies integrity.
#
# This requires a working Navi 21 / gfx1030 GPU (the AMD reset bug can
# wedge it; recovery needs a host power-cycle). It is therefore GATED:
# unless STRESS_USE_GPU=1 it SKIPs cleanly (exit 0). Its GPU-free sibling
# test-qid-recreate-stress.sh covers the same queue-lifecycle + ring-
# pointer-reset logic without a GPU and runs everywhere.
#
# Each iteration:
#   1. Controller reset so the module re-captures a clean snapshot and
#      the ring starts fresh; stamp a windowed dmesg marker.
#   2. WARM via GPU: run xio-tester nvme-ep -m 8 (device/GPU memory)
#      against QID $QID. This is the real hijack. xio-tester's own GPU
#      kernel may or may not complete cleanly; what matters here is that
#      on exit it deletes the device-side queue and the module schedules
#      the resurrect. We wait for the resurrect to land in dmesg.
#   3. Confirm resurrect: dmesg must show the "resurrect ... DONE" line
#      for this BDF/QID inside the window. If it never appears, FAIL.
#   4. POST-CREATE HAMMER: sustained heavy kernel I/O on CPU $CPU to the
#      recreated queue -- many ring wraps. fio if present, else looped
#      dd. A hang/timeout = FAIL (the queue did not come back usable).
#   5. Final integrity check: write a known random pattern to a high LBA
#      on CPU $CPU, read it back, cmp. Mismatch = FAIL.
#   6. dmesg_bad_since must be empty (no QID timeout / controller reset /
#      oops). Non-empty = FAIL.
#
# Env:
#   STRESS_USE_GPU       MUST be 1 to run; otherwise SKIP (exit 0).
#   ROCXIO_NVME_DEVICE   controller node, default /dev/nvme2
#   ROCXIO_NVME_BDEV     block device,    default <ctrl>n1
#   STRESS_ITERS         iterations,      default 3
#   STRESS_CPU           pin CPU for kernel hammer, default 7 (-> QID 8)
#   STRESS_QID           NVMe I/O QID,    default CPU+1
#   STRESS_HALF_WRAPS    odd # of half-ring-wraps for the pre-wrap that
#                        advances host ring pointers off fresh state so a
#                        missing resurrect reset is detectable, default 3
#   QUEUE_LENGTH         NVMe SQ/CQ depth, default 1024
#   POST_HAMMER_MB       MiB to move in the post-create hammer, default 256
#   FIRST_IO_TIMEOUT_S   max seconds for the final verify I/O, default 8
#   RESURRECT_WAIT_S     max seconds to wait for the resurrect DONE line
#                        after xio-tester exits, default 15
#   XIO_TESTER           path to xio-tester binary (required)
#   XIO_WRITE_IO         xio-tester --write-io, default 4
#   XIO_READ_IO          xio-tester --read-io,  default 4
#   XIO_TIMEOUT_S        max seconds for the xio-tester run, default 60
#   STRESS_VERIFY_BYTES  verify transfer size, default 256 KiB
#   NVME_CMD             nvme-cli binary, default nvme

set -u

# shellcheck source=lib-qid-stress.sh
. "$(dirname "$0")/lib-qid-stress.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

# --- GPU gate -------------------------------------------------------
if [ "${STRESS_USE_GPU:-0}" != "1" ]; then
    echo -e "${YELLOW}SKIP: GPU delete/create stress test is gated.${NC}"
    echo "      Set STRESS_USE_GPU=1 to run (needs a working gfx1030 GPU)."
    echo "      The GPU-free sibling test-qid-recreate-stress.sh covers the"
    echo "      same queue-lifecycle + ring-pointer-reset logic without a GPU."
    exit 0
fi

NVME_CTRL="${ROCXIO_NVME_DEVICE:-/dev/nvme2}"
NVME_BDEV="${ROCXIO_NVME_BDEV:-${NVME_CTRL}n1}"
ITERS="${STRESS_ITERS:-3}"
CPU="${STRESS_CPU:-7}"
QID="${STRESS_QID:-$((CPU + 1))}"
HALF_WRAPS="${STRESS_HALF_WRAPS:-3}"
QUEUE_LENGTH="${QUEUE_LENGTH:-1024}"
POST_HAMMER_MB="${POST_HAMMER_MB:-256}"
FIRST_IO_TIMEOUT_S="${FIRST_IO_TIMEOUT_S:-8}"
RESURRECT_WAIT_S="${RESURRECT_WAIT_S:-15}"
XIO_TESTER="${XIO_TESTER:-}"
XIO_WRITE_IO="${XIO_WRITE_IO:-4}"
XIO_READ_IO="${XIO_READ_IO:-4}"
XIO_TIMEOUT_S="${XIO_TIMEOUT_S:-60}"
NVME_CMD="${NVME_CMD:-nvme}"
export NVME_CMD

TMP="$(mktemp -d /tmp/qid-recreate-gpu-stress.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- preconditions ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: must run as root${NC}"; exit 2
fi
[ -e "$NVME_CTRL" ] || { echo -e "${RED}Error: $NVME_CTRL not found${NC}"; exit 2; }
[ -b "$NVME_BDEV" ] || { echo -e "${RED}Error: $NVME_BDEV not a block dev${NC}"; exit 2; }
if [ -z "$XIO_TESTER" ] || [ ! -x "$XIO_TESTER" ]; then
    echo -e "${RED}Error: needs xio-tester. Set XIO_TESTER=/path/to/xio-tester${NC}"
    exit 2
fi
[ -e /dev/kfd ] || { echo -e "${RED}Error: /dev/kfd absent; no GPU.${NC}"; exit 2; }

CTRL_NAME="$(basename "$NVME_CTRL")"
PCI_BDF_FULL="$(basename "$(readlink -f "/sys/class/nvme/$CTRL_NAME/device")")"
BDF="$(resolve_bdf "$NVME_CTRL")"

if command -v fio >/dev/null 2>&1; then
    HAMMER_DRIVER="fio"
else
    HAMMER_DRIVER="dd"
fi

echo "======== QID $QID GPU-driven delete/create stress test (post-create hammer) ========"
echo "controller=$NVME_CTRL ($PCI_BDF_FULL, bdf=$BDF) bdev=$NVME_BDEV"
echo "cpu=$CPU  qid=$QID  qlen=$QUEUE_LENGTH  half-wraps=$HALF_WRAPS  iterations=$ITERS"
echo "xio-tester=$XIO_TESTER  (write-io=$XIO_WRITE_IO read-io=$XIO_READ_IO, m=8/GPU)"
echo "post-hammer=${POST_HAMMER_MB}MiB  hammer-driver=$HAMMER_DRIVER"
echo "resurrect wait=${RESURRECT_WAIT_S}s  first-IO timeout=${FIRST_IO_TIMEOUT_S}s"
echo -e "${YELLOW}NOTE: requires a working gfx1030 GPU; the AMD reset bug can wedge it.${NC}"
echo "==================================================================================="

LBA_SIZE="$(lba_size "$NVME_BDEV")"
PREWRAP_CMDS=$(( HALF_WRAPS * QUEUE_LENGTH / 2 ))
if [ $((HALF_WRAPS % 2)) -eq 0 ]; then
    echo -e "${YELLOW}WARN: STRESS_HALF_WRAPS is EVEN; cq_phase ends fresh (1),${NC}"
    echo -e "${YELLOW}      which does NOT expose a missing ring-pointer reset.${NC}"
fi

HAMMER_BYTES=$(( POST_HAMMER_MB * 1024 * 1024 ))
HAMMER_OFFSET=$(( 1024 * 1024 * 1024 ))          # 1 GiB
HAMMER_REGION_BYTES=$(( 64 * 1024 * 1024 ))      # 64 MiB working set
HAMMER_BS=$(( 64 * 1024 ))
HAMMER_CMDS=$(( HAMMER_BYTES / HAMMER_BS ))
HAMMER_SKIP_BLOCKS=$(( HAMMER_OFFSET / HAMMER_BS ))
HAMMER_TIMEOUT_S=$(( POST_HAMMER_MB > 30 ? POST_HAMMER_MB : 30 ))

VERIFY_BYTES="${STRESS_VERIFY_BYTES:-$((256 * 1024))}"
VERIFY_LBA=$(( 2 * 1024 * 1024 * 1024 / LBA_SIZE ))
PATTERN="$TMP/pattern.bin"
head -c "$VERIFY_BYTES" /dev/urandom > "$PATTERN"

echo "LBA size: $LBA_SIZE bytes"
echo "hammer region: ${HAMMER_REGION_BYTES} bytes @ offset ${HAMMER_OFFSET} (clear of LBA 0)"
echo "verify: ${VERIFY_BYTES} bytes @ LBA ${VERIFY_LBA}  (hammer timeout=${HAMMER_TIMEOUT_S}s)"

# Drive a real GPU hijack of QID via xio-tester nvme-ep -m 8. xio-tester
# may itself error on the GPU kernel; we do not require its success, only
# that it issues the DELETE on exit so the module schedules the resurrect.
run_gpu_hijack() {
    timeout "$XIO_TIMEOUT_S" "$XIO_TESTER" nvme-ep -v \
        --controller "$NVME_CTRL" \
        --queue-length "$QUEUE_LENGTH" \
        --queue-id "$QID" \
        --base-lba 1024 --lbas-per-io 8 \
        --write-io "$XIO_WRITE_IO" --read-io "$XIO_READ_IO" \
        --access-pattern sequential --batch-size 0 \
        -m 8 >"$TMP/xio.$1.log" 2>&1
    return $?
}

# Wait until dmesg (since marker) shows the resurrect DONE line for our
# BDF+QID, or until RESURRECT_WAIT_S elapses. Returns 0 if seen.
wait_for_resurrect() {
    local marker="$1" deadline
    deadline=$(( SECONDS + RESURRECT_WAIT_S ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if dmesg_bad_since "$marker" "$QID" >/dev/null 2>&1; then : ; fi
        if dmesg | grep -iE "resurrect: .*qid=$QID DONE" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

post_create_hammer() {
    local t0 t1 rc
    t0=$(date +%s.%N)
    if [ "$HAMMER_DRIVER" = fio ]; then
        timeout "$HAMMER_TIMEOUT_S" fio \
            --name=hammer --filename="$NVME_BDEV" \
            --rw=randrw --bs=4k --iodepth=64 --numjobs=1 \
            --cpus_allowed="$CPU" --ioengine=libaio --direct=1 \
            --offset="$HAMMER_OFFSET" --size="$HAMMER_REGION_BYTES" \
            --io_size="$HAMMER_BYTES" --verify=crc32c \
            --verify_fatal=1 --verify_state_save=0 --group_reporting \
            >"$TMP/fio.log" 2>&1
        rc=$?
    else
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
                rc=99
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

    echo "  [1] controller reset (fresh queue + snapshot)..."
    controller_reset_fresh "$CTRL_NAME"
    dmesg_mark "$MARKER"

    # Pre-wrap: advance the host ring pointers off device-fresh state so
    # that a resurrect which fails to reset them leaves a detectable
    # desync. xio-tester's hijack rewrites device-side PRP1 only; it does
    # not move the kernel host-side nvme_queue pointers, so this pre-wrap
    # survives the hijack and is what gives the test its teeth (without it
    # a broken resurrect can still pass on a near-fresh ring).
    echo "  [2a] pre-wrap: $PREWRAP_CMDS direct reads on CPU $CPU (QID $QID)..."
    prewrap_ring "$CPU" "$NVME_BDEV" "$HALF_WRAPS" "$QUEUE_LENGTH" "$LBA_SIZE"

    echo "  [2] GPU hijack: xio-tester nvme-ep -m 8 on QID $QID..."
    run_gpu_hijack "$it"; xrc=$?
    # xio-tester returning nonzero (GPU kernel error / core) is tolerated;
    # the DELETE-on-exit is what we need. Log it for visibility.
    echo "      xio-tester exited rc=$xrc (tolerated; DELETE-on-exit is what matters)"

    echo "  [3] wait for module resurrect (CREATE_CQ+CREATE_SQ + ring reset)..."
    if ! wait_for_resurrect "$MARKER"; then
        echo -e "  ${RED}resurrect DONE line never appeared within ${RESURRECT_WAIT_S}s${NC}"
        echo "      (xio-tester may not have deleted QID $QID; see $TMP/xio.$it.log)"
        tail -4 "$TMP/xio.$it.log" 2>/dev/null | sed 's/^/      XIO: /'
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:no-resurrect"
        sleep 5; continue
    fi
    echo "      resurrect DONE observed"

    echo "  [4] post-create hammer ($HAMMER_DRIVER, ${POST_HAMMER_MB}MiB) on CPU $CPU..."
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
        FAIL=$((FAIL+1)); sleep 35
        dmesg_bad_since "$MARKER" "$QID" | tail -4 | sed 's/^/      DMESG: /'
        continue
    fi
    echo "      hammer ok (${hdt}s)"

    echo "  [5] final verify on CPU $CPU (write/read/compare @ LBA $VERIFY_LBA)..."
    wdt="$(timed_io write "$CPU" "$NVME_BDEV" "$VERIFY_LBA" "$VERIFY_BYTES" "$PATTERN" "$FIRST_IO_TIMEOUT_S")"
    if [ $? -ne 0 ]; then
        echo -e "  ${RED}verify WRITE hung/timed out after ${wdt}s${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:verify-write-timeout(${wdt}s)"
        sleep 35; dmesg_bad_since "$MARKER" "$QID" | tail -4 | sed 's/^/      DMESG: /'; continue
    fi
    rdt="$(timed_io read "$CPU" "$NVME_BDEV" "$VERIFY_LBA" "$VERIFY_BYTES" "$TMP/readback.bin" "$FIRST_IO_TIMEOUT_S")"
    if [ $? -ne 0 ]; then
        echo -e "  ${RED}verify READ hung/timed out after ${rdt}s${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:verify-read-timeout(${rdt}s)"
        sleep 35; dmesg_bad_since "$MARKER" "$QID" | tail -4 | sed 's/^/      DMESG: /'; continue
    fi
    if ! cmp -s "$PATTERN" "$TMP/readback.bin"; then
        echo -e "  ${RED}DATA MISMATCH on final verify${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:verify-data-mismatch"; continue
    fi

    DMESG_BAD="$(dmesg_bad_since "$MARKER" "$QID")"
    if [ -n "$DMESG_BAD" ]; then
        echo -e "  ${RED}dmesg shows queue/controller error:${NC}"
        echo "$DMESG_BAD" | tail -6 | sed 's/^/      /'
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:dmesg-error"; continue
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
