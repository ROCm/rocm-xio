#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# QID quiesce ISOLATION stress test.
#
# Purpose: prove that rocm-xio's per-hctx quiesce (ROCM_XIO_QUIESCE_NS in
# HCTX mode -> blk_mq_stop_hw_queue) is SURGICAL and REVERSIBLE:
#
#   1. ISOLATION   while the target QID's hctx is quiesced, an I/O pinned
#                  to that QID's CPU is queued by blk-mq but NOT
#                  dispatched -- it must NOT complete.
#   2. CROSS-CPU   during that same window, I/O pinned to a DIFFERENT
#      LIVENESS    CPU (a different hctx) MUST complete normally. This
#                  proves only the target hctx stopped and the kernel /
#                  rest of the device is healthy (not an over-broad
#                  full-queue quiesce, not a wedged controller).
#   3. RESUME      after the window ends (hold-quiesce unquiesces and
#                  exits), the previously-blocked I/O completes, its data
#                  verifies byte-for-byte, and dmesg is clean.
#
# === Why the window is held by ONE long-lived process ===
# The module auto-restarts a quiesced hctx the instant the controlling
# /dev/rocm-xio fd closes (crash-safety in rocm_xio_release()). A
# fire-and-exit quiesce-qid therefore holds the queue stopped for only
# ~10 microseconds -- useless as a test window. Instead we run the
# `hold-quiesce <bdev> <qid> <seconds>` helper in the BACKGROUND: it
# opens /dev/rocm-xio, issues QUIESCE_NS, prints "held:", sleeps for the
# whole window keeping the fd open, then UNQUIESCE_NS + exits. The
# quiesce is active for exactly the sleep duration.
#
# === Why the isolation assertion has teeth ===
# A 256 KiB write to a warmed hctx is near-instant (sub-millisecond) when
# it is NOT blocked. The background CPU-target write touches a SENTINEL
# file ONLY on completion. We assert the sentinel is still ABSENT partway
# through an 8s hold: if the write were dispatched it would have finished
# in milliseconds, so an absent sentinel after seconds of hold is robust
# proof the hctx is stopped. After the hold, the sentinel MUST appear
# (resume), and the written region MUST match the pattern (integrity).
# A broken unquiesce (queue stays stopped) makes the post-window write
# never complete -> FAIL. A broken/over-broad quiesce (control CPU also
# stalls) -> FAIL. Either way the test catches a broken module.
#
# Env:
#   ROCXIO_NVME_DEVICE   controller node,  default /dev/nvme2
#   ROCXIO_NVME_BDEV     block device,     default <ctrl>n1
#   STRESS_ITERS         iterations,       default 5
#   STRESS_CPU           target pin CPU,   default 7  (-> QID 8)
#   STRESS_QID           target NVMe QID,  default CPU+1
#   STRESS_CTRL_CPU      control pin CPU,  default 3  (-> QID 4)
#   STRESS_CTRL_QID      control NVMe QID, default CTRL_CPU+1
#   QUIESCE_HOLD_S       hold-quiesce window seconds,   default 8
#   FIRST_IO_TIMEOUT_S   bound for control I/O + post-window resume wait,
#                        default 8
#   HOLD_HELPER          path to hold-quiesce helper (else search
#                        ./build, ., /tmp)
#   STRESS_VERIFY_BYTES  bytes for the verify write, default 256 KiB
#   NVME_CMD             nvme-cli binary, default nvme

set -u

# ---- locate + source the shared helper library --------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-qid-stress.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

NVME_CTRL="${ROCXIO_NVME_DEVICE:-/dev/nvme2}"
NVME_BDEV="${ROCXIO_NVME_BDEV:-${NVME_CTRL}n1}"
ITERS="${STRESS_ITERS:-5}"
CPU="${STRESS_CPU:-7}"
QID="${STRESS_QID:-$((CPU + 1))}"
CTRL_CPU="${STRESS_CTRL_CPU:-3}"
CTRL_QID="${STRESS_CTRL_QID:-$((CTRL_CPU + 1))}"
HOLD_S="${QUIESCE_HOLD_S:-8}"
FIRST_IO_TIMEOUT_S="${FIRST_IO_TIMEOUT_S:-8}"
VERIFY_BYTES="${STRESS_VERIFY_BYTES:-$((256 * 1024))}"
NVME_CMD="${NVME_CMD:-nvme}"
export NVME_CMD

# hctx index that QUIESCE_NS stops for this QID (qid - 1), used for the
# safety re-check at the end of each iteration.
HCTX_IDX=$((QID - 1))

