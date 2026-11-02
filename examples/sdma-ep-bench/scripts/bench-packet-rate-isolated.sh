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
summary="${output_dir}/summary.tsv"
summary_markdown="${output_dir}/summary.md"
printf 'Mode\tMPPS\tTime [ns/command]\tDevice latency [us]\n' >"${summary}"
{
  printf '| Mode | MPPS | Time [ns/command] | Device latency [us] |\n'
  printf '| --- | ---: | ---: | ---: |\n'
} >"${summary_markdown}"

run_mode() {
  local name="$1"; shift
  local output="${output_dir}/${name}.csv"
  local command=("${RATE_BENCHMARK}" --srcGpu "${SRC_GPU}" --dstGpu "${DST_GPU}"
    --numOfQueues 1 --minCopySize "${COPY_SIZE}" --maxCopySize "${COPY_SIZE}"
    --numCommands "${NUM_COPY_COMMANDS}" --warmup "${WARMUP}"
    --iterations "${ITERATIONS}" --outputFile "${output}" "$@")
  echo "  Mode: ${name}"
  printf '[%s] Command:' "${name}" >>"${log}"; printf ' %q' "${command[@]}" >>"${log}"; printf '\n' >>"${log}"
  "${command[@]}" >>"${log}" 2>&1
  local label="${name}"
  case "${name}" in
    poll-only) label="poll" ;;
    poll-copy) label="poll+copy" ;;
    copy-atomic-local) label="copy+atomic local" ;;
    copy-atomic-remote) label="copy+atomic remote" ;;
    poll-copy-atomic-local) label="poll+copy+atomic local" ;;
    poll-copy-atomic-remote) label="poll+copy+atomic remote" ;;
    fused-copy) label="fused copy" ;;
    fused-poll-copy) label="fused poll+copy" ;;
    fused-copy-atomic-local) label="fused copy+atomic local" ;;
    fused-copy-atomic-remote) label="fused copy+atomic remote" ;;
    fused-poll-copy-atomic-local) label="fused poll+copy+atomic local" ;;
    fused-poll-copy-atomic-remote) label="fused poll+copy+atomic remote" ;;
  esac
  awk -F, -v label="${label}" -v tsv="${summary}" \
    -v markdown="${summary_markdown}" \
    'NR == 2 {
       printf "%s\t%.3f\t%.1f\t%.3f\n", label, $13, $16, $9 >> tsv
       printf "| %s | %.3f | %.1f | %.3f |\n", label, $13, $16, $9 >> markdown
     }' "${output}"
}

echo "Running isolated SDMA modes with one queue"
run_mode copy --mode copy
run_mode poll-only --mode poll-only
run_mode atomic-local --mode atomic-only --atomic-memory local
run_mode atomic-remote --mode atomic-only --atomic-memory remote
run_mode poll-copy --mode poll-copy
run_mode copy-atomic-local --mode copy-atomic --atomic-memory local
run_mode copy-atomic-remote --mode copy-atomic --atomic-memory remote
run_mode poll-copy-atomic-local --mode poll-copy-atomic --atomic-memory local
run_mode poll-copy-atomic-remote --mode poll-copy-atomic --atomic-memory remote

# FUSED=1 also runs each mode that has a copy as one OSS7 COPY_LINEAR_WAIT_SIGNAL packet per
# command. It needs a build with -DXIO_SDMA_OSS7=ON, on a GPU whose SDMA understands it.
if [[ "${FUSED:-0}" == "1" ]]; then
  echo "Running OSS7 fused commands with one queue"
  run_mode fused-copy --mode copy --fused
  run_mode fused-poll-copy --mode poll-copy --fused
  run_mode fused-copy-atomic-local --mode copy-atomic --atomic-memory local --fused
  run_mode fused-copy-atomic-remote --mode copy-atomic --atomic-memory remote --fused
  run_mode fused-poll-copy-atomic-local --mode poll-copy-atomic --atomic-memory local --fused
  run_mode fused-poll-copy-atomic-remote --mode poll-copy-atomic --atomic-memory remote --fused
fi

echo "Results: ${output_dir}"
echo "Summary: ${summary}"
echo "Markdown: ${summary_markdown}"
