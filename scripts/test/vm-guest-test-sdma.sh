#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# vm-guest-test-sdma.sh
#
# Build and test rocm-xio *inside* a provisioned test VM that is
# attached to a rocjitsu emulated AMD GPU over vfio-user. Run this
# in the guest, not on the host.
#
# Exercises the sdma-ep endpoint in single-GPU mode:
#   - Unit tests (packet layout, config) run on CPU
#   - xio-tester sdma-ep p2p --to-host smoke run transfers data from
#     GPU memory to pinned host memory via SDMA, then verifies it
#
# For multi-GPU P2P (XGMI/Infinity Fabric) tests, two physical GPUs
# are required and cannot run in the rocjitsu single-GPU VM.
#
# Environment variables:
#   SRC_DIR       rocm-xio source tree (default: ~/rocm-xio)
#   BUILD_DIR     Build directory (default: $SRC_DIR/build)
#   OFFLOAD_ARCH  GPU arch to compile for (default: gfx1250)
#   CTEST_LABEL   ctest label regex (default: sdma)
#   SKIP_GPU      Set to 1 to skip GPU bring-up and GPU tests

set -euo pipefail

SRC_DIR="${SRC_DIR:-${HOME}/rocm-xio}"
BUILD_DIR="${BUILD_DIR:-${SRC_DIR}/build}"
OFFLOAD_ARCH="${OFFLOAD_ARCH:-gfx1250}"
CTEST_LABEL="${CTEST_LABEL:-sdma}"
SKIP_GPU="${SKIP_GPU:-0}"

# shellcheck source=vm-guest-test-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/vm-guest-test-common.sh"

# --------------------------------------------------------------
# Build BEFORE loading amdgpu — amdgpu reload can corrupt amdclang++.
if lsmod | grep -q '^amdgpu'; then
    banner "Unloading amdgpu before build (will reload via amdgpu-probe after)"
    sudo modprobe -r ionic_rdma 2>/dev/null || true
    sudo modprobe -r ionic 2>/dev/null || true
    sudo modprobe -r rocm_xio 2>/dev/null || true
    sudo modprobe -r amdgpu 2>/dev/null || true
fi
# --------------------------------------------------------------
find_rocm
build_xio_tester

banner "Building sdma-ep unit tests and integration examples"
cmake --build "${BUILD_DIR}" \
    --target test-sdma-config test-sdma-packet-layout \
    --parallel "$(( $(nproc) > 2 ? 2 : $(nproc) ))"

load_kernel_module

# --------------------------------------------------------------
# GPU bring-up (after build to avoid compiler corruption)
# --------------------------------------------------------------
gpu_bringup

# --------------------------------------------------------------
# Tests
# --------------------------------------------------------------
banner "Running sdma-ep unit tests"
cd "${BUILD_DIR}"

# Unit tests (test-sdma-config, test-sdma-packet-layout) run on CPU
# and cover packet builder correctness without hardware.
# Wrap with a wall-clock timeout: xio-tester can block in KFD/HSA
# syscalls that ignore SIGTERM.
timeout --kill-after=30 300 \
    sudo env \
    ROCXIO_ROCJITSU=1 \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    ctest --label-regex "${CTEST_LABEL}" \
          --output-on-failure \
          --no-tests=error

if [ "${SKIP_GPU}" = "1" ]; then
    banner "Done (GPU smoke test skipped)"
    exit 0
fi

# --------------------------------------------------------------
# Single-GPU smoke test: SDMA GPU → pinned host
# --------------------------------------------------------------
banner "Running sdma-ep single-GPU smoke test (--to-host)"

XIO_TESTER="${BUILD_DIR}/xio-tester"

# --to-host: single GPU, SDMA from device memory to pinned host memory.
# -n 10:      10 transfers; -v: verbose; --verify: LFSR data check.
timeout --kill-after=30 120 \
    sudo env \
    ROCXIO_ROCJITSU=1 \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    "${XIO_TESTER}" sdma-ep p2p \
        --to-host \
        --iterations 10 \
        --verify \
        --verbose

# --------------------------------------------------------------
# Integration: sdma-ep-p2p (build + skip-if-no-P2P run via ctest)
# --------------------------------------------------------------
banner "Running sdma-ep-p2p integration example (P2P skip expected)"

timeout --kill-after=30 120 \
    sudo env \
    ROCXIO_ROCJITSU=1 \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    ctest --test-dir "${BUILD_DIR}" \
          --tests-regex "example-install-rocm-xio|example-sdma-ep-p2p" \
          --output-on-failure || true

banner "Done"
