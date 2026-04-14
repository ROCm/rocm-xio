#!/bin/bash

sudo LD_LIBRARY_PATH=/opt/rocm/lib \
  HSA_FORCE_FINE_GRAIN_PCIE=1 \
  ./build/xio-tester nvme-ep \
  --controller /dev/nvme2 \
  --memory-mode 8 \
  --read-io 128 \
  --batch-size 16 \
  --queue-length 1024 \
  --num-queues 4 \
  --less-timing \
  --infinite
