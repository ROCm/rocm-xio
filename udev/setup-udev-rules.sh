#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Install or remove rocm-xio udev rules and
# systemd .link files for NIC naming.
#
# Usage:
#   sudo ./udev/setup-udev-rules.sh --install
#   sudo ./udev/setup-udev-rules.sh --uninstall

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" \
  && pwd)"
UDEV_DEST="/etc/udev/rules.d"
LINK_DEST="/etc/systemd/network"

RULES=(
  "99-rocm-xio-rdma.rules"
  "99-rocm-xio-vfio.rules"
  "99-rocm-xio-nvme.rules"
)

LINK_FILES=(
  "10-rocm-xio-bnxt.link"
  "10-rocm-xio-ionic.link"
  "10-rocm-xio-mlx5.link"
  "10-rocm-xio-ernic.link"
)

usage() {
  cat <<EOF
Usage: $(basename "$0") [--install | --uninstall]

  --install    Copy udev rules to ${UDEV_DEST}
               and .link files to ${LINK_DEST},
               then reload udevd.
  --uninstall  Remove installed rules and .link
               files, then reload udevd.
  --help       Show this message.
EOF
  exit "${1:-0}"
}

check_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "ERROR: must be run as root (use sudo)"
    exit 1
  fi
}

do_install() {
  check_root
  echo "Installing rocm-xio udev rules..."
  echo ""

  for rule in "${RULES[@]}"; do
    local src="${SCRIPT_DIR}/${rule}"
    if [ ! -f "${src}" ]; then
      echo "  SKIP  ${rule} (not found)"
      continue
    fi
    cp "${src}" "${UDEV_DEST}/${rule}"
    echo "  OK    ${UDEV_DEST}/${rule}"
  done

  echo ""
  echo "Installing systemd .link files..."
  echo ""
  mkdir -p "${LINK_DEST}"

  for lf in "${LINK_FILES[@]}"; do
    local src="${SCRIPT_DIR}/${lf}"
    if [ ! -f "${src}" ]; then
      echo "  SKIP  ${lf} (not found)"
      continue
    fi
    cp "${src}" "${LINK_DEST}/${lf}"
    echo "  OK    ${LINK_DEST}/${lf}"
  done

  echo ""
  echo "Reloading udev rules..."
  udevadm control --reload-rules
  udevadm trigger
  echo "Done."
}

do_uninstall() {
  check_root
  echo "Removing rocm-xio udev rules..."
  echo ""

  for rule in "${RULES[@]}"; do
    local dst="${UDEV_DEST}/${rule}"
    if [ -f "${dst}" ]; then
      rm -f "${dst}"
      echo "  OK    removed ${dst}"
    else
      echo "  SKIP  ${dst} (not present)"
    fi
  done

  echo ""
  echo "Removing systemd .link files..."
  echo ""

  for lf in "${LINK_FILES[@]}"; do
    local dst="${LINK_DEST}/${lf}"
    if [ -f "${dst}" ]; then
      rm -f "${dst}"
      echo "  OK    removed ${dst}"
    else
      echo "  SKIP  ${dst} (not present)"
    fi
  done

  echo ""
  echo "Reloading udev rules..."
  udevadm control --reload-rules
  udevadm trigger
  echo "Done."
}

if [ $# -eq 0 ]; then
  usage 1
fi

case "$1" in
  --install)
    do_install
    ;;
  --uninstall)
    do_uninstall
    ;;
  --help|-h)
    usage 0
    ;;
  *)
    echo "ERROR: unknown option: $1"
    usage 1
    ;;
esac
