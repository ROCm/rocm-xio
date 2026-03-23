#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Setup DKMS tree for rocm_ernic_eth + rocm_ernic_rdma
# (rocm-xio).
#
# Unlike the ionic setup which downloads kernel source,
# this script copies source directly from the rocm-ernic
# project tree (../rocm-ernic by default, relative to
# rocm-xio root).
#
# 1. Copies driver source from ERNIC_DIR/driver/
# 2. Copies ABI and DV UAPI headers to include/rdma/
# 3. Injects rocm-xio modinfo into rocm_ernic_main.c
# 4. Populates /usr/src/rocm-xio-ernic-eth-rdma-<ver>/
# 5. Registers and builds with DKMS.
#
# Usage:
#   setup-rocm-ernic-eth-rdma-dkms.sh [OPTIONS]
#
# Options:
#   --ernic-dir DIR   Path to rocm-ernic project
#                     (default: auto-detect)
#   --version VER     DKMS package version
#                     (default: 0.1.0-g<shortrev>)
#   --build-only      Build but do not install
#   --uninstall       Remove the DKMS module

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
XIO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PKG_NAME="rocm-xio-ernic-eth-rdma"
BASE_VERSION="0.1.0"
ERNIC_DIR=""
PKG_VERSION=""
BUILD_ONLY=false
UNINSTALL=false

# -------------------------------------------------------
# Argument parsing
# -------------------------------------------------------

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

# Auto-detect driver source: prefer in-tree copy,
# fall back to external rocm-ernic project.
INTREE_DRV="${SCRIPT_DIR}/driver"
if [ -z "${ERNIC_DIR}" ]; then
  if [ -d "${INTREE_DRV}" ] && \
     [ -f "${INTREE_DRV}/rocm_ernic_main.c" ]; then
    ERNIC_DIR="${XIO_ROOT}"
    ERNIC_DRV_DIR="${INTREE_DRV}"
    echo "Using in-tree driver source:" \
      "${INTREE_DRV}"
  else
    ERNIC_DIR="$(cd "${XIO_ROOT}/.." \
      && pwd)/rocm-ernic"
    ERNIC_DRV_DIR="${ERNIC_DIR}/driver"
  fi
else
  ERNIC_DRV_DIR="${ERNIC_DIR}/driver"
fi

# GIT_REV: use rocm-xio rev for in-tree source,
# rocm-ernic rev for external source.
GIT_REV="$(git -C "${ERNIC_DIR}" \
  rev-parse --short HEAD 2>/dev/null \
  || echo "unknown")"

if [ -z "${PKG_VERSION}" ]; then
  PKG_VERSION="${BASE_VERSION}-g${GIT_REV}"
fi

DKMS_SRC="/usr/src/${PKG_NAME}-${PKG_VERSION}"

# -------------------------------------------------------
# Uninstall
# -------------------------------------------------------

if $UNINSTALL; then
  echo "Removing DKMS module" \
    "${PKG_NAME}/${PKG_VERSION}..."
  sudo dkms remove \
    "${PKG_NAME}/${PKG_VERSION}" \
    --all 2>/dev/null || true
  sudo rm -rf "${DKMS_SRC}"
  echo "Done."
  exit 0
fi

# -------------------------------------------------------
# Prerequisites
# -------------------------------------------------------

PATCHES_DIR="${SCRIPT_DIR}/patches"

check_prereqs() {
  local missing=()
  command -v dkms &>/dev/null \
    || missing+=("dkms")
  command -v make &>/dev/null \
    || missing+=("make")
  command -v patch &>/dev/null \
    || missing+=("patch")

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
  if [ ! -f \
    "/lib/modules/${kver}/build/Makefile" ]; then
    echo "ERROR: Kernel headers not found" \
      "for ${kver}."
    echo "Install with:"
    echo "  sudo apt install" \
      "linux-headers-${kver}"
    exit 1
  fi
}

check_prereqs

# -------------------------------------------------------
# Print status
# -------------------------------------------------------

echo ""
echo "=== setup-rocm-ernic-eth-rdma-dkms ==="
echo "  ernic dir   : ${ERNIC_DIR}"
echo "  driver dir  : ${ERNIC_DRV_DIR}"
echo "  DKMS src    : ${DKMS_SRC}"
echo "  package     :" \
  "${PKG_NAME}/${PKG_VERSION}"
echo ""

# -------------------------------------------------------
# Skip if already installed
# -------------------------------------------------------

if ! $BUILD_ONLY && \
    dkms status \
    "${PKG_NAME}/${PKG_VERSION}" \
    2>/dev/null | grep -q "installed"; then
  echo "${PKG_NAME}/${PKG_VERSION}" \
    "already installed."
  echo "Use --uninstall to remove first."
  exit 0
fi

# -------------------------------------------------------
# Populate DKMS source tree
# -------------------------------------------------------

