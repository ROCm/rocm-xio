#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Setup DKMS tree for bnxt_re with uapi extensions
# (v11 patches).
#
# 1. Downloads the bnxt_re driver source from
#    kernel.org (cached across runs).
# 2. Extracts a fresh copy and applies the vendored
#    v11 uapi-extension patches unconditionally.
# 3. Copies the patched source + our Makefile/dkms.conf
#    into /usr/src/rocm-xio-bnxt-re-<ver>/.
# 4. Registers and builds with DKMS.
#
# Usage:
#   setup-bnxt-re-dkms.sh [--kernel-tag vX.Y] \
#                          [--work-dir DIR]
#
# Options:
#   --kernel-tag TAG  Upstream kernel tag for source
#                     (default: auto-detect from uname)
#   --work-dir DIR    Working directory for downloads
#                     (default: /tmp/rocm-xio-bnxt-re-build)
#   --version VER     DKMS package version
#                     (default: 1.0.0-g<shortrev>)
#   --build-only      Build but do not install
#   --uninstall       Remove the DKMS module and exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_NAME="rocm-xio-bnxt-re"
BASE_VERSION="0.1.0"
GIT_REV="$(git -C "$(dirname "$0")" \
  rev-parse --short HEAD 2>/dev/null || echo "unknown")"
PKG_VERSION="${BASE_VERSION}-g${GIT_REV}"
KERNEL_TAG=""
WORK_DIR="/tmp/rocm-xio-bnxt-re-build"
BUILD_ONLY=false
UNINSTALL=false

# googlesource provides per-directory tarballs
GS_BASE="https://kernel.googlesource.com"
GS_REPO="${GS_BASE}/pub/scm/linux/kernel/git"
GS_REPO="${GS_REPO}/torvalds/linux/+archive"

# git.kernel.org provides raw files
GK_BASE="https://git.kernel.org/pub/scm/linux/kernel"
GK_REPO="${GK_BASE}/git/torvalds/linux.git/plain"

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
echo "=== setup-bnxt-re-dkms ==="
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
# Download kernel source (cached in download/)
# -----------------------------------------------------------

DL_DIR="${WORK_DIR}/download"
SRC_DIR="${WORK_DIR}/src"
DRV_DIR="${SRC_DIR}/${DRIVER_PATH}"
UAPI_DIR="${SRC_DIR}/$(dirname "${UAPI_FILE}")"
BNXT_HDR_DIR="${SRC_DIR}/include/bnxt"

download_source() {
  local drv_tgz="${DL_DIR}/bnxt_re.tar.gz"
  local uapi_dl="${DL_DIR}/bnxt_re-abi.h"
  local eth_tgz="${DL_DIR}/bnxt_eth.tar.gz"

  mkdir -p "${DL_DIR}"

  if [ -f "${drv_tgz}" ]; then
    echo "Using cached downloads."
    return 0
  fi

  echo "Downloading bnxt_re source" \
    "(${KERNEL_TAG})..."
  local url="${GS_REPO}/${KERNEL_TAG}"
  url="${url}/${DRIVER_PATH}.tar.gz"
  if ! curl -sL -f "${url}" -o "${drv_tgz}"; then
    echo "ERROR: Failed to download bnxt_re source."
    echo "  URL: ${url}"
    echo "  Tag ${KERNEL_TAG} may not exist."
    rm -f "${drv_tgz}"
    exit 1
  fi

  echo "Downloading bnxt_re-abi.h..."
  local uapi_url
  uapi_url="${GK_REPO}/${UAPI_FILE}?h=${KERNEL_TAG}"
  if ! curl -sL -f "${uapi_url}" \
      -o "${uapi_dl}"; then
    echo "ERROR: Failed to download bnxt_re-abi.h"
    rm -f "${drv_tgz}"
    exit 1
  fi

  echo "Downloading bnxt ethernet headers..."
  url="${GS_REPO}/${KERNEL_TAG}"
  url="${url}/${BNXT_ETH_PATH}.tar.gz"
  if ! curl -sL -f "${url}" -o "${eth_tgz}"; then
    echo "WARN: Could not download bnxt ethernet" \
      "headers. Build may fail."
  fi

  echo "Download complete."
}

