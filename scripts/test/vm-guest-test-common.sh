#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# vm-guest-test-common.sh
#
# Shared setup functions for vm-guest-test-kv.sh and vm-guest-test-nvme.sh.
# Source this file; do not execute it directly.
#
# Functions provided:
#   banner MESSAGE         Print a visible section header.
#   gpu_bringup            Load amdgpu and wait for a KFD agent.
#   find_rocm              Set ROCM_PATH and update PATH.
#   build_xio_tester       cmake configure + build xio-tester.
#   load_kernel_module     Install udev rules and insmod rocm-xio.ko.
#
# Environment variables consumed (with defaults):
#   SRC_DIR       rocm-xio source tree   (default: ~/rocm-xio)
#   BUILD_DIR     cmake build directory  (default: $SRC_DIR/build)
#   OFFLOAD_ARCH  GPU offload arch       (default: gfx1250)
#   SKIP_GPU      Set to 1 to skip GPU bring-up  (default: 0)

banner() {
    echo ""
    echo "=== $* ==="
}

gpu_bringup() {
    if [ "${SKIP_GPU}" = "1" ]; then
        banner "GPU bring-up skipped (SKIP_GPU=1)"
        return 0
    fi

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
        return 1
    fi

    banner "KFD agent"
    for node in /sys/class/kfd/kfd/topology/nodes/[1-9]*; do
        [ -r "${node}/properties" ] || continue
        echo "${node}:"
        grep -E '^(gfx_target_version|simd_count|vendor_id|device_id) ' \
            "${node}/properties" || true
    done
    # Skip rocminfo on rocjitsu: it triggers amdgpu_vm_make_compute WARN_ON
    # which corrupts the guest page cache and causes all subsequent test
    # invocations to segfault in libhsa/libdrm/libc.
    if command -v rocminfo > /dev/null && \
       [ "$(cat /sys/module/amdgpu/parameters/emu_mode 2>/dev/null || echo 0)" = "0" ]; then
        rocminfo | grep -E 'Name:|gfx' || true
    fi
}

find_rocm() {
    roots=()
    for d in /opt/rocm /opt/rocm-*; do
        [ -d "${d}" ] && roots+=("${d}")
    done
    if [ "${#roots[@]}" -eq 0 ]; then
        echo "ERROR: no /opt/rocm* directory in the guest at all." >&2
        return 1
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
        return 1
    fi
    echo "Using ROCM_PATH=${ROCM_PATH}"
    export ROCM_PATH
    export PATH="${ROCM_PATH}/bin:${PATH}"
}

build_xio_tester() {
    banner "Configuring rocm-xio"

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

    # Release (not RelWithDebInfo): debug info inflates the HIP device-code
    # link step beyond 7 GiB, causing ld.lld to abort on standard GitHub
    # runners.  Optimisation level is unchanged (-O2/-O3), so GPU dispatch
    # still completes on the rocjitsu emulated target.
    # CMAKE_EXTRA_FLAGS may be set by the caller to pass additional -D flags.
    cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
        ${HIP_CXX:+-DCMAKE_HIP_COMPILER="${HIP_CXX}"} \
        -DCMAKE_BUILD_TYPE=Release \
        -DOFFLOAD_ARCH="${OFFLOAD_ARCH}" \
        -DROCM_PATH="${ROCM_PATH}" \
        -DCMAKE_PREFIX_PATH="${ROCM_PATH}" \
        -DBUILD_TESTING=ON \
        ${CMAKE_EXTRA_FLAGS:-}

    banner "Building rocm-xio (xio-tester only)"
    # Cap at 2 parallel jobs: the HIP device-code link step (ld.lld + clang
    # offload bundler) consumes ~3-4 GiB per job and OOMs the 8 GiB VM with
    # nproc=4.
    local build_jobs
    build_jobs=$(( $(nproc) > 2 ? 2 : $(nproc) ))
    cmake --build "${BUILD_DIR}" --target xio-tester --parallel "${build_jobs}"
}

load_kernel_module() {
    banner "Installing rocm-xio udev rules"
    sudo "${SRC_DIR}/udev/setup-udev-rules.sh" --install

    banner "Building and loading the rocm-xio kernel module"
    make -C "${SRC_DIR}/kernel/rocm-xio"
    sudo rmmod rocm_xio 2>/dev/null || true
    sudo insmod "${SRC_DIR}/kernel/rocm-xio/rocm-xio.ko"
    lsmod | grep -q rocm_xio || {
        echo "ERROR: rocm-xio module did not load" >&2
        sudo dmesg | tail -50 >&2
        return 1
    }
}
