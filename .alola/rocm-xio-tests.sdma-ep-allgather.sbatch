#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# usage: sbatch rocm-xio-tests.sdma-ep-allgather.sbatch
#
# SDMA allgather example on a single 8-GPU node.
# Builds rocm-xio, installs to a temp prefix, builds
# the sdma-ep-allgather example against it, then runs
# via mpirun with one MPI rank per GPU.
#
# Each rank owns one GPU and uses the sdma_ep device-
# side API to DMA its local buffer into every other
# rank's output buffer -- a GPU-initiated allgather
# without CPU involvement in the data path.
#
# Requires XGMI / Infinity Fabric P2P between all 8
# GPUs (MI300X or MI350X).
#
#SBATCH --output=logs/%x.%j.out
#SBATCH --error=logs/%x.%j.err
#SBATCH --cpus-per-task=4
#SBATCH --container-image=/cluster/images/rocm-xio/rocm-xio-alola.sqsh
#SBATCH --container-mount-home
#SBATCH --constraint=MARKHAM&(GFX942|GFX950)
#SBATCH --nodes=1
#SBATCH --gpus-per-node=8

set -xe

if [ -n "${SLURM_SUBMIT_DIR}" ]; then
  . "${SLURM_SUBMIT_DIR}/rocm-xio-tests.common"
else
  . "$(dirname "${BASH_SOURCE[0]}")/rocm-xio-tests.common"
fi

# Use timestamped logs directory if provided
LOGS_DIR="${ALOLA_LOGS_DIR:-logs}"
mkdir -p "${LOGS_DIR}" 2>/dev/null || true

# Initialize test tracking
test_init

# Display job information
display_job_info

cd "${PROJECT_DIR}"
detect_gpu_arch
if ! $sdma_ep_allowed; then
  echo "ERROR: ${ROCM_GPU_ARCH} not in SDMA" \
    "whitelist (${SDMA_EP_GFX_WHITELIST})."
  exit 1
fi
setup_and_build_workdir "sdma-ep-allgather"

if ! command -v mpirun >/dev/null 2>&1; then
  echo "ERROR: mpirun not found in PATH;" \
    "cannot run sdma-ep-allgather."
  exit 1
fi

test_run \
  "sdma-ep-allgather 8-GPU (install + build + run)" \
  "build_and_run_example sdma-ep-allgather && \
   mpirun --allow-run-as-root --oversubscribe \
     -np 8 \
     ${WORKING_DIR}/_ex_sdma-ep-allgather/sdma-ep-allgather"

cd "$HOME"
rm -rf "${WORKING_DIR}"

# Report results and exit with appropriate code
test_report
EXIT_CODE=$?

exit ${EXIT_CODE}
