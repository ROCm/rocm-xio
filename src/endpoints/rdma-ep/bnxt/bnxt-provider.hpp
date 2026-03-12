/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/bnxt/provider_gda_bnxt.hpp, adapted for rocm-xio.
 * BNXT (Broadcom Thor 2) provider structures and function table.
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
  void *handle;
  void *umem_handle;
  uint64_t length;
  uint32_t depth;
  struct ibv_cq *cq;
  uint64_t dmabuf_offset;
  int dmabuf_fd;
} __attribute__((packed));

struct bnxt_host_qp {
  struct bnxt_re_dv_qp_mem_info mem_info;
  struct bnxt_re_dv_qp_init_attr attr;
  struct bnxt_re_dv_db_region_attr *db_region_attr;
  void *sq_buf;
  void *rq_buf;
  void *msntbl;
  uint32_t msn_tbl_sz;
  uint64_t sq_dmabuf_offset;
  uint64_t rq_dmabuf_offset;
  int sq_dmabuf_fd;
  int rq_dmabuf_fd;
} __attribute__((packed));

struct bnxtdv_funcs_t {
  int (*init_obj)(struct bnxt_re_dv_obj *obj, uint64_t obj_type);
  struct ibv_qp *(*create_qp)(struct ibv_pd *pd,
                               struct bnxt_re_dv_qp_init_attr *qp_attr);
  int (*destroy_qp)(struct ibv_qp *ibvqp);
  int (*modify_qp)(struct ibv_qp *ibv_qp, struct ibv_qp_attr *attr,
                   int attr_mask, uint32_t type, uint32_t value);
  int (*qp_mem_alloc)(struct ibv_pd *ibvpd, struct ibv_qp_init_attr *attr,
                      struct bnxt_re_dv_qp_mem_info *dv_qp_mem);
  struct ibv_cq *(*create_cq)(struct ibv_context *ibvctx,
                               struct bnxt_re_dv_cq_init_attr *cq_attr);
  int (*destroy_cq)(struct ibv_cq *ibv_cq);
  void *(*cq_mem_alloc)(struct ibv_context *ibvctx, int num_cqe,
                        struct bnxt_re_dv_cq_attr *cq_attr);
  void *(*umem_reg)(struct ibv_context *ibvctx,
                    struct bnxt_re_dv_umem_reg_attr *in);
  int (*umem_dereg)(void *umem_handle);
  struct bnxt_re_dv_db_region_attr *(*alloc_db_region)(
    struct ibv_context *ctx);
  int (*free_db_region)(struct ibv_context *ctx,
                        struct bnxt_re_dv_db_region_attr *attr);
};

} // namespace rdma_ep

#endif // RDMA_EP_BNXT_PROVIDER_HPP
