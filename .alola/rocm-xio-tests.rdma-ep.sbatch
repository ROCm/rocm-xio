#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# usage: sbatch rocm-xio-tests.rdma-ep.sbatch
#
# RDMA-EP loopback test. Builds with all GDA vendors
# enabled, auto-detects which NIC is present on the
# allocated node, then runs loopback tests for each
# detected vendor via ssh localhost (host access is
# required for kernel modules and RDMA devices).
#
# To check compatible nodes:
#   sinfo -Na -o "%N %100f" | grep IB
#
#SBATCH --output=logs/%x.%j.out
#SBATCH --error=logs/%x.%j.err
#SBATCH --cpus-per-task=4
#SBATCH --container-image=/cluster/images/rocm-xio/rocm-xio-alola.sqsh
#SBATCH --container-mount-home
#SBATCH --constraint=MARKHAM&IB&(ROCM7.2.0|ROCM7.3.0|ROCM7.1.1|ROCM7.0.1)
#SBATCH --gpus-per-node=1

set -xe

# Use timestamped logs directory if provided
LOGS_DIR="${ALOLA_LOGS_DIR:-logs}"
mkdir -p "${LOGS_DIR}" 2>/dev/null || true

if [ -n "${SLURM_SUBMIT_DIR}" ]; then
  . "${SLURM_SUBMIT_DIR}/rocm-xio-tests.common"
else
  . "$(dirname "${BASH_SOURCE[0]}")/rocm-xio-tests.common"
fi

LOOPBACK_SEEDS="${LOOPBACK_SEEDS:-1 2 3 4 5}"
LOOPBACK_SIZE="${LOOPBACK_SIZE:-256}"
LOOPBACK_ITERS="${LOOPBACK_ITERS:-100}"

