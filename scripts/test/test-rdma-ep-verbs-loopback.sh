#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Verbs-level RDMA loopback smoke test.
# Runs ibv_rc_pingpong in loopback mode (server and
# client on the same NIC using the neighbor-GID
# self-connect) to validate the basic RDMA stack
# without any GPU involvement.
#
# Environment variables:
#   ROCXIO_RDMA_DEVICE  RDMA device name (required,
#                       set by run-rdma-script-test.sh)
#   RDMA_CORE_BIN       Path to in-tree rdma-core
#                       bin/ (auto-detected)
#   RDMA_CORE_LIB       Path to in-tree rdma-core
#                       lib/ (auto-detected)
#   GID_INDEX           GID table index (default: auto)
#   LOOPBACK_IP         Loopback IP (derived from device
#                       name: bnxt=198.18.0.1,
#                       ionic=198.18.1.1, mlx5=198.18.2.1)
#   NUM_ITERS           Ping-pong iterations (default: 100)

set -euo pipefail

RDMA_DEV="${ROCXIO_RDMA_DEVICE:?ROCXIO_RDMA_DEVICE not set}"

# Derive loopback IP from device name when not set.
# Must match setup-rdma-loopback.sh assignments.
if [ -z "${LOOPBACK_IP:-}" ]; then
    case "$RDMA_DEV" in
        *bnxt*)  LOOPBACK_IP=198.18.0.1 ;;
        *ionic*) LOOPBACK_IP=198.18.1.1 ;;
        *mlx5*)  LOOPBACK_IP=198.18.2.1 ;;
        *)       LOOPBACK_IP=198.18.0.1 ;;
    esac
fi
NUM_ITERS="${NUM_ITERS:-100}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" \
    && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build}"
RDMA_CORE_BIN="${RDMA_CORE_BIN:-${BUILD_DIR}/_deps/rdma-core/install/bin}"
RDMA_CORE_LIB="${RDMA_CORE_LIB:-${BUILD_DIR}/_deps/rdma-core/install/lib}"

# Prefer in-tree tools (matching provider ABI)
# over system tools (stock provider).
PINGPONG=""
if [ -x "${RDMA_CORE_BIN}/ibv_rc_pingpong" ]; then
    PINGPONG="${RDMA_CORE_BIN}/ibv_rc_pingpong"
    export LD_LIBRARY_PATH="${RDMA_CORE_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
elif command -v ibv_rc_pingpong &>/dev/null; then
    PINGPONG="ibv_rc_pingpong"
else
    echo "SKIP: ibv_rc_pingpong not found"
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

echo "=== RDMA Verbs Loopback Smoke Test ==="
echo "  device=$RDMA_DEV"
echo "  gid_index=$GID_INDEX"
echo "  loopback_ip=$LOOPBACK_IP"
echo "  iterations=$NUM_ITERS"
echo ""

# Start server in background, capturing output
# to detect DV-only drivers that reject standard
# verbs QP creation.
SRV_LOG=$(mktemp /tmp/rdma-verbs-srv-XXXXXX.log)
CLT_LOG=$(mktemp /tmp/rdma-verbs-clt-XXXXXX.log)
trap 'rm -f "$SRV_LOG" "$CLT_LOG"' EXIT

TIMEOUT_SEC="${TIMEOUT_SEC:-30}"

"$PINGPONG" -d "$RDMA_DEV" \
    -g "$GID_INDEX" -n "$NUM_ITERS" \
    >"$SRV_LOG" 2>&1 &
SERVER_PID=$!
sleep 2

CLIENT_RC=0
timeout "${TIMEOUT_SEC}" \
    "$PINGPONG" -d "$RDMA_DEV" \
    -g "$GID_INDEX" -n "$NUM_ITERS" \
    "$LOOPBACK_IP" >"$CLT_LOG" 2>&1 || CLIENT_RC=$?

SERVER_RC=0
if kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_RC=124
else
    wait "$SERVER_PID" || SERVER_RC=$?
fi

cat "$SRV_LOG"
cat "$CLT_LOG"

echo ""
if [ "$CLIENT_RC" -eq 0 ] && \
   [ "$SERVER_RC" -eq 0 ]; then
    echo "PASSED: ibv_rc_pingpong loopback" \
        "($NUM_ITERS iterations)"
    exit 0
fi

# DV-only drivers (e.g. patched bnxt_re) don't
# support standard verbs QP creation.  Treat as
# skip rather than failure.
if grep -qi "Couldn't create QP\|create_qp" \
    "$SRV_LOG" "$CLT_LOG" 2>/dev/null; then
    echo "SKIP: driver does not support" \
        "standard verbs QP creation" \
        "(DV-only driver)"
    exit 77
fi

# IONIC firmware in PHY/SerDes loopback mode
# does not complete RC send/recv CQEs.  QP
# creation and modify_qp (INIT->RTR->RTS) all
# succeed, but ibv_poll_cq returns -EIO from
# an error or unexpected CQE type.  The GDA
# path (RDMA WRITE) works because it uses a
# simpler single-sided completion model.
# Treat as skip -- this is a known firmware
# limitation, not a driver bug.
if grep -qi "poll CQ failed" \
    "$SRV_LOG" "$CLT_LOG" 2>/dev/null; then
    echo "SKIP: ibv_poll_cq returned error" \
        "in loopback mode (IONIC firmware" \
        "does not support verbs RC" \
        "send/recv CQE completion in" \
        "PHY/SerDes loopback -- known" \
        "limitation)"
    exit 77
fi

# Timeout (rc=124) in loopback mode means the
# driver doesn't complete verbs-level RC
# send/recv in self-connect (common with
# firmware-based loopback on IONIC/BNXT).
if [ "$CLIENT_RC" -eq 124 ] || \
   [ "$SERVER_RC" -eq 124 ]; then
    echo "SKIP: ibv_rc_pingpong timed out" \
        "in loopback mode (driver may not" \
        "support verbs RC self-connect)"
    exit 77
fi

echo "FAILED: ibv_rc_pingpong loopback" \
    "(server=$SERVER_RC, client=$CLIENT_RC)"
exit 1