# ---- locate the hold-quiesce helper -------------------------------------
HOLD_HELPER="${HOLD_HELPER:-}"
if [ -z "$HOLD_HELPER" ]; then
    for c in "$SCRIPT_DIR/build/hold-quiesce" ./build/hold-quiesce \
             ./hold-quiesce /tmp/hold-quiesce; do
        [ -x "$c" ] && HOLD_HELPER="$c" && break
    done
fi

# ---- preflight ----------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: must run as root${NC}"; exit 2
fi
[ -e "$NVME_CTRL" ] || { echo -e "${RED}Error: $NVME_CTRL not found${NC}"; exit 2; }
[ -b "$NVME_BDEV" ] || { echo -e "${RED}Error: $NVME_BDEV not a block dev${NC}"; exit 2; }
if [ -z "$HOLD_HELPER" ] || [ ! -x "$HOLD_HELPER" ]; then
    echo -e "${RED}Error: hold-quiesce helper not found.${NC}"
    echo "  Build it: cc -O2 -o /tmp/hold-quiesce <repo>/scripts/test/hold-quiesce.c"
    echo "  or set HOLD_HELPER=/path/to/hold-quiesce"
    exit 2
fi
if [ "$HOLD_S" -le "$((FIRST_IO_TIMEOUT_S + 1))" ]; then
    echo -e "${YELLOW}WARN: QUIESCE_HOLD_S ($HOLD_S) should comfortably exceed${NC}"
    echo -e "${YELLOW}      FIRST_IO_TIMEOUT_S ($FIRST_IO_TIMEOUT_S) so the control I/O${NC}"
    echo -e "${YELLOW}      finishes well inside the hold window.${NC}"
fi

CTRL_NAME="$(basename "$NVME_CTRL")"
PCI_BDF_FULL="$(basename "$(readlink -f "/sys/class/nvme/$CTRL_NAME/device")")"
QCOUNT="$(cat "/sys/class/nvme/$CTRL_NAME/queue_count" 2>/dev/null || echo 0)"
LBA_SIZE="$(lba_size "$NVME_BDEV")"

VERIFY_BLOCKS=$((VERIFY_BYTES / LBA_SIZE))
VERIFY_NLB=$((VERIFY_BLOCKS - 1))
# Verify region for the TARGET (blocked) CPU: well clear of LBA 0 (at the
# 256 GiB mark) and clear of the control region below.
TARGET_LBA=$(( 256 * 1024 * 1024 * 1024 / LBA_SIZE ))
# Control region for the cross-CPU read: a separate high LBA (320 GiB).
CTRL_LBA=$(( 320 * 1024 * 1024 * 1024 / LBA_SIZE ))

# ---- temp area + cleanup trap -------------------------------------------
TMP="$(mktemp -d /tmp/qid-quiesce-stress.XXXXXX)"
HOLD_PID=""
WRITE_PID=""

