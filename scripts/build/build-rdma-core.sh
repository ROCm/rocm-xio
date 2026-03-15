#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Unified rdma-core build script.
# Downloads the upstream v62.0 tarball, applies vendor
# patches (bnxt DV, ionic GDA), and builds/installs.
#
# Usage:
#   build-rdma-core.sh \
#     <build_dir> <install_dir> \
#     [nproc] [--build-only]
#
# Environment:
#   RDMA_CORE_VERSION  - upstream version (default 62.0)
#   GDA_BNXT           - apply bnxt DV patches (1/0)
#   GDA_IONIC          - apply ionic GDA patches (1/0)
#   GDA_ERNIC          - inject ernic provider (1/0)
#   ERNIC_PROJECT_DIR  - path to rocm-ernic project

set -euo pipefail

BUILD_DIR="$(realpath -m "$1")"
INSTALL_DIR="$(realpath -m "$2")"
NPROC="${3:-$(nproc)}"
BUILD_ONLY=false
if [ "${4:-}" = "--build-only" ]; then
  BUILD_ONLY=true
fi

VERSION="${RDMA_CORE_VERSION:-62.0}"
GDA_BNXT="${GDA_BNXT:-1}"
GDA_IONIC="${GDA_IONIC:-1}"
GDA_ERNIC="${GDA_ERNIC:-0}"
ERNIC_DIR="${ERNIC_PROJECT_DIR:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PATCHES_DIR="${PROJECT_DIR}/rdma-core"

TARBALL_URL="https://github.com/linux-rdma/rdma-core"
TARBALL_URL="${TARBALL_URL}/releases/download"
TARBALL_URL="${TARBALL_URL}/v${VERSION}"
TARBALL_URL="${TARBALL_URL}/rdma-core-${VERSION}.tar.gz"

SRC_DIR="${BUILD_DIR}/rdma-core-${VERSION}"
TARBALL="${BUILD_DIR}/rdma-core-${VERSION}.tar.gz"
CMAKE_BUILD="${BUILD_DIR}/cmake-build"

echo "=== build-rdma-core ==="
echo "  version    : ${VERSION}"
echo "  bnxt DV    : ${GDA_BNXT}"
echo "  ionic GDA  : ${GDA_IONIC}"
echo "  ernic DV   : ${GDA_ERNIC}"
echo "  build      : ${BUILD_DIR}"
echo "  install    : ${INSTALL_DIR}"
echo ""

# Skip if already built
if [ -f "${INSTALL_DIR}/lib/libibverbs.so" ]; then
  echo "rdma-core already installed, skipping."
  exit 0
fi

mkdir -p "${BUILD_DIR}"

# --- Download tarball ---
if [ ! -f "${TARBALL}" ]; then
  echo "Downloading rdma-core v${VERSION}..."
  curl -fsSL -o "${TARBALL}" "${TARBALL_URL}"
fi

# --- Extract ---
if [ ! -d "${SRC_DIR}" ]; then
  echo "Extracting..."
  tar xf "${TARBALL}" -C "${BUILD_DIR}"
fi

# --- Apply bnxt DV patches ---
if [ "${GDA_BNXT}" = "1" ]; then
  echo ""
  echo "--- Applying bnxt DV patches ---"
  BNXT_PATCH_DIR="${PATCHES_DIR}/bnxt-dv"

  for p in "${BNXT_PATCH_DIR}"/0*.patch; do
    echo "  $(basename "$p")..."
    patch -d "${SRC_DIR}" -p1 -N \
      --no-backup-if-mismatch \
      < "$p" || true
  done

  if [ -x "${BNXT_PATCH_DIR}/apply-bnxt-dv-fixups.sh" ]
  then
    echo "  Applying bnxt DV fixups..."
    "${BNXT_PATCH_DIR}/apply-bnxt-dv-fixups.sh" \
      "${SRC_DIR}"
  fi
fi

# --- Apply ionic GDA patches ---
if [ "${GDA_IONIC}" = "1" ]; then
  echo ""
  echo "--- Applying ionic GDA patches ---"
  IONIC_PATCH_DIR="${PATCHES_DIR}/ionic-gda"

  for p in "${IONIC_PATCH_DIR}"/0*.patch; do
    echo "  $(basename "$p")..."
    patch -d "${SRC_DIR}" -p1 -N \
      --no-backup-if-mismatch \
      < "$p" || true
  done
fi

# --- Inject ernic provider ---
if [ "${GDA_ERNIC}" = "1" ]; then
  echo ""
  echo "--- Injecting ernic provider ---"
  LOCAL_ERNIC="${PATCHES_DIR}/rocm-ernic"
  ERNIC_INJECTED=false
  if [ -d "${LOCAL_ERNIC}" ]; then
    cp -r "${LOCAL_ERNIC}" \
      "${SRC_DIR}/providers/rocm_ernic"
    echo "  Injected rocm_ernic from" \
         "${LOCAL_ERNIC}"
    ERNIC_INJECTED=true
  elif [ -n "${ERNIC_DIR}" ] && \
       [ -d "${ERNIC_DIR}" ]; then
    ERNIC_PROV="${ERNIC_DIR}/rdma-core"
    ERNIC_PROV="${ERNIC_PROV}/providers"
    ERNIC_PROV="${ERNIC_PROV}/rocm_ernic"
    if [ -d "${ERNIC_PROV}" ]; then
      cp -r "${ERNIC_PROV}" \
        "${SRC_DIR}/providers/"
      echo "  Injected rocm_ernic from" \
           "${ERNIC_PROV}"
      ERNIC_INJECTED=true
    else
      echo "  WARNING: ${ERNIC_PROV}" \
           "not found."
    fi
  else
    echo "WARNING: No rocm_ernic source" \
         "found."
    echo "  Checked: ${LOCAL_ERNIC}"
    echo "  Skipping ernic injection."
  fi

  # Record rocm-ernic git SHA for provenance
  if $ERNIC_INJECTED && \
     [ -n "${ERNIC_DIR}" ] && \
     [ -d "${ERNIC_DIR}/.git" ]; then
    ERNIC_SHA="$(git -C "${ERNIC_DIR}" \
      rev-parse --short HEAD 2>/dev/null \
      || echo "unknown")"
    echo "${ERNIC_SHA}" > \
      "${SRC_DIR}/providers/rocm_ernic/SOURCE_SHA"
    echo "  rocm-ernic SHA: ${ERNIC_SHA}"
  fi
fi

# --- Build with cmake ---
echo ""
echo "Configuring rdma-core..."
mkdir -p "${CMAKE_BUILD}"
cmake -S "${SRC_DIR}" -B "${CMAKE_BUILD}" \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DIOCTL_MODE=both \
  -DNO_PYVERBS=1 \
  -DNO_MAN_PAGES=1 \
  -DENABLE_STATIC=0

echo "Building rdma-core (${NPROC} jobs)..."
cmake --build "${CMAKE_BUILD}" -j "${NPROC}"

if $BUILD_ONLY; then
  echo ""
  echo "=== rdma-core built (no install) ==="
  echo "  build dir : ${CMAKE_BUILD}"
  exit 0
fi

echo "Installing rdma-core to ${INSTALL_DIR}..."
cmake --install "${CMAKE_BUILD}"

echo ""
echo "=== rdma-core installed ==="
echo "  libibverbs : ${INSTALL_DIR}/lib/"
echo "  libionic   : ${INSTALL_DIR}/lib/"
echo "  libbnxt_re : ${INSTALL_DIR}/lib/"
echo "  headers    : ${INSTALL_DIR}/include/"
