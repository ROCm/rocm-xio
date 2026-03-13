#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Build rdma-core with the ROCm ERNIC Direct Verbs
# provider.
#
# This script clones upstream rdma-core, copies the
# rocm_ernic provider into providers/rocm_ernic/,
# and builds with CMake.
#
# Usage:
#   build-ernic-dv-rdma-core.sh \
#     <source_dir> <build_dir> <install_dir> \
#     <ernic_project_dir> [nproc] [--build-only]
#
# The script is idempotent: if the install directory
# already contains librocm_ernic.so it exits early.

set -euo pipefail

SRC_DIR="$(realpath -m "$1")"
BUILD_DIR="$(realpath -m "$2")"
INSTALL_DIR="$(realpath -m "$3")"
ERNIC_DIR="$(realpath -m "$4")"
NPROC="${5:-$(nproc)}"
BUILD_ONLY=false
if [ "${6:-}" = "--build-only" ]; then
  BUILD_ONLY=true
fi

UPSTREAM_REPO="https://github.com/linux-rdma/rdma-core.git"
UPSTREAM_TAG="v62.0"

echo "=== build-ernic-dv-rdma-core ==="
echo "  ernic dir    : ${ERNIC_DIR}"
echo "  source       : ${SRC_DIR}"
echo "  build        : ${BUILD_DIR}"
echo "  install      : ${INSTALL_DIR}"
echo ""

# -----------------------------------------------------------
# Skip if already built
# -----------------------------------------------------------

if [ -f "${INSTALL_DIR}/lib/libibverbs.so" ] && \
   ! $BUILD_ONLY; then
  echo "rdma-core already installed at" \
    "${INSTALL_DIR}"
  echo "Delete it to force rebuild."
  exit 0
fi

# -----------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------

check_prereqs() {
  local missing=()
  command -v git &>/dev/null || missing+=("git")
  command -v cmake &>/dev/null || missing+=("cmake")
  command -v ninja &>/dev/null || missing+=("ninja-build")

  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing required tools:" \
      "${missing[*]}"
    exit 1
  fi
}

check_prereqs

# -----------------------------------------------------------
# Clone upstream rdma-core
# -----------------------------------------------------------

clone_upstream() {
  if [ -d "${SRC_DIR}/.git" ]; then
    echo "Source already cloned, reusing."
    return 0
  fi

  echo "Cloning upstream rdma-core" \
    "(${UPSTREAM_TAG})..."
  git clone --depth 1 -b "${UPSTREAM_TAG}" \
    "${UPSTREAM_REPO}" "${SRC_DIR}"
}

clone_upstream

# -----------------------------------------------------------
# Add rocm_ernic provider
# -----------------------------------------------------------

