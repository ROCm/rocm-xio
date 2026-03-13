#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Setup DKMS tree for rocm_ernic with Direct Verbs
# extensions.
#
# Unlike the BNXT setup script which downloads source
# from kernel.org, this script copies source directly
# from the rocm-ernic project tree (../rocm-ernic by
# default, relative to the rocm-xio root).
#
# 1. Copies the driver source from the rocm-ernic
#    project tree.
# 2. Copies our DV Makefile and dkms.conf into
#    /usr/src/rocm-ernic-dv-<ver>/.
# 3. Registers and builds with DKMS.
#
# Usage:
#   setup-rocm-ernic-dv-dkms.sh [OPTIONS]
#
# Options:
#   --ernic-dir DIR   Path to rocm-ernic project
#                     (default: auto-detect relative
#                     to rocm-xio)
#   --version VER     DKMS package version
#                     (default: 0.1)
#   --build-only      Build but do not install
#   --uninstall       Remove the DKMS module and exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
XIO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PKG_NAME="rocm-ernic-dv"
PKG_VERSION="0.1"
ERNIC_DIR=""
BUILD_ONLY=false
UNINSTALL=false

# -----------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ernic-dir)
      ERNIC_DIR="$2"; shift 2 ;;
    --version)
      PKG_VERSION="$2"; shift 2 ;;
    --build-only)
      BUILD_ONLY=true; shift ;;
    --uninstall)
      UNINSTALL=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--ernic-dir DIR]" \
        "[--version VER]" \
        "[--build-only] [--uninstall]"
      exit 0 ;;
    *)
      echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Auto-detect rocm-ernic directory
if [ -z "${ERNIC_DIR}" ]; then
  ERNIC_DIR="$(cd "${XIO_ROOT}/.." && pwd)/rocm-ernic"
fi

ERNIC_DRV_DIR="${ERNIC_DIR}/driver"
DKMS_SRC="/usr/src/${PKG_NAME}-${PKG_VERSION}"

# -----------------------------------------------------------
# Uninstall
# -----------------------------------------------------------

if $UNINSTALL; then
  echo "Removing DKMS module" \
    "${PKG_NAME}/${PKG_VERSION}..."
  sudo dkms remove "${PKG_NAME}/${PKG_VERSION}" \
    --all 2>/dev/null || true
  sudo rm -rf "${DKMS_SRC}"
  echo "Done."
  exit 0
fi

# -----------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------

check_prereqs() {
  local missing=()
  command -v dkms &>/dev/null || missing+=("dkms")
  command -v make &>/dev/null || missing+=("make")

  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing required tools:" \
      "${missing[*]}"
    echo "Install with:"
    echo "  sudo apt install ${missing[*]}"
    exit 1
  fi

  if [ ! -d "${ERNIC_DRV_DIR}" ]; then
    echo "ERROR: rocm-ernic driver source not" \
      "found at ${ERNIC_DRV_DIR}"
    echo "Set --ernic-dir to the rocm-ernic" \
      "project root."
    exit 1
  fi

  if [ ! -f "${ERNIC_DRV_DIR}/rocm_ernic_main.c" ]
  then
    echo "ERROR: rocm_ernic_main.c not found in" \
      "${ERNIC_DRV_DIR}"
    exit 1
  fi

  local kver
  kver="$(uname -r)"
  if [ ! -f "/lib/modules/${kver}/build/Makefile" ]
  then
    echo "ERROR: Kernel headers not found for" \
      "${kver}."
    echo "Install with:"
    echo "  sudo apt install" \
      "linux-headers-${kver}"
    exit 1
  fi
}

check_prereqs

echo ""
echo "=== setup-rocm-ernic-dv-dkms ==="
echo "  ernic dir   : ${ERNIC_DIR}"
echo "  driver dir  : ${ERNIC_DRV_DIR}"
echo "  DKMS src    : ${DKMS_SRC}"
echo "  package     : ${PKG_NAME}/${PKG_VERSION}"
echo ""

# -----------------------------------------------------------
# Skip if already installed
# -----------------------------------------------------------

if ! $BUILD_ONLY && \
    dkms status "${PKG_NAME}/${PKG_VERSION}" \
    2>/dev/null | grep -q "installed"; then
  echo "${PKG_NAME}/${PKG_VERSION} already installed."
  echo "Use --uninstall to remove first."
  exit 0
fi

# -----------------------------------------------------------
# Populate DKMS source tree
# -----------------------------------------------------------

populate_dkms() {
  echo "Installing source to ${DKMS_SRC}..."
  sudo mkdir -p "${DKMS_SRC}/include/rdma"

  # Driver source (.c and .h)
  sudo cp -a "${ERNIC_DRV_DIR}/"*.c "${DKMS_SRC}/"
  sudo cp -a "${ERNIC_DRV_DIR}/"*.h "${DKMS_SRC}/"

  # ABI header at include/rdma/ so the patched
  # version is found before any stock header.
  if [ -f "${ERNIC_DRV_DIR}/rocm_ernic-abi.h" ]; then
    sudo cp -a \
      "${ERNIC_DRV_DIR}/rocm_ernic-abi.h" \
      "${DKMS_SRC}/include/rdma/"
  fi

  # Our DV Makefile and dkms.conf
  sudo cp "${SCRIPT_DIR}/Makefile" "${DKMS_SRC}/"
  sudo cp "${SCRIPT_DIR}/dkms.conf" "${DKMS_SRC}/"

  echo "Source tree populated."
}

populate_dkms

# -----------------------------------------------------------
# Register and build with DKMS
# -----------------------------------------------------------

build_dkms() {
  echo ""

  # Remove stale registration if present
  if dkms status "${PKG_NAME}/${PKG_VERSION}" \
      2>/dev/null | grep -q .; then
    echo "Removing stale DKMS registration..."
    sudo dkms remove "${PKG_NAME}/${PKG_VERSION}" \
      --all 2>/dev/null || true
  fi

  echo "Registering with DKMS..."
  sudo dkms add "${PKG_NAME}/${PKG_VERSION}"

  local kver
  kver="$(uname -r)"

  echo "Building rocm_ernic.ko for ${kver}..."
  if ! sudo dkms build \
      "${PKG_NAME}/${PKG_VERSION}" -k "${kver}"; then
    echo ""
    echo "ERROR: DKMS build failed."
    echo "Check: /var/lib/dkms/${PKG_NAME}/" \
      "${PKG_VERSION}/build/make.log"
    exit 1
  fi

  echo ""
  echo "=== rocm_ernic (DV) built via DKMS ==="
  echo "  Module: /var/lib/dkms/${PKG_NAME}/" \
    "${PKG_VERSION}/${kver}/$(uname -m)/module/"
  echo ""
  echo "To install:"
  echo "  $0 # (re-run without --build-only)"
}

install_dkms() {
  local kver
  kver="$(uname -r)"

  echo "Installing rocm_ernic.ko..."
  sudo dkms install \
    "${PKG_NAME}/${PKG_VERSION}" -k "${kver}"

  echo ""
  echo "=== rocm_ernic (DV) installed via DKMS ==="
  echo ""
  echo "The stock rocm_ernic module is overridden."
  echo "DKMS will rebuild on kernel upgrades."
  echo ""
  echo "To load now:"
  echo "  sudo modprobe -r rocm_ernic 2>/dev/null"
  echo "  sudo modprobe rocm_ernic"
  echo ""
  echo "To revert to stock:"
  echo "  $0 --uninstall"
  echo "  sudo depmod -a"
  echo "  sudo modprobe rocm_ernic"
}

build_dkms
if ! $BUILD_ONLY; then
  install_dkms
fi
