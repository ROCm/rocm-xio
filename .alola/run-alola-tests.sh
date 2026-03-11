#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# usage: ./run-alola-tests.sh [--submit] [--wait|--no-wait] [--verbose]
#
# Shows summary for existing test jobs. Use --submit to submit new jobs.
# Options:
#   --submit    Submit new test jobs (required for new submissions)
#   --wait      Wait for all jobs to complete before showing summary
#   --no-wait   Submit jobs and exit immediately (only with --submit)
#   --verbose   Show detailed test summary and test details (default: brief)
#   --help      Show this help message

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Color definitions (only use if output is a TTY)
if [ -t 1 ]; then
  COLOR_GREEN='\033[0;32m'
  COLOR_RED='\033[0;31m'
  COLOR_YELLOW='\033[0;33m'
  COLOR_RESET='\033[0m'
else
  COLOR_GREEN=''
  COLOR_RED=''
  COLOR_YELLOW=''
  COLOR_RESET=''
fi

JOB_IDS_FILE="${SCRIPT_DIR}/.alola-job-ids"

# Trap SIGINT to handle Ctrl+C gracefully
trap 'echo ""; \
  if [ -f "${JOB_IDS_FILE}" ]; then \
    echo "Interrupted. Jobs continue running in SLURM."; \
    echo "Run without --submit later to check status."; \
  else \
    echo "Interrupted before job submission."; \
  fi; \
  exit 130' INT

WAIT_FOR_COMPLETION=false
SUBMIT=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --submit)
      SUBMIT=true
      shift
      ;;
    --wait)
      WAIT_FOR_COMPLETION=true
      shift
      ;;
    --no-wait)
      WAIT_FOR_COMPLETION=false
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --help)
      echo "Usage: $0 [--submit] [--wait|--no-wait] [--verbose]"
      echo ""
      echo "Shows summary for existing test jobs. Use --submit to submit new jobs."
      echo ""
      echo "Options:"
      echo "  --submit    Submit new test jobs (required for new submissions)"
      echo "  --wait      Wait for all jobs to complete before showing summary"
      echo "  --no-wait   Submit jobs and exit immediately (only with --submit)"
      echo "  --verbose   Show detailed test summary and test details (default: brief)"
      echo "  --help      Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Test script names
TESTS=(
  "single-gpu:rocm-xio-tests.single-gpu.sbatch"
  "two-gpu:rocm-xio-tests.two-gpu.sbatch"
  "nvme-ep:rocm-xio-tests.nvme-ep.sbatch"
)

declare -A JOB_IDS
declare -A TEST_STATUS
declare -A OUTPUT_FILES
declare -A ERROR_FILES

# Check if --submit was specified and if job IDs file exists
if [ "${SUBMIT}" = "true" ] && [ -f "${JOB_IDS_FILE}" ]; then
  echo -e "${COLOR_RED}ERROR:${COLOR_RESET} Job IDs file already exists: ${JOB_IDS_FILE}"
  echo ""
  echo "This file contains job IDs from a previous test submission."
  echo "To submit new tests, you must first remove this file:"
  echo "  rm ${JOB_IDS_FILE}"
  echo ""
  echo "Alternatively, run without --submit to check status of existing jobs."
  exit 1
fi

# If --submit not specified and no job IDs file exists, exit with error
if [ "${SUBMIT}" = "false" ] && [ ! -f "${JOB_IDS_FILE}" ]; then
  echo -e "${COLOR_RED}ERROR:${COLOR_RESET} No existing job IDs file found: ${JOB_IDS_FILE}"
  echo ""
  echo "To submit new test jobs, use the --submit flag:"
  echo "  $0 --submit"
  echo ""
  echo "To wait for completion after submission:"
  echo "  $0 --submit --wait"
  echo ""
  echo "Use --help for more information."
  exit 1
fi

