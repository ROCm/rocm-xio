#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# vm-guest-test-kv.sh
#
# Build and test rocm-xio *inside* a provisioned test VM that is
# attached to a rocjitsu emulated GPU and an SPDK NVMe KV controller,
# both presented over vfio-user with the pci-mmio-bridge. Run this in
# the guest, not on the host.
#
# Exercises the NVMe Key-Value command set: xio-tester --kv-op
# store/retrieve in both host-buffer (mode 0) and VRAM/P2PDMA (mode 8).
#
# Environment variables:
#   SRC_DIR       rocm-xio source tree (default: ~/rocm-xio)
#   BUILD_DIR     Build directory (default: $SRC_DIR/build)
#   OFFLOAD_ARCH  GPU arch to compile for (default: gfx1250)
#   KV_NSID       Integer NSID of the KV namespace (required; set by CI
#                 action from the SPDK server's nsid map log line)
#   CTEST_LABEL   ctest label regex (default: kv)
#   SKIP_GPU      Set to 1 to skip GPU bring-up and GPU tests

set -euo pipefail

SRC_DIR="${SRC_DIR:-${HOME}/rocm-xio}"
BUILD_DIR="${BUILD_DIR:-${SRC_DIR}/build}"
OFFLOAD_ARCH="${OFFLOAD_ARCH:-gfx1250}"
CTEST_LABEL="${CTEST_LABEL:-kv}"
SKIP_GPU="${SKIP_GPU:-0}"
# KV_NSID is the integer namespace ID reported by the SPDK server's nsid map
# (e.g. "1"). Linux does not expose KV namespaces as block devices, so there
# is no /dev/nvme0n1 for them; xio-tester receives --controller /dev/nvme0
# --namespace 1 instead.
KV_NSID="${KV_NSID:?KV_NSID must be set to the integer NSID of the KV namespace (e.g. 1)}"

# shellcheck source=vm-guest-test-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/vm-guest-test-common.sh"

# --------------------------------------------------------------
# Locate the NVMe controller
# --------------------------------------------------------------
banner "Locating NVMe controller for SPDK KV namespace (NSID ${KV_NSID})"

# KV namespaces (CSI=2) are not attached as block devices by the Linux NVMe
# driver, so there is no /dev/nvme0n<N> for them. Discover the controller by
# finding the first NVMe controller device node.
KV_CTRL=""
for dev in /dev/nvme[0-9]*; do
    if [[ "$(basename "${dev}")" =~ ^nvme[0-9]+$ ]]; then
        KV_CTRL="${dev}"
        break
    fi
done
if [ -z "${KV_CTRL}" ] || [ ! -e "${KV_CTRL}" ]; then
    echo "ERROR: no NVMe controller found in the guest" >&2
    lspci -nn || true
    ls /dev/nvme* 2>/dev/null || echo "no nvme devices"
    exit 1
fi
echo "NVMe controller: ${KV_CTRL}  KV NSID: ${KV_NSID}"
sudo nvme id-ctrl "${KV_CTRL}" 2>/dev/null | grep -E "^mn|^sn" | head -4 || true

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
cmake --build "${BUILD_DIR}" --target test-nvme-kv-helpers --parallel "$(nproc)"
load_kernel_module

# --------------------------------------------------------------
# GPU bring-up (after build to avoid compiler corruption)
# --------------------------------------------------------------
gpu_bringup

# --------------------------------------------------------------
# Tests
# --------------------------------------------------------------
banner "Running nvme-ep KV tests"
cd "${BUILD_DIR}"

# ROCXIO_NVME_KV_CTRL: the NVMe controller device (/dev/nvme0).
# ROCXIO_NVME_KV_NSID: integer NSID of the KV namespace.
# KV namespaces are not block devices; run-nvme-kv-test.sh uses these two
# vars to construct --controller / --namespace for xio-tester directly.
#
# XIO_FORCE_PCI_MMIO_BRIDGE is required: GPU doorbells are replayed through
# the pci-mmio-bridge because direct BAR0 mmap does not work for vfio-user.
# Wrap with a wall-clock timeout: xio-tester can block in KFD/HSA syscalls
# that ignore SIGTERM; --kill-after=30 sends SIGKILL as a backstop.
# Max time: 8 tests x 120 s + 30 s kill grace = ~990 s (< 20 min).
timeout --kill-after=30 1000 \
    sudo env \
    ROCXIO_NVME_KV_CTRL="${KV_CTRL}" \
    ROCXIO_NVME_KV_NSID="${KV_NSID}" \
    XIO_FORCE_PCI_MMIO_BRIDGE=1 \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    ctest --label-regex "${CTEST_LABEL}" \
          --output-on-failure \
          --no-tests=error

banner "Done"
