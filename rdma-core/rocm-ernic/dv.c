/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Direct Verbs API for the rocm_ernic rdma-core provider.
 * Written against rdma-core v62.0 APIs.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <errno.h>
#include <inttypes.h>

#include <infiniband/driver.h>
#include <infiniband/verbs.h>

#include "rocm_ernic.h"
#include "rocm_ernic_dv.h"

/* ---- UMEM registration ---- */

struct rocm_ernic_dv_umem *
rocm_ernic_dv_umem_reg(struct ibv_context *ctx,
                       struct rocm_ernic_dv_umem_attr *in)
{
    struct rocm_ernic_dv_umem *umem;
    int ret;

    if (!in || !in->addr || in->size == 0) {
        errno = EINVAL;
        return NULL;
    }

    if ((in->comp_mask &
         ROCM_ERNIC_DV_UMEM_FLAGS_DMABUF) &&
        in->dmabuf_fd < 0) {
        errno = EBADF;
        return NULL;
    }

    ret = ibv_dontfork_range(in->addr, in->size);
    if (ret) {
        errno = ret;
        return NULL;
    }

    umem = calloc(1, sizeof(*umem));
    if (!umem) {
        ibv_dofork_range(in->addr, in->size);
        errno = ENOMEM;
        return NULL;
    }

    umem->context = ctx;
    umem->addr = in->addr;
    umem->size = in->size;
    umem->access_flags = in->access_flags;
    umem->dmabuf_fd =
        (in->comp_mask &
         ROCM_ERNIC_DV_UMEM_FLAGS_DMABUF)
            ? in->dmabuf_fd
            : -1;

    return umem;
}

int rocm_ernic_dv_umem_dereg(
    struct rocm_ernic_dv_umem *umem)
{
    if (!umem)
        return -EINVAL;

    ibv_dofork_range(umem->addr, umem->size);
    free(umem);
    return 0;
}

/* ---- DV CQ ---- */

struct ibv_cq *rocm_ernic_dv_create_cq(
    struct ibv_context *ctx,
    struct rocm_ernic_dv_cq_init_attr *attr)
{
    struct rocm_ernic_cq *cq;
    struct ib_uverbs_create_cq_resp resp = {};
    int ret;

    if (!attr || !attr->umem_handle ||
        attr->ncqe == 0) {
        errno = EINVAL;
        return NULL;
    }

    cq = calloc(1, sizeof(*cq));
    if (!cq) {
        errno = ENOMEM;
        return NULL;
    }

    ret = ibv_cmd_create_cq(
        ctx, (int)attr->ncqe, NULL, 0,
        &cq->vcq.cq, NULL, 0,
        &resp, sizeof(resp));
    if (ret) {
        free(cq);
        errno = -ret;
        return NULL;
    }

    cq->cqn = resp.cq_handle;
    cq->ncqe = attr->ncqe;
    cq->cqe_size = sizeof(struct rocm_ernic_cqe);

    struct rocm_ernic_dv_umem *umem =
        (struct rocm_ernic_dv_umem *)attr->umem_handle;
    cq->buf = umem->addr;
    cq->buf_len = umem->size;

    return &cq->vcq.cq;
}

int rocm_ernic_dv_destroy_cq(struct ibv_cq *ibcq)
{
    struct rocm_ernic_cq *cq;
    int ret;

    if (!ibcq)
        return -EINVAL;

    cq = to_rocm_ernic_cq(ibcq);
    ret = ibv_cmd_destroy_cq(ibcq);
    if (ret)
        return ret;

    free(cq);
    return 0;
}

/* ---- DV QP ---- */

struct ibv_qp *rocm_ernic_dv_create_qp(
    struct ibv_pd *pd,
    struct rocm_ernic_dv_qp_init_attr *attr)
{
    struct rocm_ernic_qp *qp;
    struct ibv_qp_init_attr ib_attr = {};
    struct ibv_create_qp cmd = {};
    struct ib_uverbs_create_qp_resp resp = {};
    int ret;

    if (!attr || !attr->send_cq ||
        !attr->sq_umem_handle) {
        errno = EINVAL;
        return NULL;
    }

    qp = calloc(1, sizeof(*qp));
    if (!qp) {
        errno = ENOMEM;
        return NULL;
    }

    ib_attr.send_cq = attr->send_cq;
    ib_attr.recv_cq = attr->recv_cq
                          ? attr->recv_cq
                          : attr->send_cq;
    ib_attr.cap.max_send_wr = attr->max_send_wr;
    ib_attr.cap.max_recv_wr = attr->max_recv_wr;
    ib_attr.cap.max_send_sge = attr->max_send_sge;
    ib_attr.cap.max_recv_sge = attr->max_recv_sge;
    ib_attr.cap.max_inline_data =
        attr->max_inline_data;
    ib_attr.qp_type = attr->qp_type;

    ret = ibv_cmd_create_qp(pd, &qp->vqp.qp, &ib_attr,
                            &cmd, sizeof(cmd),
                            &resp, sizeof(resp));
    if (ret) {
        free(qp);
        errno = -ret;
        return NULL;
    }

    qp->qpn = resp.qpn;
    qp->qp_handle = resp.qp_handle;

    return &qp->vqp.qp;
}

int rocm_ernic_dv_destroy_qp(struct ibv_qp *ibqp)
{
    struct rocm_ernic_qp *qp;
    int ret;

    if (!ibqp)
        return -EINVAL;

    qp = to_rocm_ernic_qp(ibqp);

    if (qp->uar_ptr) {
        long page_size = sysconf(_SC_PAGESIZE);
        munmap(qp->uar_ptr, page_size);
    }

    ret = ibv_cmd_destroy_qp(ibqp);
    if (ret)
        return ret;

    free(qp);
    return 0;
}

int rocm_ernic_dv_modify_qp(struct ibv_qp *qp,
                            struct ibv_qp_attr *attr,
                            int attr_mask)
{
    struct ibv_modify_qp cmd;

    return ibv_cmd_modify_qp(qp, attr, attr_mask,
                             &cmd, sizeof(cmd));
}

/* ---- DV query helpers ---- */

uint32_t rocm_ernic_dv_get_cq_id(struct ibv_cq *ibcq)
{
    if (!ibcq)
        return 0;

    return to_rocm_ernic_cq(ibcq)->cqn;
}

int rocm_ernic_dv_get_qp_attr(
    struct ibv_qp *ibqp,
    struct rocm_ernic_dv_qp_attr *out)
{
    struct rocm_ernic_qp *qp;

    if (!ibqp || !out)
        return -EINVAL;

    qp = to_rocm_ernic_qp(ibqp);

    memset(out, 0, sizeof(*out));
    out->qpn = qp->qpn;
    out->sq_depth = qp->sq_depth;
    out->rq_depth = qp->rq_depth;
    out->sq_wqe_size = qp->sq_wqe_size;
    out->rq_wqe_size = qp->rq_wqe_size;
    out->uar_ptr = qp->uar_ptr;
    out->uar_qp_offset = qp->uar_qp_offset;
    out->uar_cq_offset = qp->uar_cq_offset;

    return 0;
}
