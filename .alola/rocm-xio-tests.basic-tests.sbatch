#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# usage: sbatch rocm-xio-tests.basic-tests.sbatch
#
# Basic build-validation tests: ctest unit suite,
# ctest integration suite, and example compile/install
# checks.  No specific GPU architecture required.
#
#SBATCH --output=logs/%x.%j.out
#SBATCH --error=logs/%x.%j.err
#SBATCH --cpus-per-task=4
#SBATCH --container-image=/cluster/images/rocm-xio/rocm-xio-alola.sqsh
#SBATCH --container-mount-home
#SBATCH --constraint=MARKHAM
#SBATCH --gpus-per-node=1

set -xe

# Use timestamped logs directory if provided, otherwise use logs/
LOGS_DIR="${ALOLA_LOGS_DIR:-logs}"
mkdir -p "${LOGS_DIR}" 2>/dev/null || true

if [ -n "${SLURM_SUBMIT_DIR}" ]; then
  . "${SLURM_SUBMIT_DIR}/rocm-xio-tests.common"
else
  . "$(dirname "${BASH_SOURCE[0]}")/rocm-xio-tests.common"
fi

# Display job information
display_job_info

# Initialize test tracking
test_init

cd "${PROJECT_DIR}"
detect_gpu_arch
setup_and_build_workdir "basic-tests"

test_run "ctest unit tests" \
  "ctest --test-dir build --preset unit"

# TODO: re-enable once the deadlock hang in
# test-doorbell-coherence is fixed (the test detects
# the timeout but the process never exits, blocking
# the entire sbatch job indefinitely).
# test_run "doorbell coherence stress" \
#   "./build/tests/system/coherence/test-doorbell-coherence"

# Install the library and run examples against the
# installed prefix via the CTest integration fixture.
test_run "ctest integration suite" \
  "ctest --test-dir build -V -L integration \
  --output-on-failure --timeout 300"

test_run "example list-endpoints (install)" \
  "build_and_run_example list-endpoints run"

test_run "example endpoint-info (install)" \
  "build_and_run_example endpoint-info run"

test_run "example nvme-ep-info (compile-only)" \
  "build_and_run_example nvme-ep-info"

test_run "example sdma-ep-p2p (compile-only)" \
  "build_and_run_example sdma-ep-p2p"

cd "$HOME"
rm -rf "${WORKING_DIR}"

# Report results and exit with appropriate code
test_report
EXIT_CODE=$?

exit ${EXIT_CODE}
