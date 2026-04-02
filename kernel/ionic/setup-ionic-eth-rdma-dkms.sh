#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Setup DKMS tree for ionic + ionic_rdma
# (rocm-xio).
#
# 1. Downloads the ionic ethernet driver source
#    from kernel.googlesource.com (cached).
# 2. Applies the vendored v6 RDMA patch series
#    (14 plain .patch files in patches/).
# 3. Copies patched source + Makefile + dkms.conf
#    into /usr/src/rocm-xio-ionic-eth-rdma-<ver>/.
# 4. Registers and builds with DKMS.
#
# The patches originate from the v6 ionic RDMA
# kernel submission (Sept 2025) and were decoded
# from the patchew mbox into plain unified diffs.
#
# Usage:
#   setup-ionic-eth-rdma-dkms.sh [OPTIONS]
#
# Options:
#   --kernel-tag TAG  Upstream kernel tag
#                     (default: auto-detect)
#   --work-dir DIR    Working directory
#                     (default: /tmp/rocm-xio-ionic-eth-rdma-build)
#   --version VER     DKMS package version
#                     (default: 1.0.0-g<shortrev>)
#   --build-only      Build but do not install
#   --uninstall       Remove the DKMS module

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_NAME="rocm-xio-ionic-eth-rdma"
BASE_VERSION="0.1.0"
GIT_REV="$(git -C "$(dirname "$0")" \
  rev-parse --short HEAD 2>/dev/null || echo "unknown")"
PKG_VERSION="${BASE_VERSION}-g${GIT_REV}"
KERNEL_TAG=""
WORK_DIR="/tmp/rocm-xio-ionic-eth-rdma-build"
BUILD_ONLY=false
UNINSTALL=false

# googlesource per-directory tarballs
GS_BASE="https://kernel.googlesource.com"
GS_REPO="${GS_BASE}/pub/scm/linux/kernel/git"
GS_REPO="${GS_REPO}/torvalds/linux/+archive"

PATCHES_DIR="${SCRIPT_DIR}/patches"

# kernel tree paths
ETH_PATH="drivers/net/ethernet/pensando/ionic"
RDMA_PATH="drivers/infiniband/hw/ionic"

# -------------------------------------------------------
# Argument parsing
# -------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kernel-tag)
      KERNEL_TAG="$2"; shift 2 ;;
    --work-dir)
      WORK_DIR="$2"; shift 2 ;;
    --version)
      PKG_VERSION="$2"; shift 2 ;;
    --build-only)
      BUILD_ONLY=true; shift ;;
    --uninstall)
      UNINSTALL=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--kernel-tag vX.Y]" \
        "[--work-dir DIR] [--version VER]" \
        "[--build-only] [--uninstall]"
      exit 0 ;;
    *)
      echo "Unknown option: $1"; exit 1 ;;
  esac
done

DKMS_SRC="/usr/src/${PKG_NAME}-${PKG_VERSION}"

# shellcheck source=../dkms-common.sh
. "$(dirname "${SCRIPT_DIR}")/dkms-common.sh"

dkms_uninstall_guard
dkms_check_tools curl dkms make patch
dkms_check_kernel_headers

if [ ! -d "${PATCHES_DIR}" ] || \
   [ -z "$(ls -A "${PATCHES_DIR}"/*.patch \
     2>/dev/null)" ]; then
  echo "ERROR: No patches found in" \
    "${PATCHES_DIR}/"
  exit 1
fi

dkms_detect_kernel_tag

echo ""
echo "=== setup-ionic-eth-rdma-dkms ==="
echo "  kernel tag  : ${KERNEL_TAG}"
echo "  work dir    : ${WORK_DIR}"
echo "  DKMS src    : ${DKMS_SRC}"
echo "  package     :" \
  "${PKG_NAME}/${PKG_VERSION}"
echo ""

dkms_skip_if_installed

# -------------------------------------------------------
# Download kernel source (cached)
# -------------------------------------------------------

DL_DIR="${WORK_DIR}/download"
SRC_DIR="${WORK_DIR}/src"
ETH_DIR="${SRC_DIR}/${ETH_PATH}"
RDMA_DIR="${SRC_DIR}/${RDMA_PATH}"

