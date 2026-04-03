#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# RDMA WRITE bandwidth loopback test.
# Runs ib_write_bw in loopback mode (server and
# client on the same NIC using the neighbor-GID
# self-connect) to validate the RDMA WRITE data
# path -- the same verb the GDA backend uses for
# GPU-direct transfers.
#
# Environment variables:
#   ROCXIO_RDMA_DEVICE  RDMA device name (required,
#                       set by run-rdma-script-test.sh)
#   RDMA_CORE_BIN       Path to in-tree rdma-core
#                       bin/ (auto-detected)
#   RDMA_CORE_LIB       Path to in-tree rdma-core
#                       lib/ (auto-detected)
#   GID_INDEX           GID table index (default: auto)
#   LOOPBACK_IP         Loopback IP (default: 198.18.0.1)
#   NUM_ITERS           Number of iterations (default: 100)
#   MSG_SIZE            Message size in bytes (default: 4096)

set -euo pipefail

RDMA_DEV="${ROCXIO_RDMA_DEVICE:?ROCXIO_RDMA_DEVICE not set}"
LOOPBACK_IP="${LOOPBACK_IP:-198.18.0.1}"
NUM_ITERS="${NUM_ITERS:-100}"
MSG_SIZE="${MSG_SIZE:-4096}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" \
    && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build}"
RDMA_CORE_BIN="${RDMA_CORE_BIN:-${BUILD_DIR}/_deps/rdma-core/install/bin}"
RDMA_CORE_LIB="${RDMA_CORE_LIB:-${BUILD_DIR}/_deps/rdma-core/install/lib}"

# ib_write_bw is from perftest, not rdma-core.
# The in-tree rdma-core LD_LIBRARY_PATH is still
# needed so the system ib_write_bw loads the
# matching provider library.
if [ -d "$RDMA_CORE_LIB" ]; then
    export LD_LIBRARY_PATH="${RDMA_CORE_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

if ! command -v ib_write_bw &>/dev/null; then
    echo "SKIP: ib_write_bw not found"
    exit 77
fi

# Find the RoCEv2 IPv4-mapped GID index.  Verbs
# loopback tools connect via an IP address, so they
# need the IPv4-mapped GID (::ffff:x.x.x.x) rather
# than a link-local fe80:: entry.
find_ipv4_mapped_gid() {
    local dev="$1"
    local gid_dir
    gid_dir="/sys/class/infiniband/${dev}/ports/1/gids"
    local types_dir
    types_dir="/sys/class/infiniband/${dev}"
    types_dir="${types_dir}/ports/1/gid_attrs/types"

    for idx_path in "${gid_dir}"/*; do
        [ -f "$idx_path" ] || continue
        local idx
        idx="$(basename "$idx_path")"
        local val
        val="$(cat "$idx_path" 2>/dev/null || true)"
        case "$val" in
            0000:0000:0000:0000:0000:ffff:*)
                local gtype
                gtype="$(cat "${types_dir}/${idx}" \
                    2>/dev/null || true)"
                case "$gtype" in
                    *"RoCE v2"*)
                        echo "$idx"
                        return 0 ;;
                esac
                ;;
        esac
    done
    return 1
}

if [ -n "${GID_INDEX:-}" ]; then
    true
elif GID_INDEX="$(find_ipv4_mapped_gid "$RDMA_DEV")"; then
    true
else
    echo "SKIP: no IPv4-mapped RoCEv2 GID on" \
        "$RDMA_DEV (need IP + neighbor setup)"
    exit 77
fi

# Verify the loopback IP is reachable on this host
if ! ip addr show 2>/dev/null \
    | grep -q "inet ${LOOPBACK_IP}/"; then
    echo "SKIP: $LOOPBACK_IP not assigned to any" \
        "interface (run setup-rdma-loopback.sh)"
    exit 77
fi

echo "=== RDMA WRITE Bandwidth Loopback Test ==="
echo "  device=$RDMA_DEV"
echo "  gid_index=$GID_INDEX"
echo "  loopback_ip=$LOOPBACK_IP"
echo "  msg_size=$MSG_SIZE"
echo "  iterations=$NUM_ITERS"
echo ""

# Start server in background, capturing output
# to detect DV-only drivers that reject standard
# verbs QP creation.
SRV_LOG=$(mktemp /tmp/rdma-writebw-srv-XXXXXX.log)
CLT_LOG=$(mktemp /tmp/rdma-writebw-clt-XXXXXX.log)
trap 'rm -f "$SRV_LOG" "$CLT_LOG"' EXIT

ib_write_bw -d "$RDMA_DEV" \
    -x "$GID_INDEX" -s "$MSG_SIZE" \
    -n "$NUM_ITERS" -F \
    >"$SRV_LOG" 2>&1 &
SERVER_PID=$!
sleep 2

CLIENT_RC=0
ib_write_bw -d "$RDMA_DEV" \
    -x "$GID_INDEX" -s "$MSG_SIZE" \
    -n "$NUM_ITERS" -F \
    "$LOOPBACK_IP" >"$CLT_LOG" 2>&1 || CLIENT_RC=$?

SERVER_RC=0
wait "$SERVER_PID" || SERVER_RC=$?

cat "$SRV_LOG"
cat "$CLT_LOG"

echo ""
if [ "$CLIENT_RC" -eq 0 ] && \
   [ "$SERVER_RC" -eq 0 ]; then
    echo "PASSED: ib_write_bw loopback" \
        "(${MSG_SIZE}B x ${NUM_ITERS})"
    exit 0
fi

# DV-only drivers (e.g. patched bnxt_re) don't
# support standard verbs QP creation.  Treat as
# skip rather than failure.
if grep -qi "Couldn't create QP\|create_qp\|Failed to modify QP" \
    "$SRV_LOG" "$CLT_LOG" 2>/dev/null; then
    echo "SKIP: driver does not support" \
        "standard verbs QP creation" \
        "(DV-only driver)"
    exit 77
fi

echo "FAILED: ib_write_bw loopback" \
    "(server=$SERVER_RC, client=$CLIENT_RC)"
exit 1
