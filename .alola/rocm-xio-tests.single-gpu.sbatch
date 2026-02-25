#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# usage: sbatch rocm-xio-tests.single-gpu.sbatch
#
#SBATCH --array=1-4
#SBATCH --output=%x.%A.%a.out
#SBATCH --error=%x.%A.%a.err
#SBATCH --cpus-per-task=4
#SBATCH --container-image=/cluster/images/rocm-xio/rocm-xio-alola.sqsh
#SBATCH --container-mount-home
#SBATCH --constraint=MARKHAM
#SBATCH --gpus-per-node=1

set -e
if [ -n "${SLURM_SUBMIT_DIR}" ]; then
  . "${SLURM_SUBMIT_DIR}/rocm-xio-tests.common"
else
  . "$(dirname "${BASH_SOURCE[0]}")/rocm-xio-tests.common"
fi

ITERATIONS=100
THREADS=4
DOORBELL=64
DELAY=1000

cd "${PROJECT_DIR}"
detect_gpu_arch
setup_and_build_workdir "single-gpu"
./build/xio-tester test-ep --emulate -n ${ITERATIONS}
./build/xio-tester test-ep -n ${ITERATIONS}
./build/xio-tester test-ep -n ${ITERATIONS} --threads ${THREADS} \
    --doorbell ${DOORBELL} --delay ${DELAY}
./build/xio-tester test-ep -n ${ITERATIONS} --threads ${THREADS} \
  --doorbell ${DOORBELL} --delay -${DELAY}
for MEMORY_MODE in 1 2 3 4 5 6 7; do
  ./build/xio-tester test-ep -n ${ITERATIONS} --threads ${THREADS} \
    --doorbell ${DOORBELL} --delay ${DELAY} --memory-mode ${MEMORY_MODE}
done
# Subcommand must come first; run sdma-ep only when GPU is whitelisted
if $sdma_ep_allowed; then
  ./build/xio-tester sdma-ep p2p --to-host --verify -n 100
else
  echo "INFO: Skipping sdma-ep tests (${ROCM_GPU_ARCH} not in SDMA whitelist)."
fi
# Run the doca-gin tests
./build/doca-gin-doorbell-test
./build/doca-gin-wqe-test
cd "$HOME"
rm -rf "${WORKING_DIR}"
