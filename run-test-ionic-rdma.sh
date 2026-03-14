#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Ionic RDMA loopback test runner.
# Configures the ionic NIC, waits for GID table,
# and runs the test-rdma-ionic-loopback binary
# with LFSR sweep.

set -euo pipefail

TEST_SIZE=${TEST_SIZE:-256}
TEST_SEED=${TEST_SEED:-1}
ITERATIONS=${ITERATIONS:-10}
BUILD_DIR=${BUILD_DIR:-./build-dv}
NIC_IF=${NIC_IF:-enp132s0np0}
NIC_IP=${NIC_IP:-198.18.1.1/24}
BUILD_ALL=${BUILD_ALL:-false}
RDMA_DEV=${RDMA_DEV:-rocep132s0}

SHA=$(git rev-parse --short HEAD)

NIC_MAC=$(ip link show "${NIC_IF}" \
  | grep -oP 'link/ether \K[0-9a-f:]+')
if [ -z "${NIC_MAC}" ]; then
  echo "ERROR: cannot read MAC from ${NIC_IF}"
  exit 1
fi

IP_BARE=${NIC_IP%%/*}

if [ "${BUILD_ALL}" = "true" ]; then
cmake -S . -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/opt/rocm-xio-${SHA} \
  -DGDA_BNXT=ON -DGDA_IONIC=ON \
  -DIONIC_BUILD_KMOD=ON \
  -DBUILD_TESTING=ON --fresh

cmake --build "${BUILD_DIR}" \
  --target test-rdma-ionic-loopback \
  --target install-bnxt-dv-rdma-core \
  --target build-ionic-rdma-dkms \
  --parallel

sudo cmake --build "${BUILD_DIR}" \
  --target install-ionic-rdma-dkms

sleep 1
sudo modprobe -r ionic_rdma 2>/dev/null || true
sudo modprobe -r ionic 2>/dev/null || true
sleep 3
sudo modprobe ionic loopback=2
sleep 5
sudo ip link set "${NIC_IF}" up
sleep 2
sudo modprobe ionic_rdma
sleep 5

else

cmake --build "${BUILD_DIR}" \
  --target test-rdma-ionic-loopback

fi

# Ensure IP and static neighbor configured
if ! ip addr show "${NIC_IF}" \
    | grep -q "${IP_BARE}"; then
  echo "Adding ${NIC_IP} to ${NIC_IF}..."
  sudo ip addr add "${NIC_IP}" dev "${NIC_IF}"
fi
sudo ip neigh replace "${IP_BARE}" \
  lladdr "${NIC_MAC}" nud permanent \
  dev "${NIC_IF}"

# Wait for the IPv4-mapped GID to appear
echo -n "Checking GID table... "
for attempt in $(seq 1 10); do
  if grep -q 'ffff' \
    /sys/class/infiniband/*/ports/1/gids/* \
    2>/dev/null; then
    echo "ready."
    break
  fi
  if [ "${attempt}" -eq 1 ]; then
    echo ""
    echo -n "  waiting"
  fi
  echo -n "."
  sleep 2
done

IONIC_RDMA_CORE=${IONIC_RDMA_CORE:-""}
if [ -z "${IONIC_RDMA_CORE}" ]; then
  IONIC_RDMA_CORE=$(
    realpath ../rdma-core/install/lib 2>/dev/null \
    || echo ""
  )
fi

if [ -n "${IONIC_RDMA_CORE}" ] && \
   [ -f "${IONIC_RDMA_CORE}/libionic.so" ]; then
  echo "Using ionic rdma-core:" \
       "${IONIC_RDMA_CORE}"
  LIB_PATH="${IONIC_RDMA_CORE}"
  LIB_PATH="${LIB_PATH}:/opt/rocm/lib"
else
  echo "WARNING: ionic-rdma rdma-core not found."
  echo "  Set IONIC_RDMA_CORE=/path/to/lib"
  LIB_PATH="${BUILD_DIR}/_deps/bnxt-dv/"
  LIB_PATH="${LIB_PATH}rdma-core-install/lib"
  LIB_PATH="${LIB_PATH}:/opt/rocm/lib"
fi
BIN="${BUILD_DIR}/tests/unit/rdma-ep/"
BIN="${BIN}test-rdma-ionic-loopback"

echo "=== IONIC RDMA loopback sweep ==="
echo "  size=${TEST_SIZE}" \
     " seed=${TEST_SEED}" \
     " iters=${ITERATIONS}"
echo ""

mismatches=0
times=()

for i in $(seq 1 "${ITERATIONS}"); do
  seed=$((TEST_SEED + i - 1))
  log=$(mktemp /tmp/ionic-lb-XXXXXX.log)

  rc=0
  sudo env LD_LIBRARY_PATH="${LIB_PATH}" \
    XIO_IONIC_DEV="${RDMA_DEV}" \
    "${BIN}" --size "${TEST_SIZE}" \
    --seed "${seed}" \
    --device "${RDMA_DEV}" \
    > "${log}" 2>&1 || rc=$?

  if [ "${rc}" -ne 0 ]; then
    mismatches=$((mismatches + 1))
    printf "  [%3d] seed=%-6u" "${i}" "${seed}"
    printf "  LFSR Check = FAIL  (rc=%d)\n" \
           "${rc}"
    cat "${log}"
  else
    us=$(grep -oP 'completed: \K[0-9.]+' \
         "${log}" || echo "0")
    times+=("${us}")
    printf "  [%3d] seed=%-6u" "${i}" "${seed}"
    printf "  LFSR Check = PASS  %s us\n" "${us}"
  fi
  rm -f "${log}"
done

echo ""

if [ ${#times[@]} -eq 0 ]; then
  echo "No successful iterations to summarize."
  exit 1
fi

read -r min max mean std <<< $(
  printf '%s\n' "${times[@]}" | awk '
    BEGIN { min=1e18; max=0; s=0; s2=0; n=0 }
    {
      v = $1 + 0
      if (v < min) min = v
      if (v > max) max = v
      s  += v
      s2 += v * v
      n++
    }
    END {
      mean = s / n
      var  = (n > 1) ? (s2/n - mean*mean) : 0
      if (var < 0) var = 0
      printf "%.1f %.1f %.1f %.1f", \
             min, max, mean, sqrt(var)
    }
  '
)

echo "--- Timing (us) over ${#times[@]} runs ---"
printf "  min=%-10s  max=%-10s\n" "${min}" "${max}"
printf "  mean=%-9s  std=%-10s\n" "${mean}" "${std}"

if [ "${mismatches}" -gt 0 ]; then
  echo ""
  echo "FAILED: ${mismatches}/${ITERATIONS}" \
       "iterations had data mismatches."
  exit 1
fi

echo ""
echo "PASSED: all ${ITERATIONS} iterations OK."