extract_fresh() {
  echo "Extracting fresh source tree..."
  rm -rf "${SRC_DIR}" 2>/dev/null \
    || sudo rm -rf "${SRC_DIR}"
  mkdir -p "${DRV_DIR}" "${UAPI_DIR}" "${BNXT_HDR_DIR}"

  tar xzf "${DL_DIR}/bnxt_re.tar.gz" -C "${DRV_DIR}"
  cp "${DL_DIR}/bnxt_re-abi.h" \
    "${SRC_DIR}/${UAPI_FILE}"

  if [ -f "${DL_DIR}/bnxt_eth.tar.gz" ]; then
    tar xzf "${DL_DIR}/bnxt_eth.tar.gz" \
      -C "${BNXT_HDR_DIR}" \
      --wildcards '*.h' 2>/dev/null || true
  fi

  if [ ! -f "${DRV_DIR}/main.c" ]; then
    echo "ERROR: bnxt_re source incomplete."
    exit 1
  fi
}

download_source
extract_fresh

# -----------------------------------------------------------
# Apply vendored patches
# -----------------------------------------------------------

apply_patches() {
  cd "${SRC_DIR}"

  echo "Applying v11 uapi extension patches..."
  local applied=0
  local failed=0
  for p in "${PATCHES_DIR}"/*.patch; do
    local name
    name=$(basename "${p}")
    echo "  ${name}..."
    if patch -p1 --fuzz=3 --force \
        < "${p}" >/dev/null 2>&1; then
      applied=$((applied + 1))
    else
      applied=$((applied + 1))
      failed=$((failed + 1))
    fi
  done

  # Handle reject files from context drift
  local rej_count
  rej_count=$(find . -name '*.rej' | wc -l)
  if [ "${rej_count}" -gt 0 ]; then
    echo ""
    echo "  ${rej_count} reject file(s) found," \
      "applying fixups..."
    fixup_rejects
  fi

  # Always inject DV QP handling (patch 0007's
  # ib_verbs.c hunk is always rejected due to
  # context drift from patches 0001-0006).
  inject_dv_qp "${DRV_DIR}/ib_verbs.c"

  # Clean up reject/orig files
  find . \( -name '*.rej' -o -name '*.orig' \) \
    -delete 2>/dev/null || true

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

inject_dv_qp() {
  local iv="$1"
  if grep -q 'BNXT_RE_QP_REQ_MASK_DV_QP_ENABLE' \
      "${iv}"; then
    return 0
  fi
  echo "  Injecting DV QP handling into ib_verbs.c"

  python3 - "${iv}" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

DV_BLOCK = r'''
	if (ureq->comp_mask & BNXT_RE_QP_REQ_MASK_DV_QP_ENABLE) {
		bytes = (int)ureq->sq_slots * (int)ureq->sq_wqe_sz;
		if (qplib_qp->type == CMDQ_CREATE_QP_TYPE_RC)
			bytes += (int)ureq->sq_npsn * (int)ureq->sq_psn_sz;
		bytes = PAGE_ALIGN(bytes);
		umem = ib_umem_get(&rdev->ibdev, ureq->qpsva,
				   bytes, IB_ACCESS_LOCAL_WRITE);
		if (IS_ERR(umem))
			return PTR_ERR(umem);
		qp->sumem = umem;
		qplib_qp->sq.sg_info.umem = umem;
		qplib_qp->sq.sg_info.pgsize = PAGE_SIZE;
		qplib_qp->sq.sg_info.pgshft = PAGE_SHIFT;
		qplib_qp->qp_handle = ureq->qp_handle;
		/* No RQ umem: zero RQ depth so
		 * setup_qp_hwqs skips it */
		if (!qplib_qp->srq && !ureq->qprva) {
			qplib_qp->rq.max_wqe = 0;
			qplib_qp->rq.max_sw_wqe = 0;
		}
		if (!qplib_qp->srq && ureq->qprva) {
			bytes = (int)ureq->rq_slots *
				(int)ureq->rq_wqe_sz;
			bytes = PAGE_ALIGN(bytes);
			umem = ib_umem_get(&rdev->ibdev, ureq->qprva,
					   bytes,
					   IB_ACCESS_LOCAL_WRITE);
			if (IS_ERR(umem))
				goto rqfail;
			qp->rumem = umem;
			qplib_qp->rq.sg_info.umem = umem;
			qplib_qp->rq.sg_info.pgsize = PAGE_SIZE;
			qplib_qp->rq.sg_info.pgshft = PAGE_SHIFT;
		}
		qplib_qp->dpi = &cntx->dpi;
		qplib_qp->is_user = true;
		return 0;
	}

