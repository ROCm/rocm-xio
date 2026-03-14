#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Unified RDMA loopback test runner.
# Supports both BNXT and IONIC NICs via VENDOR
# environment variable.
#
# Usage:
#   VENDOR=all ./run-test-rdma-loopback.sh
#   VENDOR=bnxt ./run-test-rdma-loopback.sh
#   VENDOR=ionic ./run-test-rdma-loopback.sh

set -euo pipefail

TEST_SIZE=${TEST_SIZE:-256}
TEST_SEED=${TEST_SEED:-1}
ITERATIONS=${ITERATIONS:-10}
BUILD_DIR=${BUILD_DIR:-./build-dv}
BUILD_ALL=${BUILD_ALL:-false}
VENDOR=${VENDOR:-all}

SHA=$(git rev-parse --short HEAD 2>/dev/null \
  || echo "dev")

# Per-vendor configuration
run_vendor_test() {
  local vendor="$1"
  local nic_if nic_ip rdma_dev
  local provider_flag=""
  local total_fail=0

  case "${vendor}" in
    bnxt)
      nic_if="${BNXT_NIC_IF:-enp195s0f0np0}"
      nic_ip="${BNXT_NIC_IP:-198.18.0.1/24}"
      rdma_dev="${BNXT_RDMA_DEV:-rocep195s0f0}"
      provider_flag="--provider bnxt"
      provider_flag="${provider_flag} --device"
      provider_flag="${provider_flag} ${rdma_dev}"
      ;;
    ionic)
      nic_if="${IONIC_NIC_IF:-enp132s0np0}"
      nic_ip="${IONIC_NIC_IP:-198.18.1.1/24}"
      rdma_dev="${IONIC_RDMA_DEV:-rocep132s0}"
      provider_flag="--provider ionic"
      provider_flag="${provider_flag}"
      provider_flag="${provider_flag} --device"
      provider_flag="${provider_flag} ${rdma_dev}"
      ;;
    *)
      echo "ERROR: Unknown vendor '${vendor}'"
      return 1
      ;;
  esac

  # Resolve PCIe BDF and VID/DID from the
  # RDMA device sysfs path
  local pci_bdf=""
  local pci_vid=""
  local pci_did=""
  local dev_link
  dev_link="/sys/class/infiniband/${rdma_dev}"
  dev_link="${dev_link}/device"
  if [ -d "${dev_link}" ]; then
    pci_bdf=$(basename "$(readlink -f \
      "${dev_link}")" 2>/dev/null || echo "")
    pci_vid=$(cat "${dev_link}/vendor" \
      2>/dev/null || echo "")
    pci_did=$(cat "${dev_link}/device" \
      2>/dev/null || echo "")
  fi

  echo ""
  echo "====================================="
  echo "  ${vendor^^} loopback test"
  echo "====================================="
  echo "  NIC       : ${nic_if}"
  echo "  IP        : ${nic_ip}"
  echo "  PCIe      : ${pci_bdf}" \
       " VID/DID=${pci_vid}/${pci_did}"
  echo ""

  # Module reload for vendor
  if [ "${BUILD_ALL}" = "true" ]; then
    case "${vendor}" in
      bnxt)
        sudo modprobe -r bnxt_re 2>/dev/null \
          || true
        sleep 3
        sudo modprobe bnxt_re
        sleep 5
        ;;
      ionic)
        sudo modprobe -r ionic_rdma \
          2>/dev/null || true
        sudo modprobe -r ionic \
          2>/dev/null || true
        sleep 3
        sudo modprobe ionic loopback=2
        sleep 5
        sudo ip link set "${nic_if}" up
        sleep 2
        sudo modprobe ionic_rdma
        sleep 5
        ;;
    esac
  fi

  # Get MAC address
  local nic_mac
  nic_mac=$(ip link show "${nic_if}" \
    | grep -oP 'link/ether \K[0-9a-f:]+' \
    || echo "")
  if [ -z "${nic_mac}" ]; then
    echo "ERROR: cannot read MAC from ${nic_if}"
    echo "  Is the interface present?"
    return 1
  fi

  local ip_bare="${nic_ip%%/*}"

  # Ensure IP and static neighbor configured
  if ! ip addr show "${nic_if}" \
      | grep -q "${ip_bare}"; then
    echo "Adding ${nic_ip} to ${nic_if}..."
    sudo ip addr add "${nic_ip}" \
      dev "${nic_if}" 2>/dev/null || true
  fi
  sudo ip neigh replace "${ip_bare}" \
    lladdr "${nic_mac}" nud permanent \
    dev "${nic_if}"

  # Wait for GID table
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

  # Library path: unified rdma-core install
  local lib_path
  lib_path="${BUILD_DIR}/_deps/rdma-core"
  lib_path="${lib_path}/install/lib"
  lib_path="${lib_path}:/opt/rocm/lib"

  local bin="${BUILD_DIR}/tests/unit/rdma-ep"
  bin="${bin}/test-rdma-loopback"

  echo ""
  echo "=== ${vendor^^} RDMA loopback sweep ==="
  echo "  size=${TEST_SIZE}" \
       " seed=${TEST_SEED}" \
       " iters=${ITERATIONS}"
  echo ""

  local mismatches=0
  local -a times=()

  for i in $(seq 1 "${ITERATIONS}"); do
    local seed=$((TEST_SEED + i - 1))
    local log
    log=$(mktemp /tmp/rdma-lb-XXXXXX.log)

    local rc=0
    # shellcheck disable=SC2086
    sudo env LD_LIBRARY_PATH="${lib_path}" \
      "${bin}" \
      ${provider_flag} \
      --size "${TEST_SIZE}" \
      --seed "${seed}" \
      > "${log}" 2>&1 || rc=$?

    if [ "${rc}" -ne 0 ]; then
      mismatches=$((mismatches + 1))
      printf "  [%3d] seed=%-6u" \
             "${i}" "${seed}"
      printf "  LFSR = FAIL  (rc=%d)\n" "${rc}"
      cat "${log}"
    else
      local us
      us=$(grep -oP 'completed: \K[0-9.]+' \
           "${log}" || echo "0")
      times+=("${us}")
      printf "  [%3d] seed=%-6u" \
             "${i}" "${seed}"
      printf "  LFSR = PASS  %s us\n" "${us}"
    fi
    rm -f "${log}"
  done

  echo ""

  if [ ${#times[@]} -eq 0 ]; then
    echo "  No successful iterations."
    return 1
  fi

  local min max mean std
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
        var  = (n>1) ? (s2/n - mean*mean) : 0
        if (var < 0) var = 0
        printf "%.1f %.1f %.1f %.1f", \
               min, max, mean, sqrt(var)
      }
    '
  )

  echo "--- ${vendor^^} Timing (us)" \
       "over ${#times[@]} runs ---"
  printf "  min=%-10s  max=%-10s\n" \
         "${min}" "${max}"
  printf "  mean=%-9s  std=%-10s\n" \
         "${mean}" "${std}"

  if [ "${mismatches}" -gt 0 ]; then
    echo ""
    echo "${vendor^^} FAILED:" \
         "${mismatches}/${ITERATIONS}" \
         "iterations had data mismatches."
    total_fail=1
  else
    echo ""
    echo "${vendor^^} PASSED:" \
         "all ${ITERATIONS} iterations OK."
  fi

  return ${total_fail}
}

# --- Build phase ---
if [ "${BUILD_ALL}" = "true" ]; then
  cmake -S . -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="/opt/rocm-xio-${SHA}" \
    -DGDA_BNXT=ON -DGDA_IONIC=ON \
    -DBUILD_TESTING=ON --fresh

  cmake --build "${BUILD_DIR}" \
    --target test-rdma-loopback \
    --target install-rdma-core \
    --parallel
else
  cmake --build "${BUILD_DIR}" \
    --target test-rdma-loopback 2>/dev/null \
    || true
fi

# --- Test phase ---
overall_rc=0
vendors=()

case "${VENDOR}" in
  all)
    vendors=(bnxt ionic)
    ;;
  bnxt|ionic)
    vendors=("${VENDOR}")
    ;;
  *)
    echo "ERROR: VENDOR must be" \
         "bnxt, ionic, or all"
    exit 1
    ;;
esac

for v in "${vendors[@]}"; do
  if ! run_vendor_test "${v}"; then
    overall_rc=1
  fi
done

echo ""
echo "====================================="
if [ "${overall_rc}" -eq 0 ]; then
  echo "  ALL VENDORS PASSED"
else
  echo "  SOME VENDORS FAILED"
fi
echo "====================================="

exit ${overall_rc}
