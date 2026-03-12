#!/bin/bash

set -euo pipefail

cmake --build build --target test-rdma-bnxt-loopback --parallel

TEST_SIZE=${TEST_SIZE:-256}
TEST_SEED=${TEST_SEED:-1}
ITERATIONS=${ITERATIONS:-10}
BUILD_DIR=${BUILD_DIR:-./build}

LIB_PATH="${BUILD_DIR}/_deps/bnxt-dv/rdma-core-install/lib"
BIN="${BUILD_DIR}/tests/unit/rdma-ep/test-rdma-bnxt-loopback"

echo "=== RDMA loopback sweep ==="
echo "  size=${TEST_SIZE}  seed=${TEST_SEED}" \
     " iters=${ITERATIONS}"
echo ""

mismatches=0
declare -a times

for i in $(seq 1 "${ITERATIONS}"); do
  seed=$((TEST_SEED + i - 1))
  log=$(mktemp /tmp/rdma-lb-XXXXXX.log)

  rc=0
  sudo LD_LIBRARY_PATH="${LIB_PATH}" \
    "${BIN}" --size "${TEST_SIZE}" \
    --seed "${seed}" > "${log}" 2>&1 || rc=$?

  if [ "${rc}" -ne 0 ]; then
    mismatches=$((mismatches + 1))
    printf "  [%3d] seed=%-6u  FAIL (rc=%d)\n" \
           "${i}" "${seed}" "${rc}"
    cat "${log}"
  else
    us=$(grep -oP 'completed: \K[0-9.]+' \
         "${log}" || echo "0")
    times+=("${us}")
    printf "  [%3d] seed=%-6u  %s us\n" \
           "${i}" "${seed}" "${us}"
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
