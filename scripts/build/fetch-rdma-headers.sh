#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Fetch RDMA provider headers from rdma-core repository

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/build/gh-fetch-lib.sh
. "${SCRIPT_DIR}/gh-fetch-lib.sh"

OUTPUT_DIR="$1"
RDMA_CORE_VERSION="${RDMA_CORE_VERSION:-v62.0}"
RDMA_CORE_SLUG="linux-rdma/rdma-core"

mkdir -p "$OUTPUT_DIR"

echo "Fetching RDMA provider headers from rdma-core repository..."

# These stay non-fatal: a provider header that rdma-core has moved or dropped
# should not stop a build that may not use that provider. The anchor and the
# temp-file dance still matter though -- previously a rate-limited or missing
# fetch left an HTML error page on disk under a .h name, which is a far worse
# outcome than an absent file.
rdma_fetch() {
    gh_fetch "${RDMA_CORE_SLUG}" "${RDMA_CORE_VERSION}" "$1" "$2" "$3" optional
}

# Mellanox/NVIDIA mlx5 provider
echo "  - Downloading mlx5 headers..."
mkdir -p "$OUTPUT_DIR/mlx"
rdma_fetch providers/mlx5/mlx5dv.h "$OUTPUT_DIR/mlx/mlx5dv.h" "#define"
rdma_fetch providers/mlx5/wqe.h "$OUTPUT_DIR/mlx/mlx5_wqe.h" "#define"
rdma_fetch providers/mlx5/cq.h "$OUTPUT_DIR/mlx/mlx5_cq.h" "#define"

# Broadcom bnxt_re provider
echo "  - Downloading bnxt_re headers..."
mkdir -p "$OUTPUT_DIR/bnxt"
rdma_fetch providers/bnxt_re/bnxt_re-abi.h "$OUTPUT_DIR/bnxt/bnxt_re_abi.h" "#define"
rdma_fetch providers/bnxt_re/main.h "$OUTPUT_DIR/bnxt/bnxt_re_main.h" "#define"

# Pensando Ionic RDMA provider
echo "  - Downloading ionic headers..."
mkdir -p "$OUTPUT_DIR/ionic"
rdma_fetch providers/ionic/ionic.h "$OUTPUT_DIR/ionic/ionic.h" "#define"
rdma_fetch providers/ionic/ionic-abi.h "$OUTPUT_DIR/ionic/ionic_abi.h" "#define"

# Common RDMA verbs header
echo "  - Downloading common RDMA verbs header..."
rdma_fetch kernel-headers/rdma/ib_user_verbs.h "$OUTPUT_DIR/ib_user_verbs.h" "#define"

echo ""
echo "Successfully downloaded RDMA headers to $OUTPUT_DIR/"
echo ""
echo "Downloaded files:"
echo "  MLX5 (Mellanox/NVIDIA):"
echo "    - mlx/mlx5dv.h (direct verbs)"
echo "    - mlx/mlx5_wqe.h (work queue elements)"
echo "    - mlx/mlx5_cq.h (completion queue)"
echo "  BNXT_RE (Broadcom NetXtreme):"
echo "    - bnxt/bnxt_re_abi.h (ABI definitions)"
echo "    - bnxt/bnxt_re_main.h (main structures)"
echo "  IONIC (Pensando Ionic RDMA):"
echo "    - ionic/ionic.h (main header)"
echo "    - ionic/ionic_abi.h (ABI structures)"
echo "  Common:"
echo "    - ib_user_verbs.h (InfiniBand user verbs)"
