#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Install-integration tests: install the library to a temp
# prefix, then configure, build, and run standalone example
# programs against it via CTest.
#
# usage: sbatch rocm-xio-tests.integration.sbatch
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

display_job_info
test_init

cd "${PROJECT_DIR}"
detect_gpu_arch
setup_and_build_workdir "integration"

# Run the full CTest integration suite.
# The fixture installs the library to build/_install_test,
# then each example is configured, built, and run against
# the installed prefix.
test_run "ctest integration suite" \
  "ctest --test-dir build -V -L integration \
  --output-on-failure --timeout 300"

cd "$HOME"
rm -rf "${WORKING_DIR}"

test_report
EXIT_CODE=$?

exit ${EXIT_CODE}
