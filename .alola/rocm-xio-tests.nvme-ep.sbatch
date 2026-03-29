#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# usage: sbatch rocm-xio-tests.nvme-ep.sbatch
#
#SBATCH --output=logs/%x.%j.out
#SBATCH --error=logs/%x.%j.err
#SBATCH --cpus-per-task=4
#SBATCH --container-image=/cluster/images/rocm-xio/rocm-xio-alola.sqsh
#SBATCH --container-mount-home
#SBATCH --gpus-per-node=1
#   Ensure job only runs on nodes with spare NVMe devices
#   To check compatible nodes: sinfo -Na -o "%N %100f" | grep NVME
#   Also ensure a recent ROCm version since we need to run outside enroot.
#SBATCH --constraint=MARKHAM&NVME&(ROCM7.2.0|ROCM7.3.0|ROCM7.1.1|ROCM7.0.1)

set -xe

# Use timestamped logs directory if provided, otherwise use logs/
LOGS_DIR="${ALOLA_LOGS_DIR:-logs}"
# Create directory if it doesn't exist (suppress errors if read-only or exists)
mkdir -p "${LOGS_DIR}" 2>/dev/null || true
if [ -n "${SLURM_SUBMIT_DIR}" ]; then
  . "${SLURM_SUBMIT_DIR}/rocm-xio-tests.common"
else
  . "$(dirname "${BASH_SOURCE[0]}")/rocm-xio-tests.common"
fi

run_on_host() {
  ssh_with_retry "sudo env \
LD_LIBRARY_PATH=/opt/rocm/lib \
HSA_FORCE_FINE_GRAIN_PCIE=1 $*"
}

cleanup() {
  echo "Cleaning up..."
  unload_kernel_module_on_host
  rm -rf "${WORKING_DIR}"
  ${SSH_LOCALHOST} "sudo rm -rf ${WORKING_DIR}"
}
trap cleanup EXIT

# Initialize test tracking
test_init

# Display job information
display_job_info

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

echo "INFO: Constructing list of NVMe controllers, namespaces, and " \
     "partitions..."
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
NON_ROOTFS_CTRL=$(find_non_rootfs_nvme_ctrl "${ROOT_DEVICE}" \
  "${CTRL_LIST[@]}")
echo "  NON_ROOTFS_CTRL: ${NON_ROOTFS_CTRL}"

# Find namespace corresponding to the controller
# Extract controller number (e.g., /dev/nvme0 -> 0)
if [[ "${NON_ROOTFS_CTRL}" =~ ^/dev/nvme([0-9]+)$ ]]; then
  CTRL_NUM="${BASH_REMATCH[1]}"
  # Find first namespace for this controller (typically n1)
  for ns in "${NS_LIST[@]}"; do
    if [[ "$ns" =~ ^/dev/nvme${CTRL_NUM}n[0-9]+$ ]]; then
      NVME_NAMESPACE="$ns"
      break
    fi
  done
fi
if [ -z "${NVME_NAMESPACE}" ]; then
  echo "WARN: Could not determine namespace for controller " \
       "${NON_ROOTFS_CTRL}"
fi

# Build rocm-xio
cd "${PROJECT_DIR}"
detect_gpu_arch
setup_and_build_workdir "nvme-ep"

test_run "ctest nvme-ep unit tests" \
  "ctest --test-dir build -L nvme -LE hardware"

echo "Building and loading kernel module on host..."
build_and_load_kernel_module_on_host

# Copy over test program and verification script
${SSH_LOCALHOST} "mkdir -p ${WORKING_DIR}/build/"
${SCP_COMMAND} ${WORKING_DIR}/build/xio-tester \
  localhost:${WORKING_DIR}/build/xio-tester
${SSH_LOCALHOST} \
  "mkdir -p ${WORKING_DIR}/scripts/test/"
