#!/usr/bin/env bash
#
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
example_dir="$(cd "${script_dir}/.." && pwd)"

BENCHMARK="${BENCHMARK:-${example_dir}/build/sdma-ep-bw}"
SRC_GPU="${SRC_GPU:-0}"
WARMUP="${WARMUP:-3}"
ITERATIONS="${ITERATIONS:-50}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${PWD}}"

require_benchmark() {
  if [[ ! -x "${BENCHMARK}" ]]; then
    echo "ERROR: benchmark executable not found: ${BENCHMARK}" >&2
    echo "Set BENCHMARK=/path/to/sdma-ep-bw." >&2
    exit 1
  fi
}

create_output_dir() {
  local prefix="$1"
  local timestamp

  timestamp="$(date '+%Y-%m-%d_%Hh%Mm%Ss')"
  OUTPUT_DIR="${OUTPUT_ROOT}/${prefix}_${timestamp}"
  SUMMARY_FILE="${OUTPUT_DIR}/summary.csv"
  LOG_FILE="${OUTPUT_DIR}/benchmark.log"
  mkdir -p "${OUTPUT_DIR}"
  : >"${SUMMARY_FILE}"
  : >"${LOG_FILE}"
}

run_benchmark() {
  local result_csv="$1"
  shift

  echo "Command: ${BENCHMARK} $*" >>"${LOG_FILE}"
  "${BENCHMARK}" \
    --srcGpu "${SRC_GPU}" \
    --warmup "${WARMUP}" \
    --iterations "${ITERATIONS}" \
    --outputFile "${OUTPUT_DIR}/${result_csv}" \
    "$@" >>"${LOG_FILE}" 2>&1
}

append_summary() {
  local result_csv="$1"

  if [[ ! -s "${SUMMARY_FILE}" ]]; then
    cat "${OUTPUT_DIR}/${result_csv}" >>"${SUMMARY_FILE}"
  else
    tail -n +2 "${OUTPUT_DIR}/${result_csv}" >>"${SUMMARY_FILE}"
  fi
}

print_results() {
  echo "Results: ${OUTPUT_DIR}"
  echo "Summary: ${SUMMARY_FILE}"
  echo "Log:     ${LOG_FILE}"
}
