#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# vm-guest-test-rdma.sh
#
# Build and test rocm-xio *inside* a provisioned test VM that is
# attached to a rocjitsu emulated GPU and a rocm-ernic emulated ionic
# RDMA NIC, both presented over vfio-user. Run this in the guest.
#
# Exercises the rdma-ep loopback path: ionic firmware loopback mode
# reflects RDMA packets back to the sender, enabling single-node testing.
#
# Environment variables:
#   SRC_DIR       rocm-xio source tree (default: ~/rocm-xio)
#   BUILD_DIR     Build directory (default: $SRC_DIR/build)
#   OFFLOAD_ARCH  GPU arch to compile for (default: gfx1250)
#   VENDOR        RDMA vendor to test (default: ionic)
#   CTEST_LABEL   ctest label regex (default: rdma)
#   SKIP_GPU      Set to 1 to skip GPU bring-up and GPU tests

set -euo pipefail

SRC_DIR="${SRC_DIR:-${HOME}/rocm-xio}"
BUILD_DIR="${BUILD_DIR:-${SRC_DIR}/build}"
OFFLOAD_ARCH="${OFFLOAD_ARCH:-gfx1250}"
CTEST_LABEL="${CTEST_LABEL:-rdma}"
SKIP_GPU="${SKIP_GPU:-0}"
VENDOR="${VENDOR:-ionic}"

# shellcheck source=vm-guest-test-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/vm-guest-test-common.sh"

# --------------------------------------------------------------
# GPU bring-up
# --------------------------------------------------------------
gpu_bringup

# --------------------------------------------------------------
# ionic RDMA driver
# The ernic-rocjitsu qcow2 ships with ionic and ionic_rdma pre-installed
# via DKMS for its kernel.  Do not rebuild from source; just reload.
# --------------------------------------------------------------
banner "Loading ionic RDMA drivers"
sudo modprobe -r ionic_rdma 2>/dev/null || true
sudo modprobe -r ionic 2>/dev/null || true
sudo modprobe ionic
sudo modprobe ionic_rdma

# --------------------------------------------------------------
# udev naming rules + RDMA loopback setup
# --------------------------------------------------------------
banner "Installing rocm-xio udev rules"
sudo "${SRC_DIR}/udev/setup-udev-rules.sh" --install
sudo udevadm trigger

banner "Waiting for rocm-ionic0 to appear"
for _ in $(seq 1 30); do
    [ -d /sys/class/net/rocm-ionic0 ] && break
    sleep 2
done
[ -d /sys/class/net/rocm-ionic0 ] || {
    echo "ERROR: rocm-ionic0 did not appear after udev trigger" >&2
    ip link show || true
    exit 1
}

banner "Configuring ionic loopback"
sudo env VENDOR="${VENDOR}" \
    "${SRC_DIR}/scripts/test/setup-rdma-loopback.sh"

# --------------------------------------------------------------
# Build + kernel module
# --------------------------------------------------------------
find_rocm
build_xio_tester
load_kernel_module

# --------------------------------------------------------------
# Tests
# --------------------------------------------------------------
banner "Running rdma-ep loopback tests (VENDOR=${VENDOR})"
cd "${BUILD_DIR}"

RDMA_DEVICE="rocm-rdma-${VENDOR}0"

# Wrap with a wall-clock timeout: xio-tester can block in KFD/HSA syscalls
# that ignore SIGTERM; --kill-after=30 sends SIGKILL as a backstop.
# Max time: 8 tests x 120 s + 30 s kill grace = ~990 s (< 20 min).
timeout --kill-after=30 1000 \
    sudo env \
    VENDOR="${VENDOR}" \
    ROCXIO_RDMA_DEVICE="${RDMA_DEVICE}" \
    PROVIDER="${VENDOR}" \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    ctest --label-regex "${CTEST_LABEL}" \
          --output-on-failure \
          --no-tests=error

banner "Done"