cleanup() {
    # Kill any stragglers. hold-quiesce unquiesces itself on exit; even if
    # we SIGKILL it, the fd-close auto-restart in the module re-starts the
    # hctx, so QID is never left stopped (on a healthy module).
    #
    # NOTE: a background target write that is blocked on a stopped hctx
    # sits in uninterruptible (D) state and cannot be killed or waited on
    # until the queue restarts. We therefore do NOT `wait` for it here --
    # that would hang. We only signal it; if the module is healthy the
    # hctx restart lets it complete and reap, and on a BROKEN module the
    # FAIL has already been reported (see step 8) before we get here.
    [ -n "$WRITE_PID" ] && kill "$WRITE_PID" 2>/dev/null
    [ -n "$HOLD_PID" ] && { kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null; }
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

PATTERN="$TMP/pattern.bin"
head -c "$VERIFY_BYTES" /dev/urandom > "$PATTERN"
CTRL_DATA="$TMP/ctrl_read.bin"

echo "============= QID $QID quiesce ISOLATION stress test ============="
echo "controller=$NVME_CTRL ($PCI_BDF_FULL) bdev=$NVME_BDEV queue_count=$QCOUNT"
echo "target:  CPU $CPU -> QID $QID (hctx $HCTX_IDX)   verify LBA=$TARGET_LBA"
echo "control: CPU $CTRL_CPU -> QID $CTRL_QID            read   LBA=$CTRL_LBA"
echo "iterations=$ITERS  hold=${HOLD_S}s  io-timeout=${FIRST_IO_TIMEOUT_S}s"
echo "verify bytes=$VERIFY_BYTES  lba-size=$LBA_SIZE  helper=$HOLD_HELPER"
echo "================================================================="

PASS=0; FAIL=0; FAIL_REASONS=""

# Re-check at iteration end that the target hctx is NOT left stopped and a
# direct read works. Returns 0 if healthy.
target_hctx_healthy() {
    local statef="/sys/kernel/debug/block/$(basename "$NVME_BDEV")/hctx${HCTX_IDX}/state"
    if [ -r "$statef" ] && grep -qiw STOPPED "$statef" 2>/dev/null; then
        return 1
    fi
    dd if="$NVME_BDEV" of=/dev/null bs="$LBA_SIZE" count=1 iflag=direct \
        >/dev/null 2>&1
}

for ((it=1; it<=ITERS; it++)); do
    echo ""
    echo "---- iteration $it/$ITERS ----"
    HOLD_PID=""; WRITE_PID=""
    SENTINEL="$TMP/done.$it"
    MARKER="$TMP/dmesg.$it"
    rm -f "$SENTINEL"

    # 1. Fresh controller + dmesg baseline.
    echo "  [1] controller reset (fresh queues)..."
    controller_reset_fresh "$CTRL_NAME"
    dmesg_mark "$MARKER"

    # 2. Warm both hctxs so blk-mq has live hardware contexts to dispatch
    #    from (and so a non-blocked write would be near-instant).
    echo "  [2] warm target hctx (CPU $CPU) + control hctx (CPU $CTRL_CPU)..."
    taskset -c "$CPU" dd if="$NVME_BDEV" of=/dev/null bs="$LBA_SIZE" \
        count=2048 iflag=direct >/dev/null 2>&1
    taskset -c "$CTRL_CPU" dd if="$NVME_BDEV" of=/dev/null bs="$LBA_SIZE" \
        count=2048 iflag=direct >/dev/null 2>&1

    # 3. Open the quiesce window: hold-quiesce in the BACKGROUND.
    echo "  [3] hold-quiesce QID $QID for ${HOLD_S}s (background window)..."
    "$HOLD_HELPER" "$NVME_BDEV" "$QID" "$HOLD_S" > "$TMP/hold.$it.log" 2>&1 &
    HOLD_PID=$!

    # Wait until it prints "held:" so the quiesce is definitely active.
    held=0
    for _ in $(seq 1 50); do
        if grep -q "^held:" "$TMP/hold.$it.log" 2>/dev/null; then
            held=1; break
        fi
        if ! kill -0 "$HOLD_PID" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    if [ "$held" -ne 1 ]; then
        echo -e "  ${RED}hold-quiesce never reported 'held:'${NC}"
        sed 's/^/      hold: /' "$TMP/hold.$it.log"
        wait "$HOLD_PID" 2>/dev/null; HOLD_PID=""
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:no-held"
        continue
    fi
    HOLD_T0=$(date +%s.%N)

    # 4. Background TARGET write on CPU $CPU. It must NOT complete while the
    #    hctx is quiesced. Sentinel touched ONLY on completion.
    echo "  [4] background CPU-$CPU write to LBA $TARGET_LBA (should BLOCK)..."
    (
        taskset -c "$CPU" "$NVME_CMD" write "$NVME_BDEV" \
            --start-block="$TARGET_LBA" --block-count="$VERIFY_NLB" \
            --data-size="$VERIFY_BYTES" --data="$PATTERN" >/dev/null 2>&1 \
            && touch "$SENTINEL"
    ) &
    WRITE_PID=$!

    # 5. Cross-CPU control read during the window. MUST succeed.
    echo "  [5] control read on CPU $CTRL_CPU (QID $CTRL_QID) during window..."
    cdt="$(timed_io read "$CTRL_CPU" "$NVME_BDEV" "$CTRL_LBA" "$VERIFY_BYTES" \
            "$CTRL_DATA" "$FIRST_IO_TIMEOUT_S")"; crc=$?
    if [ $crc -ne 0 ]; then
        echo -e "  ${RED}control read on CPU $CTRL_CPU TIMED OUT (${cdt}s)${NC}"
        echo -e "  ${RED}-> quiesce was over-broad (stopped more than QID $QID)${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:control-io-timeout(${cdt}s)"
        # Let the window close + reap before continuing.
        wait "$HOLD_PID" 2>/dev/null; HOLD_PID=""
        kill "$WRITE_PID" 2>/dev/null; wait "$WRITE_PID" 2>/dev/null; WRITE_PID=""
        continue
    fi
    echo -e "      control read OK in ${cdt}s (cross-CPU liveness intact)"

    # 6. ISOLATION assertion: partway through the hold the target write must
    #    still be unfinished. Wait until we are clearly inside the window
    #    (control read already proved seconds remain), then check sentinel.
    #    A non-blocked 256 KiB write finishes in ms, so absence here is
    #    robust proof the target hctx is stopped.
    sleep 1
    if [ -f "$SENTINEL" ]; then
        echo -e "  ${RED}ISOLATION FAILED: CPU-$CPU write COMPLETED during hold${NC}"
        echo -e "  ${RED}-> target QID $QID was NOT actually quiesced${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:not-isolated"
        wait "$HOLD_PID" 2>/dev/null; HOLD_PID=""
        wait "$WRITE_PID" 2>/dev/null; WRITE_PID=""
        continue
    fi
    echo -e "      sentinel absent mid-hold (target write correctly BLOCKED)"

    # 7. Let the window close: hold-quiesce unquiesces + exits.
    echo "  [7] waiting for hold-quiesce to release (unquiesce + exit)..."
    wait "$HOLD_PID" 2>/dev/null; HOLD_RC=$?; HOLD_PID=""
    if [ $HOLD_RC -ne 0 ]; then
        echo -e "  ${YELLOW}hold-quiesce exited rc=$HOLD_RC; tail:${NC}"
        tail -3 "$TMP/hold.$it.log" | sed 's/^/      /'
    fi

    # 8. RESUME: the previously-blocked write must now complete within a
    #    bounded wait.
    echo "  [8] waiting for blocked CPU-$CPU write to RESUME + complete..."
    resumed=0
    for _ in $(seq 1 $(( (FIRST_IO_TIMEOUT_S + 2) * 10 )) ); do
        if [ -f "$SENTINEL" ]; then resumed=1; break; fi
        if ! kill -0 "$WRITE_PID" 2>/dev/null; then
            # process exited; sentinel reflects success/failure
            [ -f "$SENTINEL" ] && resumed=1
            break
        fi
        sleep 0.1
    done
    if [ "$resumed" -ne 1 ]; then
        echo -e "  ${RED}RESUME FAILED: CPU-$CPU write never completed after window${NC}"
        echo -e "  ${RED}-> unquiesce did not restart hctx (broken module)${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:no-resume"
        # Diagnostics: dmesg + current hctx state (likely STOPPED).
        bad="$(dmesg_bad_since "$MARKER" "$QID")"
        [ -n "$bad" ] && echo "$bad" | tail -4 | sed 's/^/      DMESG: /'
        statef="/sys/kernel/debug/block/$(basename "$NVME_BDEV")/hctx${HCTX_IDX}/state"
        [ -r "$statef" ] && echo "      hctx${HCTX_IDX} state: [$(cat "$statef")]"
        # The blocked write is in uninterruptible (D) state on the stopped
        # hctx; do NOT `wait` on it (that would hang). Signal it and leave
        # the reap to cleanup once the queue is restored. WRITE_PID stays
        # set so the EXIT trap signals it.
        kill "$WRITE_PID" 2>/dev/null
        # A no-resume failure means the queue is wedged stopped: further
        # iterations would just hang on the same broken path. Stop now and
        # report FAIL; an operator must restore the hctx (reload the good
        # module, then a brief hold-quiesce cycle, or reboot).
        echo -e "  ${YELLOW}queue wedged stopped; aborting remaining iterations.${NC}"
        break
    fi
    # Resumed: the write completed, so reaping it will not block.
    wait "$WRITE_PID" 2>/dev/null; WRITE_PID=""
    HOLD_T1=$(date +%s.%N)
    elapsed="$(awk "BEGIN{printf \"%.2f\", $HOLD_T1-$HOLD_T0}")"
    echo -e "      write resumed + completed (~${elapsed}s after hold start)"

    # 9. Data integrity: read the target region back, compare to pattern.
    echo "  [9] read-back + compare target region..."
    if ! taskset -c "$CPU" "$NVME_CMD" read "$NVME_BDEV" \
            --start-block="$TARGET_LBA" --block-count="$VERIFY_NLB" \
            --data-size="$VERIFY_BYTES" --data="$TMP/readback.$it.bin" \
            >/dev/null 2>&1; then
        echo -e "  ${RED}read-back of target region failed${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:readback-failed"
        continue
    fi
    if ! cmp -s "$PATTERN" "$TMP/readback.$it.bin"; then
        echo -e "  ${RED}DATA MISMATCH in resumed write region${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:data-mismatch"
        continue
    fi

    # 10. dmesg must be clean since baseline.
    DMESG_BAD="$(dmesg_bad_since "$MARKER" "$QID")"
    if [ -n "$DMESG_BAD" ]; then
        echo -e "  ${RED}dmesg shows queue/controller error:${NC}"
        echo "$DMESG_BAD" | tail -6 | sed 's/^/      /'
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:dmesg-error"
        continue
    fi

    # SAFETY: confirm target hctx not left stopped + device readable.
    if ! target_hctx_healthy; then
        echo -e "  ${RED}SAFETY: target hctx left STOPPED or device unreadable${NC}"
        FAIL=$((FAIL+1)); FAIL_REASONS="$FAIL_REASONS iter$it:hctx-left-stopped"
        continue
    fi

    echo -e "  ${GREEN}PASS${NC} (isolated, cross-CPU live=${cdt}s, resumed, data ok, dmesg clean)"
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
