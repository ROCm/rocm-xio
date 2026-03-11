#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# usage: ./monitor-alola-jobs.sh [job_id1] [job_id2] [job_id3]
#
# Monitors SLURM job status. If no job IDs provided, shows all user jobs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -eq 0 ]; then
  echo "Showing all your SLURM jobs:"
  echo ""
  squeue -u "${USER}" -o "%.10i %.20j %.8T %.10M %.6D %R"
else
  echo "Monitoring job(s): $@"
  echo ""
  
  while true; do
    clear
    echo "=========================================="
    echo "Job Status - $(date)"
    echo "=========================================="
    echo ""
    
    for job_id in "$@"; do
      echo "Job ${job_id}:"
      squeue -j "${job_id}" -o "%.10i %.20j %.8T %.10M %.6D %R" 2>/dev/null || \
        echo "  Job ${job_id} not found (may have completed)"
      echo ""
    done
    
    # Check if all jobs are done
    all_done=true
    for job_id in "$@"; do
      if squeue -j "${job_id}" -h &>/dev/null; then
        all_done=false
        break
      fi
    done
    
    if [ "${all_done}" = "true" ]; then
      echo "All jobs completed!"
      break
    fi
    
    sleep 5
  done
fi
