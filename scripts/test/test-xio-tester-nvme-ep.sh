#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# NVMe-EP benchmark via xio-tester.
# Runs infinite reads until SIGINT.
#
# Usage:
#   ./test-xio-tester-nvme-ep.sh
#   CONTROLLER=/dev/nvme3 BATCH_SIZE=32 \
#     ./test-xio-tester-nvme-ep.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONTROLLER=${CONTROLLER:-/dev/nvme2}
MEMORY_MODE=${MEMORY_MODE:-8}
READ_IO=${READ_IO:-128}
BATCH_SIZE=${BATCH_SIZE:-16}
QUEUE_LENGTH=${QUEUE_LENGTH:-1024}
NUM_QUEUES=${NUM_QUEUES:-16}
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build}"

sudo LD_LIBRARY_PATH=/opt/rocm/lib \
  HSA_FORCE_FINE_GRAIN_PCIE=1 \
  "${BUILD_DIR}/xio-tester" nvme-ep \
  --controller ${CONTROLLER} \
  --memory-mode ${MEMORY_MODE} \
  --read-io ${READ_IO} \
  --batch-size ${BATCH_SIZE} \
  --queue-length ${QUEUE_LENGTH} \
  --num-queues ${NUM_QUEUES} \
  --less-timing \
  --infinite
