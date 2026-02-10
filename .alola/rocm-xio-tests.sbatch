#!/bin/bash
# usage: sbatch rocm-xio-tests.sbatch
#
#SBATCH --array=1-4
#SBATCH --output=%x.%A.%a.out
#SBATCH --error=%x.%A.%a.err
#SBATCH --cpus-per-task=4
#SBATCH --container-image=/cluster/images/rocm-xio/rocm-xio-alola.sqsh
#SBATCH --container-mount-home
#SBATCH --container-workdir=/home/AMD/stebates/Projects/rocm-xio
#SBATCH --constraint=MARKHAM
#SBATCH --gpus-per-node=1

set -e

ITERATIONS=100
THREADS=4
DOORBELL=64
DELAY=1000

ROCM_GPU_ARCH=$(/opt/rocm/bin/rocminfo | grep -m 1 -E gfx[^0]{1} | \
  sed -e 's/ *Name: *\(gfx[0-9,a-f]*\) *$/\1/')
echo "Detected GPU architecture: ${ROCM_GPU_ARCH}"

# Whitelist: 300A (gfx941), 300X/325X (gfx942), 355X (gfx950)
SDMA_EP_GFX_WHITELIST="${SDMA_EP_GFX_WHITELIST:-gfx941 gfx942 gfx950}"
sdma_ep_allowed=false
for g in $SDMA_EP_GFX_WHITELIST; do
  if [ "${ROCM_GPU_ARCH}" = "$g" ]; then sdma_ep_allowed=true; break; fi
done

WORKING_DIR="/tmp/rocm-xio-tests-$RANDOM"
mkdir -p ${WORKING_DIR}
#git clone git@github.com:ROCm/rocm-xio.git ${WORKING_DIR}
rsync -a --exclude='.git' . ${WORKING_DIR}
cd ${WORKING_DIR}
rm -rf build
cmake -S . -B build
cmake --build build --target all --parallel
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
  ./build/xio-tester sdma-ep --to-host --verify -n 100
else
  echo "INFO: Skipping sdma-ep tests (${ROCM_GPU_ARCH} not in SDMA whitelist)."
fi
cd $HOME
rm -rf ${WORKING_DIR}
