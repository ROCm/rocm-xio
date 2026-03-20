#!/bin/bash
# Run 2-node RDMA test between two nodes.
#
# Usage: ./run-2node-test.sh <server-node> <client-node> [device] [gid-index]
#
# Example:
#   ./run-2node-test.sh dell300x-ccs-aus-k13-03 dell300x-ccs-aus-k13-41

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <server-node> <client-node> [device] [gid-index]"
  echo ""
  echo "Example:"
  echo "  $0 dell300x-ccs-aus-k13-03 dell300x-ccs-aus-k13-41"
  echo "  $0 dell300x-ccs-aus-k13-03 dell300x-ccs-aus-k13-41 bnxt_re0 3"
  exit 1
fi

NODE_A="$1"
NODE_B="$2"
DEVICE="${3:-}"
GID="${4:-3}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/../../../build"
TEST_BIN="$BUILD_DIR/tests/unit/rdma-ep/test-rdma-2node"

if [ ! -f "$TEST_BIN" ]; then
  echo "Error: $TEST_BIN not found. Build with -DGDA_BNXT=ON -DBUILD_TESTING=ON first."
  exit 1
fi

DEVICE_ARG=""
if [ -n "$DEVICE" ]; then
  DEVICE_ARG="--device $DEVICE"
fi

echo "=== 2-Node RDMA Test ==="
echo "Server: $NODE_A"
echo "Client: $NODE_B"
echo "GID index: $GID"
echo ""

# Launch server on node A
ssh -o StrictHostKeyChecking=no "$NODE_A" \
  "$TEST_BIN --server $DEVICE_ARG --gid-index $GID" 2>&1 | sed "s/^/[SERVER] /" &
SERVER_PID=$!

# Wait for server to start listening
sleep 3

# Launch client on node B, connecting to server via hostname
ssh -o StrictHostKeyChecking=no "$NODE_B" \
  "$TEST_BIN --client --server-host $NODE_A $DEVICE_ARG --gid-index $GID" 2>&1 | sed "s/^/[CLIENT] /" &
CLIENT_PID=$!

# Wait for both to finish
wait $CLIENT_PID
CLIENT_EXIT=$?

wait $SERVER_PID
SERVER_EXIT=$?

echo ""
if [ $CLIENT_EXIT -eq 0 ] && [ $SERVER_EXIT -eq 0 ]; then
  echo "=== 2-Node RDMA Test PASSED ==="
else
  echo "=== 2-Node RDMA Test FAILED (server=$SERVER_EXIT, client=$CLIENT_EXIT) ==="
  exit 1
fi
