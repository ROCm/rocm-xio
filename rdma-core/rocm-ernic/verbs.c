/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Standard verbs for the rocm_ernic provider.
 * Written against rdma-core v62.0 APIs.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>

#include <infiniband/driver.h>
#include <infiniband/verbs.h>

#include "rocm_ernic.h"

int rocm_ernic_query_device(
    struct ibv_context *ctx,
    const struct ibv_query_device_ex_input *in,
    struct ibv_device_attr_ex *attr,
    size_t attr_size)
{
    struct ib_uverbs_ex_query_device_resp resp;
    size_t resp_size = sizeof(resp);

    return ibv_cmd_query_device_any(
        ctx, in, attr, attr_size, &resp, &resp_size);
}

int rocm_ernic_query_port(struct ibv_context *ctx,
                          uint8_t port,
                          struct ibv_port_attr *attr)
{
    struct ibv_query_port cmd;

    return ibv_cmd_query_port(ctx, port, attr,
                              &cmd, sizeof(cmd));
}

struct ibv_pd *rocm_ernic_alloc_pd(
    struct ibv_context *ctx)
{
    struct ibv_alloc_pd cmd;
    struct rocm_ernic_alloc_pd_resp_ex resp = {};
    struct rocm_ernic_pd *pd;

    pd = calloc(1, sizeof(*pd));
    if (!pd)
        return NULL;

    if (ibv_cmd_alloc_pd(ctx, &pd->ibvpd,
                         &cmd, sizeof(cmd),
                         &resp.ibv_resp,
                         sizeof(resp))) {
        free(pd);
        return NULL;
    }

    pd->pdn = resp.pdn;
    return &pd->ibvpd;
}

int rocm_ernic_dealloc_pd(struct ibv_pd *ibpd)
{
    int ret;

    ret = ibv_cmd_dealloc_pd(ibpd);
    if (ret)
        return ret;

    free(ibpd);
    return 0;
}

struct ibv_mr *rocm_ernic_reg_mr(struct ibv_pd *pd,
                                 void *addr,
                                 size_t length,
                                 uint64_t hca_va,
                                 int access)
{
    struct verbs_mr *vmr;
    struct ibv_reg_mr cmd;
    struct ib_uverbs_reg_mr_resp resp;
    int ret;

    vmr = calloc(1, sizeof(*vmr));
    if (!vmr)
        return NULL;

    ret = ibv_cmd_reg_mr(pd, addr, length, hca_va,
                         access, vmr, &cmd,
                         sizeof(cmd), &resp,
                         sizeof(resp));
    if (ret) {
        free(vmr);
        return NULL;
    }

    return &vmr->ibv_mr;
}

int rocm_ernic_dereg_mr(struct verbs_mr *vmr)
{
    int ret;

    ret = ibv_cmd_dereg_mr(vmr);
    if (ret)
        return ret;

    free(vmr);
    return 0;
}

struct ibv_cq *rocm_ernic_create_cq_v(
    struct ibv_context *ctx, int cqe,
    struct ibv_comp_channel *ch,
    int comp_vector)
{
    struct rocm_ernic_cq *cq;
    struct rocm_ernic_create_cq_resp_ex resp = {};
    int ret;

    cq = calloc(1, sizeof(*cq));
    if (!cq)
        return NULL;

    ret = ibv_cmd_create_cq(ctx, cqe, ch, comp_vector,
                            &cq->vcq.cq,
                            NULL, 0,
                            &resp.ibv_resp,
                            sizeof(resp));
    if (ret) {
        free(cq);
        return NULL;
    }

    cq->cqn = resp.cqn;
    cq->ncqe = resp.ncqe;
    cq->cqe_size = resp.cqe_size;

    return &cq->vcq.cq;
}

int rocm_ernic_destroy_cq_v(struct ibv_cq *ibcq)
{
    struct rocm_ernic_cq *cq = to_rocm_ernic_cq(ibcq);
    int ret;

    ret = ibv_cmd_destroy_cq(ibcq);
    if (ret)
        return ret;

    free(cq);
    return 0;
}

int rocm_ernic_poll_cq_v(struct ibv_cq *cq, int ne,
                         struct ibv_wc *wc)
{
    return ibv_cmd_poll_cq(cq, ne, wc);
}

int rocm_ernic_req_notify_cq_v(struct ibv_cq *cq,
                               int solicited_only)
{
    return ibv_cmd_req_notify_cq(cq, solicited_only);
}

struct ibv_qp *rocm_ernic_create_qp_v(
    struct ibv_pd *pd,
    struct ibv_qp_init_attr *attr)
{
    struct rocm_ernic_qp *qp;
    struct ibv_create_qp cmd = {};
    struct rocm_ernic_create_qp_resp_ex resp = {};
    int ret;

    qp = calloc(1, sizeof(*qp));
    if (!qp)
        return NULL;

    ret = ibv_cmd_create_qp(pd, &qp->vqp.qp, attr,
                            &cmd, sizeof(cmd),
                            &resp.ibv_resp,
                            sizeof(resp));
    if (ret) {
        free(qp);
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

int rocm_ernic_modify_qp_v(struct ibv_qp *qp,
                           struct ibv_qp_attr *attr,
                           int attr_mask)
{
    struct ibv_modify_qp cmd;

    return ibv_cmd_modify_qp(qp, attr, attr_mask,
                             &cmd, sizeof(cmd));
}

int rocm_ernic_query_qp_v(struct ibv_qp *qp,
                          struct ibv_qp_attr *attr,
                          int attr_mask,
                          struct ibv_qp_init_attr *ia)
{
    struct ibv_query_qp cmd;

    return ibv_cmd_query_qp(qp, attr, attr_mask,
                            ia, &cmd, sizeof(cmd));
}

int rocm_ernic_destroy_qp_v(struct ibv_qp *ibqp)
{
    struct rocm_ernic_qp *qp = to_rocm_ernic_qp(ibqp);
    int ret;

    ret = ibv_cmd_destroy_qp(ibqp);
    if (ret)
        return ret;

    free(qp);
    return 0;
}

int rocm_ernic_post_send_v(struct ibv_qp *qp,
                           struct ibv_send_wr *wr,
                           struct ibv_send_wr **bad_wr)
{
    return ibv_cmd_post_send(qp, wr, bad_wr);
}

int rocm_ernic_post_recv_v(struct ibv_qp *qp,
                           struct ibv_recv_wr *wr,
                           struct ibv_recv_wr **bad_wr)
{
    return ibv_cmd_post_recv(qp, wr, bad_wr);
}
