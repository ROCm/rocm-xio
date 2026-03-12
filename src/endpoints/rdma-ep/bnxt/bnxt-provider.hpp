/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM
 *   src/gda/bnxt/provider_gda_bnxt.hpp,
 * adapted for rocm-xio.
 * BNXT (Broadcom Thor 2) provider structures and
 * function table.
 *
 * Updated for the v11 Direct Verbs API from the
 * sbasavapatna/rdma-core dv-upstream fork.
 */

#ifndef RDMA_EP_BNXT_PROVIDER_HPP
#define RDMA_EP_BNXT_PROVIDER_HPP

#include "ibv-core.hpp"

extern "C" {
#include "bnxt/bnxt-re-dv.h"
#include "bnxt/bnxt-re-hsi.h"
}

namespace rdma_ep {

#define GDA_BNXT_WQE_SLOT_COUNT 3

struct bnxt_device_wq {
  void *buf;
  uint32_t depth;
  uint32_t head;
  uint32_t tail;
  uint32_t flags;
  uint32_t id;
} __attribute__((packed));

struct bnxt_device_cq : public bnxt_device_wq {
} __attribute__((packed));

struct bnxt_device_sq : public bnxt_device_wq {
  uint32_t psn;
  void *msntbl;
  uint32_t msn;
  uint32_t msn_tbl_sz;
  uint32_t psn_sz_log2;
  uint64_t mtu;
  uint32_t lock;
} __attribute__((packed));

struct bnxt_host_cq {
  void *buf;
  struct bnxt_re_dv_umem *umem;
  uint64_t length;
  uint32_t depth;
  uint32_t cqe_size;
  struct ibv_cq *cq;
  uint64_t dmabuf_offset;
  int dmabuf_fd;
} __attribute__((packed));

struct bnxt_host_qp {
  struct bnxt_re_dv_qp_init_attr attr;
  struct bnxt_re_dv_db_region_attr *db_region_attr;
  void *sq_buf;
  void *rq_buf;
  void *msntbl;
  uint32_t msn_tbl_sz;
  uint32_t sq_len;
  uint32_t sq_slots;
  uint32_t sq_wqe_sz;
  uint32_t sq_psn_sz;
  uint32_t sq_npsn;
  uint32_t rq_len;
  uint32_t rq_slots;
  uint32_t rq_wqe_sz;
  uint64_t sq_dmabuf_offset;
  uint64_t rq_dmabuf_offset;
  int sq_dmabuf_fd;
  int rq_dmabuf_fd;
} __attribute__((packed));

struct bnxtdv_funcs_t {
  struct ibv_qp *(*create_qp)(
      struct ibv_pd *pd,
      struct bnxt_re_dv_qp_init_attr *qp_attr);
  int (*destroy_qp)(struct ibv_qp *ibvqp);
  int (*modify_qp)(
      struct ibv_qp *ibv_qp,
      struct ibv_qp_attr *attr,
      int attr_mask);
  struct ibv_cq *(*create_cq)(
      struct ibv_context *ibvctx,
      struct bnxt_re_dv_cq_init_attr *cq_attr);
  int (*destroy_cq)(struct ibv_cq *ibv_cq);
  struct bnxt_re_dv_umem *(*umem_reg)(
      struct ibv_context *ibvctx,
      struct bnxt_re_dv_umem_reg_attr *in);
  int (*umem_dereg)(struct bnxt_re_dv_umem *umem);
  struct bnxt_re_dv_db_region_attr *(*alloc_db_region)(
      struct ibv_context *ctx);
  int (*free_db_region)(
      struct ibv_context *ctx,
      struct bnxt_re_dv_db_region_attr *attr);
  int (*get_default_db_region)(
      struct ibv_context *ibvctx,
      struct bnxt_re_dv_db_region_attr *out);
  uint32_t (*get_cq_id)(struct ibv_cq *ibvcq);
};

} // namespace rdma_ep

#endif // RDMA_EP_BNXT_PROVIDER_HPP
