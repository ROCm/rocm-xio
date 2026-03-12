#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Setup DKMS tree for bnxt_re with uapi extensions
# (Direct Verbs v11 patches).
#
# 1. Downloads the bnxt_re driver source from kernel.org
#    at a tag matching the running kernel (via curl).
# 2. Applies the vendored v11 uapi-extension patches
#    (with fuzz for offset drift).
# 4. Copies the patched source + our Makefile/dkms.conf
#    into /usr/src/bnxt-re-dv-<ver>/.
# 5. Registers and builds with DKMS.
#
# Usage:
#   setup-bnxt-dv-dkms.sh [--kernel-tag vX.Y] \
#                          [--work-dir DIR]
#
# Options:
#   --kernel-tag TAG  Upstream kernel tag for source
#                     (default: auto-detect from uname)
#   --work-dir DIR    Working directory for downloads
#                     (default: /tmp/bnxt-re-dv-build)
#   --version VER     DKMS package version (default: 0.1)
#   --build-only      Build but do not install the module
#   --uninstall       Remove the DKMS module and exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_NAME="bnxt-re-dv"
PKG_VERSION="0.1"
KERNEL_TAG=""
WORK_DIR="/tmp/bnxt-re-dv-build"
BUILD_ONLY=false
UNINSTALL=false

# googlesource provides per-directory tarballs
GS_BASE="https://kernel.googlesource.com"
GS_REPO="${GS_BASE}/pub/scm/linux/kernel/git"
GS_REPO="${GS_REPO}/torvalds/linux/+archive"

# git.kernel.org provides raw files
GK_BASE="https://git.kernel.org/pub/scm/linux/kernel/git"
GK_REPO="${GK_BASE}/torvalds/linux.git/plain"

# Vendored v11 patch series (Feb 10, 2026)
# "RDMA/bnxt_re: Support uapi extensions"
PATCHES_DIR="${SCRIPT_DIR}/patches"

# Kernel tree paths
DRIVER_PATH="drivers/infiniband/hw/bnxt_re"
UAPI_FILE="include/uapi/rdma/bnxt_re-abi.h"
BNXT_ETH_PATH="drivers/net/ethernet/broadcom/bnxt"

# -----------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------

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
  command -v curl &>/dev/null || missing+=("curl")
  command -v dkms &>/dev/null || missing+=("dkms")
  command -v make &>/dev/null || missing+=("make")

  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing required tools:" \
      "${missing[*]}"
    echo "Install with:"
    echo "  sudo apt install ${missing[*]}"
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

# -----------------------------------------------------------
# Detect kernel tag
# -----------------------------------------------------------

detect_kernel_tag() {
  if [ -n "${KERNEL_TAG}" ]; then
    return
  fi
  local kver
  kver="$(uname -r)"
  local major_minor
  major_minor="$(echo "${kver}" | \
    sed 's/\([0-9]*\.[0-9]*\).*/\1/')"
  KERNEL_TAG="v${major_minor}"
  echo "Auto-detected kernel tag: ${KERNEL_TAG}" \
    "(from ${kver})"
}

detect_kernel_tag

echo ""
echo "=== setup-bnxt-dv-dkms ==="
echo "  kernel tag  : ${KERNEL_TAG}"
echo "  work dir    : ${WORK_DIR}"
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
# Download kernel source files (curl, no git clone)
# -----------------------------------------------------------

SRC_DIR="${WORK_DIR}/src"
DRV_DIR="${SRC_DIR}/${DRIVER_PATH}"
UAPI_DIR="${SRC_DIR}/$(dirname "${UAPI_FILE}")"
BNXT_HDR_DIR="${SRC_DIR}/include/bnxt"

