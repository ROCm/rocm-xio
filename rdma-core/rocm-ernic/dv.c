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

    fprintf(stderr,
            "rocm_ernic_dv: umem_reg: "
            "addr=%p size=%zu comp_mask=0x%lx "
            "dmabuf_fd=%d access=0x%x\n",
            in ? in->addr : NULL,
            in ? in->size : 0,
            in ? (unsigned long)in->comp_mask : 0,
            in ? in->dmabuf_fd : -1,
            in ? in->access_flags : 0);

    if (!in || in->size == 0) {
        fprintf(stderr,
                "rocm_ernic_dv: umem_reg: "
                "EINVAL (null input or zero size)\n");
        errno = EINVAL;
        return NULL;
    }

    if ((in->comp_mask &
         ROCM_ERNIC_DV_UMEM_FLAGS_DMABUF) &&
        in->dmabuf_fd < 0) {
        fprintf(stderr,
                "rocm_ernic_dv: umem_reg: "
                "EBADF (dmabuf fd=%d)\n",
                in->dmabuf_fd);
        errno = EBADF;
        return NULL;
    }

    /*
     * Skip ibv_dontfork_range for dmabuf-backed
     * buffers and GPU device memory where addr
     * may not be a valid CPU VA.
     */
    if (!(in->comp_mask &
          ROCM_ERNIC_DV_UMEM_FLAGS_DMABUF) &&
        in->addr) {
        ret = ibv_dontfork_range(in->addr, in->size);
        if (ret) {
            fprintf(stderr,
                    "rocm_ernic_dv: umem_reg: "
                    "dontfork failed: %d (%s)\n",
                    ret, strerror(ret));
            errno = ret;
            return NULL;
        }
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
    struct rocm_ernic_create_cq_cmd cmd = {};
    struct rocm_ernic_create_cq_resp_ex resp = {};
    struct rocm_ernic_dv_umem *umem;
    int ret;

    if (!attr || !attr->umem_handle ||
        attr->ncqe == 0) {
        errno = EINVAL;
        return NULL;
    }

    umem = (struct rocm_ernic_dv_umem *)
        attr->umem_handle;

    cq = calloc(1, sizeof(*cq));
    if (!cq) {
        errno = ENOMEM;
        return NULL;
    }

    cmd.buf_addr = (uintptr_t)umem->addr;
    cmd.buf_size = (uint32_t)umem->size;
    cmd.ncqe = attr->ncqe;
    cmd.cqe_size = sizeof(struct rocm_ernic_cqe);

    fprintf(stderr,
            "rocm_ernic_dv: create_cq: "
            "ncqe=%u buf_addr=0x%lx "
            "buf_size=%u cqe_size=%u\n",
            attr->ncqe,
            (unsigned long)cmd.buf_addr,
            cmd.buf_size, cmd.cqe_size);

    ret = ibv_cmd_create_cq(
        ctx, (int)attr->ncqe, NULL, 0,
        &cq->vcq.cq,
        &cmd.ibv_cmd, sizeof(cmd),
        &resp.ibv_resp, sizeof(resp));
    if (ret) {
        fprintf(stderr,
                "rocm_ernic_dv: create_cq: "
                "ibv_cmd_create_cq failed: "
                "%d (%s)\n",
                ret, strerror(-ret));
        free(cq);
        errno = -ret;
        return NULL;
    }

    cq->cqn = resp.cqn;
    cq->ncqe = resp.ncqe ? resp.ncqe : attr->ncqe;
    cq->cqe_size = resp.cqe_size
                       ? resp.cqe_size
                       : sizeof(struct rocm_ernic_cqe);
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
    struct rocm_ernic_create_qp_cmd cmd = {};
    struct rocm_ernic_create_qp_resp_ex resp = {};
    struct rocm_ernic_dv_umem *sq_umem;
    struct rocm_ernic_dv_umem *rq_umem;
    int ret;

    if (!attr || !attr->send_cq ||
        !attr->sq_umem_handle) {
        errno = EINVAL;
        return NULL;
    }

    sq_umem = (struct rocm_ernic_dv_umem *)
        attr->sq_umem_handle;
    rq_umem = (struct rocm_ernic_dv_umem *)
        attr->rq_umem_handle;

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

    cmd.sbuf_addr = (uintptr_t)sq_umem->addr;
    cmd.sbuf_size = (uint32_t)sq_umem->size;
    cmd.sq_wqe_size = attr->sq_wqe_size;
    cmd.sq_depth = attr->max_send_wr;
    if (rq_umem) {
        cmd.rbuf_addr = (uintptr_t)rq_umem->addr;
        cmd.rbuf_size = (uint32_t)rq_umem->size;
        cmd.rq_wqe_size = attr->rq_wqe_size;
        cmd.rq_depth = attr->max_recv_wr;
    }

    fprintf(stderr,
            "rocm_ernic_dv: create_qp: "
            "sq_buf=0x%lx sq_size=%u "
            "sq_depth=%u sq_wqe=%u\n",
            (unsigned long)cmd.sbuf_addr,
            cmd.sbuf_size, cmd.sq_depth,
            cmd.sq_wqe_size);

    ret = ibv_cmd_create_qp(pd, &qp->vqp.qp,
                            &ib_attr,
                            &cmd.ibv_cmd, sizeof(cmd),
                            &resp.ibv_resp,
                            sizeof(resp));
    if (ret) {
        fprintf(stderr,
                "rocm_ernic_dv: create_qp: "
                "failed: %d (%s)\n",
                ret, strerror(-ret));
        free(qp);
        errno = -ret;
        return NULL;
    }

    qp->qpn = resp.qpn;
    qp->qp_handle = resp.qp_handle;
    qp->sq_depth = resp.sq_depth;
    qp->rq_depth = resp.rq_depth;
    qp->sq_wqe_size = resp.sq_wqe_size;
    qp->rq_wqe_size = resp.rq_wqe_size;

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