VERIFY_SCRIPT="scripts/test"
VERIFY_SCRIPT="${VERIFY_SCRIPT}/test-nvme-ep-random-write-verify.sh"
${SCP_COMMAND} \
  ${WORKING_DIR}/${VERIFY_SCRIPT} \
  localhost:${WORKING_DIR}/${VERIFY_SCRIPT}

# Copy hardware unit test binary to host
HW_TEST_DIR="build/tests/unit/nvme-ep"
${SSH_LOCALHOST} \
  "mkdir -p ${WORKING_DIR}/${HW_TEST_DIR}"
${SCP_COMMAND} \
  ${WORKING_DIR}/${HW_TEST_DIR}/test-nvme-hardware \
  localhost:${WORKING_DIR}/${HW_TEST_DIR}/test-nvme-hardware

# Run tests
echo "=========================================="
echo "Running NVMe-EP unit tests"
echo "=========================================="
echo "NVMe Controller: ${NON_ROOTFS_CTRL}"
if [ -n "${NVME_NAMESPACE}" ]; then
  echo "NVMe Namespace: ${NVME_NAMESPACE}"
fi
echo ""

test_run "nvme-ep hardware unit tests" \
  "run_on_host \
'${WORKING_DIR}/${HW_TEST_DIR}/test-nvme-hardware \
--controller ${NON_ROOTFS_CTRL}'"

test_run "nvme-ep reject --threads > 1 (expect fail)" \
  "! run_on_host '${WORKING_DIR}/build/xio-tester \
nvme-ep --controller ${NON_ROOTFS_CTRL} \
--threads 2 -n 1'"

test_run "nvme-ep reject --batch-size > wavefront (expect fail)" \
  "! run_on_host '${WORKING_DIR}/build/xio-tester \
nvme-ep --controller ${NON_ROOTFS_CTRL} \
--batch-size 128 -n 1'"

test_run "NVMe-EP memory-mode 0" \
  "run_on_host '${WORKING_DIR}/build/xio-tester \
nvme-ep --controller ${NON_ROOTFS_CTRL} \
--access-pattern random --memory-mode 0 \
--lbas-per-io 1 --lfsr-seed 32 --read-io 23 \
--queue-length 128'"

sleep 3

test_run "NVMe-EP batch-size 4 memory-mode 0" \
  "run_on_host '${WORKING_DIR}/build/xio-tester \
nvme-ep --controller ${NON_ROOTFS_CTRL} \
--access-pattern random --memory-mode 0 \
--lbas-per-io 1 --lfsr-seed 32 --read-io 23 \
--queue-length 128 --batch-size 4'"

sleep 3

test_run "NVMe-EP batch-size 16 memory-mode 0" \
  "run_on_host '${WORKING_DIR}/build/xio-tester \
nvme-ep --controller ${NON_ROOTFS_CTRL} \
--access-pattern random --memory-mode 0 \
--lbas-per-io 1 --lfsr-seed 32 --read-io 23 \
--queue-length 128 --batch-size 16'"

sleep 3

test_run "NVMe-EP batch-size 0 (all-at-once)" \
  "run_on_host '${WORKING_DIR}/build/xio-tester \
nvme-ep --controller ${NON_ROOTFS_CTRL} \
--access-pattern random --memory-mode 0 \
--lbas-per-io 1 --lfsr-seed 32 --read-io 23 \
--queue-length 128 --batch-size 0'"

sleep 3

# VRAM-backed queues require CDNA GPUs; RDNA (gfx1100)
# cannot DMA NVMe I/O to device memory reliably.
if [ "${ROCM_GPU_ARCH}" != "gfx1100" ]; then

test_run "NVMe-EP memory-mode 3" \
  "run_on_host '${WORKING_DIR}/build/xio-tester \
nvme-ep --controller ${NON_ROOTFS_CTRL} \
--access-pattern random --memory-mode 3 --less-timing \
--lbas-per-io 1 --lfsr-seed 32 --read-io 573 \
--queue-length 128'"

