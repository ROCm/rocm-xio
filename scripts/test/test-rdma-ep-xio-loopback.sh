#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# GPU RDMA loopback data-verification test.
# Single-invocation wrapper around the compiled
# test-rdma-loopback binary.  Posts an RDMA WRITE
# from a GPU kernel, waits for CQE, and verifies
# the transferred data against an LFSR pattern.
#
# Extracted from run-test-rdma-loopback.sh to allow
# individual CTest registration via
# xio_add_script_test().
#
# Environment variables:
#   ROCXIO_RDMA_DEVICE  RDMA device (set by wrapper)
#   PROVIDER            bnxt|mlx5|ionic|auto
#                       (default: auto)
#   TRANSFER_SIZE       Bytes per RDMA WRITE
#                       (default: 256)
#   LFSR_SEED           Data pattern seed
#                       (default: 1)
#   ITERATIONS          RDMA ops per run
#                       (default: 1)
#   TEST_BIN            Path to test-rdma-loopback
#                       binary (auto-detected)
#   RDMA_CORE_LIB       Path to in-tree rdma-core
#                       lib/ (auto-detected)

set -euo pipefail

RDMA_DEV="${ROCXIO_RDMA_DEVICE:-}"
PROVIDER="${PROVIDER:-auto}"
TRANSFER_SIZE="${TRANSFER_SIZE:-256}"
LFSR_SEED="${LFSR_SEED:-1}"
ITERATIONS="${ITERATIONS:-1}"

# Auto-detect build directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" \
    && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build}"

TEST_BIN="${TEST_BIN:-${BUILD_DIR}/tests/unit/rdma-ep/test-rdma-loopback}"
RDMA_CORE_LIB="${RDMA_CORE_LIB:-${BUILD_DIR}/_deps/rdma-core/install/lib}"

if [ ! -x "$TEST_BIN" ]; then
    echo "SKIP: test binary not found:" \
        "$TEST_BIN"
    exit 77
fi

LIB_PATH="${RDMA_CORE_LIB}:/opt/rocm/lib"
if [ -n "${LD_LIBRARY_PATH:-}" ]; then
    LIB_PATH="${LIB_PATH}:${LD_LIBRARY_PATH}"
fi

# Build command arguments
CMD_ARGS=()
CMD_ARGS+=(--size "$TRANSFER_SIZE")
CMD_ARGS+=(--seed "$LFSR_SEED")
CMD_ARGS+=(-n "$ITERATIONS")

if [ "$PROVIDER" != "auto" ]; then
    CMD_ARGS+=(--provider "$PROVIDER")
fi

if [ -n "$RDMA_DEV" ]; then
    CMD_ARGS+=(--device "$RDMA_DEV")
fi

echo "=== GPU RDMA Loopback Data Verification ==="
echo "  binary=$TEST_BIN"
echo "  provider=$PROVIDER"
echo "  device=${RDMA_DEV:-auto}"
echo "  size=$TRANSFER_SIZE"
echo "  seed=$LFSR_SEED"
echo "  iterations=$ITERATIONS"
echo ""

RC=0
env LD_LIBRARY_PATH="$LIB_PATH" \
    "$TEST_BIN" "${CMD_ARGS[@]}" || RC=$?

echo ""
if [ "$RC" -eq 0 ]; then
    echo "PASSED: GPU RDMA loopback" \
        "(${TRANSFER_SIZE}B, seed=${LFSR_SEED}," \
        "${ITERATIONS} iterations)"
elif [ "$RC" -eq 77 ]; then
    echo "SKIP: test binary returned 77"
    exit 77
else
    echo "FAILED: GPU RDMA loopback (rc=$RC)"
    exit 1
fi
