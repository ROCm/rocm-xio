#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# vm-guest-test-nvme.sh
#
# Build and test rocm-xio *inside* a provisioned test VM that is
# attached to a rocjitsu emulated GPU and a QEMU-emulated NVMe disk
# (--nvme 1). Run this in the guest, not on the host.
#
# Exercises the nvme-ep LBA path end to end. The NVMe controller is
# QEMU's built-in emulation; the guest sees it as /dev/nvme0n1 and the
# GPU kernel writes doorbells directly via BAR0 mmap — no
# pci-mmio-bridge required.
#
# Environment variables:
#   SRC_DIR            rocm-xio source tree (default: ~/rocm-xio)
#   BUILD_DIR          Build directory (default: $SRC_DIR/build)
#   OFFLOAD_ARCH       GPU arch to compile for (default: gfx1250)
#   ROCXIO_NVME_DEVICE NVMe block device path (default: /dev/nvme0n1)
#   CTEST_LABEL        ctest label regex (default: nvme)
#   SKIP_GPU           Set to 1 to skip GPU bring-up and GPU tests

set -euo pipefail

SRC_DIR="${SRC_DIR:-${HOME}/rocm-xio}"
BUILD_DIR="${BUILD_DIR:-${SRC_DIR}/build}"
OFFLOAD_ARCH="${OFFLOAD_ARCH:-gfx1250}"
CTEST_LABEL="${CTEST_LABEL:-nvme}"
SKIP_GPU="${SKIP_GPU:-0}"
ROCXIO_NVME_DEVICE="${ROCXIO_NVME_DEVICE:-/dev/nvme0n1}"

# shellcheck source=vm-guest-test-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/vm-guest-test-common.sh"

# --------------------------------------------------------------
# Verify NVMe block device
# --------------------------------------------------------------
banner "Verifying NVMe block device ${ROCXIO_NVME_DEVICE}"

if [ ! -b "${ROCXIO_NVME_DEVICE}" ]; then
    echo "ERROR: NVMe block device ${ROCXIO_NVME_DEVICE} not found" >&2
    lspci -d ::0108 || true
    ls /dev/nvme* 2>/dev/null || echo "no nvme devices"
    exit 1
fi

# Print controller identity for diagnostics.
ctrl="${ROCXIO_NVME_DEVICE%n*}"   # strip namespace suffix: /dev/nvme0n1 → /dev/nvme0
sudo nvme id-ctrl "${ctrl}" 2>/dev/null | grep -E "^mn|^sn" | head -4 || true
echo "NVMe device: ${ROCXIO_NVME_DEVICE}"

# --------------------------------------------------------------
# Build BEFORE loading amdgpu — amdgpu reload can corrupt amdclang++.
if lsmod | grep -q '^amdgpu'; then
    banner "Unloading amdgpu before build (will reload via amdgpu-probe after)"
    sudo rmmod rocm_xio 2>/dev/null || true
    sudo rmmod amdgpu 2>/dev/null || true
fi
# --------------------------------------------------------------
find_rocm
build_xio_tester
load_kernel_module

# --------------------------------------------------------------
# GPU bring-up (after build to avoid compiler corruption)
# --------------------------------------------------------------
gpu_bringup

# --------------------------------------------------------------
# Tests
# --------------------------------------------------------------
banner "Running nvme-ep LBA tests"
cd "${BUILD_DIR}"

# ROCXIO_NVME_DEVICE is the block device path (/dev/nvme0n1).
# Wrap with a wall-clock timeout: xio-tester can block in KFD/HSA syscalls
# that ignore SIGTERM; --kill-after=30 sends SIGKILL as a backstop.
# Max time: 8 tests x 120 s + 30 s kill grace = ~990 s (< 20 min).
timeout --kill-after=30 1000 \
    sudo env \
    ROCXIO_NVME_DEVICE="${ROCXIO_NVME_DEVICE}" \
    XIO_FORCE_PCI_MMIO_BRIDGE=1 \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    ctest --label-regex "${CTEST_LABEL}" \
          --output-on-failure \
          --no-tests=error

banner "Done"
