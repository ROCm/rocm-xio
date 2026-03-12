/*
 * Copyright (c) 2025, Broadcom. All rights reserved.  The term
 * Broadcom refers to Broadcom Limited and/or its
 * subsidiaries.
 *
 * This software is available to you under a choice of one
 * of two licenses.  You may choose to be licensed under
 * the terms of the GNU General Public License (GPL)
 * Version 2, available from the file COPYING in the main
 * directory of this source tree, or the BSD license below:
 *
 * Redistribution and use in source and binary forms, with
 * or without modification, are permitted provided that the
 * following conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 * 2. Redistributions in binary form must reproduce the
 *    above copyright notice, this list of conditions and
 *    the following disclaimer in the documentation and/or
 *    other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS
 * ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
 * TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY
 * WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 *
 * Description: Direct verb support user interface header
 *
 * Synced with sbasavapatna/rdma-core dv-upstream branch.
 */

#ifndef __BNXT_RE_DV_H__
#define __BNXT_RE_DV_H__

#include <stdint.h>
#include <stddef.h>
#include <linux/types.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Forward declarations -- full definitions come
 * from ibv-core.hpp or <infiniband/verbs.h>.  */
struct ibv_context;
struct ibv_pd;
struct ibv_cq;
struct ibv_qp;
struct ibv_srq;
struct ibv_qp_attr;
enum ibv_qp_type;
struct ib_uverbs_qp_attr;

struct bnxt_re_dv_db_region_attr {
	uint32_t handle;
	uint32_t dpi;
	uint64_t umdbr;
	__u64 *dbr;
};

enum bnxt_re_dv_umem_in_flags {
	BNXT_RE_DV_UMEM_FLAGS_DMABUF = 1 << 0,
};

struct bnxt_re_dv_umem_reg_attr {
	void *addr;
	size_t size;
	uint32_t access_flags;
	uint64_t pgsz_bitmap;
	uint64_t comp_mask;
	int dmabuf_fd;
};

struct bnxt_re_dv_umem;

struct bnxt_re_dv_cq_init_attr {
	uint64_t cq_handle;
	void *umem_handle;
	uint64_t cq_umem_offset;
	uint32_t ncqe;
};

struct bnxt_re_dv_cq_attr {
	uint32_t ncqe;
	uint32_t cqe_size;
};

struct bnxt_re_dv_qp_init_attr {
	enum ibv_qp_type qp_type;
	uint32_t max_send_wr;
	uint32_t max_recv_wr;
	uint32_t max_send_sge;
	uint32_t max_recv_sge;
	uint32_t max_inline_data;
	struct ibv_cq *send_cq;
	struct ibv_cq *recv_cq;
	struct ibv_srq *srq;

	uint64_t qp_handle;
	void *dbr_handle;
	void *sq_umem_handle;
	uint64_t sq_umem_offset;
	uint32_t sq_len;
	uint32_t sq_slots;
	void *rq_umem_handle;
	uint64_t rq_umem_offset;
	uint32_t sq_wqe_sz;
	uint32_t sq_psn_sz;
	uint32_t sq_npsn;
	uint32_t rq_len;
	uint32_t rq_slots;
	uint32_t rq_wqe_sz;
	uint64_t comp_mask;
};

struct bnxt_re_dv_db_region_attr *
bnxt_re_dv_alloc_db_region(struct ibv_context *ctx);
int bnxt_re_dv_free_db_region(
    struct ibv_context *ctx,
    struct bnxt_re_dv_db_region_attr *attr);
int bnxt_re_dv_get_default_db_region(
    struct ibv_context *ibvctx,
    struct bnxt_re_dv_db_region_attr *out);
struct bnxt_re_dv_umem *bnxt_re_dv_umem_reg(
    struct ibv_context *ibvctx,
    struct bnxt_re_dv_umem_reg_attr *in);
int bnxt_re_dv_umem_dereg(struct bnxt_re_dv_umem *umem);
struct ibv_cq *bnxt_re_dv_create_cq(
    struct ibv_context *ibvctx,
    struct bnxt_re_dv_cq_init_attr *cq_attr);
int bnxt_re_dv_destroy_cq(struct ibv_cq *ibv_cq);
struct ibv_qp *bnxt_re_dv_create_qp(
    struct ibv_pd *pd,
    struct bnxt_re_dv_qp_init_attr *qp_attr);
int bnxt_re_dv_destroy_qp(struct ibv_qp *ibvqp);
int bnxt_re_dv_modify_qp(
    struct ibv_qp *ibv_qp,
    struct ibv_qp_attr *attr,
    int attr_mask);
int bnxt_re_dv_query_qp(
    void *qp_handle,
    struct ib_uverbs_qp_attr *attr);
uint32_t bnxt_re_dv_get_cq_id(
    struct ibv_cq *ibvcq);

#ifdef __cplusplus
}
#endif
#endif /* __BNXT_RE_DV_H__ */
