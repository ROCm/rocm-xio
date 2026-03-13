#!/bin/bash

set -euo pipefail


TEST_SIZE=${TEST_SIZE:-256}
TEST_SEED=${TEST_SEED:-1}
ITERATIONS=${ITERATIONS:-10}
BUILD_DIR=${BUILD_DIR:-./build-dv}
NIC_IF=${NIC_IF:-enp195s0f0np0}
NIC_IP=${NIC_IP:-198.18.0.1/24}
BUILD_ALL=${BUILD_ALL:-false}

SHA=$(git rev-parse --short HEAD)

# Discover the NIC MAC for the static neighbor entry
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
  -DGDA_BNXT=ON -DGDA_ERNIC=ON \
  -DBNXT_DV_BUILD_KMOD=ON \
  -DBUILD_TESTING=ON --fresh

cmake --build "${BUILD_DIR}" \
  --target test-rdma-bnxt-loopback \
  --target build-bnxt-dv-dkms \
  --target install-bnxt-dv-rdma-core \
  --parallel

sudo cmake --build "${BUILD_DIR}" \
  --target install-bnxt-dv-dkms

sleep 1
sudo modprobe -r bnxt_re
sleep 3
sudo modprobe bnxt_re
sleep 5

else

cmake --build "${BUILD_DIR}" \
  --target test-rdma-bnxt-loopback

fi

# Ensure IP and static neighbor are configured.
# These are lost after module reloads / reboots.
if ! ip addr show "${NIC_IF}" \
    | grep -q "${IP_BARE}"; then
  echo "Adding ${NIC_IP} to ${NIC_IF}..."
  sudo ip addr add "${NIC_IP}" dev "${NIC_IF}"
fi
sudo ip neigh replace "${IP_BARE}" \
  lladdr "${NIC_MAC}" nud permanent \
  dev "${NIC_IF}"

# Wait for the IPv4-mapped GID to appear.
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

LIB_PATH="${BUILD_DIR}/_deps/bnxt-dv/rdma-core-install/lib"
LIB_PATH="${LIB_PATH}:/opt/rocm/lib"
BIN="${BUILD_DIR}/tests/unit/rdma-ep/test-rdma-bnxt-loopback"

echo "=== RDMA loopback sweep ==="
echo "  size=${TEST_SIZE}  seed=${TEST_SEED}" \
     " iters=${ITERATIONS}"
echo ""

mismatches=0
times=()

for i in $(seq 1 "${ITERATIONS}"); do
  seed=$((TEST_SEED + i - 1))
  log=$(mktemp /tmp/rdma-lb-XXXXXX.log)

  rc=0
  sudo env LD_LIBRARY_PATH="${LIB_PATH}" \
    "${BIN}" --size "${TEST_SIZE}" \
    --seed "${seed}" > "${log}" 2>&1 || rc=$?

  if [ "${rc}" -ne 0 ]; then
    mismatches=$((mismatches + 1))
    printf "  [%3d] seed=%-6u  LFSR Check = FAIL" \
           "${i}" "${seed}"
    printf "  (rc=%d)\n" "${rc}"
    cat "${log}"
  else
    us=$(grep -oP 'completed: \K[0-9.]+' \
         "${log}" || echo "0")
    times+=("${us}")
    printf "  [%3d] seed=%-6u  LFSR Check = PASS" \
           "${i}" "${seed}"
    printf "  %s us\n" "${us}"
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
