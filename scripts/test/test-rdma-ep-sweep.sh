#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# RDMA loopback test runner.
# Delegates hardware setup to the CTest fixture
# (scripts/test/setup-rdma-loopback.sh) and test
# execution to ctest --preset sweep.
#
# This script adds:
#   - Optional build step (BUILD_ALL=true)
#   - Optional rocprofv3 GPU kernel profiling
#   - Timing statistics (min/max/mean/std)
#
# Usage:
#   ./test-rdma-ep-sweep.sh
#   BUILD_ALL=true ./test-rdma-ep-sweep.sh
#   VENDOR=mlx5 ./test-rdma-ep-sweep.sh
#   PROFILE=1 VENDOR=ionic ./test-rdma-ep-sweep.sh
#
# For a quick CTest-only run without this wrapper:
#   ctest --test-dir build --preset sweep
#   ctest --test-dir build -L hardware

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BUILD_DIR=${BUILD_DIR:-${REPO_ROOT}/build}
BUILD_ALL=${BUILD_ALL:-false}
VENDOR=${VENDOR:-all}
PROFILE=${PROFILE:-0}
PROFILE_DIR=${PROFILE_DIR:-/tmp/rocprof-out}
ITERATIONS=${ITERATIONS:-10}
TEST_SIZE=${TEST_SIZE:-256}
TEST_SEED=${TEST_SEED:-1}

SHA=$(git rev-parse --short HEAD 2>/dev/null \
  || echo "dev")

# --- Build phase ---
if [ "${BUILD_ALL}" = "true" ]; then
  cmake -S . -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="/opt/rocm-xio-${SHA}" \
    -DGDA_BNXT=ON -DGDA_MLX5=ON -DGDA_IONIC=ON \
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

# --- Hardware setup ---
echo ""
echo "====================================="
echo "  Running hardware setup fixture"
echo "====================================="
sudo VENDOR="${VENDOR}" \
  "${SCRIPT_DIR}/setup-rdma-loopback.sh"

# --- Test phase ---
run_sweep() {
  local vendor="$1"
  local provider_flag="--provider ${vendor}"
  local rdma_dev

  case "${vendor}" in
    bnxt)
      rdma_dev="${BNXT_RDMA_DEV:-rocm-rdma-bnxt0}"
      provider_flag="${provider_flag} --device"
      provider_flag="${provider_flag} ${rdma_dev}"
      ;;
    mlx5)
      rdma_dev="${MLX5_RDMA_DEV:-rocm-rdma-mlx5-0}"
      provider_flag="${provider_flag} --device"
      provider_flag="${provider_flag} ${rdma_dev}"
      ;;
    ionic)
      rdma_dev="${IONIC_RDMA_DEV:-rocm-rdma-ionic0}"
      provider_flag="${provider_flag} --device"
      provider_flag="${provider_flag} ${rdma_dev}"
      ;;
  esac

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
    local prof_prefix=""
    if [ "${PROFILE}" = "1" ]; then
      mkdir -p "${PROFILE_DIR}"
      prof_prefix="rocprofv3 --kernel-trace"
      prof_prefix="${prof_prefix} -d"
      prof_prefix="${prof_prefix} ${PROFILE_DIR}"
      prof_prefix="${prof_prefix} -f csv"
      prof_prefix="${prof_prefix} --"
    fi
    # shellcheck disable=SC2086
    # shellcheck disable=SC2024
    sudo env LD_LIBRARY_PATH="${lib_path}" \
      ${prof_prefix} \
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
  # shellcheck disable=SC2046
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
    return 1
  fi

  echo ""
  echo "${vendor^^} PASSED:" \
       "all ${ITERATIONS} iterations OK."

  if [ "${PROFILE}" = "1" ]; then
    echo ""
    echo "Kernel traces: ${PROFILE_DIR}/"
    ls "${PROFILE_DIR}"/*.csv 2>/dev/null \
      | head -5
  fi

  return 0
}

# --- Run vendors ---
overall_rc=0
vendors=()

case "${VENDOR}" in
  all)
    vendors=(bnxt mlx5 ionic)
    ;;
  bnxt|mlx5|ionic)
    vendors=("${VENDOR}")
    ;;
  *)
    echo "ERROR: VENDOR must be" \
         "bnxt, mlx5, ionic, or all"
    exit 1
    ;;
esac

for v in "${vendors[@]}"; do
  if ! run_sweep "${v}"; then
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
