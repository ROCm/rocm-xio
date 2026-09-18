#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
# SPDX-License-Identifier: MIT
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
example_dir="$(cd "${script_dir}/.." && pwd)"
LATENCY_BENCHMARK="${LATENCY_BENCHMARK:-${example_dir}/build/sdma-ep-latency}"
SRC_GPU="${SRC_GPU:-0}"; DST_GPU="${DST_GPU:-1}"
MIN_COPY_SIZE="${MIN_COPY_SIZE:-256}"; MAX_COPY_SIZE="${MAX_COPY_SIZE:-1048576}"
NUM_COPY_COMMANDS="${NUM_COPY_COMMANDS:-1}"; WARMUP="${WARMUP:-3}"
ITERATIONS="${ITERATIONS:-100}"; FINE_GRAINED="${FINE_GRAINED:-0}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${PWD}}"
[[ -x "${LATENCY_BENCHMARK}" ]] || { echo "Missing ${LATENCY_BENCHMARK}" >&2; exit 1; }
timestamp="$(date '+%Y-%m-%d_%Hh%Mm%Ss')"
output_dir="${OUTPUT_ROOT}/results_latency_${timestamp}"
mkdir -p "${output_dir}"
summary="${output_dir}/summary.csv"
: >"${output_dir}/benchmark.log"
for ((size = MIN_COPY_SIZE; size <= MAX_COPY_SIZE; size *= 2)); do
  result="${output_dir}/latency_${size}.csv"
  command=("${LATENCY_BENCHMARK}" --srcGpu "${SRC_GPU}" --dstGpu "${DST_GPU}"
    --minCopySize "${size}" --maxCopySize "${size}"
    --numCopyCommands "${NUM_COPY_COMMANDS}" --warmup "${WARMUP}"
    --iterations "${ITERATIONS}" --outputFile "${result}")
  [[ "${FINE_GRAINED}" == 1 ]] && command+=(--fine-grained)
  printf 'Command:' >>"${output_dir}/benchmark.log"
  printf ' %q' "${command[@]}" >>"${output_dir}/benchmark.log"
  printf '\n' >>"${output_dir}/benchmark.log"
  "${command[@]}" >>"${output_dir}/benchmark.log" 2>&1
  if [[ ! -s "${summary}" ]]; then
    cat "${result}" >>"${summary}"
  else
    tail -n +2 "${result}" >>"${summary}"
  fi
done
echo "Results: ${output_dir}"
