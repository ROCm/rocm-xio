#!/usr/bin/env bash
#
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=benchmark-common.sh
source "${script_dir}/benchmark-common.sh"

MIN_COPY_SIZE="${MIN_COPY_SIZE:-$((1 << 10))}"
MAX_COPY_SIZE="${MAX_COPY_SIZE:-$((1 << 22))}"
NUM_COPY_COMMANDS="${NUM_COPY_COMMANDS:-100}"
MIN_QUEUES_PER_DESTINATION="${MIN_QUEUES_PER_DESTINATION:-1}"
MAX_QUEUES_PER_DESTINATION="${MAX_QUEUES_PER_DESTINATION:-8}"
NUM_DESTINATIONS="${NUM_DESTINATIONS:-1}"
TOTAL_WORKGROUPS="${TOTAL_WORKGROUPS:-304}"
WARPS_PER_WORKGROUP="${WARPS_PER_WORKGROUP:-1}"

require_benchmark
create_output_dir "results_contention_multiqueue"

echo "Running multi-queue contention sweeps from ${MIN_COPY_SIZE} to " \
  "${MAX_COPY_SIZE} bytes"
for ((queues = MIN_QUEUES_PER_DESTINATION;
      queues <= MAX_QUEUES_PER_DESTINATION;
      queues *= 2)); do
  if ((TOTAL_WORKGROUPS % queues != 0)); then
    echo "ERROR: TOTAL_WORKGROUPS must be divisible by queue count ${queues}" \
      >&2
    exit 1
  fi
  workgroups=$((TOTAL_WORKGROUPS / queues))
  result_csv="contention_${queues}queues_${workgroups}wgs_"\
"${WARPS_PER_WORKGROUP}waves_${NUM_COPY_COMMANDS}copies.csv"
  echo "  Queues/destination: ${queues}; workgroups/queue: ${workgroups}"
  run_benchmark "${result_csv}" \
    --minCopySize "${MIN_COPY_SIZE}" \
    --maxCopySize "${MAX_COPY_SIZE}" \
    --numCopyCommands "${NUM_COPY_COMMANDS}" \
    --numOfQueuesPerDestination "${queues}" \
    --numDestinations "${NUM_DESTINATIONS}" \
    --wgsPerQueue "${workgroups}" \
    --warpsPerWG "${WARPS_PER_WORKGROUP}"
  append_summary "${result_csv}"
done

print_results
