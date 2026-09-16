#!/usr/bin/env bash
#
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
example_dir="$(cd "${script_dir}/.." && pwd)"

RATE_BENCHMARK="${RATE_BENCHMARK:-${example_dir}/build/sdma-ep-rate}"
SRC_GPU="${SRC_GPU:-0}"
DST_GPU="${DST_GPU:-1}"
MIN_COPY_SIZE="${MIN_COPY_SIZE:-64}"
MAX_COPY_SIZE="${MAX_COPY_SIZE:-64}"
NUM_COPY_COMMANDS="${NUM_COPY_COMMANDS:-10000}"
MIN_QUEUES="${MIN_QUEUES:-1}"
MAX_QUEUES="${MAX_QUEUES:-8}"
WARMUP="${WARMUP:-1}"
ITERATIONS="${ITERATIONS:-10}"
DEVICE_TRIGGERED="${DEVICE_TRIGGERED:-0}"
DEVICE_TRIGGERED_COPY_ONLY="${DEVICE_TRIGGERED_COPY_ONLY:-0}"
SDMA_TIMESTAMPS="${SDMA_TIMESTAMPS:-0}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${PWD}}"

if [[ ! -x "${RATE_BENCHMARK}" ]]; then
  echo "ERROR: rate benchmark executable not found: ${RATE_BENCHMARK}" >&2
  echo "Set RATE_BENCHMARK=/path/to/sdma-ep-rate." >&2
  exit 1
fi

timestamp="$(date '+%Y-%m-%d_%Hh%Mm%Ss')"
output_dir="${OUTPUT_ROOT}/results_packet_rate_${timestamp}"
summary_file="${output_dir}/summary.csv"
log_file="${output_dir}/benchmark.log"
mkdir -p "${output_dir}"
: >"${summary_file}"
: >"${log_file}"

echo "Running packet-rate sweep with ${NUM_COPY_COMMANDS} copy commands"
for ((queues = MIN_QUEUES; queues <= MAX_QUEUES; ++queues)); do
  result_csv="packet_rate_${queues}queues.csv"
  command=("${RATE_BENCHMARK}"
    --srcGpu "${SRC_GPU}"
    --dstGpu "${DST_GPU}"
    --minCopySize "${MIN_COPY_SIZE}"
    --maxCopySize "${MAX_COPY_SIZE}"
    --numCopyCommands "${NUM_COPY_COMMANDS}"
    --numOfQueues "${queues}"
    --warmup "${WARMUP}"
    --iterations "${ITERATIONS}"
    --outputFile "${output_dir}/${result_csv}")
  if [[ "${DEVICE_TRIGGERED}" == 1 ]]; then
    command+=(--device-triggered)
  fi
  if [[ "${DEVICE_TRIGGERED_COPY_ONLY}" == 1 ]]; then
    command+=(--device-triggered-copy-only)
  fi
  if [[ "${SDMA_TIMESTAMPS}" == 1 ]]; then
    command+=(--sdma-timestamps)
  fi
  printf 'Command:' >>"${log_file}"
  printf ' %q' "${command[@]}" >>"${log_file}"
  printf '\n' >>"${log_file}"
  echo "  Queues: ${queues}"
  "${command[@]}" >>"${log_file}" 2>&1

  if [[ ! -s "${summary_file}" ]]; then
    cat "${output_dir}/${result_csv}" >>"${summary_file}"
  else
    tail -n +2 "${output_dir}/${result_csv}" >>"${summary_file}"
  fi
done

echo "Results: ${output_dir}"
echo "Summary: ${summary_file}"
echo "Log:     ${log_file}"