'''

anchor = 'qplib_qp = &qp->qplib_qp;\n'
fn_start = src.find('bnxt_re_init_user_qp')
pos = src.find(anchor, fn_start)
if pos < 0:
    print("  WARN: cannot find anchor in "
          "bnxt_re_init_user_qp", file=sys.stderr)
    sys.exit(0)
ins = pos + len(anchor)
src = src[:ins] + DV_BLOCK + src[ins:]

src = src.replace(
    'struct bnxt_re_qp_req ureq;',
    'struct bnxt_re_qp_req ureq = {};')

with open(path, 'w') as f:
    f.write(src)
print("  DV QP handling injected.")
PYEOF
}

apply_patches

# -----------------------------------------------------------
# Kernel 6.17+ compat: ensure is_user in qplib_qp
# -----------------------------------------------------------

fixup_kernel_compat() {
  local fp="${DRV_DIR}/qplib_fp.h"
  if ! grep -q 'is_user' "${fp}" 2>/dev/null ||
     ! grep -B5 'is_user' "${fp}" \
       | grep -q 'struct bnxt_qplib_qp'; then
    echo "Adding is_user to bnxt_qplib_qp" \
      "(kernel compat fixup)..."
    sed -i '/u8\t\t\t\tstate;/a\\tu8\t\t\t\tis_user;' \
      "${fp}"
  fi
}

fixup_kernel_compat

# -----------------------------------------------------------
# Inject rocm-xio modinfo into driver source
# -----------------------------------------------------------

inject_modinfo() {
  local main="${DRV_DIR}/main.c"
  echo "Injecting rocm-xio modinfo into main.c..."
  cat >> "${main}" <<MODEOF

/* rocm-xio project metadata (injected at build) */
MODULE_VERSION("${PKG_VERSION}");
MODULE_INFO(project, "rocm-xio");
MODULE_INFO(project_pkg, "${PKG_NAME}");
MODEOF
}

inject_modinfo

# -----------------------------------------------------------
# Populate DKMS source tree
# -----------------------------------------------------------

populate_dkms() {
  echo ""
  echo "Installing source to ${DKMS_SRC}..."
  sudo mkdir -p "${DKMS_SRC}/include/bnxt" \
    "${DKMS_SRC}/include/rdma"

  sudo cp -a "${DRV_DIR}/"*.c "${DKMS_SRC}/"
  sudo cp -a "${DRV_DIR}/"*.h "${DKMS_SRC}/"

  sudo cp -a \
    "${SRC_DIR}/${UAPI_FILE}" \
    "${DKMS_SRC}/include/rdma/"

  if ls "${BNXT_HDR_DIR}/"*.h &>/dev/null; then
    sudo cp -a "${BNXT_HDR_DIR}/"*.h \
      "${DKMS_SRC}/include/bnxt/"
  fi

  sudo cp "${SCRIPT_DIR}/Makefile" "${DKMS_SRC}/"
  sudo cp "${SCRIPT_DIR}/dkms.conf" "${DKMS_SRC}/"
  sudo sed -i \
    "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"${PKG_VERSION}\"/" \
    "${DKMS_SRC}/dkms.conf"

  echo "Source tree populated."
}

populate_dkms

# -----------------------------------------------------------
# Register and build with DKMS
# -----------------------------------------------------------

build_dkms() {
  echo ""

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
      "${PKG_NAME}/${PKG_VERSION}" -k "${kver}"
  then
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
