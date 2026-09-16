#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
# SPDX-License-Identifier: MIT
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
example_dir="$(cd "${script_dir}/.." && pwd)"
RATE_BENCHMARK="${RATE_BENCHMARK:-${example_dir}/build/sdma-ep-rate}"
SRC_GPU="${SRC_GPU:-0}"; DST_GPU="${DST_GPU:-1}"
NUM_COPY_COMMANDS="${NUM_COPY_COMMANDS:-1000}"
COPY_SIZE="${COPY_SIZE:-64}"; WARMUP="${WARMUP:-1}"
ITERATIONS="${ITERATIONS:-10}"; OUTPUT_ROOT="${OUTPUT_ROOT:-${PWD}}"
[[ -x "${RATE_BENCHMARK}" ]] || { echo "Missing ${RATE_BENCHMARK}" >&2; exit 1; }

timestamp="$(date '+%Y-%m-%d_%Hh%Mm%Ss')"
output_dir="${OUTPUT_ROOT}/results_packet_rate_isolated_${timestamp}"
mkdir -p "${output_dir}"
log="${output_dir}/benchmark.log"; : >"${log}"

run_mode() {
  local name="$1"; shift
  local output="${output_dir}/${name}.csv"
  local command=("${RATE_BENCHMARK}" --srcGpu "${SRC_GPU}" --dstGpu "${DST_GPU}"
    --numOfQueues 1 --minCopySize "${COPY_SIZE}" --maxCopySize "${COPY_SIZE}"
    --numCopyCommands "${NUM_COPY_COMMANDS}" --warmup "${WARMUP}"
    --iterations "${ITERATIONS}" --outputFile "${output}" "$@")
  printf '[%s] Command:' "${name}" >>"${log}"; printf ' %q' "${command[@]}" >>"${log}"; printf '\n' >>"${log}"
  "${command[@]}" >>"${log}" 2>&1
}

echo "Running isolated SDMA modes with one queue"
run_mode copy
run_mode poll-only --poll-only
run_mode atomic-local --atomic-only --atomic-memory local
run_mode atomic-remote --atomic-only --atomic-memory remote
run_mode device-initiated-poll-copy --device-initiated-poll
run_mode copy-atomic-local --copy-atomic --atomic-memory local
run_mode copy-atomic-remote --copy-atomic --atomic-memory remote
run_mode poll-copy-atomic-local --device-initiated-poll --copy-atomic --atomic-memory local
run_mode poll-copy-atomic-remote --device-initiated-poll --copy-atomic --atomic-memory remote

"${script_dir}/report-isolated-rate.py" \
  -o "${output_dir}/isolated-rate.md" \
  "${output_dir}/copy.csv" "${output_dir}/poll-only.csv" \
  "${output_dir}/atomic-local.csv" "${output_dir}/atomic-remote.csv" \
  "${output_dir}/device-initiated-poll-copy.csv" \
  "${output_dir}/copy-atomic-local.csv" \
  "${output_dir}/copy-atomic-remote.csv" \
  "${output_dir}/poll-copy-atomic-local.csv" \
  "${output_dir}/poll-copy-atomic-remote.csv"
echo "Results: ${output_dir}"
