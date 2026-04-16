#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Quick rdma-ep loopback test via xio-tester.
# All parameters are env-var tuneable.
#
# Usage:
#   ./test-xio-tester-rdma-ep.sh
#   VENDOR=ionic BATCH_SIZE=4 NUM_QUEUES=2 \
#     ./test-xio-tester-rdma-ep.sh
#   ITERATIONS=0 ./test-xio-tester-rdma-ep.sh
#   VERIFY=false ./test-xio-tester-rdma-ep.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SETUP_GID=${SETUP_GID:-false}
VENDOR=${VENDOR:-bnxt}
ITERATIONS=${ITERATIONS:-128}
BATCH_SIZE=${BATCH_SIZE:-1}
NUM_QUEUES=${NUM_QUEUES:-1}
TRANSFER_SIZE=${TRANSFER_SIZE:-4096}
VERIFY=${VERIFY:-true}
NIC=rocm-${VENDOR}0

if [ "${SETUP_GID}" = "true" ]; then
  sudo ip addr add 198.18.0.1/24 dev ${NIC}
  MAC=$(ip link show ${NIC} \
    | grep -oP 'link/ether \K[0-9a-f:]+')
  sudo ip neigh replace 198.18.0.1 \
    lladdr ${MAC} nud permanent dev ${NIC}

  for _i in $(seq 1 10); do
    if grep -q 'ffff' \
      /sys/class/infiniband/rocm-rdma-${VENDOR}0/ports/1/gids/* \
      2>/dev/null; then
      echo "GID table ready."
      break
    fi
    sleep 2
  done
fi

BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build}"
LIB="${BUILD_DIR}/_deps/rdma-core/install/lib"
LIB="${LIB}:/opt/rocm/lib"

sudo LD_LIBRARY_PATH="${LIB}" \
HSA_FORCE_FINE_GRAIN_PCIE=1 \
"${BUILD_DIR}/xio-tester" rdma-ep \
  --provider ${VENDOR} \
  --device rocm-rdma-${VENDOR}0 \
  --loopback \
  --iterations ${ITERATIONS} \
  --batch-size ${BATCH_SIZE} \
  --num-queues ${NUM_QUEUES} \
  --transfer-size ${TRANSFER_SIZE} \
  --less-timing \
  $( [ "${VERIFY}" = "true" ] && echo "--verify" )
