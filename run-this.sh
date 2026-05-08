#!/bin/bash

LIB=/home/stebates/Projects/rocm-xio/build/_deps/rdma-core/install/lib

# PRP dump: set ROCXIO_NVME_DUMP_PRP=1 and ROCXIO_LOG_LEVEL=3 (do not put `#`
# comments inside a backslash-continued sudo env line — it splits the command
# so xio-tester runs without sudo and hits EACCES on the NVMe node).
sudo env ROCXIO_NVME_DUMP_VERIFY_MISMATCH=1 \
  ROCXIO_NVME_DUMP_VERIFY_MISMATCH_HALF=48 \
  ROCXIO_NVME_DUMP_PRP=1 \
  ROCXIO_NVME_DUMP_PRP_BATCH=2 \
  ROCXIO_LOG_LEVEL=3 \
  LD_LIBRARY_PATH="${LIB}:/opt/rocs-ais/lib:/opt/rocm/lib:${LD_LIBRARY_PATH:-}" \
  HSA_FORCE_FINE_GRAIN_PCIE=1 \
  ./build/xio-tester nvme-ep \
  --controller /dev/disk/by-id/nvme-MTR_SLC_16GB_0400000E3CBC \
  --access-pattern random \
  --lfsr-seed 0x4444 \
  --memory-mode 8 \
  --write-io 1 \
  --read-io 1 \
  --queue-length 1024 \
  --batch-size 1 \
  --num-queues 1 \
  --histogram \
  --verify \
  --lbas-per-io 17 \
  --verbose