# Submit jobs
if [ "${SUBMIT}" = "true" ]; then
  echo "=========================================="
  echo "Submitting test jobs"
  echo "=========================================="
  echo ""
  
  # Create timestamped logs directory
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  LOGS_DIR="logs/${TIMESTAMP}"
  mkdir -p "${LOGS_DIR}"
  echo "Logs directory: ${LOGS_DIR}"
  echo ""
  
  for test_entry in "${TESTS[@]}"; do
    IFS=':' read -r test_name test_script <<< "${test_entry}"
    
    if [ ! -f "${test_script}" ]; then
      echo "ERROR: Test script not found: ${test_script}"
      continue
    fi
    
    echo -e "${COLOR_YELLOW}Submitting ${test_name}...${COLOR_RESET}"
    
    # Override output/error paths to use timestamp directory
    # All scripts now use %x.%j.out format (no array jobs)
    output_path="${LOGS_DIR}/%x.%j.out"
    error_path="${LOGS_DIR}/%x.%j.err"
    
    job_output=$(sbatch --export=ALL,ALOLA_LOGS_DIR="${LOGS_DIR}" \
      --job-name="${test_script%.sbatch}" \
      --output="${output_path}" \
      --error="${error_path}" \
      "${test_script}" 2>&1)
    
    if [ $? -eq 0 ]; then
      # Extract job ID from output (format: "Submitted batch job 12345")
      job_id=$(echo "${job_output}" | grep -oE '[0-9]+' | head -1)
      JOB_IDS["${test_name}"]="${job_id}"
      echo -e "  ${COLOR_YELLOW}Job ID:${COLOR_RESET} ${job_id}"
      
      # Set output file paths (will be in timestamp directory)
      # All scripts use same format: %x.%j.out
      OUTPUT_FILES["${test_name}"]="${LOGS_DIR}/${test_script%.sbatch}.${job_id}.out"
      ERROR_FILES["${test_name}"]="${LOGS_DIR}/${test_script%.sbatch}.${job_id}.err"
    else
      echo -e "  ${COLOR_RED}ERROR:${COLOR_RESET} Failed to submit job"
      TEST_STATUS["${test_name}"]="SUBMIT_FAILED"
    fi
  done
  
  echo ""
  echo "All jobs submitted. Job IDs:"
  for test_name in "${!JOB_IDS[@]}"; do
    echo "  ${test_name}: ${JOB_IDS[${test_name}]}"
  done
  
  # Save job IDs and logs directory to file for later retrieval
  > "${JOB_IDS_FILE}"
  echo "LOGS_DIR:${LOGS_DIR}" >> "${JOB_IDS_FILE}"
  for test_name in "${!JOB_IDS[@]}"; do
    echo "${test_name}:${JOB_IDS[${test_name}]}" >> "${JOB_IDS_FILE}"
  done
  echo ""
  echo "Job IDs saved to: ${JOB_IDS_FILE}"
  echo "Logs directory: ${LOGS_DIR}"
  echo ""
fi

