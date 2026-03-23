/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Direct Verbs API for the rocm_ernic rdma-core
 * provider.  This header defines the DV functions
 * that rocm-xio loads via dlopen/dlsym from
 * librocm_ernic.so.
 *
 * Modeled after the bnxt_re DV API.
 */

#ifndef __ROCM_ERNIC_DV_H__
#define __ROCM_ERNIC_DV_H__

#define ROCM_ERNIC_DV_API_VERSION 1

#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

struct ibv_context;
struct ibv_pd;
struct ibv_cq;
struct ibv_qp;
struct ibv_qp_attr;

/*
 * UMEM -- user memory registration for GPU or
 * CPU buffers used in DV queues.
 */

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

struct rocm_ernic_dv_umem {
	struct ibv_context *context;
	void *addr;
	size_t size;
	uint32_t access_flags;
	int dmabuf_fd;
};

/* CQ creation attributes for DV */
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

/* QP creation attributes for DV */
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

/* UAR doorbell info returned after QP creation */
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

/* DV API functions */

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

uint32_t rocm_ernic_dv_get_cq_id(struct ibv_cq *cq);

int rocm_ernic_dv_get_qp_attr(
	struct ibv_qp *qp,
	struct rocm_ernic_dv_qp_attr *attr);

#ifdef __cplusplus
}
#endif
#endif /* __ROCM_ERNIC_DV_H__ */
