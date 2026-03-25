#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# CTest fixture setup for RDMA loopback tests.
# Handles module reload, network config, RDMA device
# naming, and GID table readiness.
#
# Intended to run as:
#   sudo scripts/test/setup-rdma-loopback.sh
#
# Supports VENDOR=bnxt|ionic|mlx5|all (default: all).

set -euo pipefail

VENDOR=${VENDOR:-all}

setup_vendor() {
  local vendor="$1"
  local nic_if rdma_dev nic_ip

  case "${vendor}" in
    bnxt)
      nic_if="${BNXT_NIC_IF:-rocm-bnxt0}"
      nic_ip="${BNXT_NIC_IP:-198.18.0.1/24}"
      rdma_dev="${BNXT_RDMA_DEV:-rocm-rdma-bnxt0}"
      ;;
    ionic)
      nic_if="${IONIC_NIC_IF:-rocm-ionic0}"
      nic_ip="${IONIC_NIC_IP:-198.18.1.1/24}"
      rdma_dev="${IONIC_RDMA_DEV:-rocm-rdma-ionic0}"
      ;;
    mlx5)
      nic_if="${MLX5_NIC_IF:-rocm-mlx5-0}"
      nic_ip="${MLX5_NIC_IP:-198.18.2.1/24}"
      rdma_dev="${MLX5_RDMA_DEV:-rocm-rdma-mlx5-0}"
      ;;
    *)
      echo "ERROR: Unknown vendor '${vendor}'"
      return 1
      ;;
  esac

  echo "--- ${vendor^^}: setup ---"

  # Module reload
  case "${vendor}" in
    bnxt)
      modprobe -r bnxt_re 2>/dev/null || true
      sleep 3
      modprobe bnxt_re
      sleep 5
      ip link set "${nic_if}" up 2>/dev/null || true
      sleep 3
      ;;
    ionic)
      local pci_bdf
      pci_bdf=$(basename "$(readlink -f \
        "/sys/class/net/${nic_if}/device" \
        2>/dev/null)" 2>/dev/null || true)
      local lb_path="/sys/bus/pci/devices"
      lb_path="${lb_path}/${pci_bdf}/loopback_mode"

      if [ -f "${lb_path}" ]; then
        local cur
        cur=$(cat "${lb_path}")
        if [ "${cur}" != "2" ]; then
          echo "Setting ionic loopback=2 via sysfs..."
          echo 2 > "${lb_path}"
          sleep 2
        fi
      else
        echo "WARN: ${lb_path} not found," \
          "falling back to module reload"
        modprobe -r ionic_rdma 2>/dev/null || true
        modprobe -r ionic 2>/dev/null || true
        sleep 3
        modprobe ionic
        sleep 5
      fi

      ip link set "${nic_if}" up 2>/dev/null || true
      modprobe ionic_rdma 2>/dev/null || true
      sleep 3
      ;;
    mlx5)
      modprobe mlx5_ib 2>/dev/null || true
      ip link set "${nic_if}" up 2>/dev/null || true
      sleep 3
      ;;
  esac

  # RDMA device rename if udev hasn't fired
  if [ ! -d \
    "/sys/class/infiniband/${rdma_dev}" ]; then
    local nic_pci
    nic_pci=$(readlink -f \
      "/sys/class/net/${nic_if}/device" \
      2>/dev/null || true)
    if [ -n "${nic_pci}" ]; then
      local ib_name=""
      local ib
      for ib in /sys/class/infiniband/*; do
        local ib_pci
        ib_pci=$(readlink -f "${ib}/device" \
          2>/dev/null || true)
        if [ "${ib_pci}" = "${nic_pci}" ]; then
          ib_name=$(basename "${ib}")
          break
        fi
      done
      if [ -n "${ib_name}" ]; then
        echo "Renaming '${ib_name}'" \
          "-> '${rdma_dev}'"
        rdma dev set "${ib_name}" \
          name "${rdma_dev}"
        sleep 1
      fi
    fi
  fi

  # MAC address
  local nic_mac
  nic_mac=$(ip link show "${nic_if}" \
    | grep -oP 'link/ether \K[0-9a-f:]+' \
    || echo "")
  if [ -z "${nic_mac}" ]; then
    echo "WARN: cannot read MAC from ${nic_if}"
    return 0
  fi

  local ip_bare="${nic_ip%%/*}"

  # IP and static neighbor
  if ! ip addr show "${nic_if}" \
      | grep -q "${ip_bare}"; then
    echo "Adding ${nic_ip} to ${nic_if}..."
    ip addr add "${nic_ip}" \
      dev "${nic_if}" 2>/dev/null || true
  fi
  ip neigh replace "${ip_bare}" \
    lladdr "${nic_mac}" nud permanent \
    dev "${nic_if}"

  # Wait for GID table
  echo -n "Checking GID table... "
  for attempt in $(seq 1 10); do
    if grep -q 'ffff' \
      /sys/class/infiniband/*/ports/1/gids/* \
      2>/dev/null; then
      echo "ready."
      return 0
    fi
    if [ "${attempt}" -eq 1 ]; then
      echo ""
      echo -n "  waiting"
    fi
    echo -n "."
    sleep 2
  done
  echo " timeout (may still work)."
}

# --- Main ---
vendors=()
case "${VENDOR}" in
  all)   vendors=(bnxt ionic mlx5) ;;
  bnxt)  vendors=(bnxt) ;;
  ionic) vendors=(ionic) ;;
  mlx5)  vendors=(mlx5) ;;
  *)
    echo "ERROR: VENDOR must be" \
      "bnxt, ionic, mlx5, or all"
    exit 1
    ;;
esac

for v in "${vendors[@]}"; do
  setup_vendor "${v}" || true
done

echo "RDMA hardware setup complete."