# Load job IDs and logs directory from file if it exists (for both submit and non-submit modes)
if [ "${SUBMIT}" = "false" ] || [ "${WAIT_FOR_COMPLETION}" = "true" ]; then
  echo "=========================================="
  echo "Finding existing test output files"
  echo "=========================================="
  echo ""
  
  # Try to load job IDs and logs directory from file if it exists
  LOGS_DIR=""
  if [ -f "${JOB_IDS_FILE}" ]; then
    echo -e "${COLOR_YELLOW}Loading job IDs from:${COLOR_RESET} ${JOB_IDS_FILE}"
    while IFS=':' read -r key value; do
      if [ "${key}" = "LOGS_DIR" ]; then
        LOGS_DIR="${value}"
        echo -e "  ${COLOR_YELLOW}Logs directory:${COLOR_RESET} ${LOGS_DIR}"
      elif [ -n "${key}" ] && [ -n "${value}" ] && [ "${key}" != "LOGS_DIR" ]; then
        test_name="${key}"
        job_id="${value}"
        JOB_IDS["${test_name}"]="${job_id}"
        echo "  ${test_name}: ${job_id}"
        
        # Determine output file based on job ID
        test_script=""
        for test_entry in "${TESTS[@]}"; do
          IFS=':' read -r tname tscript <<< "${test_entry}"
          if [ "${tname}" = "${test_name}" ]; then
            test_script="${tscript}"
            break
          fi
        done
        
        if [ -n "${test_script}" ]; then
          potential_file=""
          potential_err=""
          
          # First check timestamp directory if LOGS_DIR is set
          if [ -n "${LOGS_DIR}" ] && [ -d "${LOGS_DIR}" ]; then
            potential_file="${LOGS_DIR}/${test_script%.sbatch}.${job_id}.out"
            potential_err="${LOGS_DIR}/${test_script%.sbatch}.${job_id}.err"
            # SLURM %x includes .sbatch extension by default
            if [ ! -f "${potential_file}" ]; then
              potential_file="${LOGS_DIR}/${test_script}.${job_id}.out"
              potential_err="${LOGS_DIR}/${test_script}.${job_id}.err"
            fi
          fi
          
          # Fallback to logs/ directory
          if [ -z "${potential_file}" ] || [ ! -f "${potential_file}" ]; then
            potential_file="logs/${test_script%.sbatch}.${job_id}.out"
            potential_err="logs/${test_script%.sbatch}.${job_id}.err"
          fi
          if [ ! -f "${potential_file}" ]; then
            potential_file="logs/${test_script}.${job_id}.out"
            potential_err="logs/${test_script}.${job_id}.err"
          fi
          
          # Only set if file actually exists
          if [ -n "${potential_file}" ] && [ -f "${potential_file}" ]; then
            OUTPUT_FILES["${test_name}"]="${potential_file}"
            ERROR_FILES["${test_name}"]="${potential_err}"
          fi
        fi
      fi
    done < "${JOB_IDS_FILE}"
    echo ""
  fi
  
  # Find most recent output files for each test (fallback only if no job IDs loaded)
  # If we have job IDs from file, only look for files matching those IDs
  # Don't search for "most recent" files when we have specific job IDs to track
  if [ ${#JOB_IDS[@]} -eq 0 ]; then
    # No job IDs loaded - use fallback to find any existing files
    for test_entry in "${TESTS[@]}"; do
      IFS=':' read -r test_name test_script <<< "${test_entry}"
      
      # Skip if we already have output file from job ID
      if [ -n "${OUTPUT_FILES[${test_name}]}" ] && \
         [ -f "${OUTPUT_FILES[${test_name}]}" ]; then
        continue
      fi
      
      # Find most recent output file
      # Priority: 1) LOGS_DIR if set, 2) timestamp directories, 3) flat logs/, 4) current dir
      # All scripts now use same format: %x.%j.out (no array jobs)
      pattern_name="${test_script%.sbatch}.*.out"
      
      # First check LOGS_DIR if it was loaded from job IDs file
      if [ -n "${LOGS_DIR}" ] && [ -d "${LOGS_DIR}" ]; then
        latest_file=$(ls -t "${LOGS_DIR}"/${pattern_name} 2>/dev/null | head -1)
      fi
      
      # Search in timestamp directories (most recent first) if not found
      if [ -z "${latest_file}" ]; then
        latest_file=$(find logs -mindepth 2 -maxdepth 2 -name "${pattern_name}" -type f 2>/dev/null | sort -r | head -1)
      fi
      
      # Fallback to flat logs directory
      if [ -z "${latest_file}" ]; then
        latest_file=$(ls -t logs/${pattern_name} 2>/dev/null | head -1)
      fi
      
      # Fallback to old location for backward compatibility
      if [ -z "${latest_file}" ]; then
        latest_file=$(ls -t ${pattern_name} 2>/dev/null | head -1)
      fi
      if [ -n "${latest_file}" ]; then
        OUTPUT_FILES["${test_name}"]="${latest_file}"
        ERROR_FILES["${test_name}"]="${latest_file%.out}.err"
      fi
    done
  fi
  echo ""
fi

# Wait for jobs to complete if requested
if [ "${WAIT_FOR_COMPLETION}" = "true" ]; then
  echo "=========================================="
  echo "Waiting for jobs to complete"
  echo "=========================================="
  echo ""
  
  all_done=false
  # Track number of status lines to clear
  prev_line_count=0
  declare -A no_output_retries
  while [ "${all_done}" = "false" ]; do
    all_done=true
    
    # Build status lines for each test (one per line)
    status_lines=()
    for test_name in "${!JOB_IDS[@]}"; do
      job_id="${JOB_IDS[${test_name}]}"
      if [ -z "${job_id}" ]; then
        continue
      fi
      
      # Find output file for this test
      output_file=""
      # First check if we already have it in OUTPUT_FILES array (populated during submission or --no-submit)
      if [ -n "${OUTPUT_FILES[${test_name}]}" ]; then
        if [ -f "${OUTPUT_FILES[${test_name}]}" ]; then
          output_file="${OUTPUT_FILES[${test_name}]}"
        fi
      fi
      
      # If not found, search for it
      if [ -z "${output_file}" ]; then
        for test_entry in "${TESTS[@]}"; do
          IFS=':' read -r tname tscript <<< "${test_entry}"
          if [ "${tname}" = "${test_name}" ]; then
            # Check timestamp directory first (if LOGS_DIR is set)
            if [ -n "${LOGS_DIR}" ]; then
              potential_file="${LOGS_DIR}/${tscript%.sbatch}.${job_id}.out"
              if [ -f "${potential_file}" ]; then
                output_file="${potential_file}"
              fi
              # SLURM %x includes .sbatch extension by default
              if [ -z "${output_file}" ]; then
                potential_file="${LOGS_DIR}/${tscript}.${job_id}.out"
                if [ -f "${potential_file}" ]; then
                  output_file="${potential_file}"
                fi
              fi
            fi
            # Fallback: find by job ID in logs/ subdirectories
            if [ -z "${output_file}" ]; then
              potential_file=$(find logs -name "*.${job_id}.out" \
                -type f 2>/dev/null | head -1)
              if [ -n "${potential_file}" ] && \
                 [ -f "${potential_file}" ]; then
                output_file="${potential_file}"
              fi
            fi
            # Final fallback: check flat logs/ directory
            if [ -z "${output_file}" ]; then
              potential_file="logs/${tscript%.sbatch}.${job_id}.out"
              if [ -f "${potential_file}" ]; then
                output_file="${potential_file}"
              fi
            fi
            if [ -z "${output_file}" ]; then
              potential_file="logs/${tscript}.${job_id}.out"
              if [ -f "${potential_file}" ]; then
                output_file="${potential_file}"
              fi
            fi
            break
          fi
        done
      fi
      
      # Check job status (with timeout to avoid hanging)
      job_state=""
      if command -v timeout >/dev/null 2>&1; then
        job_state=$(timeout 1 squeue -j "${job_id}" -h -o "%T" 2>/dev/null || echo "")
      else
        job_state=$(squeue -j "${job_id}" -h -o "%T" 2>/dev/null || echo "")
      fi
      
      # Determine if job is still running
      # First check if output file exists and has final status
      # Re-check output_file from OUTPUT_FILES if not set yet
      if [ -z "${output_file}" ] && [ -n "${OUTPUT_FILES[${test_name}]}" ]; then
        if [ -f "${OUTPUT_FILES[${test_name}]}" ]; then
          output_file="${OUTPUT_FILES[${test_name}]}"
        fi
      fi
      
      has_final_status=false
      if [ -n "${output_file}" ] && [ -f "${output_file}" ]; then
        if grep -q "Status: PASS\|Status: FAIL" "${output_file}" 2>/dev/null; then
          has_final_status=true
        fi
      fi
      
      is_running=false
      if [ -n "${job_state}" ]; then
        # Got valid response from squeue
        if [ "${job_state}" != "COMPLETED" ] && \
           [ "${job_state}" != "FAILED" ] && \
           [ "${job_state}" != "CANCELLED" ]; then
          is_running=true
          all_done=false
        elif [ "${has_final_status}" = "false" ]; then
          # Job state says completed but no final status in output yet - wait a bit
          is_running=true
          all_done=false
        fi
      else
        # squeue returned empty (job not in queue) - job is likely done
        # Try harder to find output file and check status
        if [ -z "${output_file}" ]; then
          for test_entry in "${TESTS[@]}"; do
            IFS=':' read -r tname tscript <<< "${test_entry}"
            if [ "${tname}" = "${test_name}" ]; then
              if [ -n "${LOGS_DIR}" ]; then
                potential_file="${LOGS_DIR}/${tscript%.sbatch}.${job_id}.out"
                if [ -f "${potential_file}" ]; then
                  output_file="${potential_file}"
                fi
                if [ -z "${output_file}" ]; then
                  potential_file="${LOGS_DIR}/${tscript}.${job_id}.out"
                  if [ -f "${potential_file}" ]; then
                    output_file="${potential_file}"
                  fi
                fi
              fi
              if [ -z "${output_file}" ]; then
                potential_file=$(find logs \
                  -name "*.${job_id}.out" \
                  -type f 2>/dev/null | head -1)
                if [ -n "${potential_file}" ] && \
                   [ -f "${potential_file}" ]; then
                  output_file="${potential_file}"
                fi
              fi
              break
            fi
          done
        fi
        
        # Re-check for final status now that we have the file path
        if [ -n "${output_file}" ] && [ -f "${output_file}" ]; then
          if grep -q "Status: PASS\|Status: FAIL" "${output_file}" 2>/dev/null; then
            has_final_status=true
          fi
        fi
        
        # If we have final status, job is done
        # If no final status but file exists and hasn't been modified recently, also done
        if [ "${has_final_status}" = "false" ]; then
          if [ -z "${output_file}" ] || [ ! -f "${output_file}" ]; then
            retries=${no_output_retries["${test_name}"]:-0}
            no_output_retries["${test_name}"]=$((retries + 1))
            # Give up after ~60s (12 x 5s) of no output file
            if [ ${retries} -lt 12 ]; then
              is_running=true
              all_done=false
            fi
          else
            # File exists but no final status - check modification time
            if command -v stat >/dev/null 2>&1; then
              file_age=0
              mod_time=0
              now=$(date +%s 2>/dev/null || echo "0")
              if [[ "$OSTYPE" == "darwin"* ]]; then
                mod_time=$(stat -f %m "${output_file}" 2>/dev/null || echo "0")
              else
                mod_time=$(stat -c %Y "${output_file}" 2>/dev/null || echo "0")
              fi
              if [ "${mod_time}" != "0" ] && [ "${now}" != "0" ]; then
                file_age=$((now - mod_time))
                # If file was modified within last 30 seconds, assume still running
                if [ ${file_age} -lt 30 ] && [ ${file_age} -ge 0 ]; then
                  is_running=true
                  all_done=false
                fi
                # If file hasn't been modified in 30+ seconds, assume done
              else
                # Can't determine file age - assume still running
                is_running=true
                all_done=false
              fi
            else
              # Can't check modification time - assume still running
              is_running=true
              all_done=false
            fi
          fi
        fi
        # If has_final_status is true, job is done
      fi
      
      if [ -n "${output_file}" ] && [ -f "${output_file}" ]; then
        OUTPUT_FILES["${test_name}"]="${output_file}"
        if grep -q "Status: PASS" "${output_file}" 2>/dev/null; then
          status_color="${COLOR_GREEN}"
        elif grep -q "Status: FAIL" "${output_file}" 2>/dev/null; then
          status_color="${COLOR_RED}"
          if [ "${is_running}" = "true" ]; then
            all_done=false
          fi
        elif [ "${is_running}" = "true" ]; then
          status_color="${COLOR_YELLOW}"
        else
          status_color="${COLOR_YELLOW}"
        fi
        
        last_line=$(tail -1 "${output_file}" 2>/dev/null \
          | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
          | cut -c1-50)
        if [ -n "${last_line}" ]; then
          status_lines+=("${status_color}${test_name}:${COLOR_RESET} ${last_line}")
        fi
      elif [ "${is_running}" = "true" ]; then
        status_lines+=("${COLOR_YELLOW}${test_name}:${COLOR_RESET} (waiting for output...)")
      else
        status_lines+=("${COLOR_RED}${test_name}:${COLOR_RESET} (output file not found)")
      fi
    done
    
    if [ "${all_done}" = "false" ]; then
      # Move cursor up to overwrite previous status lines
      for ((i=0; i<${prev_line_count}; i++)); do
        echo -ne "\033[A\033[K"
      done
      
      # Print new status lines (each test on its own line)
      for status_line in "${status_lines[@]}"; do
        echo -e "\r${status_line}"
      done
      
      # Update line count for next iteration
      prev_line_count=${#status_lines[@]}
      sleep 5
    fi
  done
  
  # Clear the status lines
  for ((i=0; i<${prev_line_count}; i++)); do
    echo -ne "\033[A\033[K"
  done
  echo ""
  echo ""
  echo -e "${COLOR_GREEN}All jobs completed.${COLOR_RESET}"
  echo ""
  
  # Clean up job IDs file after successful completion (only if we submitted)
  if [ "${SUBMIT}" = "true" ]; then
    rm -f "${JOB_IDS_FILE}"
  fi
fi

# If we just submitted jobs without --wait, exit here with a simple message
if [ "${SUBMIT}" = "true" ] && [ "${WAIT_FOR_COMPLETION}" = "false" ]; then
  echo -e "${COLOR_GREEN}Jobs submitted successfully.${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}Run './run-alola-tests.sh' to check status later.${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}Run './run-alola-tests.sh --wait' to wait for completion.${COLOR_RESET}"
  exit 0
fi

# Function to extract test summary from output file
extract_test_summary() {
  local output_file="$1"
  local test_name="$2"
  
  if [ ! -f "${output_file}" ]; then
    echo "  Output file not found: ${output_file}"
    return 1
  fi
  
  # Find the line number of "Test Summary"
  local summary_line=$(grep -n "^Test Summary$" "${output_file}" | cut -d: -f1)
  
  if [ -z "${summary_line}" ]; then
    echo "  No test summary found in output"
    return 1
  fi
  
  # Start from the separator line before "Test Summary" (usually summary_line - 1)
  # End at the final separator line after the summary section (second occurrence)
  local start_line=$((summary_line - 1))
  
  # Find the second separator line after "Test Summary" (the closing separator)
  # The first separator is right after "Test Summary", we want the second one
  local end_line=$(sed -n "${summary_line},\$p" "${output_file}" | \
    grep -n "^==========================================$" | sed -n '2p' | cut -d: -f1)
  
  if [ -n "${end_line}" ]; then
    end_line=$((summary_line + end_line - 1))
  else
    # If no ending separator found, extract to end of file
    end_line="\$"
  fi
  
  # Extract the summary section
  sed -n "${start_line},${end_line}p" "${output_file}" | sed 's/^/  /'
}

# Function to check job exit status
check_job_status() {
  local test_name="$1"
  # Get output file from the associative array
  local output_file="${OUTPUT_FILES[${test_name}]}"
  local error_file="${ERROR_FILES[${test_name}]}"
  local job_id="${JOB_IDS[${test_name}]}"
  
  # Always read from OUTPUT_FILES array to get the latest value
  output_file="${OUTPUT_FILES[${test_name}]}"
  
  # If still empty, return NO_OUTPUT
  if [ -z "${output_file}" ]; then
    return 3  # No output file set
  fi
  
  # First check if job is still running in SLURM (with timeout to avoid hanging)
  # Skip squeue check if not submitting to avoid hanging, or use very short timeout
  if [ -n "${job_id}" ] && [ "${SUBMIT}" = "true" ]; then
    # Use timeout if available, otherwise skip squeue check to avoid hanging
    local job_state=""
    if command -v timeout >/dev/null 2>&1; then
      job_state=$(timeout 1 squeue -j "${job_id}" -h -o "%T" 2>/dev/null || echo "")
    fi
    # Only use job_state if we got a valid response (not empty, not error)
    if [ -n "${job_state}" ] && [ "${job_state}" != "COMPLETED" ] && \
       [ "${job_state}" != "FAILED" ] && [ "${job_state}" != "CANCELLED" ]; then
      # Job is still in queue (RUNNING, PENDING, etc.)
      return 4  # Running
    fi
  fi
  
  # Job is not in queue, check output file
  if [ -z "${output_file}" ] || [ ! -f "${output_file}" ]; then
    return 3  # No output
  fi
  
  # Check if test summary shows PASS or FAIL
  if grep -q "Status: PASS" "${output_file}" 2>/dev/null; then
    return 0  # PASS
  elif grep -q "Status: FAIL" "${output_file}" 2>/dev/null; then
    return 1  # FAIL
  else
    # If no summary found, check if file exists and has content
    # Also check if file was recently modified (within last 5 minutes) - might be running
    # Skip file modification check if not submitting to avoid delays
    if [ -s "${output_file}" ]; then
      # Check if file was modified recently (within 5 minutes) - only if submitting
      if [ "${SUBMIT}" = "true" ] && command -v stat >/dev/null 2>&1 && [ -f "${output_file}" ]; then
        local file_age=0
        local mod_time=0
        local now=$(date +%s 2>/dev/null || echo "0")
        if [[ "$OSTYPE" == "darwin"* ]]; then
          # macOS
          mod_time=$(stat -f %m "${output_file}" 2>/dev/null || echo "0")
        else
          # Linux
          mod_time=$(stat -c %Y "${output_file}" 2>/dev/null || echo "0")
        fi
        if [ "${mod_time}" != "0" ] && [ "${now}" != "0" ]; then
          file_age=$((now - mod_time))
          # If file was modified within last 5 minutes (300 seconds), consider it running
          if [ ${file_age} -lt 300 ] && [ ${file_age} -ge 0 ]; then
            return 4  # Running (file recently modified)
          fi
        fi
      fi
      return 2  # Unknown status (output exists but no summary)
    else
      return 3  # No output
    fi
  fi
}

# Display consolidated summary
echo "=========================================="
echo "Test Results Summary"
echo "=========================================="
echo ""

total_passed=0
total_failed=0
total_unknown=0
total_running=0
subtest_counts=()
total_subtests=0

for test_entry in "${TESTS[@]}"; do
  IFS=':' read -r test_name test_script <<< "${test_entry}"
  
  echo "----------------------------------------"
  echo "${test_name}"
  echo "----------------------------------------"
  
  if [ -n "${JOB_IDS[${test_name}]}" ]; then
    echo -e "${COLOR_YELLOW}Job ID:${COLOR_RESET} ${JOB_IDS[${test_name}]}"
  fi
  
  output_file="${OUTPUT_FILES[${test_name}]}"
  error_file="${ERROR_FILES[${test_name}]}"
  
  # Show output file paths if available (before status check to ensure they're always shown)
  if [ -n "${output_file}" ] && [ -f "${output_file}" ]; then
    echo -e "stdout: ${output_file}"
    if [ -n "${error_file}" ]; then
      echo -e "stderr: ${error_file}"
    fi
  fi
  
  # Check logs directory first (where SLURM writes files), then timestamp directory
  if [ -z "${output_file}" ] || [ ! -f "${output_file}" ]; then
    if [ -n "${JOB_IDS[${test_name}]}" ]; then
      job_id="${JOB_IDS[${test_name}]}"
      # First check timestamp directory if LOGS_DIR is set
      if [ -n "${LOGS_DIR}" ] && [ -d "${LOGS_DIR}" ]; then
        if [ -f "${LOGS_DIR}/${test_script%.sbatch}.${job_id}.out" ]; then
          output_file="${LOGS_DIR}/${test_script%.sbatch}.${job_id}.out"
          error_file="${LOGS_DIR}/${test_script%.sbatch}.${job_id}.err"
          OUTPUT_FILES["${test_name}"]="${output_file}"
          ERROR_FILES["${test_name}"]="${error_file}"
        elif [ -f "${LOGS_DIR}/${test_script}.${job_id}.out" ]; then
          output_file="${LOGS_DIR}/${test_script}.${job_id}.out"
          error_file="${LOGS_DIR}/${test_script}.${job_id}.err"
          OUTPUT_FILES["${test_name}"]="${output_file}"
          ERROR_FILES["${test_name}"]="${error_file}"
        fi
      fi
      if [ -z "${output_file}" ] || [ ! -f "${output_file}" ]; then
        if [ -f "logs/${test_script%.sbatch}.${job_id}.out" ]; then
          output_file="logs/${test_script%.sbatch}.${job_id}.out"
          error_file="logs/${test_script%.sbatch}.${job_id}.err"
          OUTPUT_FILES["${test_name}"]="${output_file}"
          ERROR_FILES["${test_name}"]="${error_file}"
        elif [ -f "logs/${test_script}.${job_id}.out" ]; then
          output_file="logs/${test_script}.${job_id}.out"
          error_file="logs/${test_script}.${job_id}.err"
          OUTPUT_FILES["${test_name}"]="${output_file}"
          ERROR_FILES["${test_name}"]="${error_file}"
        fi
      fi
    fi
  fi
  
  # Ensure OUTPUT_FILES is updated with the found file before checking status
  if [ -n "${output_file}" ]; then
    OUTPUT_FILES["${test_name}"]="${output_file}"
    ERROR_FILES["${test_name}"]="${error_file}"
  fi
  
  # Check job status (with timeout protection)
  # Use direct grep for fast status detection, fallback to function if needed
  status_code=2  # Default to Unknown
  if [ -n "${output_file}" ] && [ -f "${output_file}" ]; then
    # Fast direct check - grep for status in file
    if grep -q "Status: PASS" "${output_file}" 2>/dev/null; then
      status_code=0  # PASS
    elif grep -q "Status: FAIL" "${output_file}" 2>/dev/null; then
      status_code=1  # FAIL
    else
      # No status found, check if job might be running
      # Only check squeue if submitting (to avoid hanging)
      if [ "${SUBMIT}" = "true" ] && [ -n "${JOB_IDS[${test_name}]}" ]; then
        # Quick squeue check with timeout
        if command -v timeout >/dev/null 2>&1; then
          job_state=$(timeout 1 squeue -j "${JOB_IDS[${test_name}]}" -h -o "%T" 2>/dev/null || echo "")
        else
          job_state=""
        fi
        if [ -n "${job_state}" ] && [ "${job_state}" != "COMPLETED" ] && \
           [ "${job_state}" != "FAILED" ] && [ "${job_state}" != "CANCELLED" ]; then
          status_code=4  # RUNNING
        else
          status_code=2  # Unknown (file exists but no status)
        fi
      else
        status_code=2  # Unknown (file exists but no status)
      fi
    fi
  else
    # No output file found
    status_code=3  # NO_OUTPUT
  fi
  
  # Ensure status_code is a valid number (0-4)
  if [ -z "${status_code}" ] || ! [[ "${status_code}" =~ ^[0-9]+$ ]] || [ ${status_code} -gt 4 ]; then
    status_code=2  # Default to Unknown
  fi
  
  # If output_file is still not set but we have a status, try to find it
  # Only use pattern matching fallback if we don't have a job ID for this test
  # If we have a job ID, we should only look for files matching that specific ID
  if [ -z "${output_file}" ] && [ ${status_code} -ne 3 ]; then
    # If we have a job ID, try one more time to find the file matching that ID
    if [ -n "${JOB_IDS[${test_name}]}" ]; then
      job_id="${JOB_IDS[${test_name}]}"
      for test_entry in "${TESTS[@]}"; do
        IFS=':' read -r tname tscript <<< "${test_entry}"
        if [ "${tname}" = "${test_name}" ]; then
          if [ -n "${LOGS_DIR}" ] && [ -d "${LOGS_DIR}" ]; then
            potential_file="${LOGS_DIR}/${tscript%.sbatch}.${job_id}.out"
            if [ ! -f "${potential_file}" ]; then
              potential_file="${LOGS_DIR}/${tscript}.${job_id}.out"
            fi
            if [ -f "${potential_file}" ]; then
              OUTPUT_FILES["${test_name}"]="${potential_file}"
              ERROR_FILES["${test_name}"]="${potential_file%.out}.err"
              output_file="${potential_file}"
              break
            fi
          fi
          if [ -z "${output_file}" ]; then
            potential_file="logs/${tscript%.sbatch}.${job_id}.out"
            if [ ! -f "${potential_file}" ]; then
              potential_file="logs/${tscript}.${job_id}.out"
            fi
            if [ -f "${potential_file}" ]; then
              OUTPUT_FILES["${test_name}"]="${potential_file}"
              ERROR_FILES["${test_name}"]="${potential_file%.out}.err"
              output_file="${potential_file}"
              break
            fi
          fi
          if [ -z "${output_file}" ]; then
            potential_file=$(find logs \
              -name "*.${job_id}.out" \
              -type f 2>/dev/null | head -1)
            if [ -n "${potential_file}" ] && \
               [ -f "${potential_file}" ]; then
              OUTPUT_FILES["${test_name}"]="${potential_file}"
              ERROR_FILES["${test_name}"]="${potential_file%.out}.err"
              output_file="${potential_file}"
              break
            fi
          fi
          break
        fi
      done
    else
      # No job ID - use pattern matching fallback (for backward compatibility)
      for test_entry in "${TESTS[@]}"; do
        IFS=':' read -r tname tscript <<< "${test_entry}"
        if [ "${tname}" = "${test_name}" ]; then
          # All scripts now use same format: %x.%j.out (no array jobs)
          pattern_name="${tscript%.sbatch}.*.out"
          
          # First check LOGS_DIR if it was loaded from job IDs file
          if [ -n "${LOGS_DIR}" ] && [ -d "${LOGS_DIR}" ]; then
            latest_file=$(ls -t "${LOGS_DIR}"/${pattern_name} 2>/dev/null | head -1)
          fi
          
          # Search in timestamp directories (most recent first) if not found
          if [ -z "${latest_file}" ]; then
            latest_file=$(find logs -mindepth 2 -maxdepth 2 -name "${pattern_name}" -type f 2>/dev/null | sort -r | head -1)
          fi
          
          # Fallback to flat logs directory
          if [ -z "${latest_file}" ]; then
            latest_file=$(ls -t logs/${pattern_name} 2>/dev/null | head -1)
          fi
          
          # Fallback to old location for backward compatibility (including .1.out for old array jobs)
          if [ -z "${latest_file}" ]; then
            latest_file=$(ls -t ${pattern_name} 2>/dev/null | head -1)
            # Also check for old .1.out format for backward compatibility
            if [ -z "${latest_file}" ]; then
              old_pattern="${tscript%.sbatch}.*.1.out"
              latest_file=$(ls -t ${old_pattern} 2>/dev/null | head -1)
            fi
          fi
          if [ -n "${latest_file}" ]; then
            OUTPUT_FILES["${test_name}"]="${latest_file}"
            ERROR_FILES["${test_name}"]="${latest_file%.out}.err"
            output_file="${latest_file}"
          fi
          break
        fi
      done
    fi
  fi
  
  # Display status right after Job ID
  # Try to extract full status line from output file (includes "(X of Y)" if available)
  status_suffix=""
  if [ -n "${output_file}" ] && [ -f "${output_file}" ]; then
    # Extract the full status line (e.g., "Status: PASS (5 of 5)" or "Status: FAIL (2 of 5 failed)")
    full_status_line=$(grep "^Status:" "${output_file}" 2>/dev/null | head -1)
    if [ -n "${full_status_line}" ]; then
      # Extract everything after "Status: PASS" or "Status: FAIL"
      case ${status_code} in
        0)
          status_suffix=$(echo "${full_status_line}" | sed -n 's/^Status: *PASS *//p')
          ;;
        1)
          status_suffix=$(echo "${full_status_line}" | sed -n 's/^Status: *FAIL *//p')
          ;;
      esac
    fi
  fi

  # Extract subtest total from status line for summary
  test_subcount=0
  if [ -n "${full_status_line}" ]; then
    test_subcount=$(echo "${full_status_line}" \
      | sed -n 's/.* of \([0-9]*\).*/\1/p')
    test_subcount=${test_subcount:-0}
  fi
  subtest_counts+=("${test_subcount}")
  total_subtests=$((total_subtests + test_subcount))

  case ${status_code} in
    0)
      if [ -n "${status_suffix}" ]; then
        echo -e "Status: ${COLOR_GREEN}PASS${COLOR_RESET} ${status_suffix}"
      else
        echo -e "Status: ${COLOR_GREEN}PASS${COLOR_RESET}"
      fi
      total_passed=$((total_passed + 1))
      ;;
    1)
      if [ -n "${status_suffix}" ]; then
        echo -e "Status: ${COLOR_RED}FAIL${COLOR_RESET} ${status_suffix}"
      else
        echo -e "Status: ${COLOR_RED}FAIL${COLOR_RESET}"
      fi
      total_failed=$((total_failed + 1))
      ;;
    2)
      echo -e "Status: ${COLOR_YELLOW}Unknown${COLOR_RESET} (no summary found)"
      total_unknown=$((total_unknown + 1))
      ;;
    3)
      echo -e "Status: ${COLOR_YELLOW}NO_OUTPUT${COLOR_RESET}"
      total_unknown=$((total_unknown + 1))
      ;;
    4)
      echo -e "Status: ${COLOR_YELLOW}RUNNING${COLOR_RESET}"
      total_running=$((total_running + 1))
      # Show job state from SLURM (with timeout to avoid hanging)
      # Try to get job state even if not submitting, but use shorter timeout
      if [ -n "${JOB_IDS[${test_name}]}" ]; then
        timeout_val=2
        if [ "${SUBMIT}" = "false" ]; then
          timeout_val=1
        fi
        if command -v timeout >/dev/null 2>&1; then
          job_state=$(timeout ${timeout_val} squeue -j "${JOB_IDS[${test_name}]}" -h -o "%T %M %R" 2>/dev/null || echo "")
        elif [ "${SUBMIT}" = "true" ]; then
          job_state=$(squeue -j "${JOB_IDS[${test_name}]}" -h -o "%T %M %R" 2>/dev/null || echo "")
        fi
        if [ -n "${job_state}" ]; then
          if [ "${VERBOSE}" = "true" ]; then
            echo "  Job State: ${job_state}"
          fi
        fi
      fi
      ;;
    *)
      # Default case - should not happen, but ensure status is shown
      echo -e "Status: ${COLOR_YELLOW}Unknown${COLOR_RESET}"
      total_unknown=$((total_unknown + 1))
      ;;
  esac
  
  if [ -n "${output_file}" ] && [ -f "${output_file}" ]; then
    # Only extract summary if job is not running (status codes 0, 1, 2)
    if [ ${status_code} -ne 4 ] && [ ${status_code} -ne 3 ]; then
      # Extract and display test summary only in verbose mode
      if [ "${VERBOSE}" = "true" ]; then
        echo ""
        extract_test_summary "${output_file}" "${test_name}" || true
      fi
    elif [ ${status_code} -eq 4 ]; then
      # For running jobs, show last few lines of output only in verbose mode
      if [ "${VERBOSE}" = "true" ]; then
        echo ""
        echo -e "${COLOR_YELLOW}Recent output (last 10 lines):${COLOR_RESET}"
        tail -10 "${output_file}" 2>/dev/null | sed 's/^/  /' || echo "  (no output yet)"
      fi
    fi
  fi
  
  if [ -n "${error_file}" ] && [ -f "${error_file}" ] && [ -s "${error_file}" ]; then
    if [ "${VERBOSE}" = "true" ]; then
      echo ""
      echo -e "${COLOR_RED}Errors (last 10 lines):${COLOR_RESET}"
      tail -10 "${error_file}" | sed 's/^/  /'
    fi
  fi
  
  echo ""
