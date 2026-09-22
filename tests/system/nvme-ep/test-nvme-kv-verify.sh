#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# KV store→retrieve data-integrity roundtrip test.
#
# Stores N values to distinct keys with a deterministic LFSR pattern,
# then retrieves them in reverse key order and verifies the data
# byte-for-byte against the same pattern.  A mismatch means the
# retrieved payload did not match what was stored, catching wrong-key
# returns or data corruption in the vfio-user/P2PDMA path.
#
# Server-side cross-check: after the store phase, each key is inspected
# via rpc.py kvdev_mem_get_entry to confirm SPDK actually received and
# stored the value.  This distinguishes a false-positive xio-tester
# success (stale CQE) from a genuine SPDK-side store.
#
# Required environment:
#   ROCXIO_NVME_KV_CTRL   NVMe controller (e.g. /dev/nvme0)
#   ROCXIO_NVME_KV_NSID   Integer NSID of the KV namespace
#   SPDK_CONTAINER        Docker container name for the SPDK server
#                         (default: spdk-kv-nvme-vm-spdk-nvme-1)
#
# Usage (normally invoked by CTest via run-nvme-kv-test.sh):
#   test-nvme-kv-verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XIO_TESTER="${XIO_TESTER:-./build/xio-tester}"
KV_CTRL="${ROCXIO_NVME_KV_CTRL:-}"
KV_NSID="${ROCXIO_NVME_KV_NSID:-}"
LFSR_SEED="0xc01dc0fe"
VALUE_SIZE=4096
KEYS=(kvverify0 kvverify1 kvverify2 kvverify3)

# ---- prerequisite checks -------------------------------------------------

if [ -z "$KV_CTRL" ] || [ ! -e "$KV_CTRL" ]; then
    echo "SKIP: ROCXIO_NVME_KV_CTRL not set or not present"
    exit 77
fi
if [ -z "$KV_NSID" ]; then
    echo "SKIP: ROCXIO_NVME_KV_NSID not set"
    exit 77
fi
if [ "$EUID" -ne 0 ]; then
    echo "SKIP: requires root"
    exit 77
fi
if [ ! -f "$XIO_TESTER" ]; then
    echo "SKIP: xio-tester not found at $XIO_TESTER"
    exit 77
fi

# Pass --pci-mmio-bridge when the rocjitsu CI environment requests it.
PCI_MMIO_BRIDGE_ARG=""
if [ "${XIO_FORCE_PCI_MMIO_BRIDGE:-0}" = "1" ] || \
   [ "${USE_PCI_MMIO_BRIDGE:-0}" = "1" ]; then
    PCI_MMIO_BRIDGE_ARG="--pci-mmio-bridge"
fi

# ---- phase 1: store each key with a distinct value ----------------------

echo "KV verify: storing ${#KEYS[@]} keys to $KV_CTRL nsid=$KV_NSID"
for i in "${!KEYS[@]}"; do
    key="${KEYS[$i]}"
    # Each key gets a unique seed derived from its index so the LFSR
    # pattern is distinct per key; a wrong-key return would mismatch.
    seed=$(printf "0x%08x" $(( 0xc01dc0fe + i )))
    timeout 60 "$XIO_TESTER" nvme-ep \
        --controller "$KV_CTRL" --namespace "$KV_NSID" \
        --kv-op store --key "$key" \
        --write-io 1 --batch-size 1 \
        --value-size "$VALUE_SIZE" --data-buffer-size "$VALUE_SIZE" \
        --lfsr-seed "$seed" \
        ${PCI_MMIO_BRIDGE_ARG:+"$PCI_MMIO_BRIDGE_ARG"} \
        --less-timing > /dev/null
    echo "  stored key=$key seed=$seed"
done

# ---- phase 2: retrieve in reverse order and verify data -----------------
#
# Server-side cross-check (kvdev_mem_get_entry) runs on the host, not here,
# because the guest has no Docker. In CI it is a separate workflow step; for
# local runs use scripts/test/spdk-kv-check.sh from the host after this test.

echo "KV verify: retrieving keys in reverse order and verifying data"
for i in $(seq $(( ${#KEYS[@]} - 1 )) -1 0); do
    key="${KEYS[$i]}"
    seed=$(printf "0x%08x" $(( 0xc01dc0fe + i )))
    result=$(timeout 60 "$XIO_TESTER" nvme-ep \
        --controller "$KV_CTRL" --namespace "$KV_NSID" \
        --kv-op retrieve --key "$key" \
        --read-io 1 --batch-size 1 \
        --value-size "$VALUE_SIZE" --data-buffer-size "$VALUE_SIZE" \
        --lfsr-seed "$seed" --verify \
        ${PCI_MMIO_BRIDGE_ARG:+"$PCI_MMIO_BRIDGE_ARG"} \
        --less-timing 2>&1)
    if echo "$result" | grep -E "Verify Failed:[[:space:]]+[^0]" > /dev/null; then
        echo "  FAIL: data mismatch for key=$key"
        echo "$result"
        exit 1
    fi
    if ! echo "$result" | grep -E "Verify Passed:[[:space:]]+[1-9]" > /dev/null; then
        echo "  FAIL: verify did not pass for key=$key (no passing verifications reported)"
        echo "$result"
        exit 1
    fi
    echo "  OK:   key=$key data verified"
done

echo "KV verify: all ${#KEYS[@]} keys stored and retrieved correctly"
