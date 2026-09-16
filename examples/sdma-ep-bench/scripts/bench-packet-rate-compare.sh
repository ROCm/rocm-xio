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
WARMUP="${WARMUP:-1}"
ITERATIONS="${ITERATIONS:-10}"
SDMA_TIMESTAMPS="${SDMA_TIMESTAMPS:-0}"
QUEUES="${QUEUES:-1 2 4 8}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${PWD}}"

if [[ ! -x "${RATE_BENCHMARK}" ]]; then
  echo "ERROR: rate benchmark executable not found: ${RATE_BENCHMARK}" >&2
  exit 1
fi

timestamp="$(date '+%Y-%m-%d_%Hh%Mm%Ss')"
output_dir="${OUTPUT_ROOT}/results_packet_rate_compare_${timestamp}"
regular_dir="${output_dir}/regular"
triggered_dir="${output_dir}/device-triggered"
copy_only_dir="${output_dir}/device-triggered-copy-only"
initiated_poll_dir="${output_dir}/device-initiated-poll"
mkdir -p "${regular_dir}" "${triggered_dir}" "${copy_only_dir}" "${initiated_poll_dir}"
regular_summary="${regular_dir}/summary.csv"
triggered_summary="${triggered_dir}/summary.csv"
copy_only_summary="${copy_only_dir}/summary.csv"
initiated_poll_summary="${initiated_poll_dir}/summary.csv"
log_file="${output_dir}/benchmark.log"
: >"${regular_summary}"
: >"${triggered_summary}"
: >"${copy_only_summary}"
: >"${initiated_poll_summary}"
: >"${log_file}"

run_variant() {
  local mode="$1"
  local destination="$2"
  local result_csv="$3"
  shift 3
  local command=("${RATE_BENCHMARK}"
    --srcGpu "${SRC_GPU}"
    --dstGpu "${DST_GPU}"
    --minCopySize "${MIN_COPY_SIZE}"
    --maxCopySize "${MAX_COPY_SIZE}"
    --numCopyCommands "${NUM_COPY_COMMANDS}"
    --numOfQueues "$1"
    --warmup "${WARMUP}"
    --iterations "${ITERATIONS}"
    --outputFile "${destination}/${result_csv}")
  shift
  if [[ "${mode}" == "device-triggered" ]]; then
    command+=(--device-triggered)
  elif [[ "${mode}" == "device-triggered-copy-only" ]]; then
    command+=(--device-triggered-copy-only)
  elif [[ "${mode}" == "device-initiated-poll" ]]; then
    command+=(--device-initiated-poll)
  fi
  if [[ "${SDMA_TIMESTAMPS}" == 1 && "${mode}" != "regular" ]]; then
    command+=(--sdma-timestamps)
  fi
  printf '[%s] Command:' "${mode}" >>"${log_file}"
  printf ' %q' "${command[@]}" >>"${log_file}"
  printf '\n' >>"${log_file}"
  "${command[@]}" >>"${log_file}" 2>&1
  if [[ ! -s "${destination}/summary.csv" ]]; then
    cat "${destination}/${result_csv}" >>"${destination}/summary.csv"
  else
    tail -n +2 "${destination}/${result_csv}" >>"${destination}/summary.csv"
  fi
}

echo "Running regular, copy-only, and full device-triggered packet-rate sweeps"
if [[ "${SDMA_TIMESTAMPS}" == 1 ]]; then
  echo "  SDMA timestamps: host-triggered modes only; regular uses GPU clock"
fi
for queues in ${QUEUES}; do
  echo "  Queues: ${queues}"
  run_variant regular "${regular_dir}" "packet_rate_${queues}queues.csv" \
    "${queues}"
  run_variant device-triggered "${triggered_dir}" \
    "packet_rate_${queues}queues.csv" "${queues}"
  run_variant device-triggered-copy-only "${copy_only_dir}" \
    "packet_rate_${queues}queues.csv" "${queues}"
  run_variant device-initiated-poll "${initiated_poll_dir}" \
    "packet_rate_${queues}queues.csv" "${queues}"
done

report="${output_dir}/packet-rate-comparison.md"
"${script_dir}/report-packet-rate.py" "${regular_summary}" \
  "${triggered_summary}" "${copy_only_summary}" "${initiated_poll_summary}" \
  --output "${report}"
cat "${report}"
echo "Results: ${output_dir}"
echo "Log:     ${log_file}"
