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

    # rocminfo is not in the guest image: it is outside the minimal ROCm set
    # the image installs and the therock runtime package does not carry it.
    # The KFD topology above is the authoritative check anyway -- rocminfo
    # reads the same sysfs nodes -- so report from sysfs and use rocminfo only
    # to add detail when a consumer happens to have it.
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
# The guest installs ROCm from the therock stream, whose layout is
# /opt/rocm/<component>-<version> rather than a single versioned root with a
# /opt/rocm symlink over it. A hardcoded /opt/rocm therefore fails
# CMakeDetermineHIPCompiler with "Failed to find ROCm root directory" before
# any of our CMakeLists runs -- and that message reads like a path problem even
# when the real cause is a toolchain the minimal package set never installed.
#
# So locate the root by the thing CMake actually needs, the hip-lang package,
# and fall back to hipcc. Searching beats globbing here because the component
# directory name is not ours to predict.
# Collect the roots that exist before searching them. An unmatched /opt/rocm-*
# glob stays literal, and find then fails on it -- which under "set -e" with
# pipefail kills the script inside the command substitution, with no output at
# all. Every search below is also "|| true": a search finding nothing is an
# answer, not an error, and must reach the diagnostic at the bottom.
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
        # <root>/lib/cmake/hip-lang -> <root>
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
    echo "The guest installs a minimal ROCm set (amdrocm-runtime-dev," >&2
    echo "amdrocm-blas-dev); CMake's HIP language needs a compiler too." >&2
    echo "Tree:" >&2
    find "${roots[@]}" -maxdepth 3 2>/dev/null | head -40 >&2
    exit 1
fi
echo "Using ROCM_PATH=${ROCM_PATH}"
export ROCM_PATH

# CMakeDetermineHIPCompiler establishes the ROCm root in one of two ways: a
# HIP-capable clang whose "-v -print-targets" prints "Found HIP installation:",
# or "hipconfig --rocmpath". Both have to be reachable, and nothing puts the
# therock bin directory on PATH -- the image only adds its libraries to
# ld.so.conf. Without this, CMake reports "Failed to find ROCm root directory"
# no matter what -DROCM_PATH says, because it never consults that variable.
export PATH="${ROCM_PATH}/bin:${PATH}"

echo "HIP toolchain:"
ls "${ROCM_PATH}/bin" 2>/dev/null | head -30 || echo "  (no bin directory)"
echo "CMake packages:"
ls "${ROCM_PATH}/lib/cmake" 2>/dev/null | head -30 || echo "  (no lib/cmake)"

# Point CMake straight at the compiler when one is present, rather than
# relying on it to guess: the therock trees ship amdclang++ and may not ship
# the hipcc wrapper at all.
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

cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    ${HIP_CXX:+-DCMAKE_HIP_COMPILER="${HIP_CXX}"} \
    -DCMAKE_BUILD_TYPE=Debug \
    -DOFFLOAD_ARCH="${OFFLOAD_ARCH}" \
    -DROCM_PATH="${ROCM_PATH}" \
    -DCMAKE_PREFIX_PATH="${ROCM_PATH}" \
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
# XIO_FORCE_PCI_MMIO_BRIDGE is not optional in here. The emulated NVMe
# controller never sees a doorbell written directly by the GPU; it only sees
# MMIO replayed through the pci-mmio-bridge device QEMU exposes at 1b36:0015.
# The nvme-ep ctests pin USE_PCI_MMIO_BRIDGE=0 for hardware, so without this
# every device-touching test submits I/O and then waits for completions that
# can never arrive -- 14 consecutive ctest timeouts, no failures.
sudo env \
    ROCXIO_NVME_DEVICE="${NVME_CTRL}" \
    XIO_FORCE_PCI_MMIO_BRIDGE=1 \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    ctest --label-regex "${CTEST_LABEL}" \
          --output-on-failure \
          --no-tests=error

banner "Done"
