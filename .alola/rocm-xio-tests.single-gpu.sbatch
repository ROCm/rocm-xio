#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# usage: sbatch rocm-xio-tests.single-gpu.sbatch
#
#SBATCH --output=logs/%x.%j.out
#SBATCH --error=logs/%x.%j.err
#SBATCH --cpus-per-task=4
#SBATCH --container-image=/cluster/images/rocm-xio/rocm-xio-alola.sqsh
#SBATCH --container-mount-home
#SBATCH --constraint=MARKHAM&(GFX942|GFX950)
#SBATCH --gpus-per-node=1

set -xe

# Use timestamped logs directory if provided, otherwise use logs/
LOGS_DIR="${ALOLA_LOGS_DIR:-logs}"
# Create directory if it doesn't exist (suppress errors if read-only or exists)
mkdir -p "${LOGS_DIR}" 2>/dev/null || true

if [ -n "${SLURM_SUBMIT_DIR}" ]; then
  . "${SLURM_SUBMIT_DIR}/rocm-xio-tests.common"
else
  . "$(dirname "${BASH_SOURCE[0]}")/rocm-xio-tests.common"
fi

ITERATIONS=100
THREADS=4
DOORBELL=64
DELAY=1000

# Display job information
display_job_info

# Initialize test tracking
test_init

cd "${PROJECT_DIR}"
detect_gpu_arch
setup_and_build_workdir "single-gpu"

test_run "ctest unit tests" \
  "ctest --test-dir build --preset unit"

test_run "test-ep --emulate" \
  "./build/xio-tester test-ep --emulate -n ${ITERATIONS}"

test_run "test-ep basic" \
  "./build/xio-tester test-ep -n ${ITERATIONS}"

test_run "test-ep with threads and delay" \
  "./build/xio-tester test-ep -n ${ITERATIONS} \
  --threads ${THREADS} --doorbell ${DOORBELL} \
  --delay ${DELAY}"

test_run "test-ep with negative delay" \
  "./build/xio-tester test-ep -n ${ITERATIONS} \
  --threads ${THREADS} --doorbell ${DOORBELL} \
  --delay -${DELAY}"

for MEMORY_MODE in 1 2 3 4 5 6 7; do
  test_run "test-ep memory-mode ${MEMORY_MODE}" \
    "./build/xio-tester test-ep -n ${ITERATIONS} \
    --threads ${THREADS} --doorbell ${DOORBELL} \
    --delay ${DELAY} --memory-mode ${MEMORY_MODE}"
done

test_run "test-ep with histogram" \
  "./build/xio-tester test-ep -n ${ITERATIONS} --histogram"

for DB in 16 32 128; do
  test_run "test-ep doorbell ${DB}" \
    "./build/xio-tester test-ep -n ${ITERATIONS} \
    --threads ${THREADS} --doorbell ${DB}"
done

test_run "test-ep max-threads" \
  "./build/xio-tester test-ep -n ${ITERATIONS} --threads 32"

# Subcommand must come first; run sdma-ep only when GPU is whitelisted
if $sdma_ep_allowed; then
  test_run "sdma-ep p2p --to-host" \
    "./build/xio-tester sdma-ep p2p --to-host --verify -n 100"
else
  echo "INFO: Skipping sdma-ep tests" \
    "(${ROCM_GPU_ARCH} not in SDMA whitelist)."
fi

# Negative tests: verify invalid arguments fail gracefully.
# The ! prefix inverts the exit code so test_run records PASS
# when the command correctly exits non-zero.
test_run "test-ep invalid memory-mode (expect fail)" \
  "! ./build/xio-tester test-ep --memory-mode 99 -n 1"

test_run "test-ep invalid thread count (expect fail)" \
  "! ./build/xio-tester test-ep --threads 0 -n 1"

cd "$HOME"
rm -rf "${WORKING_DIR}"

# Report results and exit with appropriate code
test_report
EXIT_CODE=$?

exit ${EXIT_CODE}
