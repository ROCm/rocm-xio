/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef __ROCM_ERNIC_PROVIDER_H__
#define __ROCM_ERNIC_PROVIDER_H__

#include <infiniband/driver.h>
#include <infiniband/verbs.h>
#include <stdint.h>
#include <pthread.h>

#define ROCM_ERNIC_VENDOR_ID 0x1022
#define ROCM_ERNIC_DEVICE_ID 0x8000
#define ROCM_ERNIC_UVERBS_ABI_VERSION 3

struct rocm_ernic_cqe {
    uint64_t wr_id;
    uint64_t qp;
    uint32_t opcode;
    uint32_t status;
    uint32_t byte_len;
    uint32_t imm_data;
    uint32_t src_qp;
    uint32_t wc_flags;
    uint32_t vendor_err;
    uint16_t pkey_index;
    uint16_t slid;
    uint8_t sl;
    uint8_t dlid_path_bits;
    uint8_t port_num;
    uint8_t smac[6];
    uint8_t network_hdr_type;
    uint8_t reserved2[6];
};

struct rocm_ernic_alloc_ucontext_resp {
    struct ib_uverbs_get_context_resp ibv_resp;
    __u32 qp_tab_size;
    __u32 reserved;
};

struct rocm_ernic_alloc_pd_resp_ex {
    struct ib_uverbs_alloc_pd_resp ibv_resp;
    __u32 pdn;
    __u32 reserved;
};

struct rocm_ernic_create_cq_resp_ex {
    struct ib_uverbs_create_cq_resp ibv_resp;
    __u32 cqn;
    __u32 ncqe;
    __u32 cqe_size;
    __u32 reserved;
};

struct rocm_ernic_create_qp_resp_ex {
    struct ib_uverbs_create_qp_resp ibv_resp;
    __u32 qpn;
    __u32 qp_handle;
    __u32 sq_depth;
    __u32 rq_depth;
    __u32 sq_wqe_size;
    __u32 rq_wqe_size;
};

struct rocm_ernic_device {
    struct verbs_device vdev;
};

struct rocm_ernic_context {
    struct verbs_context vctx;
    uint32_t qp_tab_size;
    uint32_t dv_abi_version;
};

struct rocm_ernic_pd {
    struct ibv_pd ibvpd;
    uint32_t pdn;
};

struct rocm_ernic_cq {
    struct verbs_cq vcq;
    uint32_t cqn;
    uint32_t ncqe;
    uint32_t cqe_size;
    void *buf;
    size_t buf_len;
};

struct rocm_ernic_qp {
    struct verbs_qp vqp;
    uint32_t qpn;
    uint32_t qp_handle;
    uint32_t sq_depth;
    uint32_t rq_depth;
    uint32_t sq_wqe_size;
    uint32_t rq_wqe_size;
    void *uar_ptr;
    uint32_t uar_qp_offset;
    uint32_t uar_cq_offset;
};

static inline struct rocm_ernic_device *
to_rocm_ernic_dev(struct ibv_device *ibdev)
{
    return container_of(ibdev, struct rocm_ernic_device,
                        vdev.device);
}

static inline struct rocm_ernic_context *
to_rocm_ernic_ctx(struct ibv_context *ibctx)
{
    return container_of(ibctx, struct rocm_ernic_context,
                        vctx.context);
}

static inline struct rocm_ernic_pd *
to_rocm_ernic_pd(struct ibv_pd *ibpd)
{
    return container_of(ibpd, struct rocm_ernic_pd, ibvpd);
}

static inline struct rocm_ernic_cq *
to_rocm_ernic_cq(struct ibv_cq *ibcq)
{
    return container_of(ibcq, struct rocm_ernic_cq, vcq.cq);
}

static inline struct rocm_ernic_qp *
to_rocm_ernic_qp(struct ibv_qp *ibqp)
{
    return container_of(ibqp, struct rocm_ernic_qp, vqp.qp);
}

int rocm_ernic_query_device(
    struct ibv_context *ctx,
    const struct ibv_query_device_ex_input *in,
    struct ibv_device_attr_ex *attr, size_t attr_size);
int rocm_ernic_query_port(struct ibv_context *ctx,
                          uint8_t port,
                          struct ibv_port_attr *attr);
struct ibv_pd *rocm_ernic_alloc_pd(struct ibv_context *ctx);
int rocm_ernic_dealloc_pd(struct ibv_pd *pd);
struct ibv_mr *rocm_ernic_reg_mr(struct ibv_pd *pd,
                                 void *addr, size_t length,
                                 uint64_t hca_va, int access);
int rocm_ernic_dereg_mr(struct verbs_mr *vmr);
struct ibv_cq *rocm_ernic_create_cq_v(
    struct ibv_context *ctx, int cqe,
    struct ibv_comp_channel *ch, int comp_vector);
int rocm_ernic_destroy_cq_v(struct ibv_cq *cq);
int rocm_ernic_poll_cq_v(struct ibv_cq *cq, int ne,
                         struct ibv_wc *wc);
int rocm_ernic_req_notify_cq_v(struct ibv_cq *cq,
                               int solicited_only);
struct ibv_qp *rocm_ernic_create_qp_v(
    struct ibv_pd *pd, struct ibv_qp_init_attr *attr);
int rocm_ernic_modify_qp_v(struct ibv_qp *qp,
                           struct ibv_qp_attr *attr,
                           int attr_mask);
int rocm_ernic_query_qp_v(struct ibv_qp *qp,
                          struct ibv_qp_attr *attr,
                          int attr_mask,
                          struct ibv_qp_init_attr *init_attr);
int rocm_ernic_destroy_qp_v(struct ibv_qp *qp);
int rocm_ernic_post_send_v(struct ibv_qp *qp,
                           struct ibv_send_wr *wr,
                           struct ibv_send_wr **bad_wr);
int rocm_ernic_post_recv_v(struct ibv_qp *qp,
                           struct ibv_recv_wr *wr,
                           struct ibv_recv_wr **bad_wr);

#endif /* __ROCM_ERNIC_PROVIDER_H__ */
