#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Snapshot a fixed LBA range with dd, run xio-tester nvme-ep for a single
# write that uses a PRP list (17 LBAs = 8704 B), then dd again and show
# whether the namespace content changed. When the snapshot differs, also
# compares the post-write dd image to the LFSR golden from xio-tester
# --dump-pattern, then runs nvme-ep once with --write-io 1 --read-io 1
# --verify so the read DMA buffer is checked against the same golden (host
# verify; requires a second in-process write before the read, same pattern).
#
# Requires: root for dd to the namespace and for xio-tester nvme-ep; a
# stable /dev/disk/by-id/... namespace path (never use volatile /dev/nvmeXnY
# for destructive workflows—pick a scratch region the operator confirms).
#
# Usage:
#   sudo ./scripts/test/dd-prp-list-write-confirm.sh [SLBA]
# Environment (optional):
#   NVME_NS   Namespace block device (default: MTR by-id path below).
#   LBAS      LBAs per I/O (default: 17 => 8704 B, PRP list path).
#   XIO_TESTER  Path to xio-tester (default: ./build/xio-tester from repo root).
#   MEMORY_MODE  nvme-ep --memory-mode (default: 8).
#   LFSR_SEED   Passed to --lfsr-seed (default: 0). If the namespace already
#               holds the same LFSR bytes for this SLBA/length/seed, BEFORE
#               and AFTER hashes match even when the write succeeded.
#   DD_PRP_SCRATCH_RANDOMIZE  If set to 1, overwrites the SLBA range with
#               random bytes (dd from urandom) before step (1). DESTRUCTIVE;
#               only on a confirmed scratch namespace.
#   REPO_ROOT If unset, inferred from script location.
#
# Exit codes: 0 success (dd changed, disk matches golden, xio verify pass);
#   1 root/device/binary errors; 2 before/after identical; 3 disk vs golden
#   mismatch; 4 xio --verify failure.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")"/../.. && pwd)}"
cd "$REPO_ROOT"

NVME_NS="${NVME_NS:-/dev/disk/by-id/nvme-MTR_SLC_16GB_0400000E3CBC}"
SLBA="${1:-${SLBA:-20000000}}"
LBAS="${LBAS:-17}"
BS=512
COUNT="$LBAS"
WORKDIR="${WORKDIR:-/tmp}"
BEFORE="${WORKDIR}/nvme-prp-dd-before.$$"
AFTER="${WORKDIR}/nvme-prp-dd-after.$$"
EXPECTED="${WORKDIR}/nvme-prp-lfsr-expected.$$"
BYTES=$((COUNT * BS))
XIO_TESTER="${XIO_TESTER:-$REPO_ROOT/build/xio-tester}"
LIB="${LIB:-$REPO_ROOT/build/_deps/rdma-core/install/lib}"
LFSR_SEED="${LFSR_SEED:-0}"

nvme_ep_common=(
  nvme-ep
  --controller "$NVME_NS"
  --access-pattern sequential
  --base-lba "$SLBA"
  --lfsr-seed "$LFSR_SEED"
  --lbas-per-io "$LBAS"
  --memory-mode "${MEMORY_MODE:-8}"
  --queue-length 1024
  --batch-size 1
  --num-queues 1
)

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo) so dd and xio-tester can open the NVMe node."
  exit 1
fi

if [[ ! -b "$NVME_NS" ]]; then
  echo "Not a block device: $NVME_NS"
  exit 1
fi

if [[ ! -x "$XIO_TESTER" ]]; then
  echo "Missing xio-tester: $XIO_TESTER (build the project first)."
  exit 1
fi

cleanup() {
  rm -f "$BEFORE" "$AFTER" "$EXPECTED"
}
trap cleanup EXIT

echo "Namespace: $NVME_NS"
echo "SLBA=$SLBA  sectors=$COUNT  bytes=$((COUNT * BS))  (PRP list when LBAS>=17 at 512 B/LBA)"
echo "LFSR_SEED=$LFSR_SEED (export LFSR_SEED to change pattern; see script header)"
echo

if [[ "${DD_PRP_SCRATCH_RANDOMIZE:-0}" == 1 ]]; then
  echo "=== (0) DD_PRP_SCRATCH_RANDOMIZE=1: overwrite SLBA range with urandom (DESTRUCTIVE) ==="
  dd if=/dev/urandom of="$NVME_NS" bs="$BS" seek="$SLBA" count="$COUNT" status=none conv=fdatasync
  echo
