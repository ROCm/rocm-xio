#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# usage: sbatch rocm-xio-tests-nvme-ep.sbatch
#        or: NVME_DEVICE=/dev/nvme1 sbatch rocm-xio-tests-nvme-ep.sbatch
#
#SBATCH --output=%x.%j.out
#SBATCH --error=%x.%j.err
#SBATCH --cpus-per-task=4
#SBATCH --container-image=/cluster/images/rocm-xio/rocm-xio-alola.sqsh
#SBATCH --container-mount-home
#SBATCH --gpus-per-node=1

set -e

if [ -n "${SLURM_SUBMIT_DIR}" ]; then
  . "${SLURM_SUBMIT_DIR}/rocm-xio-tests.common"
else
  . "$(dirname "${BASH_SOURCE[0]}")/rocm-xio-tests.common"
fi

# NVMe device to test (required)
NVME_DEVICE="${NVME_DEVICE:-/dev/nvme0}"
NAMESPACE_ID="${NAMESPACE_ID:-1}"

cd "${PROJECT_DIR}"

echo "=========================================="
echo "NVMe-EP Unit Test Script"
echo "=========================================="
echo "NVMe Device: ${NVME_DEVICE}"
echo "Namespace ID: ${NAMESPACE_ID}"
echo ""

# Check if NVMe device exists
if [ ! -e "${NVME_DEVICE}" ]; then
  echo "ERROR: NVMe device ${NVME_DEVICE} not found"
  exit 1
fi

# Check if device is rootfs (HARD FAILURE - no override)
echo "Checking if device is root filesystem..."
NS_DEVICE="${NVME_DEVICE}n${NAMESPACE_ID}"
ROOT_DEVICE=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")

if [ -n "${ROOT_DEVICE}" ]; then
  if echo "${ROOT_DEVICE}" | grep -q "${NS_DEVICE}" || \
     echo "${ROOT_DEVICE}" | grep -q "${NVME_DEVICE}"; then
    echo "ERROR: NVMe device ${NVME_DEVICE} appears to be the root "
    echo "       filesystem!"
    echo "This test will NOT run on rootfs to prevent data corruption."
    echo "Please specify a different NVMe device."
    echo "Root device: ${ROOT_DEVICE}"
    exit 1
  fi
fi
echo "Device is not rootfs - OK"
echo ""

# Build kernel module
echo "Building kernel module..."
cd kernel/rocm-xio
if ! make; then
  echo "ERROR: Kernel module build failed"
  exit 1
fi
cd "${PROJECT_DIR}"
echo "Kernel module built successfully"
echo ""

# Load kernel module
echo "Loading kernel module..."
if ! lsmod | grep -q "^rocm_xio"; then
  if ! sudo modprobe rocm-xio; then
    echo "ERROR: Failed to load kernel module"
    exit 1
  fi
  echo "Kernel module loaded"
else
  echo "Kernel module already loaded"
fi

# Create device node if missing
if [ ! -e "/dev/rocm-xio" ]; then
  echo "Creating device node..."
  MAJOR=$(grep rocm-xio /proc/devices | awk '{print $1}')
  if [ -z "${MAJOR}" ]; then
    echo "ERROR: Failed to find rocm-xio major number"
    exit 1
  fi
  if ! sudo mknod /dev/rocm-xio c "${MAJOR}" 0; then
    echo "ERROR: Failed to create device node"
    exit 1
  fi
  if ! sudo chmod 666 /dev/rocm-xio; then
    echo "WARNING: Failed to set permissions on device node"
  fi
  echo "Device node created"
else
  echo "Device node already exists"
fi
echo ""

# Build unit tests
echo "Building unit tests..."
detect_gpu_arch
setup_and_build_workdir "nvme-ep"

# Check if test executable exists
TEST_EXEC="./build/tests/unit/nvme-ep/test-nvme-ep-simple-io"
if [ ! -f "${TEST_EXEC}" ]; then
  echo "ERROR: Test executable not found at ${TEST_EXEC}"
  exit 1
fi
echo "Unit tests built successfully"
echo ""

# Run tests
echo "=========================================="
echo "Running NVMe-EP unit tests"
echo "=========================================="
echo ""

# Set HSA_FORCE_FINE_GRAIN_PCIE for GPU-PCIe coherency (required for GPU
# writes to be visible to PCIe devices like NVMe controllers)
export HSA_FORCE_FINE_GRAIN_PCIE=1

if ! "${TEST_EXEC}" --controller "${NVME_DEVICE}" \
     --namespace "${NAMESPACE_ID}"; then
  echo ""
  echo "ERROR: Unit tests failed"
  exit 1
fi

echo ""
echo "=========================================="
echo "All tests passed!"
echo "=========================================="

cd "$HOME"
rm -rf "${WORKING_DIR}"
