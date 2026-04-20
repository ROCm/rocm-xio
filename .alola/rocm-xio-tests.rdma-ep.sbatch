#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# usage: sbatch rocm-xio-tests.rdma-ep.sbatch
#
# RDMA-EP test suite.  Allocates 2 IB nodes, builds
# with all GDA vendors, auto-detects which NIC is
# present on each node, then runs:
#
#   Phase 1 -- loopback tests on both nodes
#   Phase 2 -- two-node client-server ping-pong
#
# Host access via SSH is required for kernel modules
# and RDMA devices.
#
# To check compatible nodes:
#   sinfo -Na -o "%N %100f" | grep IB
#
#SBATCH --output=logs/%x.%j.out
#SBATCH --error=logs/%x.%j.err
#SBATCH --cpus-per-task=4
#SBATCH --container-image=/cluster/images/rocm-xio/rocm-xio-alola.sqsh
#SBATCH --container-mount-home
#SBATCH --constraint=MARKHAM&IB
#SBATCH --nodes=2
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
PP_SIZE="${PP_SIZE:-64}"
PP_ITERS="${PP_ITERS:-100}"

# --- Parse node list ---
mapfile -t NODES < <(expand_nodelist "${SLURM_JOB_NODELIST}")
if [ ${#NODES[@]} -lt 2 ]; then
  echo "ERROR: Need 2 nodes, got ${#NODES[@]}"
  exit 1
fi
NODE_A="${NODES[0]}"
NODE_B="${NODES[1]}"

cleanup() {
  echo "Cleaning up..."
  for node in "${NODE_A}" "${NODE_B}"; do
    ${SSH_COMMAND} "${node}" \
      "rm -rf ${WORKING_DIR}" \
      2>/dev/null || true
  done
  rm -rf "${WORKING_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

# Initialize test tracking
test_init

# Display job information
display_job_info

echo "=========================================="
echo "RDMA-EP Test Suite"
echo "=========================================="
echo "  Node A: ${NODE_A}"
echo "  Node B: ${NODE_B}"
echo ""

cd "${PROJECT_DIR}"
detect_gpu_arch

# --- Build phase (inside container) ---
WORKING_DIR="/tmp/rocm-xio-tests.rdma-ep.$RANDOM"
rdma_alola_build "${WORKING_DIR}" "test-rdma-loopback"
LOOPBACK_BIN="${TEST_BIN}"
SETUP_SCRIPT="${WORKING_DIR}/scripts/test"
SETUP_SCRIPT="${SETUP_SCRIPT}/setup-rdma-loopback.sh"

cmake --build build \
  --target test-rdma-2node \
  --parallel
TWONODE_BIN="${WORKING_DIR}/build/tests/unit"
TWONODE_BIN="${TWONODE_BIN}/rdma-ep/test-rdma-2node"

# Run CPU-only RDMA unit tests inside the container
# (no NIC, GPU, or host access needed).
test_run "ctest rdma-ep unit tests" \
  "ctest --test-dir build -L rdma -LE hardware"

# --- Copy artifacts to both nodes ---
echo ""
echo "Copying test artifacts to nodes..."
for node in "${NODE_A}" "${NODE_B}"; do
  ${SSH_COMMAND} "${node}" \
    "mkdir -p ${WORKING_DIR}/build/tests/unit/rdma-ep"
  ${SSH_COMMAND} "${node}" \
    "mkdir -p ${WORKING_DIR}/scripts/test"
  ${SCP_COMMAND} "${LOOPBACK_BIN}" \
    "${node}:${LOOPBACK_BIN}"
  ${SCP_COMMAND} "${TWONODE_BIN}" \
    "${node}:${TWONODE_BIN}"
  ${SCP_COMMAND} "${SETUP_SCRIPT}" \
    "${node}:${SETUP_SCRIPT}"
  ${SSH_COMMAND} "${node}" \
    "mkdir -p ${WORKING_DIR}/build/_deps/rdma-core"
  ${SCP_COMMAND} -r \
    "${WORKING_DIR}/build/_deps/rdma-core/install" \
    "${node}:${WORKING_DIR}/build/_deps/rdma-core/"
done

LIB_PATH="${RDMA_CORE_LIB}:${ROCM_NFS}/lib"

# ---------------------------------------------------------
# detect_vendors_on_node NODE
#
# Detect all RDMA vendors on NODE.  Prints space-
# separated vendor names on stdout (e.g. "mlx5 bnxt").
# Sets ${VENDOR}_DEV_${suffix} and ${VENDOR}_BDF_${suffix}
# variables where suffix is the sanitised node name.
# ---------------------------------------------------------
resolve_ib_bdf() {
  local node="$1"
  local ib_dev="$2"
  ${SSH_COMMAND} "${node}" \
    "readlink -f /sys/class/infiniband/${ib_dev}/device \
    | xargs basename" 2>/dev/null || echo "unknown"
}

detect_vendors_on_node() {
  local node="$1"
  local suffix
  suffix=$(echo "${node}" | tr '-' '_')
  DETECTED_VENDORS=""
  for _v in bnxt mlx5 ionic; do
    local _dev
    _dev=$(detect_rdma_nic "${SSH_COMMAND}" \
      "${node}" "${_v}")
    if [ -n "${_dev}" ]; then
      local _bdf
      _bdf=$(resolve_ib_bdf "${node}" "${_dev}")
      eval "${_v^^}_DEV_${suffix}=\${_dev}"
      eval "${_v^^}_BDF_${suffix}=\${_bdf}"
      DETECTED_VENDORS="${DETECTED_VENDORS} ${_v}"
      echo "  Found ${_v^^}: ${_dev}" \
        "(PCI ${_bdf})"
    fi
  done
}

# ---------------------------------------------------------
# run_loopback_on_node NODE VENDORS
#
# Run loopback tests for each vendor on the given node.
# ---------------------------------------------------------
run_loopback_on_node() {
  local node="$1"
  local vendors="$2"
  local suffix
  suffix=$(echo "${node}" | tr '-' '_')

  echo ""
  echo "Running RDMA hardware setup on ${node}..."
  ${SSH_COMMAND} "${node}" \
    "sudo VENDOR=all ${SETUP_SCRIPT}" || true

  for vendor in ${vendors}; do
    local dev="" bdf=""
    eval "dev=\${${vendor^^}_DEV_${suffix}}"
    eval "bdf=\${${vendor^^}_BDF_${suffix}}"

    echo ""
    echo "--- ${vendor^^} loopback on ${node} ---"
    echo "  device=${dev}"
    echo "  PCI BDF=${bdf}"
    echo "  size=${LOOPBACK_SIZE}"
    echo "  iterations=${LOOPBACK_ITERS}"
    echo ""

    for seed in ${LOOPBACK_SEEDS}; do
      test_run \
        "rdma-ep loopback ${vendor} ${node} seed=${seed}" \
        "${SSH_COMMAND} ${node} \
          \"sudo env LD_LIBRARY_PATH=${LIB_PATH} \
            HSA_FORCE_FINE_GRAIN_PCIE=1 \
            ${LOOPBACK_BIN} \
            --provider ${vendor} \
            --device ${dev} \
            --size ${LOOPBACK_SIZE} \
            --seed ${seed} \
            -n ${LOOPBACK_ITERS}\""
      sleep 1
    done
  done
}

# =========================================================
# Phase 1 -- Loopback tests on both nodes
# =========================================================
echo ""
echo "=========================================="
echo "Phase 1: RDMA-EP Loopback Tests"
echo "=========================================="

echo ""
echo "Detecting RDMA NICs on ${NODE_A}..."
detect_vendors_on_node "${NODE_A}"
VENDORS_A="${DETECTED_VENDORS}"
if [ -z "${VENDORS_A}" ]; then
  echo "ERROR: No RDMA NICs detected on ${NODE_A}."
  exit 1
fi
echo "  Detected vendors:${VENDORS_A}"

echo ""
echo "Detecting RDMA NICs on ${NODE_B}..."
detect_vendors_on_node "${NODE_B}"
VENDORS_B="${DETECTED_VENDORS}"
if [ -z "${VENDORS_B}" ]; then
  echo "ERROR: No RDMA NICs detected on ${NODE_B}."
  exit 1
fi
echo "  Detected vendors:${VENDORS_B}"

run_loopback_on_node "${NODE_A}" "${VENDORS_A}"
run_loopback_on_node "${NODE_B}" "${VENDORS_B}"

# Run CTest RDMA hardware suite on NODE_A.  The RDMA_HW
# fixture setup was already done by run_loopback_on_node;
# ctest -E excludes the fixture test so it doesn't re-run.
test_run "ctest rdma-ep hardware tests (${NODE_A})" \
  "${SSH_COMMAND} ${NODE_A} \
    \"cd ${WORKING_DIR} && \
    sudo env LD_LIBRARY_PATH=${LIB_PATH} \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    ctest --test-dir build -L hardware -L rdma \
    -E rdma-hw-setup \
    --output-on-failure --timeout 300\""

# =========================================================
# Phase 2 -- Two-node client-server test
# =========================================================
echo ""
echo "=========================================="
echo "Phase 2: RDMA-EP Two-Node Test"
echo "=========================================="

# Use the first vendor detected on each node and
# verify they match.
detect_first_vendor() {
  local node="$1"
  for _v in mlx5 bnxt ionic; do
    local _dev
    _dev=$(detect_rdma_nic "${SSH_COMMAND}" \
      "${node}" "${_v}")
    if [ -n "${_dev}" ]; then
      echo "${_v} ${_dev}"
      return
    fi
  done
}

read -r SRV_VENDOR SRV_DEV \
  <<< "$(detect_first_vendor "${NODE_A}")"
read -r CLI_VENDOR CLI_DEV \
  <<< "$(detect_first_vendor "${NODE_B}")"

if [ -z "${SRV_VENDOR}" ]; then
  echo "ERROR: No RDMA NIC on ${NODE_A}"
  exit 1
fi
if [ -z "${CLI_VENDOR}" ]; then
  echo "ERROR: No RDMA NIC on ${NODE_B}"
  exit 1
fi
if [ "${SRV_VENDOR}" != "${CLI_VENDOR}" ]; then
  echo "ERROR: vendor mismatch:" \
    "${NODE_A}=${SRV_VENDOR}" \
    "${NODE_B}=${CLI_VENDOR}"
  exit 1
fi

VENDOR="${SRV_VENDOR}"
echo "  provider=${VENDOR}"
echo "  server=${NODE_A} (${SRV_DEV})"
echo "  client=${NODE_B} (${CLI_DEV})"
echo "  pingpong-size=${PP_SIZE}"
echo "  pingpong-iters=${PP_ITERS}"
echo ""

# Launch server in background with a timeout so it
# cannot hang if the client never connects.  Process
# substitution ensures $! is the SSH PID, not sed.
SERVER_TIMEOUT=$((PP_ITERS * 2 + 60))
${SSH_COMMAND} "${NODE_A}" \
  "sudo timeout ${SERVER_TIMEOUT} \
    env LD_LIBRARY_PATH=${LIB_PATH} \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    ${TWONODE_BIN} \
    --server \
    --provider ${VENDOR} \
    --device ${SRV_DEV} \
    --pingpong-size ${PP_SIZE} \
    --pingpong-iters ${PP_ITERS}" \
  > >(sed 's/^/[SERVER] /') 2>&1 &
SERVER_PID=$!

sleep 3

# Launch client
test_run \
  "rdma-ep 2node ${VENDOR}" \
  "${SSH_COMMAND} ${NODE_B} \
    \"sudo env LD_LIBRARY_PATH=${LIB_PATH} \
      HSA_FORCE_FINE_GRAIN_PCIE=1 \
      ${TWONODE_BIN} \
      --client \
      --server-host ${NODE_A} \
      --provider ${VENDOR} \
      --device ${CLI_DEV} \
      --pingpong-size ${PP_SIZE} \
      --pingpong-iters ${PP_ITERS}\""

wait ${SERVER_PID}
SERVER_RC=$?
if [ ${SERVER_RC} -ne 0 ]; then
  echo "WARN: server exited with rc=${SERVER_RC}"
fi

# Report results and exit with appropriate code
test_report
EXIT_CODE=$?

exit ${EXIT_CODE}
