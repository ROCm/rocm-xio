#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# usage: sbatch rocm-xio-tests.nvme-ep.sbatch
#
#SBATCH --output=%x.%j.out
#SBATCH --error=%x.%j.err
#SBATCH --cpus-per-task=4
#SBATCH --container-image=/cluster/images/rocm-xio/rocm-xio-alola.sqsh
#SBATCH --container-mount-home
#SBATCH --gpus-per-node=1
#   Ensure job only runs on nodes with spare NVMe devices
#   To check compatible nodes: sinfo -Na -o "%N %100f" | grep NVME
#SBATCH --constraint=MARKHAM&NVME&ROCM7.2.0

set -e
if [ -n "${SLURM_SUBMIT_DIR}" ]; then
  . "${SLURM_SUBMIT_DIR}/rocm-xio-tests.common"
else
  . "$(dirname "${BASH_SOURCE[0]}")/rocm-xio-tests.common"
fi

cleanup() {
  echo "Cleaning up..."
  unload_kernel_module_on_host
  rm -rf "${WORKING_DIR}"
  ssh localhost "sudo rm -rf ${WORKING_DIR}"
}
trap cleanup EXIT

echo "=========================================="
echo "NVMe-EP Unit Test Script"
echo "=========================================="
echo ""

ROOT_DEVICE=$(find_root_device)
echo "  ROOT_DEVICE: ${ROOT_DEVICE}"
if [ -z "${ROOT_DEVICE}" ]; then
  echo "ERROR: Failed to find root device"
  exit 1
fi

echo "INFO: Constructing list of NVMe controllers, namespaces, and partitions..."
CTRL_LIST=()
NS_LIST=()
PART_LIST=()
for dev in /dev/nvme[0-9]*; do
    # Filter to ensure this is a controller, not a namespace.
    if [[ "$dev" =~ ^/dev/nvme[0-9]+$ ]]; then
        CTRL_LIST+=(${dev})
    elif [[ "$dev" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
        NS_LIST+=(${dev})
    elif [[ "$dev" =~ ^/dev/nvme[0-9]+n[0-9]+p[0-9]+$ ]]; then
        PART_LIST+=(${dev})
    fi
done
echo "  CTRL_LIST: ${CTRL_LIST[@]}"
echo "  NS_LIST: ${NS_LIST[@]}"
echo "  PART_LIST: ${PART_LIST[@]}"

# Find a non-rootfs controller to use for the test.
NON_ROOTFS_CTRL=$(find_non_rootfs_nvme_ctrl "${ROOT_DEVICE}" "${CTRL_LIST[@]}")
echo "  NON_ROOTFS_CTRL: ${NON_ROOTFS_CTRL}"

# Build rocm-xio
cd "${PROJECT_DIR}"
setup_and_build_workdir "nvme-ep"

echo "Building and loading kernel module on host..."
build_and_load_kernel_module_on_host

# Copy over test program
ssh localhost "mkdir -p ${WORKING_DIR}/build/"
scp ${WORKING_DIR}/build/xio-tester \
  localhost:${WORKING_DIR}/build/xio-tester

# Run tests
echo "=========================================="
echo "Running NVMe-EP unit tests"
echo "=========================================="
echo "NVMe Controller: ${NON_ROOTFS_CTRL}"
echo ""

ssh localhost "export LD_LIBRARY_PATH=/opt/rocm/lib; \
  export HSA_FORCE_FINE_GRAIN_PCIE=1; \
  sudo -E ${WORKING_DIR}/build/xio-tester \
    nvme-ep --controller ${NON_ROOTFS_CTRL} \
    --access-pattern random \
    --lfsr-seed 0 \
    --read-io -5 \
    --queue-id 63 \
    --queue-length 16 \
    --verbose"

sleep 3

ssh localhost "export LD_LIBRARY_PATH=/opt/rocm/lib; \
  export HSA_FORCE_FINE_GRAIN_PCIE=1; \
  sudo -E ${WORKING_DIR}/build/xio-tester \
    nvme-ep --controller ${NON_ROOTFS_CTRL} \
    --access-pattern random \
    --lfsr-seed 43 \
    --write-io -5 \
    --queue-id 63 \
    --queue-length 16 \
    --verbose"

echo ""
echo "=========================================="
echo "All tests passed!"
echo "=========================================="
