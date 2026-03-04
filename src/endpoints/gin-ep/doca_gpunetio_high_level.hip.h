/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef DOCA_GPUNETIO_HIGH_LEVEL_HIP_H
#define DOCA_GPUNETIO_HIGH_LEVEL_HIP_H

#include <cstdint>

#include "doca_error.hip.h"
#include "doca_gpunetio_verbs_def.hip.h"
#include "doca_verbs.hip.h"

#ifdef __cplusplus
extern "C" {
#endif

enum doca_gpu_verbs_mem_reg_type {
  DOCA_GPUNETIO_VERBS_MEM_REG_TYPE_DEFAULT = 0,
  DOCA_GPUNETIO_VERBS_MEM_REG_TYPE_CUDA_DMABUF = 1,
  DOCA_GPUNETIO_VERBS_MEM_REG_TYPE_CUDA_PEERMEM = 2,
  DOCA_GPUNETIO_VERBS_MEM_REG_TYPE_MAX,
};

struct ibv_pd;
struct doca_verbs_umem;
struct doca_verbs_uar;
struct doca_gpu_dev_verbs_qp;
struct doca_gpu;
struct doca_gpu_verbs_qp;

struct doca_gpu_verbs_qp_init_attr_hl {
  struct doca_gpu* gpu_dev;
  struct ibv_pd* ibpd;
  uint16_t sq_nwqe;
  doca_gpu_dev_verbs_nic_handler nic_handler;
  enum doca_gpu_verbs_mem_reg_type mreg_type;
  enum doca_gpu_verbs_send_dbr_mode_ext send_dbr_mode_ext;
};

struct doca_gpu_verbs_qp_hl {
  struct doca_gpu* gpu_dev;
  struct doca_verbs_cq* cq_sq;
  void* cq_sq_umem_gpu_ptr;
  struct doca_verbs_umem* cq_sq_umem;
  void* cq_sq_umem_dbr_gpu_ptr;
  struct doca_verbs_umem* cq_sq_umem_dbr;
  struct doca_verbs_qp* qp;
  void* qp_umem_gpu_ptr;
  struct doca_verbs_umem* qp_umem;
  void* qp_umem_dbr_gpu_ptr;
  struct doca_verbs_umem* qp_umem_dbr;
  struct doca_verbs_uar* external_uar;
  doca_gpu_dev_verbs_nic_handler nic_handler;
  enum doca_gpu_verbs_send_dbr_mode_ext send_dbr_mode_ext;
  struct doca_gpu_verbs_qp* qp_gverbs;
};

struct doca_gpu_verbs_qp_group_hl {
  struct doca_gpu_verbs_qp_hl qp_main;
  struct doca_gpu_verbs_qp_hl qp_companion;
};

doca_error_t doca_gpu_verbs_create_qp_hl(
  struct doca_gpu_verbs_qp_init_attr_hl* qp_init_attr,
  struct doca_gpu_verbs_qp_hl** qp);
doca_error_t doca_gpu_verbs_destroy_qp_hl(struct doca_gpu_verbs_qp_hl* qp);
doca_error_t doca_gpu_verbs_create_qp_group_hl(
  struct doca_gpu_verbs_qp_init_attr_hl* qp_init_attr,
  struct doca_gpu_verbs_qp_group_hl** qpg);
doca_error_t doca_gpu_verbs_destroy_qp_group_hl(
  struct doca_gpu_verbs_qp_group_hl* qpg);

#ifdef __cplusplus
}
#endif

#endif