add_provider() {
  local prov_dir="${SRC_DIR}/providers/rocm_ernic"
  if [ -d "${prov_dir}" ]; then
    echo "Provider already added, updating..."
  fi

  mkdir -p "${prov_dir}"

  # Create provider CMakeLists.txt
  cat > "${prov_dir}/CMakeLists.txt" << 'CEOF'
rdma_provider(rocm_ernic
  rocm_ernic.c
  rocm_ernic_dv.c
)
publish_headers(infiniband
  rocm_ernic_dv.h
)
CEOF

  # Copy DV UAPI header from the kernel driver
  if [ -f "${ERNIC_DIR}/driver/rocm_ernic_dv_uapi.h" ]
  then
    cp "${ERNIC_DIR}/driver/rocm_ernic_dv_uapi.h" \
      "${prov_dir}/"
  fi

  # Copy ABI header
  if [ -f "${ERNIC_DIR}/driver/rocm_ernic-abi.h" ]
  then
    cp "${ERNIC_DIR}/driver/rocm_ernic-abi.h" \
      "${prov_dir}/"
  fi

  # Create the provider source
  cat > "${prov_dir}/rocm_ernic.h" << 'HEOF'
/* Internal header for rocm_ernic rdma-core provider */
#ifndef __ROCM_ERNIC_PROV_H__
#define __ROCM_ERNIC_PROV_H__

#include <infiniband/driver.h>
#include <stdint.h>

struct rocm_ernic_context {
    struct verbs_context verbs_ctx;
    void *uar;
    uint32_t qp_tab_size;
};

struct rocm_ernic_dv_cq_obj {
    struct verbs_cq verbs_cq;
    uint32_t cq_handle;
    uint32_t cqn;
    uint32_t ncqe;
    uint32_t cqe_size;
};

struct rocm_ernic_dv_qp_obj {
    struct verbs_qp verbs_qp;
    uint32_t qp_handle;
    uint32_t qpn;
    void *uar_ptr;
    uint32_t uar_qp_offset;
    uint32_t uar_cq_offset;
    uint32_t sq_depth;
    uint32_t rq_depth;
    uint32_t sq_wqe_size;
    uint32_t rq_wqe_size;
};

struct rocm_ernic_dv_umem_obj {
    void *addr;
    size_t size;
    uint32_t umem_id;
};

static inline struct rocm_ernic_context *
to_ernic_ctx(struct ibv_context *ctx)
{
    return container_of(ctx,
        struct rocm_ernic_context,
        verbs_ctx.context);
}

#endif /* __ROCM_ERNIC_PROV_H__ */
HEOF

  cat > "${prov_dir}/rocm_ernic.c" << 'CEOF'
// SPDX-License-Identifier: GPL-2.0 OR BSD-2-Clause
/*
 * rocm_ernic rdma-core provider -- standard verbs
 * entry point. Matches PCI vendor 0x1022 (AMD)
 * device 0x1484 (ROCm ERNIC).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <infiniband/driver.h>

#include "rocm_ernic.h"

static const struct verbs_match_ent
    match_table[] = {
    VERBS_PCI_MATCH(0x1022, 0x1484, NULL),
    {},
};

static struct verbs_context *
rocm_ernic_alloc_context(
    struct ibv_device *ibdev,
    int cmd_fd,
    void *private_data)
{
    struct rocm_ernic_context *ctx;

    ctx = verbs_init_and_alloc_context(
        ibdev, cmd_fd, ctx, verbs_ctx,
        RDMA_DRIVER_UNKNOWN);
    if (!ctx)
        return NULL;

    return &ctx->verbs_ctx;
}

static void rocm_ernic_free_context(
    struct ibv_context *ibctx)
{
    struct rocm_ernic_context *ctx =
        to_ernic_ctx(ibctx);
    verbs_uninit_context(&ctx->verbs_ctx);
    free(ctx);
}

static const struct verbs_context_ops
    rocm_ernic_ctx_ops = {
    .free_context = rocm_ernic_free_context,
};

static struct verbs_device *
rocm_ernic_device_alloc(
    struct verbs_sysfs_dev *sysfs_dev)
{
    struct verbs_device *dev;
    dev = calloc(1, sizeof(*dev));
    if (!dev)
        return NULL;
    return dev;
}

static void rocm_ernic_device_free(
    struct verbs_device *dev)
{
    free(dev);
}

static const struct verbs_device_ops
    rocm_ernic_dev_ops = {
    .name = "rocm_ernic",
    .match_min_abi_version = 0,
    .match_max_abi_version = INT_MAX,
    .match_table = match_table,
    .alloc_device = rocm_ernic_device_alloc,
    .uninit_device = rocm_ernic_device_free,
    .alloc_context = rocm_ernic_alloc_context,
};

PROVIDER_DRIVER(rocm_ernic, rocm_ernic_dev_ops);
CEOF

  cat > "${prov_dir}/rocm_ernic_dv.c" << 'CEOF'
// SPDX-License-Identifier: GPL-2.0 OR BSD-2-Clause
/*
 * rocm_ernic DV library -- direct verbs functions
 * for GPU-direct queue access.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <infiniband/driver.h>

#include "rocm_ernic.h"
#include "rocm_ernic_dv.h"

struct rocm_ernic_dv_umem *
rocm_ernic_dv_umem_reg(
    struct ibv_context *ctx,
    struct rocm_ernic_dv_umem_attr *attr)
{
    struct rocm_ernic_dv_umem_obj *obj;
    obj = calloc(1, sizeof(*obj));
    if (!obj)
        return NULL;
    obj->addr = attr->addr;
    obj->size = attr->size;
    return (struct rocm_ernic_dv_umem *)obj;
}

int rocm_ernic_dv_umem_dereg(
    struct rocm_ernic_dv_umem *umem)
{
    free(umem);
    return 0;
}

struct ibv_cq *rocm_ernic_dv_create_cq(
    struct ibv_context *ctx,
    struct rocm_ernic_dv_cq_init_attr *attr)
{
    /* Stub -- full implementation uses kernel
     * DV ioctls */
    (void)ctx;
    (void)attr;
    return NULL;
}

int rocm_ernic_dv_destroy_cq(struct ibv_cq *cq)
{
    (void)cq;
    return 0;
}

struct ibv_qp *rocm_ernic_dv_create_qp(
    struct ibv_pd *pd,
    struct rocm_ernic_dv_qp_init_attr *attr)
{
    /* Stub -- full implementation uses kernel
     * DV ioctls */
    (void)pd;
    (void)attr;
    return NULL;
}

int rocm_ernic_dv_destroy_qp(struct ibv_qp *qp)
{
    (void)qp;
    return 0;
}

int rocm_ernic_dv_modify_qp(
    struct ibv_qp *qp,
    struct ibv_qp_attr *attr,
    int attr_mask)
{
    return ibv_modify_qp(qp, attr, attr_mask);
}