cleanup() {
  echo "Cleaning up..."
  ${SSH_LOCALHOST} "rm -rf ${WORKING_DIR}" \
    2>/dev/null || true
  rm -rf "${WORKING_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

# Initialize test tracking
test_init

# Display job information
display_job_info

echo "=========================================="
echo "RDMA-EP Loopback Test"
echo "=========================================="
echo ""

cd "${PROJECT_DIR}"
detect_gpu_arch

# --- Build phase (inside container) ---
# Cannot use setup_and_build_workdir because we
# need extra cmake flags and specific build targets.
WORKING_DIR="/tmp/rocm-xio-tests.rdma-ep.$RANDOM"
mkdir -p "${WORKING_DIR}"
rsync -a --exclude='.git' . "${WORKING_DIR}"
cd "${WORKING_DIR}"
rm -rf build
cmake -S . -B build \
  -DGDA_BNXT=ON -DGDA_MLX5=ON -DGDA_IONIC=ON
cmake --build build \
  --target test-rdma-loopback \
  --target install-rdma-core \
  --parallel

RDMA_CORE_LIB="${WORKING_DIR}/build/_deps"
RDMA_CORE_LIB="${RDMA_CORE_LIB}/rdma-core/install/lib"
TEST_BIN="${WORKING_DIR}/build/tests/unit"
TEST_BIN="${TEST_BIN}/rdma-ep/test-rdma-loopback"
SETUP_SCRIPT="${WORKING_DIR}/scripts/test"
SETUP_SCRIPT="${SETUP_SCRIPT}/setup-rdma-loopback.sh"

# --- Copy artifacts to host ---
echo ""
echo "Copying test artifacts to host..."
${SSH_LOCALHOST} "mkdir -p ${WORKING_DIR}/build/tests/unit/rdma-ep"
${SSH_LOCALHOST} "mkdir -p ${WORKING_DIR}/scripts/test"
${SCP_COMMAND} "${TEST_BIN}" \
  "localhost:${TEST_BIN}"
${SCP_COMMAND} "${SETUP_SCRIPT}" \
  "localhost:${SETUP_SCRIPT}"

# Copy rdma-core install directory to host
${SSH_LOCALHOST} \
  "mkdir -p ${WORKING_DIR}/build/_deps/rdma-core"
${SCP_COMMAND} -r \
  "${WORKING_DIR}/build/_deps/rdma-core/install" \
  "localhost:${WORKING_DIR}/build/_deps/rdma-core/"

# --- Auto-detect NICs on host ---
echo ""
echo "Detecting RDMA NICs on host..."

DETECTED_VENDORS=""

HAS_BNXT=$(${SSH_LOCALHOST} \
  "ls -d /sys/class/infiniband/rocm-rdma-bnxt* \
  /sys/class/infiniband/bnxt_* 2>/dev/null \
  | head -1" || true)
if [ -n "${HAS_BNXT}" ]; then
  BNXT_DEV=$(${SSH_LOCALHOST} \
    "basename ${HAS_BNXT}")
  DETECTED_VENDORS="${DETECTED_VENDORS} bnxt"
  echo "  Found BNXT: ${BNXT_DEV}"
fi

HAS_MLX5=$(${SSH_LOCALHOST} \
  "ls -d /sys/class/infiniband/rocm-rdma-mlx5* \
  /sys/class/infiniband/mlx5_* 2>/dev/null \
  | head -1" || true)
if [ -n "${HAS_MLX5}" ]; then
  MLX5_DEV=$(${SSH_LOCALHOST} \
    "basename ${HAS_MLX5}")
  DETECTED_VENDORS="${DETECTED_VENDORS} mlx5"
  echo "  Found MLX5: ${MLX5_DEV}"
fi

HAS_IONIC=$(${SSH_LOCALHOST} \
  "ls -d /sys/class/infiniband/rocm-rdma-ionic* \
  /sys/class/infiniband/ionic_* 2>/dev/null \
  | head -1" || true)
if [ -n "${HAS_IONIC}" ]; then
  IONIC_DEV=$(${SSH_LOCALHOST} \
    "basename ${HAS_IONIC}")
  DETECTED_VENDORS="${DETECTED_VENDORS} ionic"
  echo "  Found IONIC: ${IONIC_DEV}"
fi

if [ -z "${DETECTED_VENDORS}" ]; then
  echo "ERROR: No RDMA NICs detected on host."
  echo "  Checked /sys/class/infiniband/ for"
  echo "  rocm-rdma-bnxt*, rocm-rdma-mlx5*,"
  echo "  rocm-rdma-ionic*, bnxt_*, mlx5_*,"
  echo "  ionic_*"
  exit 1
fi

echo "  Detected vendors:${DETECTED_VENDORS}"

# --- Run setup on host ---
echo ""
echo "Running RDMA hardware setup on host..."
${SSH_LOCALHOST} \
  "sudo VENDOR=all ${SETUP_SCRIPT}" || true

# --- Run loopback tests for each vendor ---
echo ""
echo "=========================================="
echo "Running RDMA-EP loopback tests"
echo "=========================================="

LIB_PATH="${RDMA_CORE_LIB}:/opt/rocm/lib"

for vendor in ${DETECTED_VENDORS}; do
  RDMA_DEV=""
  case "${vendor}" in
    bnxt)  RDMA_DEV="${BNXT_DEV}" ;;
    mlx5)  RDMA_DEV="${MLX5_DEV}" ;;
    ionic) RDMA_DEV="${IONIC_DEV}" ;;
  esac

  echo ""
  echo "--- ${vendor^^} loopback ---"
  echo "  device=${RDMA_DEV}"
  echo "  size=${LOOPBACK_SIZE}"
  echo "  iterations=${LOOPBACK_ITERS}"
  echo ""

  for seed in ${LOOPBACK_SEEDS}; do
    test_run \
      "rdma-ep loopback ${vendor} seed=${seed}" \
      "${SSH_LOCALHOST} \
        \"sudo env LD_LIBRARY_PATH=${LIB_PATH} \
          ${TEST_BIN} \
          --provider ${vendor} \
          --device ${RDMA_DEV} \
          --size ${LOOPBACK_SIZE} \
          --seed ${seed} \
          -n ${LOOPBACK_ITERS}\""
    sleep 1
  done
done

# Report results and exit with appropriate code
test_report
EXIT_CODE=$?

exit ${EXIT_CODE}