done

echo "=========================================="
echo "Overall Summary"
echo "=========================================="
subtest_list=$(IFS=', '; echo "${subtest_counts[*]}")
echo "Total Tests: ${#TESTS[@]} (${subtest_list})"
echo -e "Passed: ${COLOR_GREEN}${total_passed}${COLOR_RESET}"
if [ ${total_failed} -gt 0 ]; then
  echo -e "Failed: ${COLOR_RED}${total_failed}${COLOR_RESET}"
else
  echo -e "Failed: ${COLOR_GREEN}${total_failed}${COLOR_RESET}"
fi
if [ ${total_running} -gt 0 ]; then
  echo -e "Running: ${COLOR_YELLOW}${total_running}${COLOR_RESET}"
fi
if [ ${total_unknown} -gt 0 ]; then
  echo -e "Unknown/No output: ${COLOR_YELLOW}${total_unknown}${COLOR_RESET}"
fi

if [ ${total_running} -gt 0 ]; then
  echo -e "Overall Status: ${COLOR_YELLOW}RUNNING${COLOR_RESET}"
  exit 3
elif [ ${total_failed} -eq 0 ] && [ ${total_unknown} -eq 0 ]; then
  echo -e "Overall Status: ${COLOR_GREEN}PASS${COLOR_RESET}"
  exit 0
elif [ ${total_failed} -gt 0 ]; then
  echo -e "Overall Status: ${COLOR_RED}FAIL${COLOR_RESET}"
  exit 1
else
  echo -e "Overall Status: ${COLOR_YELLOW}Unknown${COLOR_RESET}"
  exit 2
fi
