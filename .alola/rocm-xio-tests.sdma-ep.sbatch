#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# usage: sbatch rocm-xio-tests.sdma-ep.sbatch
#
# SDMA endpoint tests on a two-GPU node.  Exercises sdma-ep
# transfers that benefit from a multi-GPU allocation:
#
#   1. GPU-to-GPU P2P (GPU 0 -> GPU 1) with XGMI metric capture
#      (amd-smi xgmi -m -g all --json) before and after each test
#      to compare expected transfer size with counter deltas.
#   2. GPU-to-host (--to-host) DMA with LFSR verification.
#
#SBATCH --output=logs/%x.%j.out
#SBATCH --error=logs/%x.%j.err
#SBATCH --cpus-per-task=4
#SBATCH --container-image=/cluster/images/rocm-xio/rocm-xio-alola.sqsh
#SBATCH --container-mount-home
#SBATCH --constraint=MARKHAM&(GFX942|GFX950)
#SBATCH --gres=gpu:2

set -xe

if [ -n "${SLURM_SUBMIT_DIR}" ]; then
  . "${SLURM_SUBMIT_DIR}/rocm-xio-tests.common"
else
  . "$(dirname "${BASH_SOURCE[0]}")/rocm-xio-tests.common"
fi

# Use timestamped logs directory if provided
LOGS_DIR="${ALOLA_LOGS_DIR:-logs}"
mkdir -p "${LOGS_DIR}" 2>/dev/null || true

# Initialize test tracking
test_init

ITERATIONS="${ITERATIONS:-128}"
TRANSFER_SIZE="${TRANSFER_SIZE:-1048576}"

# Display job information
display_job_info

cd "${PROJECT_DIR}"
detect_gpu_arch
if ! $sdma_ep_allowed; then
  echo "ERROR: ${ROCM_GPU_ARCH} not in SDMA whitelist (${SDMA_EP_GFX_WHITELIST})."
  exit 1
fi
setup_and_build_workdir "sdma-ep"

run_p2p_test() {
  local n=$1
  local size_bytes=$2
  local label=$3
  local expected=$((n * size_bytes))
  local xgmi_before="${WORKING_DIR}/xgmi_before_${label}.json"
  local xgmi_after="${WORKING_DIR}/xgmi_after_${label}.json"

  echo "===== P2P test: -n ${n} -s ${size_bytes} (expected ${expected} bytes) ====="
  echo "Capturing XGMI metrics (before)..."
  amd-smi xgmi -m -g all --json > "${xgmi_before}" 2>/dev/null || true

  echo "Running sdma-ep P2P (GPU 0 -> GPU 1)..."
  p2p_rc=0
  ./build/xio-tester sdma-ep p2p -n "${n}" -s "${size_bytes}" --verify -v || p2p_rc=$?

  echo "Capturing XGMI metrics (after)..."
  amd-smi xgmi -m -g all --json > "${xgmi_after}" 2>/dev/null || true
  if [ "${p2p_rc}" -ne 0 ]; then
    echo "WARN: P2P test exited with ${p2p_rc}; XGMI delta below may be zero or partial."
  fi

  echo "Expected transfer size: ${expected} bytes"
  echo "XGMI before: ${xgmi_before}"
  echo "XGMI after:  ${xgmi_after}"

  # Best-effort XGMI delta check (amd-smi JSON schema varies by version)
  if command -v jq >/dev/null 2>&1 && [ -s "${xgmi_before}" ] && [ -s "${xgmi_after}" ]; then
    # Sum read+write in KB. Match amd-smi shape: {"value": N, "unit": "KB"}
    sum_xgmi_kb() {
      local f=$1
      jq -r '
        ([.. | select(type == "object" and has("value") and (.unit == "KB"))
          | .value] | add) // 0
      ' "$f" 2>/dev/null || echo "0"
    }
    before_kb=$(sum_xgmi_kb "${xgmi_before}")
    after_kb=$(sum_xgmi_kb "${xgmi_after}")
    if [ -n "${before_kb}" ] && [ -n "${after_kb}" ]; then
      delta_kb=$((after_kb - before_kb))
      delta_bytes=$((delta_kb * 1024))
      if [ "${delta_kb}" -gt 0 ] 2>/dev/null; then
        if [ "${delta_bytes}" -ge "${expected}" ] 2>/dev/null; then
          echo "XGMI delta: ${delta_bytes} bytes (>= expected ${expected}): OK"
        else
          echo "XGMI delta: ${delta_bytes} bytes vs expected ${expected}: warn (may be multi-link or partial)"
        fi
      else
        echo "XGMI counters did not change; rely on LFSR verification and timing (see README)."
      fi
    else
      echo "Could not parse XGMI JSON (schema may differ); inspect files manually."
    fi
  else
    if ! command -v jq >/dev/null 2>&1; then
      echo "jq not found; inspect JSON files manually for read/write deltas."
    fi
    echo "Note: XGMI counters may not increment for SDMA on some systems; see README."
  fi

  # Save JSONs under the logs tree for inspection (unique per array task)
  if [[ "${LOGS_DIR}" = /* ]]; then
    local xgmi_dest="${LOGS_DIR}/xgmi-captures"
  else
    local xgmi_dest="${PROJECT_DIR}/.alola/${LOGS_DIR}/xgmi-captures"
  fi
  if mkdir -p "${xgmi_dest}" 2>/dev/null; then
    if [ -n "${SLURM_ARRAY_TASK_ID}" ]; then
      array_suffix="_${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
    else
      array_suffix="_${SLURM_JOB_ID:-$$}"
    fi
    cp -f "${xgmi_before}" \
      "${xgmi_dest}/xgmi_before_${label}${array_suffix}.json" \
      2>/dev/null || true
    cp -f "${xgmi_after}" \
      "${xgmi_dest}/xgmi_after_${label}${array_suffix}.json" \
      2>/dev/null || true
  else
    echo "WARN: cannot create '${xgmi_dest}';" \
      "XGMI captures will not be archived"
  fi
  return "${p2p_rc}"
}

label="p2p_n${ITERATIONS}_s${TRANSFER_SIZE}"

test_run "sdma-ep P2P (GPU 0 -> GPU 1)" \
  "run_p2p_test ${ITERATIONS} ${TRANSFER_SIZE} ${label}"

test_run "sdma-ep p2p --to-host" \
  "./build/xio-tester sdma-ep p2p --to-host --verify -n ${ITERATIONS}"

test_run "example sdma-ep-p2p (install + run)" \
  "build_and_run_example sdma-ep-p2p run"

if command -v mpirun >/dev/null 2>&1; then
  test_run "example sdma-ep-allgather (install + run)" \
    "build_and_run_example sdma-ep-allgather && \
     mpirun --allow-run-as-root --oversubscribe -np 2 \
       ${WORKING_DIR}/_ex_sdma-ep-allgather/sdma-ep-allgather"
else
  echo "INFO: mpirun not found; skipping" \
    "sdma-ep-allgather example."
fi

cd "$HOME"
rm -rf "${WORKING_DIR}"

# Report results and exit with appropriate code
test_report
FINAL_EXIT_CODE=$?

exit ${FINAL_EXIT_CODE}