download_source() {
  if [ -f "${DRV_DIR}/main.c" ]; then
    echo "Source already downloaded, reusing."
    return 0
  fi

  mkdir -p "${DRV_DIR}" "${UAPI_DIR}" "${BNXT_HDR_DIR}"

  # 1. bnxt_re driver directory (tarball)
  local drv_tgz="${GS_REPO}/${KERNEL_TAG}"
  drv_tgz="${drv_tgz}/${DRIVER_PATH}.tar.gz"

  echo "Downloading bnxt_re source (${KERNEL_TAG})..."
  if ! curl -sL -f "${drv_tgz}" \
      | tar xz -C "${DRV_DIR}"; then
    echo "ERROR: Failed to download bnxt_re source."
    echo "  URL: ${drv_tgz}"
    echo "  Tag ${KERNEL_TAG} may not exist."
    exit 1
  fi

  # 2. UAPI header (single file)
  local uapi_url
  uapi_url="${GK_REPO}/${UAPI_FILE}?h=${KERNEL_TAG}"

  echo "Downloading bnxt_re-abi.h..."
  if ! curl -sL -f "${uapi_url}" \
      -o "${SRC_DIR}/${UAPI_FILE}"; then
    echo "ERROR: Failed to download bnxt_re-abi.h"
    exit 1
  fi

  # 3. bnxt ethernet headers (tarball, .h only)
  local eth_tgz="${GS_REPO}/${KERNEL_TAG}"
  eth_tgz="${eth_tgz}/${BNXT_ETH_PATH}.tar.gz"

  echo "Downloading bnxt ethernet headers..."
  if ! curl -sL -f "${eth_tgz}" \
      | tar xz -C "${BNXT_HDR_DIR}" \
        --wildcards '*.h' 2>/dev/null; then
    echo "WARN: Could not download bnxt ethernet" \
      "headers. Build may fail."
  fi

  # Verify
  if [ ! -f "${DRV_DIR}/main.c" ]; then
    echo "ERROR: bnxt_re source incomplete."
    exit 1
  fi

  echo "Source download complete."
}

download_source

# -----------------------------------------------------------
# Apply vendored patches
# -----------------------------------------------------------

