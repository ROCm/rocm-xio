/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * ROCm ERNIC provider structures and DV function
 * table for the rdma-ep endpoint.
 *
 * Modeled after bnxt/bnxt-provider.hpp.
 */

#ifndef RDMA_EP_ERNIC_PROVIDER_HPP
#define RDMA_EP_ERNIC_PROVIDER_HPP

#include "ibv-core.hpp"

extern "C" {
#include "rocm-ernic/rocm-ernic-dv.h"
}

namespace rdma_ep {

/* Device-side work queue (GPU-visible) */
struct ernic_device_wq {
  void *buf;
  uint32_t depth;
  uint32_t head;
  uint32_t tail;
  uint32_t wqe_size;
} __attribute__((packed));

/* Device-side CQ (GPU-visible) */
struct ernic_device_cq : public ernic_device_wq {
  uint32_t cons_idx;
  uint32_t cqe_size;
} __attribute__((packed));

/* Device-side SQ (GPU-visible) */
struct ernic_device_sq : public ernic_device_wq {
  uint32_t psn;
  uint64_t mtu;
  uint32_t lock;
  volatile uint32_t *uar_ptr;
  uint32_t uar_qp_offset;
  uint32_t qpn;
} __attribute__((packed));

/* Host-side CQ (used during setup) */
struct ernic_host_cq {
  void *buf;
  struct rocm_ernic_dv_umem *umem;
  uint64_t length;
  uint32_t depth;
  uint32_t cqe_size;
  struct ibv_cq *cq;
  int dmabuf_fd;
} __attribute__((packed));

/* Host-side QP (used during setup) */
struct ernic_host_qp {
  struct rocm_ernic_dv_qp_init_attr attr;
  void *sq_buf;
  void *rq_buf;
  uint32_t sq_len;
  uint32_t sq_depth;
  uint32_t sq_wqe_size;
  uint32_t rq_len;
  uint32_t rq_depth;
  uint32_t rq_wqe_size;
  int sq_dmabuf_fd;
  int rq_dmabuf_fd;
  void *uar_ptr;
  uint32_t uar_qp_offset;
  uint32_t uar_cq_offset;
} __attribute__((packed));

/* DV function table (dlsym'd from librocm_ernic.so) */
struct ernicdv_funcs_t {
  struct ibv_qp *(*create_qp)(
      struct ibv_pd *pd,
      struct rocm_ernic_dv_qp_init_attr *qp_attr);
  int (*destroy_qp)(struct ibv_qp *qp);
  int (*modify_qp)(
      struct ibv_qp *qp,
      struct ibv_qp_attr *attr,
      int attr_mask);
  struct ibv_cq *(*create_cq)(
      struct ibv_context *ctx,
      struct rocm_ernic_dv_cq_init_attr *cq_attr);
  int (*destroy_cq)(struct ibv_cq *cq);
  struct rocm_ernic_dv_umem *(*umem_reg)(
      struct ibv_context *ctx,
      struct rocm_ernic_dv_umem_attr *attr);
  int (*umem_dereg)(
      struct rocm_ernic_dv_umem *umem);
  uint32_t (*get_cq_id)(struct ibv_cq *cq);
  int (*get_qp_attr)(
      struct ibv_qp *qp,
      struct rocm_ernic_dv_qp_attr *attr);
};

} // namespace rdma_ep

#endif // RDMA_EP_ERNIC_PROVIDER_HPP
