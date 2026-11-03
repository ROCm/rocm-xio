#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# vm-guest-test-ep.sh
#
# Build and test rocm-xio *inside* a provisioned test VM that is
# attached to a rocjitsu emulated AMD GPU over vfio-user. Run this
# in the guest, not on the host.
#
# Exercises the test-ep endpoint with a real rocjitsu GPU (no --emulate):
#   - Unit tests (test-ep-config, test-ep-launch-cpu-threads) run on CPU.
#   - xio-tester test-ep: GPU kernel SQ/CQ ring exercise against a real
#     KFD device (gfx1250 via rocjitsu vfio-user).
#   - sdma-ep-p2p integration example build and single-GPU run attempt.
#
# No NVMe, RDMA, or pci-mmio-bridge hardware is needed.
#
# Environment variables:
#   SRC_DIR       rocm-xio source tree (default: ~/rocm-xio)
#   BUILD_DIR     Build directory (default: $SRC_DIR/build)
#   OFFLOAD_ARCH  GPU arch to compile for (default: gfx1250)
#   CTEST_LABEL   ctest label regex (default: test-ep)
#   SKIP_GPU      Set to 1 to skip GPU bring-up and GPU tests

set -euo pipefail

SRC_DIR="${SRC_DIR:-${HOME}/rocm-xio}"
BUILD_DIR="${BUILD_DIR:-${SRC_DIR}/build}"
OFFLOAD_ARCH="${OFFLOAD_ARCH:-gfx1250}"
CTEST_LABEL="${CTEST_LABEL:-test-ep}"
SKIP_GPU="${SKIP_GPU:-0}"

# shellcheck source=vm-guest-test-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/vm-guest-test-common.sh"

# --------------------------------------------------------------
# GPU bring-up
# --------------------------------------------------------------
gpu_bringup

# --------------------------------------------------------------
# Build + kernel module
# --------------------------------------------------------------
find_rocm
build_xio_tester

banner "Building test-ep unit and system tests"
cmake --build "${BUILD_DIR}" \
    --target test-ep-config test-ep-launch-cpu-threads \
            test-ep-emulate test-ep-emulate-multithread \
            test-ep-emulate-doorbell test-ep-emulate-timing \
            test-ep-emulate-delay \
    --parallel "$(( $(nproc) > 2 ? 2 : $(nproc) ))"

load_kernel_module

# --------------------------------------------------------------
# CPU unit tests
# --------------------------------------------------------------
banner "Running test-ep unit tests (CPU)"
cd "${BUILD_DIR}"

timeout --kill-after=30 120 \
    sudo env \
    ROCXIO_ROCJITSU=1 \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    ctest --label-regex "${CTEST_LABEL}" \
          --output-on-failure \
          --no-tests=error

if [ "${SKIP_GPU}" = "1" ]; then
    banner "Done (GPU tests skipped)"
    exit 0
fi

# --------------------------------------------------------------
# GPU smoke test: test-ep with real rocjitsu device
# --------------------------------------------------------------
banner "Running test-ep GPU smoke test (rocjitsu gfx1250)"

XIO_TESTER="${BUILD_DIR}/xio-tester"

# Basic: 32 iterations, single thread, verbose, verify correctness.
timeout --kill-after=30 120 \
    sudo env \
    ROCXIO_ROCJITSU=1 \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    "${XIO_TESTER}" test-ep \
        -n 32 \
        --threads 1 \
        --verify \
        --verbose

# Multi-thread: exercises per-thread SQ/CQ indexing.
timeout --kill-after=30 120 \
    sudo env \
    ROCXIO_ROCJITSU=1 \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    "${XIO_TESTER}" test-ep \
        -n 32 \
        --threads 4 \
        --verify \
        --verbose

# --------------------------------------------------------------
# Integration: sdma-ep-p2p (build + skip-if-no-P2P run via ctest)
# --------------------------------------------------------------
banner "Running sdma-ep-p2p integration example (P2P skip expected)"

# Install rocm-xio to the test prefix so the example can find it,
# then build and run via ctest. Skip gracefully if rocm-xio is not
# installed (e.g. build without install step).
timeout --kill-after=30 120 \
    sudo env \
    ROCXIO_ROCJITSU=1 \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    ctest --test-dir "${BUILD_DIR}" \
          --tests-regex "example-install-rocm-xio|example-sdma-ep-p2p" \
          --output-on-failure || true

banner "Done"