apply_patches() {
  cd "${SRC_DIR}"

  # Initialize git repo if not already done
  if [ ! -d ".git" ]; then
    git init -q
    git add -A
    git commit -q --no-gpg-sign \
      -m "bnxt_re ${KERNEL_TAG} baseline"
  fi

  # Skip if already applied
  if git log --oneline | grep -q "uapi"; then
    echo "Patches already applied, skipping."
    return 0
  fi

  echo "Applying v11 uapi extension patches..."

  local applied=0
  local failed=0
  for p in "${PATCHES_DIR}"/*.patch; do
    local name
    name=$(basename "${p}")
    echo "  ${name}..."
    git mailinfo /tmp/_msg.txt /tmp/_patch.txt \
      < "${p}" > /tmp/_info.txt 2>/dev/null

    if patch -p1 --fuzz=3 --force \
        < /tmp/_patch.txt >/dev/null 2>&1; then
      applied=$((applied + 1))
    else
      applied=$((applied + 1))
      failed=$((failed + 1))
    fi
  done

  # Handle any remaining reject files
  local rej_count
  rej_count=$(find . -name '*.rej' | wc -l)
  if [ "${rej_count}" -gt 0 ]; then
    echo ""
    echo "  ${rej_count} reject file(s) found," \
      "applying fixups..."
    fixup_rejects
  fi

  # Clean up reject/orig files
  find . \( -name '*.rej' -o -name '*.orig' \) \
    -delete 2>/dev/null || true
  git add -A
  git commit -q --no-gpg-sign \
    -m "RDMA/bnxt_re: uapi extensions (DV v11)"

  echo "All patches applied (${applied} total," \
    "${failed} needed fixup)."
}

fixup_rejects() {
  local iv="${DRV_DIR}/ib_verbs.c"
  local fph="${DRV_DIR}/qplib_fp.h"

  # ib_verbs.c: remove old UAPI methods section
  # (moved to uapi.c by patch 0001). Delete from
  # the NOTIFY_DRV handler to end-of-file.
  if [ -f "${iv}.rej" ]; then
    local start
    start=$(grep -n \
      'UVERBS_HANDLER(BNXT_RE_METHOD_NOTIFY_DRV)' \
      "${iv}" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -n "${start}" ]; then
      local del=$((start - 1))
      sed -i "${del},\$d" "${iv}"
      echo "" >> "${iv}"
    fi
    rm -f "${iv}.rej"
  fi

  # qplib_fp.h: add struct fields if missing
  if [ -f "${fph}.rej" ]; then
    if ! grep -q 'psn_sz' "${fph}"; then
      sed -i \
        '/msn_tbl_sz;/a\\tu32\t\t\t\tpsn_sz;' \
        "${fph}"
    fi
    if ! grep -q 'dev_cap_flags' "${fph}"; then
      sed -i \
        '/is_host_msn_tbl;/a\\tu16\t\t\t\tdev_cap_flags;' \
        "${fph}"
    fi
    rm -f "${fph}.rej"
  fi
}

apply_patches

# -----------------------------------------------------------
# Populate DKMS source tree
# -----------------------------------------------------------

populate_dkms() {
  echo ""
  echo "Installing source to ${DKMS_SRC}..."
  sudo mkdir -p "${DKMS_SRC}/include/bnxt" \
    "${DKMS_SRC}/include/rdma"

  # Driver source (.c and .h from patched tree)
  sudo cp -a "${DRV_DIR}/"*.c "${DKMS_SRC}/"
  sudo cp -a "${DRV_DIR}/"*.h "${DKMS_SRC}/"

  # Patched UAPI header at include/rdma/ so that
  # -I $(PWD)/include finds it before the kernel's
  # stock <rdma/bnxt_re-abi.h>.
  sudo cp -a \
    "${SRC_DIR}/${UAPI_FILE}" \
    "${DKMS_SRC}/include/rdma/"

  # bnxt ethernet headers
  if ls "${BNXT_HDR_DIR}/"*.h &>/dev/null; then
    sudo cp -a "${BNXT_HDR_DIR}/"*.h \
      "${DKMS_SRC}/include/bnxt/"
  fi

  # Our Makefile and dkms.conf
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

  echo "Building bnxt_re.ko for ${kver}..."
  if ! sudo dkms build \
      "${PKG_NAME}/${PKG_VERSION}" -k "${kver}"; then
    echo ""
    echo "ERROR: DKMS build failed."
    echo "Check: /var/lib/dkms/${PKG_NAME}/" \
      "${PKG_VERSION}/build/make.log"
    exit 1
  fi

  echo ""
  echo "=== bnxt_re (DV) built via DKMS ==="
  echo "  Module: /var/lib/dkms/${PKG_NAME}/" \
    "${PKG_VERSION}/${kver}/x86_64/module/"
  echo ""
  echo "To install:"
  echo "  $0 # (re-run without --build-only)"
}

install_dkms() {
  local kver
  kver="$(uname -r)"

  echo "Installing bnxt_re.ko..."
  sudo dkms install \
    "${PKG_NAME}/${PKG_VERSION}" -k "${kver}"

  echo ""
  echo "=== bnxt_re (DV) installed via DKMS ==="
  echo ""
  echo "The stock bnxt_re module is overridden."
  echo "DKMS will rebuild on kernel upgrades."
  echo ""
  echo "To load now:"
  echo "  sudo modprobe -r bnxt_re 2>/dev/null"
  echo "  sudo modprobe bnxt_re"
  echo ""
  echo "To revert to stock:"
  echo "  $0 --uninstall"
  echo "  sudo depmod -a"
  echo "  sudo modprobe bnxt_re"
}

build_dkms
if ! $BUILD_ONLY; then
  install_dkms
fi