download_source() {
  local eth_tgz="${DL_DIR}/ionic_eth.tar.gz"

  mkdir -p "${DL_DIR}"

  if [ -f "${eth_tgz}" ]; then
    echo "Using cached download."
    return 0
  fi

  echo "Downloading ionic ethernet source" \
    "(${KERNEL_TAG})..."
  local url="${GS_REPO}/${KERNEL_TAG}"
  url="${url}/${ETH_PATH}.tar.gz"
  if ! curl -sL -f "${url}" \
      -o "${eth_tgz}"; then
    echo "ERROR: Failed to download" \
      "ionic ethernet source."
    echo "  URL: ${url}"
    echo "  Tag ${KERNEL_TAG} may not exist."
    rm -f "${eth_tgz}"
    exit 1
  fi

  echo "Download complete."
}

extract_fresh() {
  echo "Extracting fresh source tree..."
  rm -rf "${SRC_DIR}" 2>/dev/null \
    || sudo rm -rf "${SRC_DIR}"
  mkdir -p "${ETH_DIR}" "${RDMA_DIR}"

  tar xzf "${DL_DIR}/ionic_eth.tar.gz" \
    -C "${ETH_DIR}"

  if [ ! -f "${ETH_DIR}/ionic_main.c" ] && \
     [ ! -f "${ETH_DIR}/ionic_bus_pci.c" ]; then
    echo "ERROR: ionic ethernet source" \
      "incomplete."
    exit 1
  fi
}

download_source
extract_fresh

# -------------------------------------------------------
# Apply vendored patches
# -------------------------------------------------------

apply_patches() {
  cd "${SRC_DIR}"

  echo ""
  echo "Applying vendored patches..."

  local applied=0
  local partial=0
  local skipped=0
  for p in "${PATCHES_DIR}"/*.patch; do
    local name
    name=$(basename "${p}" .patch)

    # Single pass: apply with fuzz, accept
    # partial results, no backup files
    local out
    out=$(patch -p1 --fuzz=3 --force \
      --no-backup-if-mismatch \
      < "${p}" 2>&1 || true)
    local n_ok
    n_ok=$(echo "${out}" \
      | grep -c "^patching file" || true)
    local n_fail
    n_fail=$(echo "${out}" \
      | grep -c "FAILED" || true)

    if [ "${n_ok}" -eq 0 ]; then
      skipped=$((skipped + 1))
      echo "  [SKIP]    ${name}"
    elif [ "${n_fail}" -eq 0 ]; then
      applied=$((applied + 1))
      echo "  [OK]      ${name}"
    else
      partial=$((partial + 1))
      echo "  [PARTIAL] ${name}" \
        "(${n_ok} ok, ${n_fail} failed)"
    fi
  done

  # Clean up reject/orig files
  find . \( -name '*.rej' -o -name '*.orig' \) \
    -delete 2>/dev/null || true

  echo ""
  echo "  ${applied} clean," \
    "${partial} partial," \
    "${skipped} skipped."
}

apply_patches

# -------------------------------------------------------
# Verify expected files exist
# -------------------------------------------------------

verify_source() {
  echo ""
  echo "Verifying source tree..."

  local eth_ok=true
  local rdma_ok=true

  if [ ! -f "${ETH_DIR}/ionic_main.c" ] && \
     [ ! -f "${ETH_DIR}/ionic_bus_pci.c" ]; then
    eth_ok=false
  fi

  if [ ! -d "${RDMA_DIR}" ] || \
     [ -z "$(ls -A "${RDMA_DIR}" \
       2>/dev/null)" ]; then
    rdma_ok=false
    echo "WARN: ionic_rdma source directory" \
      "is empty."
    echo "  The DKMS build will only produce" \
      "the patched ionic.ko."
  fi

  if ! $eth_ok; then
    echo "ERROR: ionic ethernet source" \
      "missing after patching."
    exit 1
  fi

  echo "  ionic ethernet: OK"
  if $rdma_ok; then
    echo "  ionic_rdma:     OK"
  fi
}

verify_source

# -------------------------------------------------------
# Inject rocm-xio modinfo into driver source
# -------------------------------------------------------

inject_modinfo() {
  echo "Injecting rocm-xio modinfo..."

  local eth_main="${ETH_DIR}/ionic_main.c"
  if [ -f "${eth_main}" ]; then
    cat >> "${eth_main}" <<MODEOF

/* rocm-xio project metadata (injected at build) */
MODULE_VERSION("${PKG_VERSION}");
MODULE_INFO(project, "rocm-xio");
MODULE_INFO(project_pkg, "${PKG_NAME}");
MODEOF
    echo "  ionic_main.c: OK"
  fi

  local rdma_main="${RDMA_DIR}/ionic_ibdev.c"
  if [ -f "${rdma_main}" ]; then
    cat >> "${rdma_main}" <<MODEOF

/* rocm-xio project metadata (injected at build) */
MODULE_VERSION("${PKG_VERSION}");
MODULE_INFO(project, "rocm-xio");
MODULE_INFO(project_pkg, "${PKG_NAME}");
MODEOF
    echo "  ionic_ibdev.c: OK"
  fi
}