populate_dkms() {
  echo "Installing source to ${DKMS_SRC}..."
  sudo rm -rf "${DKMS_SRC}"
  sudo mkdir -p "${DKMS_SRC}/include/rdma"

  # Driver source (.c and .h)
  sudo cp -a "${ERNIC_DRV_DIR}/"*.c \
    "${DKMS_SRC}/" 2>/dev/null || true
  sudo cp -a "${ERNIC_DRV_DIR}/"*.h \
    "${DKMS_SRC}/" 2>/dev/null || true

  # ABI header at include/rdma/
  if [ -f "${ERNIC_DRV_DIR}/rocm_ernic-abi.h" ]; then
    sudo cp "${ERNIC_DRV_DIR}/rocm_ernic-abi.h" \
      "${DKMS_SRC}/include/rdma/"
  fi

  # DV UAPI header at include/rdma/
  if [ -f "${ERNIC_DRV_DIR}/rocm_ernic_dv_uapi.h" ]; then
    sudo cp "${ERNIC_DRV_DIR}/rocm_ernic_dv_uapi.h" \
      "${DKMS_SRC}/include/rdma/"
  fi

  # Record rocm-ernic git SHA
  echo "${GIT_REV}" | sudo tee \
    "${DKMS_SRC}/SOURCE_SHA" >/dev/null

  # Inject rocm-xio modinfo (like ionic does)
  local modinfo_block
  modinfo_block=$(
    printf '\n\n/* rocm-xio project metadata (injected at build) */\n'
    printf 'MODULE_VERSION("%s");\n' "${PKG_VERSION}"
    printf 'MODULE_INFO(project, "rocm-xio");\n'
    printf 'MODULE_INFO(project_pkg, "%s");\n' "${PKG_NAME}"
  )
  for f in rocm_ernic_main.c rocm_ernic_eth.c; do
    local p="${DKMS_SRC}/${f}"
    if [ -f "${p}" ]; then
      echo "${modinfo_block}" | sudo tee -a "${p}" >/dev/null
    fi
  done

  # Build files
  sudo cp "${SCRIPT_DIR}/Makefile" "${DKMS_SRC}/"
  sudo cp "${SCRIPT_DIR}/dkms.conf" "${DKMS_SRC}/"
  sudo sed -i \
    "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"${PKG_VERSION}\"/" \
    "${DKMS_SRC}/dkms.conf"

  echo "Source tree populated."
}

populate_dkms

# -------------------------------------------------------
# Apply vendored patches (rocm-xio additions)
# -------------------------------------------------------

apply_patches() {
  if [ ! -d "${PATCHES_DIR}" ] || \
     [ -z "$(ls -A "${PATCHES_DIR}"/*.patch \
       2>/dev/null)" ]; then
    echo "No patches to apply."
    return
  fi

  echo ""
  echo "Applying vendored patches..."

  local applied=0
  local failed=0
  for p in "${PATCHES_DIR}"/*.patch; do
    local name
    name=$(basename "${p}" .patch)

    local out
    out=$(sudo patch -d "${DKMS_SRC}" \
      -p1 --fuzz=3 --force \
      --no-backup-if-mismatch \
      < "${p}" 2>&1 || true)
    local n_ok
    n_ok=$(echo "${out}" \
      | grep -c "^patching file" || true)
    local n_fail
    n_fail=$(echo "${out}" \
      | grep -c "FAILED" || true)

    if [ "${n_fail}" -gt 0 ]; then
      failed=$((failed + 1))
      echo "  PARTIAL: ${name}" \
        "(${n_ok} ok, ${n_fail} failed)"
    elif [ "${n_ok}" -gt 0 ]; then
      applied=$((applied + 1))
      echo "  OK: ${name} (${n_ok} files)"
    else
      echo "  SKIP: ${name}" \
        "(already applied or no match)"
    fi
  done

  echo "${applied} applied," \
    "${failed} failed."
}

apply_patches

# -------------------------------------------------------
# Register and build with DKMS
# -------------------------------------------------------

build_dkms() {
  echo ""

  if dkms status \
      "${PKG_NAME}/${PKG_VERSION}" \
      2>/dev/null | grep -q .; then
    echo "Removing stale DKMS registration..."
    sudo dkms remove \
      "${PKG_NAME}/${PKG_VERSION}" \
      --all 2>/dev/null || true
  fi

  echo "Registering with DKMS..."
  sudo dkms add "${PKG_NAME}/${PKG_VERSION}"

  local kver
  kver="$(uname -r)"

  echo "Building rocm_ernic_eth + rocm_ernic_rdma" \
    "for ${kver}..."
  if ! sudo dkms build \
      "${PKG_NAME}/${PKG_VERSION}" \
      -k "${kver}"; then
    echo ""
    echo "ERROR: DKMS build failed."
    echo "Check: /var/lib/dkms/${PKG_NAME}/" \
      "${PKG_VERSION}/build/make.log"
    exit 1
  fi

  echo ""
  echo "=== rocm_ernic eth+RDMA built via DKMS ==="
  echo "  Module: /var/lib/dkms/${PKG_NAME}/" \
    "${PKG_VERSION}/${kver}/$(uname -m)/module/"
  echo ""
  echo "To install:"
  echo "  $0  (re-run without --build-only)"
}

install_dkms() {
  local kver
  kver="$(uname -r)"

  echo "Installing rocm_ernic_eth + rocm_ernic_rdma..."
  sudo dkms install \
    "${PKG_NAME}/${PKG_VERSION}" -k "${kver}"

  echo ""
  echo "=== rocm_ernic eth+RDMA installed via DKMS ==="
  echo ""
  echo "DKMS will rebuild on kernel upgrades."
  echo ""
  echo "To load now:"
  echo "  sudo modprobe rocm_ernic_eth"
  echo "  sudo modprobe rocm_ernic_rdma"
  echo ""
  echo "To unload (reverse order):"
  echo "  sudo modprobe -r rocm_ernic_rdma"
  echo "  sudo modprobe -r rocm_ernic_eth"
  echo ""
  echo "To revert:"
  echo "  $0 --uninstall"
  echo "  sudo depmod -a"
}

build_dkms
if ! $BUILD_ONLY; then
  install_dkms
fi
