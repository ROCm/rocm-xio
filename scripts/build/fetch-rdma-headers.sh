#!/bin/bash
# Script to fetch RDMA provider headers from rdma-core repository

set -euo pipefail

OUTPUT_DIR="$1"
RDMA_CORE_VERSION="${RDMA_CORE_VERSION:-v62.0}"
RDMA_CORE_REPO="https://raw.githubusercontent.com/linux-rdma/rdma-core/${RDMA_CORE_VERSION}"

mkdir -p "$OUTPUT_DIR"

echo "Fetching RDMA provider headers from rdma-core repository..."

# Mellanox/NVIDIA mlx5 provider
echo "  - Downloading mlx5 headers..."
mkdir -p "$OUTPUT_DIR/mlx"
curl -sL "$RDMA_CORE_REPO/providers/mlx5/mlx5dv.h" -o "$OUTPUT_DIR/mlx/mlx5dv.h" || echo "    Warning: mlx5dv.h not found"
curl -sL "$RDMA_CORE_REPO/providers/mlx5/wqe.h" -o "$OUTPUT_DIR/mlx/mlx5_wqe.h" || echo "    Warning: wqe.h not found"
curl -sL "$RDMA_CORE_REPO/providers/mlx5/cq.h" -o "$OUTPUT_DIR/mlx/mlx5_cq.h" || echo "    Warning: cq.h not found"

# Broadcom bnxt_re provider
echo "  - Downloading bnxt_re headers..."
mkdir -p "$OUTPUT_DIR/bnxt"
curl -sL "$RDMA_CORE_REPO/providers/bnxt_re/bnxt_re-abi.h" -o "$OUTPUT_DIR/bnxt/bnxt_re_abi.h" || echo "    Warning: bnxt_re-abi.h not found"
curl -sL "$RDMA_CORE_REPO/providers/bnxt_re/main.h" -o "$OUTPUT_DIR/bnxt/bnxt_re_main.h" || echo "    Warning: main.h not found"

# Pensando Ionic RDMA provider
echo "  - Downloading ionic headers..."
mkdir -p "$OUTPUT_DIR/ionic"
curl -sL "$RDMA_CORE_REPO/providers/ionic/ionic.h" -o "$OUTPUT_DIR/ionic/ionic.h" || echo "    Warning: ionic.h not found"
curl -sL "$RDMA_CORE_REPO/providers/ionic/ionic-abi.h" -o "$OUTPUT_DIR/ionic/ionic_abi.h" || echo "    Warning: ionic-abi.h not found"

# Common RDMA verbs header
echo "  - Downloading common RDMA verbs header..."
curl -sL "$RDMA_CORE_REPO/kernel-headers/rdma/ib_user_verbs.h" -o "$OUTPUT_DIR/ib_user_verbs.h" || echo "    Warning: ib_user_verbs.h not found"

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
