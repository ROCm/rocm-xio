#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Install or remove rocm-xio udev rules.
#
# Usage:
#   sudo ./udev/setup-udev-rules.sh --install
#   sudo ./udev/setup-udev-rules.sh --uninstall

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" \
  && pwd)"
DEST="/etc/udev/rules.d"

RULES=(
  "99-rocm-xio-char.rules"
  "99-rocm-xio-rdma.rules"
  "99-rocm-xio-vfio.rules"
  "99-rocm-xio-nvme.rules"
)

usage() {
  cat <<EOF
Usage: $(basename "$0") [--install | --uninstall]

  --install    Copy udev rules to ${DEST}
               and reload udevd.
  --uninstall  Remove installed rules from
               ${DEST} and reload udevd.
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
    cp "${src}" "${DEST}/${rule}"
    echo "  OK    ${DEST}/${rule}"
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
    local dst="${DEST}/${rule}"
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
