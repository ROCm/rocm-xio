#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Run the full CTest sweep (NVMe + RDMA + unit + install examples) with
# hardware-oriented environment. Requires sudo.
#
# Usage:
#   ./run-ctests.sh [--] [bnxt|ionic|mlx5|all] [--] [ctest-option...]
#
# All arguments after the optional vendor keyword are passed through to
# ctest unchanged (after stripping optional "--" sentinels used only by this
# wrapper). Examples:
#   ./run-ctests.sh -R nvme-verify-seq-host-mem -V
#   ./run-ctests.sh ionic -LE rdma --output-on-failure
#   ./run-ctests.sh bnxt -- -R '^rdma-xio-loopback' --output-on-failure
#
# Optional first argument selects the RDMA vendor passed to
# setup-rdma-loopback.sh (default: bnxt). You can also set VENDOR in the
# environment. When vendor is "all", ROCXIO_RDMA_DEVICE is left unset so
# scripts auto-detect the first InfiniBand device.
#
# Override NVMe path when the default MTR by-id is not present:
#   ROCXIO_NVME_DEVICE=/dev/disk/by-id/... ./run-ctests.sh ionic

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

if [[ "${1:-}" == "--" ]]; then
  shift
elif [[ "${1:-}" =~ ^(bnxt|ionic|mlx5|all)$ ]]; then
  export VENDOR="$1"
  shift
fi

# Allow ./run-ctests.sh <vendor> -- <ctest-args> so ctest never sees a bare
# "--" from the wrapper.
if [[ "${1:-}" == "--" ]]; then
  shift
fi

export VENDOR="${VENDOR:-bnxt}"
if [[ "${VENDOR}" == all ]]; then
  export PROVIDER="${PROVIDER:-auto}"
else
  export PROVIDER="${PROVIDER:-${VENDOR}}"
fi

ROCXIO_NVME_DEVICE="${ROCXIO_NVME_DEVICE:-/dev/disk/by-id/nvme-MTR_SLC_16GB_0400000E3CBC}"

case "${VENDOR}" in
bnxt)
  export ROCXIO_RDMA_DEVICE="${ROCXIO_RDMA_DEVICE:-rocm-rdma-bnxt0}"
  ;;
ionic)
  export ROCXIO_RDMA_DEVICE="${ROCXIO_RDMA_DEVICE:-rocm-rdma-ionic0}"
  ;;
mlx5)
  export ROCXIO_RDMA_DEVICE="${ROCXIO_RDMA_DEVICE:-rocm-rdma-mlx50}"
  ;;
all)
  if [[ -z "${ROCXIO_RDMA_DEVICE:-}" ]]; then
    unset ROCXIO_RDMA_DEVICE
  fi
  ;;
esac

LIB="${REPO_ROOT}/build/_deps/rdma-core/install/lib"
RDMA_LDPATH="${LIB}:${LIB}/libibverbs:/opt/rocs-ais/lib:/opt/rocm/lib:${LD_LIBRARY_PATH:-}"

CTEST_ARGS=(--test-dir "${REPO_ROOT}/build" --output-on-failure)
if [[ -f "${REPO_ROOT}/build/ctest-resources.json" ]]; then
  CTEST_ARGS+=(--resource-spec-file "${REPO_ROOT}/build/ctest-resources.json")
fi

ENV_ARGS=(
  "ROCXIO_NVME_DEVICE=${ROCXIO_NVME_DEVICE}"
  "NVME_DEVICE=${NVME_DEVICE:-${ROCXIO_NVME_DEVICE}}"
  "VENDOR=${VENDOR}"
  "PROVIDER=${PROVIDER}"
  "LD_LIBRARY_PATH=${RDMA_LDPATH}"
  "HSA_FORCE_FINE_GRAIN_PCIE=${HSA_FORCE_FINE_GRAIN_PCIE:-1}"
)
if [[ -n "${ROCXIO_RDMA_DEVICE:-}" ]]; then
  ENV_ARGS+=("ROCXIO_RDMA_DEVICE=${ROCXIO_RDMA_DEVICE}")
fi

# Remaining "$@" are forwarded to ctest after our default flags.
sudo env "${ENV_ARGS[@]}" ctest "${CTEST_ARGS[@]}" "$@"
