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
MAX_COPY_SIZE="${MAX_COPY_SIZE:-$((1 << 20))}"
NUM_COPY_COMMANDS="${NUM_COPY_COMMANDS:-100}"
MIN_QUEUES_PER_DESTINATION="${MIN_QUEUES_PER_DESTINATION:-1}"
MAX_QUEUES_PER_DESTINATION="${MAX_QUEUES_PER_DESTINATION:-8}"
NUM_DESTINATIONS="${NUM_DESTINATIONS:-7}"
MIN_WORKGROUPS_PER_QUEUE="${MIN_WORKGROUPS_PER_QUEUE:-2}"
MAX_WORKGROUPS_PER_QUEUE="${MAX_WORKGROUPS_PER_QUEUE:-4}"
WARPS_PER_WORKGROUP="${WARPS_PER_WORKGROUP:-1}"

require_benchmark
create_output_dir "results_bandwidth_multiproducer"

echo "Running multi-producer bandwidth sweeps from ${MIN_COPY_SIZE} to " \
  "${MAX_COPY_SIZE} bytes"
for ((queues = MIN_QUEUES_PER_DESTINATION;
      queues <= MAX_QUEUES_PER_DESTINATION;
      queues *= 2)); do
  for ((workgroups = MIN_WORKGROUPS_PER_QUEUE;
        workgroups <= MAX_WORKGROUPS_PER_QUEUE;
        workgroups *= 2)); do
    result_csv="bandwidth_${NUM_DESTINATIONS}dst_${queues}queues_"\
"${workgroups}wgs_${WARPS_PER_WORKGROUP}waves_"\
"${NUM_COPY_COMMANDS}copies.csv"
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
done

print_results