inject_modinfo

# -------------------------------------------------------
# Populate DKMS source tree
# -------------------------------------------------------

populate_dkms() {
  echo ""
  echo "Installing source to ${DKMS_SRC}..."
  sudo rm -rf "${DKMS_SRC}"
  sudo mkdir -p "${DKMS_SRC}/rdma" \
    "${DKMS_SRC}/include"

  # ionic ethernet driver source
  sudo cp -a "${ETH_DIR}/"*.c \
    "${DKMS_SRC}/" 2>/dev/null || true
  sudo cp -a "${ETH_DIR}/"*.h \
    "${DKMS_SRC}/" 2>/dev/null || true

  # ionic_rdma InfiniBand driver source
  if [ -d "${RDMA_DIR}" ] && \
     [ -n "$(ls -A "${RDMA_DIR}" \
       2>/dev/null)" ]; then
    sudo cp -a "${RDMA_DIR}/"*.c \
      "${DKMS_SRC}/rdma/" 2>/dev/null || true
    sudo cp -a "${RDMA_DIR}/"*.h \
      "${DKMS_SRC}/rdma/" 2>/dev/null || true
  fi

  # UAPI headers -- the rdma driver includes
  # <rdma/ionic-abi.h> so we need it at
  # include/rdma/ionic-abi.h relative to the
  # include search path
  local abi_h
  abi_h=$(find "${SRC_DIR}" \
    -name 'ionic-abi.h' 2>/dev/null \
    | head -1)
  if [ -n "${abi_h}" ]; then
    sudo mkdir -p "${DKMS_SRC}/include/rdma"
    sudo cp "${abi_h}" \
      "${DKMS_SRC}/include/rdma/"
  fi

  # Our build files
  sudo cp "${SCRIPT_DIR}/Makefile" \
    "${DKMS_SRC}/"
  sudo cp "${SCRIPT_DIR}/dkms.conf" \
    "${DKMS_SRC}/"
  sudo sed -i \
    "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"${PKG_VERSION}\"/" \
    "${DKMS_SRC}/dkms.conf"

  # Kbuild for the rdma/ subdirectory
  if [ -d "${DKMS_SRC}/rdma" ]; then
    sudo cp "${SCRIPT_DIR}/rdma-Kbuild" \
      "${DKMS_SRC}/rdma/Kbuild"
  fi

  echo "Source tree populated."
}

populate_dkms

# -------------------------------------------------------
# Register and build with DKMS
# -------------------------------------------------------

dkms_build "ionic + ionic_rdma"
if ! $BUILD_ONLY; then
  dkms_install "ionic + ionic_rdma"

  echo ""
  echo "=== ionic RDMA installed via DKMS ==="
  echo ""
  echo "The stock ionic module is overridden."
  echo "DKMS will rebuild on kernel upgrades."
  echo ""
  echo "To load now:"
  echo "  sudo modprobe -r ionic_rdma"
  echo "  sudo modprobe -r ionic"
  echo "  sudo modprobe ionic"
  echo "  sudo modprobe ionic_rdma"
  echo ""
  echo "To revert to stock:"
  echo "  $0 --uninstall"
  echo "  sudo depmod -a"
  echo "  sudo modprobe ionic"
fi