sleep 3

test_run "NVMe-EP batch-size 4 memory-mode 3" \
  "run_on_host '${WORKING_DIR}/build/xio-tester \
nvme-ep --controller ${NON_ROOTFS_CTRL} \
--access-pattern random --memory-mode 3 --less-timing \
--lbas-per-io 1 --lfsr-seed 32 --read-io 573 \
--queue-length 128 --batch-size 4'"

sleep 3

test_run "NVMe-EP memory-mode 11" \
  "run_on_host '${WORKING_DIR}/build/xio-tester \
nvme-ep --controller ${NON_ROOTFS_CTRL} \
--access-pattern random --memory-mode 11 --less-timing \
--lbas-per-io 1 --lfsr-seed 32 --read-io 573 \
--queue-length 128'"

sleep 3

test_run "NVMe-EP batch-size 16 memory-mode 11" \
  "run_on_host '${WORKING_DIR}/build/xio-tester \
nvme-ep --controller ${NON_ROOTFS_CTRL} \
--access-pattern random --memory-mode 11 --less-timing \
--lbas-per-io 1 --lfsr-seed 32 --read-io 573 \
--queue-length 128 --batch-size 16'"

else
  echo "INFO: Skipping VRAM memory-modes 3/11" \
    "(${ROCM_GPU_ARCH} does not support NVMe DMA" \
    "to device memory)."
fi

# Disable NVMe duration capture
CAPTURE_NVME_DURATION=0

sleep 3

# Write-and-verify tests: write random LBAs via xio-tester,
# then read each back with dd and verify the data pattern.
echo ""
echo "=========================================="
echo "Running NVMe-EP write-verify tests"
echo "=========================================="
echo ""

VERIFY_CMD="${WORKING_DIR}/${VERIFY_SCRIPT}"

HAVE_VERIFY_DEPS=true
if ! ${SSH_LOCALHOST} "command -v python3" \
     > /dev/null 2>&1; then
  echo "WARN: python3 not found on host;" \
       "skipping write-verify tests"
  HAVE_VERIFY_DEPS=false
fi

if [ "${HAVE_VERIFY_DEPS}" = "true" ]; then

test_run "NVMe-EP write-verify memory-mode 0" \
  "run_on_host \
'XIO_TESTER=${WORKING_DIR}/build/xio-tester \
NUM_WRITES=64 MEMORY_MODE=0 \
LFSR_SEED=0xDEAD BASE_LBA=0 \
TEMP_DIR=${WORKING_DIR}/verify-m0 \
${VERIFY_CMD} ${NON_ROOTFS_CTRL}'"

if [ "${ROCM_GPU_ARCH}" != "gfx1100" ]; then

sleep 3

test_run "NVMe-EP write-verify memory-mode 3" \
  "run_on_host \
'XIO_TESTER=${WORKING_DIR}/build/xio-tester \
NUM_WRITES=64 MEMORY_MODE=3 \
LFSR_SEED=0xBEEF BASE_LBA=0 \
TEMP_DIR=${WORKING_DIR}/verify-m3 \
${VERIFY_CMD} ${NON_ROOTFS_CTRL}'"

sleep 3

test_run "NVMe-EP write-verify memory-mode 11" \
  "run_on_host \
'XIO_TESTER=${WORKING_DIR}/build/xio-tester \
NUM_WRITES=64 MEMORY_MODE=11 \
LFSR_SEED=0xCAFE BASE_LBA=0 \
TEMP_DIR=${WORKING_DIR}/verify-m11 \
${VERIFY_CMD} ${NON_ROOTFS_CTRL}'"

fi # gfx1100 skip

fi # HAVE_VERIFY_DEPS

# Report results and exit with appropriate code
test_report "${NVME_NAMESPACE}"
EXIT_CODE=$?

exit ${EXIT_CODE}
