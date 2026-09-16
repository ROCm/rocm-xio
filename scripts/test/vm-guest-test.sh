#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# vm-guest-test.sh
#
# Build and test rocm-xio *inside* a provisioned test VM that is
# attached to a rocjitsu emulated GPU and an emulated NVMe
# controller. Run this in the guest, not on the host.
#
# Brings the emulated GPU up, proves ROCm can see it, builds
# rocm-xio and its kernel module, then runs the NVMe endpoint
# system tests against the emulated controller.
#
# The GPU bring-up is load-bearing: the nvme-ep tests drive NVMe
# queues from __device__ code, so without a KFD agent there is
# nothing to test. A failure here is a real failure, not a skip.
#
# Environment variables:
#   SRC_DIR       rocm-xio source tree (default: ~/rocm-xio)
#   BUILD_DIR     Build directory (default: $SRC_DIR/build)
#   OFFLOAD_ARCH  GPU arch to compile for (default: gfx1250)
#   NVME_CTRL     NVMe controller (default: first /dev/nvme[0-9]+)
#   CTEST_LABEL   ctest label regex (default: nvme)
#   SKIP_GPU      Set to 1 to skip GPU bring-up and GPU tests

set -euo pipefail

SRC_DIR="${SRC_DIR:-${HOME}/rocm-xio}"
BUILD_DIR="${BUILD_DIR:-${SRC_DIR}/build}"
OFFLOAD_ARCH="${OFFLOAD_ARCH:-gfx1250}"
CTEST_LABEL="${CTEST_LABEL:-nvme}"
SKIP_GPU="${SKIP_GPU:-0}"

banner() {
    echo ""
    echo "=== $* ==="
}

# --------------------------------------------------------------
# GPU bring-up
# --------------------------------------------------------------
if [ "${SKIP_GPU}" != "1" ]; then
    banner "Loading amdgpu against the rocjitsu emulated device"
    sudo /usr/local/bin/amdgpu-probe

    # The emulator is slow; KFD topology does not appear the instant
    # modprobe returns.
    banner "Waiting for a KFD agent to appear"
    for _ in $(seq 1 60); do
        if [ -d /sys/class/kfd/kfd/topology/nodes/1 ]; then
            break
        fi
        sleep 5
    done
    if [ ! -d /sys/class/kfd/kfd/topology/nodes/1 ]; then
        echo "ERROR: no KFD agent after amdgpu load" >&2
        sudo dmesg | tail -100 >&2
        exit 1
    fi

    banner "rocminfo"
    rocminfo | grep -E 'Name:|gfx' || {
        echo "ERROR: rocminfo did not report an agent" >&2
        exit 1
    }
fi

# --------------------------------------------------------------
# Locate the emulated NVMe controller
# --------------------------------------------------------------
banner "Locating the emulated NVMe controller"
if [ -z "${NVME_CTRL:-}" ]; then
    for dev in /dev/nvme[0-9]*; do
        if [[ "$(basename "${dev}")" =~ ^nvme[0-9]+$ ]]; then
            NVME_CTRL="${dev}"
            break
        fi
    done
fi
if [ -z "${NVME_CTRL:-}" ] || [ ! -e "${NVME_CTRL}" ]; then
    echo "ERROR: no NVMe controller found in the guest" >&2
    lspci -nn || true
    exit 1
fi
echo "Using ${NVME_CTRL}"
sudo nvme id-ctrl "${NVME_CTRL}" | head -20

# --------------------------------------------------------------
# Build rocm-xio
# --------------------------------------------------------------
banner "Configuring rocm-xio"
cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Debug \
    -DOFFLOAD_ARCH="${OFFLOAD_ARCH}" \
    -DROCM_PATH=/opt/rocm \
    -DBUILD_TESTING=ON

banner "Building rocm-xio"
cmake --build "${BUILD_DIR}" --parallel "$(nproc)"

banner "rocm-xio-check"
"${SRC_DIR}/scripts/rocm-xio-check" || true

# --------------------------------------------------------------
# Kernel module and udev rules
# --------------------------------------------------------------
banner "Installing rocm-xio udev rules"
sudo "${SRC_DIR}/udev/setup-udev-rules.sh" --install

banner "Building and loading the rocm-xio kernel module"
make -C "${SRC_DIR}/kernel/rocm-xio"
sudo rmmod rocm_xio 2>/dev/null || true
sudo insmod "${SRC_DIR}/kernel/rocm-xio/rocm-xio.ko"
lsmod | grep -q rocm_xio || {
    echo "ERROR: rocm-xio module did not load" >&2
    sudo dmesg | tail -50 >&2
    exit 1
}

# --------------------------------------------------------------
# Tests
# --------------------------------------------------------------
banner "Running nvme-ep system tests"
cd "${BUILD_DIR}"
sudo env \
    ROCXIO_NVME_DEVICE="${NVME_CTRL}" \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    ctest --label-regex "${CTEST_LABEL}" \
          --output-on-failure \
          --no-tests=error

banner "Done"
