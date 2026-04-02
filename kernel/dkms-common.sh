# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Shared DKMS lifecycle helpers sourced by the
# per-driver setup-*-dkms.sh scripts.
#
# The caller must set these variables before sourcing:
#   PKG_NAME       - e.g. "rocm-xio-bnxt-re"
#   PKG_VERSION    - e.g. "0.1.0-gabcdef0"
#   DKMS_SRC       - /usr/src/${PKG_NAME}-${PKG_VERSION}
#   BUILD_ONLY     - true / false
#   UNINSTALL      - true / false
#
# Optional:
#   KERNEL_TAG     - set before calling dkms_detect_kernel_tag

# ---------------------------------------------------------
# dkms_uninstall_guard
#   Exit early if --uninstall was requested.
# ---------------------------------------------------------
dkms_uninstall_guard() {
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
}

# ---------------------------------------------------------
# dkms_check_kernel_headers
#   Verify kernel headers are installed.
# ---------------------------------------------------------
dkms_check_kernel_headers() {
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

# ---------------------------------------------------------
# dkms_check_tools TOOL [TOOL ...]
#   Verify that each listed command exists on PATH.
# ---------------------------------------------------------
dkms_check_tools() {
  local missing=()
  for tool in "$@"; do
    command -v "${tool}" &>/dev/null \
      || missing+=("${tool}")
  done

  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing required tools:" \
      "${missing[*]}"
    echo "Install with:"
    echo "  sudo apt install ${missing[*]}"
    exit 1
  fi
}

# ---------------------------------------------------------
# dkms_detect_kernel_tag
#   Auto-detect KERNEL_TAG from uname if not set.
# ---------------------------------------------------------
dkms_detect_kernel_tag() {
  if [ -n "${KERNEL_TAG:-}" ]; then
    return
  fi
  local kver
  kver="$(uname -r)"
  local major_minor
  major_minor="$(echo "${kver}" | \
    sed 's/\([0-9]*\.[0-9]*\).*/\1/')"
  KERNEL_TAG="v${major_minor}"
  echo "Auto-detected kernel tag:" \
    "${KERNEL_TAG} (from ${kver})"
}

# ---------------------------------------------------------
# dkms_skip_if_installed
#   Exit 0 if the module is already installed and
#   we're not in build-only mode.
# ---------------------------------------------------------
dkms_skip_if_installed() {
  if ! $BUILD_ONLY && \
      dkms status \
      "${PKG_NAME}/${PKG_VERSION}" \
      2>/dev/null | grep -q "installed"; then
    echo "${PKG_NAME}/${PKG_VERSION}" \
      "already installed."
    echo "Use --uninstall to remove first."
    exit 0
  fi
}

# ---------------------------------------------------------
# dkms_build MODULE_LABEL
#   Remove stale registration, add, and build.
#   MODULE_LABEL is a human-readable string like
#   "bnxt_re.ko" or "ionic + ionic_rdma".
# ---------------------------------------------------------
dkms_build() {
  local label="${1:?MODULE_LABEL required}"
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

  echo "Building ${label} for ${kver}..."
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
  echo "=== ${label} built via DKMS ==="
  echo "  Module: /var/lib/dkms/${PKG_NAME}/" \
    "${PKG_VERSION}/${kver}/$(uname -m)/module/"
  echo ""
  echo "To install:"
  echo "  $0  (re-run without --build-only)"
}

# ---------------------------------------------------------
# dkms_install MODULE_LABEL
#   Install the already-built module.
# ---------------------------------------------------------
dkms_install() {
  local label="${1:?MODULE_LABEL required}"
  local kver
  kver="$(uname -r)"

  echo "Installing ${label}..."
  sudo dkms install \
    "${PKG_NAME}/${PKG_VERSION}" -k "${kver}"
}

# ---------------------------------------------------------
# dkms_build_and_install MODULE_LABEL
#   Convenience: build, then install unless
#   BUILD_ONLY is true.
# ---------------------------------------------------------
dkms_build_and_install() {
  local label="${1:?MODULE_LABEL required}"
  dkms_build "${label}"
  if ! $BUILD_ONLY; then
    dkms_install "${label}"
  fi
}

# ---------------------------------------------------------
# dkms_patch_version DKMS_CONF
#   Sed PACKAGE_VERSION into dkms.conf.
# ---------------------------------------------------------
dkms_patch_version() {
  local conf="${1:?DKMS_CONF path required}"
  sudo sed -i \
    "s/@PACKAGE_VERSION@/${PKG_VERSION}/g" \
    "${conf}"
}