fi

echo "=== (1) dd read BEFORE xio-tester ==="
dd if="$NVME_NS" of="$BEFORE" bs="$BS" skip="$SLBA" count="$COUNT" status=none
sha256sum "$BEFORE" | awk '{print "sha256(before)=" $1}'

echo
echo "=== (2) xio-tester: one sequential write at --base-lba $SLBA (--lbas-per-io $LBAS) ==="
export LD_LIBRARY_PATH="${LIB}:/opt/rocs-ais/lib:/opt/rocm/lib:${LD_LIBRARY_PATH:-}"
export HSA_FORCE_FINE_GRAIN_PCIE="${HSA_FORCE_FINE_GRAIN_PCIE:-1}"
"$XIO_TESTER" "${nvme_ep_common[@]}" \
  --write-io 1 \
  --read-io 0

echo
echo "=== (3) dd read AFTER xio-tester ==="
dd if="$NVME_NS" of="$AFTER" bs="$BS" skip="$SLBA" count="$COUNT" status=none
sha256sum "$AFTER" | awk '{print "sha256(after)=" $1}'

echo
if cmp -s "$BEFORE" "$AFTER"; then
  echo "RESULT: BEFORE and AFTER are byte-identical (same sha256)."
  echo "This does NOT prove the NVMe write failed. Common case: the namespace"
  echo "already held the exact LFSR pattern xio-tester would write for this"
  echo "SLBA, length, and --lfsr-seed (e.g. default 0 after earlier runs)."
  echo "To force a visible delta: use a new LFSR_SEED, e.g."
  echo "  sudo LFSR_SEED=\$RANDOM $0 $SLBA"
  echo "or set DD_PRP_SCRATCH_RANDOMIZE=1 once on a confirmed scratch device"
  echo "(see script header), then rerun without it."
  echo "First 64 bytes (snapshot):"
  xxd -l 64 "$BEFORE"
  exit 2
fi

echo "RESULT: Namespace content changed (cmp differs)."
echo "First differing byte (cmp -l):"
cmp -l "$BEFORE" "$AFTER" | head -n 5 || true
echo
echo "xxd around byte 4096 (second 4 KiB page of this $BYTES B window):"
dd if="$BEFORE" bs=1 skip=4032 count=128 status=none 2>/dev/null | xxd
echo "--- after ---"
dd if="$AFTER" bs=1 skip=4032 count=128 status=none 2>/dev/null | xxd

echo
echo "=== (4) LFSR golden (${BYTES} B, --dump-pattern-block-size 512) ==="
"$XIO_TESTER" \
  --dump-pattern "$EXPECTED" \
  --dump-pattern-seed "$LFSR_SEED" \
  --dump-pattern-size "$BYTES" \
  --dump-pattern-block-size 512 \
  --dump-pattern-offset 0

echo
echo "=== (5) dd AFTER vs LFSR golden (same bytes xio --verify expects) ==="
if cmp -s "$AFTER" "$EXPECTED"; then
  echo "DISK vs GOLDEN: MATCH (namespace snapshot matches LFSR for this seed / length)."
else
  echo "DISK vs GOLDEN: MISMATCH — first differences (cmp -l):"
  cmp -l "$AFTER" "$EXPECTED" | head -n 8 || true
  exit 3
fi

echo
echo "=== (6) xio-tester: write-io 1 read-io 1 --verify (same LBAs; host checks read buffer) ==="
echo "Note: nvme-ep requires --write-io with --verify; this re-writes the same"
echo "pattern then issues one read and compares the read DMA buffer to the golden."
set +e
"$XIO_TESTER" "${nvme_ep_common[@]}" \
  --write-io 1 \
  --read-io 1 \
  --verify
verify_rc=$?
set -e
if [[ "$verify_rc" -eq 0 ]]; then
  echo "XIO_READ_VERIFY: PASS (read buffer matched LFSR golden; same as disk if step (5) matched)."
  exit 0
fi
echo "XIO_READ_VERIFY: FAIL (exit $verify_rc). If step (5) matched, suspect read DMA / PRP path."
exit 4
