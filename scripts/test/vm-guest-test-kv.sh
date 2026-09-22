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
# Parallels vm-guest-test.sh (the LBA/rocjitsu path) but exercises the
# NVMe Key-Value command set: xio-tester --kv-op store/retrieve in both
# host-buffer (mode 0) and VRAM/P2PDMA (mode 8).
#
# Environment variables:
#   SRC_DIR       rocm-xio source tree (default: ~/rocm-xio)
#   BUILD_DIR     Build directory (default: $SRC_DIR/build)
#   OFFLOAD_ARCH  GPU arch to compile for (default: gfx1250)
#   KV_NSID       NVMe namespace device path for the KV namespace,
#                 e.g. /dev/nvme0n1 (required; set by CI action from
#                 the SPDK server's nsid map log line)
#   CTEST_LABEL   ctest label regex (default: nvme kv)
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

    banner "KFD agent"
    for node in /sys/class/kfd/kfd/topology/nodes/[1-9]*; do
        [ -r "${node}/properties" ] || continue
        echo "${node}:"
        grep -E '^(gfx_target_version|simd_count|vendor_id|device_id) ' \
            "${node}/properties" || true
    done
    if command -v rocminfo > /dev/null; then
        rocminfo | grep -E 'Name:|gfx' || true
    fi
fi

# --------------------------------------------------------------
# Locate the NVMe controller and verify KV namespace
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
# Build rocm-xio
# --------------------------------------------------------------
banner "Configuring rocm-xio"

roots=()
for d in /opt/rocm /opt/rocm-*; do
    [ -d "${d}" ] && roots+=("${d}")
done
if [ "${#roots[@]}" -eq 0 ]; then
    echo "ERROR: no /opt/rocm* directory in the guest at all." >&2
    exit 1
fi

if [ -z "${ROCM_PATH:-}" ]; then
    hip_lang=$(find "${roots[@]}" -maxdepth 5 \
                   -type d -name hip-lang -path '*/cmake/*' 2>/dev/null |
                   head -1 || true)
    if [ -n "${hip_lang}" ]; then
        ROCM_PATH=$(dirname "$(dirname "$(dirname "${hip_lang}")")")
    else
        hipcc=$(find "${roots[@]}" -maxdepth 4 \
                    -type f \( -name hipcc -o -name amdclang++ \) 2>/dev/null |
                    head -1 || true)
        if [ -n "${hipcc}" ]; then
            ROCM_PATH=$(dirname "$(dirname "${hipcc}")")
        fi
    fi
fi
if [ -z "${ROCM_PATH:-}" ]; then
    echo "ERROR: no HIP toolchain under ${roots[*]}." >&2
    exit 1
fi
echo "Using ROCM_PATH=${ROCM_PATH}"
export ROCM_PATH
export PATH="${ROCM_PATH}/bin:${PATH}"

HIP_CXX=""
for c in "${ROCM_PATH}/bin/amdclang++" "${ROCM_PATH}/bin/hipcc" \
         "${ROCM_PATH}/llvm/bin/clang++"; do
    [ -x "${c}" ] && HIP_CXX="${c}" && break
done
if [ -n "${HIP_CXX}" ]; then
    echo "Using HIP compiler: ${HIP_CXX}"
else
    echo "WARNING: no amdclang++/hipcc found under ${ROCM_PATH}" >&2
fi

# RelWithDebInfo is not a preference: -O0 device code never completes a GPU
# dispatch on the emulated rocjitsu target (see vm-guest-test.sh for the
# full explanation).
cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    ${HIP_CXX:+-DCMAKE_HIP_COMPILER="${HIP_CXX}"} \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DOFFLOAD_ARCH="${OFFLOAD_ARCH}" \
    -DROCM_PATH="${ROCM_PATH}" \
    -DCMAKE_PREFIX_PATH="${ROCM_PATH}" \
    -DBUILD_TESTING=ON

banner "Building rocm-xio (xio-tester only)"
cmake --build "${BUILD_DIR}" --target xio-tester --parallel "$(nproc)"

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
banner "Running nvme-ep KV tests"
cd "${BUILD_DIR}"

# ROCXIO_NVME_KV_CTRL: the NVMe controller device (/dev/nvme0).
# ROCXIO_NVME_KV_NSID: integer NSID of the KV namespace.
# KV namespaces are not block devices; run-nvme-kv-test.sh uses these two
# vars to construct --controller / --namespace for xio-tester directly.
#
# XIO_FORCE_PCI_MMIO_BRIDGE is required for the same reason as the LBA
# path: GPU doorbells are replayed through the pci-mmio-bridge.
sudo env \
    ROCXIO_NVME_KV_CTRL="${KV_CTRL}" \
    ROCXIO_NVME_KV_NSID="${KV_NSID}" \
    XIO_FORCE_PCI_MMIO_BRIDGE=1 \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    ctest --label-regex "${CTEST_LABEL}" \
          --output-on-failure \
          --no-tests=error

banner "Done"
