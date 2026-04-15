#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# usage: sbatch rocm-xio-tests.rdma-ep-batch.sbatch
#
# RDMA-EP batch and multi-QP loopback test.  Builds
# xio-tester with all GDA vendors, auto-detects
# which NIC is present, then runs batch-size and
# num-queues test matrix for each detected vendor.
#
#SBATCH --output=logs/%x.%j.out
#SBATCH --error=logs/%x.%j.err
#SBATCH --cpus-per-task=4
#SBATCH --container-image=/cluster/images/rocm-xio/rocm-xio-alola.sqsh
#SBATCH --container-mount-home
#SBATCH --constraint=MARKHAM&IB
#SBATCH --gpus-per-node=1

set -xe

LOGS_DIR="${ALOLA_LOGS_DIR:-logs}"
mkdir -p "${LOGS_DIR}" 2>/dev/null || true

if [ -n "${SLURM_SUBMIT_DIR}" ]; then
  . "${SLURM_SUBMIT_DIR}/rocm-xio-tests.common"
else
  . "$(dirname "${BASH_SOURCE[0]}")/rocm-xio-tests.common"
fi

ITERATIONS="${ITERATIONS:-128}"
TRANSFER_SIZE="${TRANSFER_SIZE:-4096}"

cleanup() {
  echo "Cleaning up..."
  ${SSH_LOCALHOST} "rm -rf ${WORKING_DIR}" \
    2>/dev/null || true
  rm -rf "${WORKING_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

test_init
display_job_info

echo "=========================================="
echo "RDMA-EP Batch / Multi-QP Test"
echo "=========================================="
echo ""

cd "${PROJECT_DIR}"
detect_gpu_arch

WORKING_DIR="/tmp/rocm-xio-tests.rdma-ep-batch.$RANDOM"
mkdir -p "${WORKING_DIR}"
rsync -a --exclude='.git' . "${WORKING_DIR}"
cd "${WORKING_DIR}"
rm -rf build
cmake -S . -B build \
  -DGDA_BNXT=ON -DGDA_MLX5=ON -DGDA_IONIC=ON
cmake --build build \
  --target xio-tester \
  --target install-rdma-core \
  --parallel

RDMA_CORE_LIB="${WORKING_DIR}/build/_deps"
RDMA_CORE_LIB="${RDMA_CORE_LIB}/rdma-core/install/lib"
TESTER_BIN="${WORKING_DIR}/build/xio-tester"
SETUP_SCRIPT="${WORKING_DIR}/scripts/test"
SETUP_SCRIPT="${SETUP_SCRIPT}/setup-rdma-loopback.sh"

${SSH_LOCALHOST} "mkdir -p ${WORKING_DIR}/build"
${SSH_LOCALHOST} \
  "mkdir -p ${WORKING_DIR}/scripts/test"
${SCP_COMMAND} "${TESTER_BIN}" \
  "localhost:${TESTER_BIN}"
${SCP_COMMAND} "${SETUP_SCRIPT}" \
  "localhost:${SETUP_SCRIPT}"
${SSH_LOCALHOST} \
  "mkdir -p ${WORKING_DIR}/build/_deps/rdma-core"
${SCP_COMMAND} -r \
  "${WORKING_DIR}/build/_deps/rdma-core/install" \
  "localhost:${WORKING_DIR}/build/_deps/rdma-core/"

echo ""
echo "Detecting RDMA NICs on host..."

DETECTED_VENDORS=""
for _v in bnxt mlx5 ionic; do
  _dev=$(detect_rdma_nic "${SSH_COMMAND}" \
    "localhost" "${_v}")
  if [ -n "${_dev}" ]; then
    eval "${_v^^}_DEV=\${_dev}"
    DETECTED_VENDORS="${DETECTED_VENDORS} ${_v}"
    echo "  Found ${_v^^}: ${_dev}"
  fi
done
unset _v _dev

if [ -z "${DETECTED_VENDORS}" ]; then
  echo "ERROR: No RDMA NICs detected."
  exit 1
fi

echo ""
echo "Running RDMA hardware setup on host..."
${SSH_LOCALHOST} \
  "sudo VENDOR=all ${SETUP_SCRIPT}" || true

LIB_PATH="${RDMA_CORE_LIB}:${ROCM_NFS}/lib"

run_rdma_test() {
  local label="$1"; shift
  test_run "${label}" \
    "ssh_with_retry \
      \"sudo env LD_LIBRARY_PATH=${LIB_PATH} \
        PATH=${ROCM_NFS}/bin:\\\${PATH} \
        HSA_FORCE_FINE_GRAIN_PCIE=1 \
        ${TESTER_BIN} rdma-ep \
        $*\""
  sleep 1
}

echo ""
echo "=========================================="
echo "Running RDMA-EP batch/multi-QP tests"
echo "=========================================="

for vendor in ${DETECTED_VENDORS}; do
  RDMA_DEV=""
  case "${vendor}" in
    bnxt)  RDMA_DEV="${BNXT_DEV}" ;;
    mlx5)  RDMA_DEV="${MLX5_DEV}" ;;
    ionic) RDMA_DEV="${IONIC_DEV}" ;;
  esac

  COMMON="--provider ${vendor} \
    --device ${RDMA_DEV} \
    --loopback --verify --less-timing \
    --transfer-size ${TRANSFER_SIZE}"

  echo ""
  echo "--- ${vendor^^} ---"

  run_rdma_test \
    "${vendor} baseline" \
    "${COMMON} --iterations ${ITERATIONS}"

  run_rdma_test \
    "${vendor} batch-size 4" \
    "${COMMON} --iterations ${ITERATIONS} \
      --batch-size 4"

  run_rdma_test \
    "${vendor} num-queues 2" \
    "${COMMON} --iterations ${ITERATIONS} \
      --num-queues 2"

  run_rdma_test \
    "${vendor} batch-4 + queues-2" \
    "${COMMON} --iterations ${ITERATIONS} \
      --batch-size 4 --num-queues 2"
done

test_report
EXIT_CODE=$?

exit ${EXIT_CODE}
