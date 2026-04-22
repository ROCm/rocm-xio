#!/bin/bash
# Run 2-node RDMA test between two nodes.
#
# Usage: ./run-2node-test.sh <server-node> <client-node> \
#          [device] [provider]
#
# Example:
#   ./run-2node-test.sh node-03 node-41
#   ./run-2node-test.sh node-03 node-41 mlx5_0 mlx5
#   ./run-2node-test.sh node-03 node-41 bnxt_re0 bnxt

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <server-node> <client-node>" \
    "[device] [provider]"
  echo ""
  echo "provider: bnxt|mlx5|ionic|auto" \
    "(default: auto)"
  echo ""
  echo "Example:"
  echo "  $0 node-03 node-41"
  echo "  $0 node-03 node-41 mlx5_0 mlx5"
  exit 1
fi

NODE_A="$1"
NODE_B="$2"
DEVICE="${3:-}"
PROVIDER="${4:-${PROVIDER:-auto}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Default build tree; override with BUILD_DIR when using a non-default
# out-of-source directory (same convention as scripts/test/).
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/../../../build}"
TEST_BIN="$BUILD_DIR/tests/unit"
TEST_BIN="$TEST_BIN/rdma-ep/test-rdma-2node"

if [ ! -f "$TEST_BIN" ]; then
  echo "Error: $TEST_BIN not found."
  echo "  Build with -DGDA_BNXT=ON or" \
    "-DGDA_MLX5=ON or -DGDA_IONIC=ON"
  exit 1
fi

DEVICE_ARG=""
if [ -n "$DEVICE" ]; then
  DEVICE_ARG="--device $DEVICE"
fi

PROVIDER_ARG="--provider $PROVIDER"

echo "=== 2-Node RDMA Test ==="
echo "Server:   $NODE_A"
echo "Client:   $NODE_B"
echo "Provider: $PROVIDER"
if [ -n "$DEVICE" ]; then
  echo "Device:   $DEVICE"
fi
echo ""

ssh -o StrictHostKeyChecking=no "$NODE_A" \
  "$TEST_BIN --server $PROVIDER_ARG" \
  "$DEVICE_ARG" 2>&1 \
  | sed "s/^/[SERVER] /" &
SERVER_PID=$!

sleep 3

ssh -o StrictHostKeyChecking=no "$NODE_B" \
  "$TEST_BIN --client" \
  "--server-host $NODE_A" \
  "$PROVIDER_ARG $DEVICE_ARG" 2>&1 \
  | sed "s/^/[CLIENT] /" &
CLIENT_PID=$!

wait $CLIENT_PID
CLIENT_EXIT=$?

wait $SERVER_PID
SERVER_EXIT=$?

echo ""
if [ $CLIENT_EXIT -eq 0 ] && \
   [ $SERVER_EXIT -eq 0 ]; then
  echo "=== 2-Node RDMA Test PASSED ==="
else
  echo "=== 2-Node RDMA Test FAILED" \
    "(server=$SERVER_EXIT," \
    "client=$CLIENT_EXIT) ==="
  exit 1
fi