uint32_t rocm_ernic_dv_get_cq_id(
    struct ibv_cq *cq)
{
    (void)cq;
    return 0;
}

int rocm_ernic_dv_get_qp_attr(
    struct ibv_qp *qp,
    struct rocm_ernic_dv_qp_attr *attr)
{
    (void)qp;
    memset(attr, 0, sizeof(*attr));
    return 0;
}
CEOF

  # Copy the public DV header
  cat > "${prov_dir}/rocm_ernic_dv.h" << 'DVEOF'
/*
 * Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 * Public Direct Verbs API for rocm_ernic.
 */
#ifndef __ROCM_ERNIC_DV_H__
#define __ROCM_ERNIC_DV_H__

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct ibv_context;
struct ibv_pd;
struct ibv_cq;
struct ibv_qp;
struct ibv_qp_attr;

enum rocm_ernic_dv_umem_flags {
    ROCM_ERNIC_DV_UMEM_FLAGS_DMABUF = 1 << 0,
};

struct rocm_ernic_dv_umem_attr {
    void *addr;
    size_t size;
    uint32_t access_flags;
    int dmabuf_fd;
    uint64_t comp_mask;
};

struct rocm_ernic_dv_umem;

struct rocm_ernic_dv_cq_init_attr {
    uint64_t cq_handle;
    void *umem_handle;
    uint32_t ncqe;
    uint64_t comp_mask;
};

struct rocm_ernic_dv_cq_attr {
    uint32_t ncqe;
    uint32_t cqe_size;
    uint32_t cqn;
};

struct rocm_ernic_dv_qp_init_attr {
    uint32_t qp_type;
    uint32_t max_send_wr;
    uint32_t max_recv_wr;
    uint32_t max_send_sge;
    uint32_t max_recv_sge;
    uint32_t max_inline_data;
    struct ibv_cq *send_cq;
    struct ibv_cq *recv_cq;
    uint64_t qp_handle;
    void *sq_umem_handle;
    uint32_t sq_len;
    uint32_t sq_wqe_size;
    void *rq_umem_handle;
    uint32_t rq_len;
    uint32_t rq_wqe_size;
    uint64_t comp_mask;
};

struct rocm_ernic_dv_qp_attr {
    uint32_t qpn;
    uint32_t sq_depth;
    uint32_t rq_depth;
    uint32_t sq_wqe_size;
    uint32_t rq_wqe_size;
    void *uar_ptr;
    uint32_t uar_qp_offset;
    uint32_t uar_cq_offset;
};

struct rocm_ernic_dv_umem *
rocm_ernic_dv_umem_reg(
    struct ibv_context *ctx,
    struct rocm_ernic_dv_umem_attr *attr);
int rocm_ernic_dv_umem_dereg(
    struct rocm_ernic_dv_umem *umem);
struct ibv_cq *rocm_ernic_dv_create_cq(
    struct ibv_context *ctx,
    struct rocm_ernic_dv_cq_init_attr *attr);
int rocm_ernic_dv_destroy_cq(struct ibv_cq *cq);
struct ibv_qp *rocm_ernic_dv_create_qp(
    struct ibv_pd *pd,
    struct rocm_ernic_dv_qp_init_attr *attr);
int rocm_ernic_dv_destroy_qp(struct ibv_qp *qp);
int rocm_ernic_dv_modify_qp(
    struct ibv_qp *qp,
    struct ibv_qp_attr *attr,
    int attr_mask);
uint32_t rocm_ernic_dv_get_cq_id(
    struct ibv_cq *cq);
int rocm_ernic_dv_get_qp_attr(
    struct ibv_qp *qp,
    struct rocm_ernic_dv_qp_attr *attr);

#ifdef __cplusplus
}
#endif
#endif /* __ROCM_ERNIC_DV_H__ */
DVEOF

  echo "ROCm ERNIC provider added to rdma-core."
}

add_provider

# -----------------------------------------------------------
# Build with CMake
# -----------------------------------------------------------

build_rdma_core() {
  mkdir -p "${BUILD_DIR}"

  echo "Configuring rdma-core..."
  cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    -GNinja \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DNO_PYVERBS=1 \
    -DNO_MAN_PAGES=1 \
    -DENABLE_STATIC=0

  echo "Building rdma-core (${NPROC} jobs)..."
  cmake --build "${BUILD_DIR}" \
    -j "${NPROC}"

  if ! $BUILD_ONLY; then
    echo "Installing to ${INSTALL_DIR}..."
    cmake --install "${BUILD_DIR}"
  fi

  echo ""
  echo "=== rdma-core with rocm_ernic built ==="
  echo "  build: ${BUILD_DIR}"
  if ! $BUILD_ONLY; then
    echo "  install: ${INSTALL_DIR}"
  fi
}

build_rdma_core
