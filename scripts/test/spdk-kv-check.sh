#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Host-side cross-check: verify that the SPDK KV target actually stored
# the keys written by the nvme-kv-data-integrity ctest.
#
# Runs on the host (runner or local machine) where Docker is available.
# The guest cannot do this because it has no Docker daemon access.
#
# Usage:
#   SPDK_CONTAINER=spdk-kv-nvme-vm-spdk-nvme-1 \
#     scripts/test/spdk-kv-check.sh [key...]
#
# With no arguments, checks the fixed set used by test-nvme-kv-verify.sh.
# Exit 0 = all keys present; exit 1 = one or more missing.

set -euo pipefail

SPDK_CONTAINER="${SPDK_CONTAINER:-spdk-kv-nvme-vm-spdk-nvme-1}"
KVDEV="${KVDEV:-KvMem0}"

if [ "$#" -gt 0 ]; then
    KEYS=("$@")
else
    KEYS=(kvverify0 kvverify1 kvverify2 kvverify3)
fi

echo "Checking SPDK container: $SPDK_CONTAINER"
echo "KV device: $KVDEV"
echo ""

fail=0
for key in "${KEYS[@]}"; do
    result=$(docker exec "$SPDK_CONTAINER" \
        rpc.py kvdev_mem_get_entry "$KVDEV" "$key" 2>&1) || true
    if echo "$result" | grep -q "No such file or directory"; then
        echo "FAIL: key '$key' not found in SPDK -- KV command did not reach target"
        fail=1
    else
        value_len=$(echo "$result" | python3 -c \
            'import json,sys; d=json.load(sys.stdin); print(d.get("value_len", d.get("size","?")))' \
            2>/dev/null || echo "?")
        echo "OK:   key '$key' present (value_len=$value_len)"
    fi
done

echo ""
if [ "$fail" -eq 0 ]; then
    echo "All ${#KEYS[@]} keys confirmed in SPDK."
else
    echo "One or more keys missing from SPDK. KV commands are not reaching the target."
    exit 1
fi
