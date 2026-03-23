/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * rdma-core provider entry point for rocm_ernic.
 * Written against rdma-core v62.0 APIs.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include <infiniband/driver.h>
#include <infiniband/verbs.h>

#include "rocm_ernic.h"
#include "rocm_ernic_driver_id.h"
#include "rocm_ernic_dv.h"

static const struct verbs_match_ent match_table[] = {
    VERBS_PCI_MATCH(ROCM_ERNIC_VENDOR_ID,
                    ROCM_ERNIC_DEVICE_ID, NULL),
    VERBS_DRIVER_ID(RDMA_DRIVER_ROCM_ERNIC),
    {},
};

static const struct verbs_context_ops
    rocm_ernic_ctx_ops = {
        .query_device_ex = rocm_ernic_query_device,
        .query_port = rocm_ernic_query_port,
        .alloc_pd = rocm_ernic_alloc_pd,
        .dealloc_pd = rocm_ernic_dealloc_pd,
        .reg_mr = rocm_ernic_reg_mr,
        .dereg_mr = rocm_ernic_dereg_mr,
        .create_cq = rocm_ernic_create_cq_v,
        .destroy_cq = rocm_ernic_destroy_cq_v,
        .poll_cq = rocm_ernic_poll_cq_v,
        .req_notify_cq = rocm_ernic_req_notify_cq_v,
        .create_qp = rocm_ernic_create_qp_v,
        .modify_qp = rocm_ernic_modify_qp_v,
        .query_qp = rocm_ernic_query_qp_v,
        .destroy_qp = rocm_ernic_destroy_qp_v,
        .post_send = rocm_ernic_post_send_v,
        .post_recv = rocm_ernic_post_recv_v,
};

static struct verbs_context *
rocm_ernic_alloc_context(struct ibv_device *ibdev,
                         int cmd_fd,
                         void *private_data)
{
    struct rocm_ernic_context *ctx;
    struct ibv_get_context cmd;
    struct rocm_ernic_alloc_ucontext_resp resp = {};

    fprintf(stderr,
            "rocm_ernic: alloc_context entry\n");

    ctx = verbs_init_and_alloc_context(
        ibdev, cmd_fd, ctx, vctx,
        RDMA_DRIVER_ROCM_ERNIC);
    if (!ctx) {
        fprintf(stderr,
                "rocm_ernic: "
                "verbs_init_and_alloc_context "
                "failed\n");
        return NULL;
    }

    fprintf(stderr,
            "rocm_ernic: calling "
            "ibv_cmd_get_context "
            "(cmd_size=%zu resp_size=%zu)\n",
            sizeof(cmd), sizeof(resp));

    int ret = ibv_cmd_get_context(
            &ctx->vctx, &cmd, sizeof(cmd),
            NULL, &resp.ibv_resp, sizeof(resp));
    if (ret) {
        fprintf(stderr,
                "rocm_ernic: "
                "ibv_cmd_get_context failed: "
                "%d (%s)\n",
                ret, strerror(-ret));
        verbs_uninit_context(&ctx->vctx);
        free(ctx);
        return NULL;
    }

    fprintf(stderr,
            "rocm_ernic: context allocated OK "
            "(qp_tab_size=%u)\n",
            resp.qp_tab_size);

    ctx->qp_tab_size = resp.qp_tab_size;
    ctx->dv_abi_version = ROCM_ERNIC_DV_API_VERSION;

    verbs_set_ops(&ctx->vctx, &rocm_ernic_ctx_ops);
    return &ctx->vctx;
}

static void
rocm_ernic_free_context(struct ibv_context *ibctx)
{
    struct rocm_ernic_context *ctx =
        to_rocm_ernic_ctx(ibctx);

    verbs_uninit_context(&ctx->vctx);
    free(ctx);
}

static void rocm_ernic_uninit_device(
    struct verbs_device *verbs_device)
{
    struct rocm_ernic_device *dev =
        container_of(verbs_device,
                     struct rocm_ernic_device, vdev);
    free(dev);
}

static struct verbs_device *
rocm_ernic_device_alloc(
    struct verbs_sysfs_dev *sysfs)
{
    struct rocm_ernic_device *dev;

    dev = calloc(1, sizeof(*dev));
    if (!dev)
        return NULL;

    return &dev->vdev;
}

static const struct verbs_device_ops
    rocm_ernic_dev_ops = {
        .name = "rocm_ernic",
        .match_min_abi_version =
            ROCM_ERNIC_UVERBS_ABI_VERSION,
        .match_max_abi_version =
            ROCM_ERNIC_UVERBS_ABI_VERSION,
        .match_table = match_table,
        .alloc_device = rocm_ernic_device_alloc,
        .uninit_device = rocm_ernic_uninit_device,
        .alloc_context = rocm_ernic_alloc_context,
};

PROVIDER_DRIVER(rocm_ernic, rocm_ernic_dev_ops);
