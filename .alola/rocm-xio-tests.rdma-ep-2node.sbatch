#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# usage: sbatch rocm-xio-tests.rdma-ep-2node.sbatch
#
# RDMA-EP two-node test. Allocates 2 IB nodes, builds
# with all GDA vendors, auto-detects the NIC vendor,
# then runs a client-server RDMA WRITE + ping-pong
# test across the two nodes.
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
#SBATCH --nodes=2
#SBATCH --gpus-per-node=1

set -xe

LOGS_DIR="${ALOLA_LOGS_DIR:-logs}"
mkdir -p "${LOGS_DIR}" 2>/dev/null || true

if [ -n "${SLURM_SUBMIT_DIR}" ]; then
  . "${SLURM_SUBMIT_DIR}/rocm-xio-tests.common"
else
  . "$(dirname "${BASH_SOURCE[0]}")/rocm-xio-tests.common"
fi

PP_SIZE="${PP_SIZE:-64}"
PP_ITERS="${PP_ITERS:-100}"

IFS=',' read -ra NODES <<< "${SLURM_JOB_NODELIST}"
if [ ${#NODES[@]} -lt 2 ]; then
  echo "ERROR: Need 2 nodes, got ${#NODES[@]}"
  exit 1
fi
NODE_SERVER="${NODES[0]}"
NODE_CLIENT="${NODES[1]}"

cleanup() {
  echo "Cleaning up..."
  for node in "${NODE_SERVER}" "${NODE_CLIENT}"; do
    ${SSH_COMMAND} "${node}" \
      "rm -rf ${WORKING_DIR}" \
      2>/dev/null || true
  done
  rm -rf "${WORKING_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

test_init
display_job_info

echo "=========================================="
echo "RDMA-EP Two-Node Test"
echo "=========================================="
echo "  Server node: ${NODE_SERVER}"
echo "  Client node: ${NODE_CLIENT}"
echo ""

cd "${PROJECT_DIR}"
detect_gpu_arch

# --- Build phase (inside container) ---
WORKING_DIR="/tmp/rocm-xio-tests.rdma-2n.$RANDOM"
mkdir -p "${WORKING_DIR}"
rsync -a --exclude='.git' . "${WORKING_DIR}"
cd "${WORKING_DIR}"
rm -rf build
cmake -S . -B build \
  -DGDA_BNXT=ON -DGDA_MLX5=ON -DGDA_IONIC=ON
cmake --build build \
  --target test-rdma-2node \
  --target install-rdma-core \
  --parallel

RDMA_CORE_LIB="${WORKING_DIR}/build/_deps"
RDMA_CORE_LIB="${RDMA_CORE_LIB}/rdma-core/install/lib"
TEST_BIN="${WORKING_DIR}/build/tests/unit"
TEST_BIN="${TEST_BIN}/rdma-ep/test-rdma-2node"

# --- Copy artifacts to both nodes ---
echo ""
echo "Copying test artifacts to nodes..."
for node in "${NODE_SERVER}" "${NODE_CLIENT}"; do
  ${SSH_COMMAND} "${node}" \
    "mkdir -p ${WORKING_DIR}/build/tests/unit/rdma-ep"
  ${SCP_COMMAND} "${TEST_BIN}" \
    "${node}:${TEST_BIN}"
  ${SSH_COMMAND} "${node}" \
    "mkdir -p ${WORKING_DIR}/build/_deps/rdma-core"
  ${SCP_COMMAND} -r \
    "${WORKING_DIR}/build/_deps/rdma-core/install" \
    "${node}:${WORKING_DIR}/build/_deps/rdma-core/"
done

# --- Auto-detect NIC vendor on server node ---
echo ""
echo "Detecting RDMA NICs on ${NODE_SERVER}..."

detect_vendor_on_node() {
  local node="$1"
  local vendor=""
  local dev=""

  local has_mlx5
  has_mlx5=$(${SSH_COMMAND} "${node}" \
    "ls -d /sys/class/infiniband/rocm-rdma-mlx5* \
    /sys/class/infiniband/mlx5_* 2>/dev/null \
    | head -1" || true)
  if [ -n "${has_mlx5}" ]; then
    vendor="mlx5"
    dev=$(${SSH_COMMAND} "${node}" \
      "basename ${has_mlx5}")
    echo "${vendor} ${dev}"
    return
  fi

  local has_bnxt
  has_bnxt=$(${SSH_COMMAND} "${node}" \
    "ls -d /sys/class/infiniband/rocm-rdma-bnxt* \
    /sys/class/infiniband/bnxt_* 2>/dev/null \
    | head -1" || true)
  if [ -n "${has_bnxt}" ]; then
    vendor="bnxt"
    dev=$(${SSH_COMMAND} "${node}" \
      "basename ${has_bnxt}")
    echo "${vendor} ${dev}"
    return
  fi

  local has_ionic
  has_ionic=$(${SSH_COMMAND} "${node}" \
    "ls -d /sys/class/infiniband/rocm-rdma-ionic* \
    /sys/class/infiniband/ionic_* 2>/dev/null \
    | head -1" || true)
  if [ -n "${has_ionic}" ]; then
    vendor="ionic"
    dev=$(${SSH_COMMAND} "${node}" \
      "basename ${has_ionic}")
    echo "${vendor} ${dev}"
    return
  fi
}

read -r SRV_VENDOR SRV_DEV \
  <<< "$(detect_vendor_on_node "${NODE_SERVER}")"
read -r CLI_VENDOR CLI_DEV \
  <<< "$(detect_vendor_on_node "${NODE_CLIENT}")"

if [ -z "${SRV_VENDOR}" ]; then
  echo "ERROR: No RDMA NIC on ${NODE_SERVER}"
  exit 1
fi
if [ -z "${CLI_VENDOR}" ]; then
  echo "ERROR: No RDMA NIC on ${NODE_CLIENT}"
  exit 1
fi
if [ "${SRV_VENDOR}" != "${CLI_VENDOR}" ]; then
  echo "ERROR: vendor mismatch:" \
    "${NODE_SERVER}=${SRV_VENDOR}" \
    "${NODE_CLIENT}=${CLI_VENDOR}"
  exit 1
fi

VENDOR="${SRV_VENDOR}"
echo "  Server: ${SRV_DEV} (${VENDOR})"
echo "  Client: ${CLI_DEV} (${VENDOR})"

# --- Run two-node test ---
echo ""
echo "=========================================="
echo "Running RDMA-EP two-node test"
echo "  provider=${VENDOR}"
echo "  server=${NODE_SERVER} (${SRV_DEV})"
echo "  client=${NODE_CLIENT} (${CLI_DEV})"
echo "  pingpong-size=${PP_SIZE}"
echo "  pingpong-iters=${PP_ITERS}"
echo "=========================================="
echo ""

LIB_PATH="${RDMA_CORE_LIB}:/opt/rocm/lib"

# Launch server in background
${SSH_COMMAND} "${NODE_SERVER}" \
  "sudo env LD_LIBRARY_PATH=${LIB_PATH} \
    ${TEST_BIN} \
    --server \
    --provider ${VENDOR} \
    --device ${SRV_DEV} \
    --pingpong-size ${PP_SIZE} \
    --pingpong-iters ${PP_ITERS}" \
  2>&1 | sed 's/^/[SERVER] /' &
SERVER_PID=$!

sleep 3

# Launch client
test_run \
  "rdma-ep 2node ${VENDOR}" \
  "${SSH_COMMAND} ${NODE_CLIENT} \
    \"sudo env LD_LIBRARY_PATH=${LIB_PATH} \
      ${TEST_BIN} \
      --client \
      --server-host ${NODE_SERVER} \
      --provider ${VENDOR} \
      --device ${CLI_DEV} \
      --pingpong-size ${PP_SIZE} \
      --pingpong-iters ${PP_ITERS}\""

wait ${SERVER_PID} || true

test_report
EXIT_CODE=$?

exit ${EXIT_CODE}
