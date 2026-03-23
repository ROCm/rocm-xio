/*
 * Copyright (c) 2012-2016 VMware, Inc.  All rights reserved.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of EITHER the GNU General Public License
 * version 2 as published by the Free Software Foundation or the BSD
 * 2-Clause License. This program is distributed in the hope that it
 * will be useful, but WITHOUT ANY WARRANTY; WITHOUT EVEN THE IMPLIED
 * WARRANTY OF MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License version 2 for more details at
 * http://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program available in the file COPYING in the main
 * directory of this source tree.
 *
 * The BSD 2-Clause License
 *
 *     Redistribution and use in source and binary forms, with or
 *     without modification, are permitted provided that the following
 *     conditions are met:
 *
 *      - Redistributions of source code must retain the above
 *        copyright notice, this list of conditions and the following
 *        disclaimer.
 *
 *      - Redistributions in binary form must reproduce the above
 *        copyright notice, this list of conditions and the following
 *        disclaimer in the documentation and/or other materials
 *        provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <linux/version.h>
#include <asm/page.h>
#include <linux/io.h>
#include <linux/wait.h>
#include <rdma/ib_addr.h>
#include <rdma/ib_smi.h>
#include <rdma/ib_user_verbs.h>
#include <rdma/uverbs_ioctl.h>

#include "rocm_ernic.h"

/**
 * rocm_ernic_req_notify_cq - request notification for a completion queue
 * @ibcq: the completion queue
 * @notify_flags: notification flags
 *
 * @return: 0 for success.
 */
int rocm_ernic_req_notify_cq(struct ib_cq *ibcq,
                             enum ib_cq_notify_flags notify_flags)
{
    struct rocm_ernic_dev *dev = to_vdev(ibcq->device);
    struct rocm_ernic_cq *cq = to_vcq(ibcq);
    u32 val = cq->cq_handle;
    unsigned long flags;
    int has_data = 0;

    val |= (notify_flags & IB_CQ_SOLICITED_MASK) == IB_CQ_SOLICITED
               ? ROCM_ERNIC_UAR_CQ_ARM_SOL
               : ROCM_ERNIC_UAR_CQ_ARM;

    spin_lock_irqsave(&cq->cq_lock, flags);

    rocm_ernic_write_uar_cq(dev, val);

    if (notify_flags & IB_CQ_REPORT_MISSED_EVENTS) {
        unsigned int head;

        has_data = rocm_ernic_idx_ring_has_data(&cq->ring_state->rx,
                                                cq->ibcq.cqe, &head);
        if (unlikely(has_data == ROCM_ERNIC_INVALID_IDX))
            dev_err(&dev->pdev->dev, "CQ ring state invalid\n");
    }

    spin_unlock_irqrestore(&cq->cq_lock, flags);

    return has_data;
}

/**
 * rocm_ernic_create_cq - create completion queue
 * @ibcq: Allocated CQ
 * @attr: completion queue attributes
 * @attrs: bundle (kernel >= 6.11) or udata
 *
 * Handles both standard and DV paths.  In DV mode the
 * userspace provider sets comp_mask in the extended udata;
 * the kernel still pins the buffer via ib_umem_get() using
 * the address supplied in buf_addr/buf_size.
 *
 * @return: 0 on success
 */
int rocm_ernic_create_cq(struct ib_cq *ibcq, const struct ib_cq_init_attr *attr,
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 11, 0)
                         struct uverbs_attr_bundle *attrs)
#else
                         struct ib_udata *udata)
#endif
{
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 11, 0)
    struct ib_udata *udata = &attrs->driver_udata;
#endif
    struct ib_device *ibdev = ibcq->device;
    int entries = attr->cqe;
    struct rocm_ernic_dev *dev = to_vdev(ibdev);
    struct rocm_ernic_cq *cq = to_vcq(ibcq);
    int ret;
    int npages;
    unsigned long flags;
    union rocm_ernic_cmd_req req;
    union rocm_ernic_cmd_resp rsp;
    struct rocm_ernic_cmd_create_cq *cmd = &req.create_cq;
    struct rocm_ernic_cmd_create_cq_resp *resp = &rsp.create_cq_resp;
    struct rocm_ernic_create_cq_resp cq_resp = {};
    struct rocm_ernic_create_cq ucmd = {};
    struct rocm_ernic_ucontext *context = rdma_udata_to_drv_context(
        udata, struct rocm_ernic_ucontext, ibucontext);

    BUILD_BUG_ON(sizeof(struct rocm_ernic_cqe) != 64);

    dev_info(&dev->pdev->dev,
             "CQ create: ENTRY (entries=%d, "
             "flags=0x%x, is_kernel=%d)\n",
             entries, attr->flags, !udata);

    if (attr->flags) {
        dev_warn(&dev->pdev->dev,
                 "CQ create: EOPNOTSUPP "
                 "(flags=0x%x)\n",
                 attr->flags);
        return -EOPNOTSUPP;
    }

    entries = roundup_pow_of_two(entries);
    if (entries < 1 || entries > dev->dsr->caps.max_cqe) {
        dev_warn(&dev->pdev->dev, "CQ create: EINVAL "
                                  "(entries check failed)\n");
        return -EINVAL;
    }

    if (!atomic_add_unless(&dev->num_cqs, 1, dev->dsr->caps.max_cq)) {
        dev_warn(&dev->pdev->dev, "CQ create: ENOMEM "
                                  "(max CQs reached)\n");
        return -ENOMEM;
    }

    cq->ibcq.cqe = entries;
    cq->is_kernel = !udata;

    if (!cq->is_kernel) {
        if (ib_copy_from_udata(&ucmd, udata, min(udata->inlen, sizeof(ucmd)))) {
            ret = -EFAULT;
            goto err_cq;
        }

        cq->umem = ib_umem_get(ibdev, ucmd.buf_addr, ucmd.buf_size,
                               IB_ACCESS_LOCAL_WRITE);
        if (IS_ERR(cq->umem)) {
            ret = PTR_ERR(cq->umem);
            goto err_cq;
        }

        npages = ib_umem_num_dma_blocks(cq->umem, PAGE_SIZE);
    } else {
        npages = 1 + (entries * sizeof(struct rocm_ernic_cqe) + PAGE_SIZE - 1) /
                         PAGE_SIZE;
        cq->offset = PAGE_SIZE;
    }

    if (npages < 0 || npages > ROCM_ERNIC_PAGE_DIR_MAX_PAGES) {
        dev_warn(&dev->pdev->dev, "overflow pages in CQ\n");
        ret = -EINVAL;
        goto err_umem;
    }

    ret = rocm_ernic_page_dir_init(dev, &cq->pdir, npages, cq->is_kernel);
    if (ret) {
        dev_warn(&dev->pdev->dev,
                 "could not allocate page directory "
                 "(ret=%d, npages=%d)\n",
                 ret, npages);
        goto err_umem;
    }

    if (cq->is_kernel)
        cq->ring_state = cq->pdir.pages[0];
    else
        rocm_ernic_page_dir_insert_umem(&cq->pdir, cq->umem, 0);

    refcount_set(&cq->refcnt, 1);
    init_completion(&cq->free);
    spin_lock_init(&cq->cq_lock);

    memset(cmd, 0, sizeof(*cmd));
    cmd->hdr.cmd = ROCM_ERNIC_CMD_CREATE_CQ;
    cmd->nchunks = npages;
    cmd->ctx_handle = context ? context->ctx_handle : 0;
    cmd->cqe = entries;
    cmd->pdir_dma = cq->pdir.dir_dma;
    ret = rocm_ernic_cmd_post(dev, &req, &rsp, ROCM_ERNIC_CMD_CREATE_CQ_RESP);
    if (ret < 0) {
        dev_warn(&dev->pdev->dev,
                 "could not create CQ, "
                 "error: %d\n",
                 ret);
        goto err_page_dir;
    }

    cq->ibcq.cqe = resp->cqe;
    cq->cq_handle = resp->cq_handle;
    cq_resp.cqn = resp->cq_handle;
    cq_resp.ncqe = resp->cqe;
    cq_resp.cqe_size = sizeof(struct rocm_ernic_cqe);
    spin_lock_irqsave(&dev->cq_tbl_lock, flags);
    dev->cq_tbl[cq->cq_handle % dev->dsr->caps.max_cq] = cq;
    spin_unlock_irqrestore(&dev->cq_tbl_lock, flags);

    if (!cq->is_kernel) {
        cq->uar = &context->uar;

        if (ib_copy_to_udata(udata, &cq_resp,
                             min(udata->outlen, sizeof(cq_resp)))) {
            dev_warn(&dev->pdev->dev, "failed to copy back udata\n");
            rocm_ernic_destroy_cq(&cq->ibcq, udata);
            return -EINVAL;
        }
    }

    return 0;

err_page_dir:
    rocm_ernic_page_dir_cleanup(dev, &cq->pdir);
err_umem:
    ib_umem_release(cq->umem);
err_cq:
    atomic_dec(&dev->num_cqs);
    return ret;
}

static void rocm_ernic_free_cq(struct rocm_ernic_dev *dev,
                               struct rocm_ernic_cq *cq)
{
    if (refcount_dec_and_test(&cq->refcnt))
        complete(&cq->free);
    wait_for_completion(&cq->free);

    ib_umem_release(cq->umem);

    rocm_ernic_page_dir_cleanup(dev, &cq->pdir);
}

/**
 * rocm_ernic_destroy_cq - destroy completion queue
 * @cq: the completion queue to destroy.
 * @udata: user data or null for kernel object
 */
int rocm_ernic_destroy_cq(struct ib_cq *cq, struct ib_udata *udata)
{
    struct rocm_ernic_cq *vcq = to_vcq(cq);
    union rocm_ernic_cmd_req req;
    struct rocm_ernic_cmd_destroy_cq *cmd = &req.destroy_cq;
    struct rocm_ernic_dev *dev = to_vdev(cq->device);
    unsigned long flags;
    int ret;

    memset(cmd, 0, sizeof(*cmd));
    cmd->hdr.cmd = ROCM_ERNIC_CMD_DESTROY_CQ;
    cmd->cq_handle = vcq->cq_handle;

    ret = rocm_ernic_cmd_post(dev, &req, NULL, 0);
    if (ret < 0)
        dev_warn(&dev->pdev->dev,
                 "could not destroy completion queue, error: %d\n", ret);

    /* free cq's resources */
    spin_lock_irqsave(&dev->cq_tbl_lock, flags);
    dev->cq_tbl[vcq->cq_handle] = NULL;
    spin_unlock_irqrestore(&dev->cq_tbl_lock, flags);

    rocm_ernic_free_cq(dev, vcq);
    atomic_dec(&dev->num_cqs);
    return 0;
}

static inline struct rocm_ernic_cqe *get_cqe(struct rocm_ernic_cq *cq, int i)
{
    return (struct rocm_ernic_cqe *)rocm_ernic_page_dir_get_ptr(
        &cq->pdir, cq->offset + sizeof(struct rocm_ernic_cqe) * i);
}

void _rocm_ernic_flush_cqe(struct rocm_ernic_qp *qp, struct rocm_ernic_cq *cq)
{
    unsigned int head;
    int has_data;

    if (!cq->is_kernel)
        return;

    /* Lock held */
    has_data =
        rocm_ernic_idx_ring_has_data(&cq->ring_state->rx, cq->ibcq.cqe, &head);
    if (unlikely(has_data > 0)) {
        int items;
        int curr;
        int tail = rocm_ernic_idx(&cq->ring_state->rx.prod_tail, cq->ibcq.cqe);
        struct rocm_ernic_cqe *cqe;
        struct rocm_ernic_cqe *curr_cqe;

        items = (tail > head) ? (tail - head) : (cq->ibcq.cqe - head + tail);
        curr = --tail;
        while (items-- > 0) {
            if (curr < 0)
                curr = cq->ibcq.cqe - 1;
            if (tail < 0)
                tail = cq->ibcq.cqe - 1;
            curr_cqe = get_cqe(cq, curr);
            if ((curr_cqe->qp & 0xFFFF) != qp->qp_handle) {
                if (curr != tail) {
                    cqe = get_cqe(cq, tail);
                    *cqe = *curr_cqe;
                }
                tail--;
            } else {
                rocm_ernic_idx_ring_inc(&cq->ring_state->rx.cons_head,
                                        cq->ibcq.cqe);
            }
            curr--;
        }
    }
}

static int rocm_ernic_poll_one(struct rocm_ernic_cq *cq,
                               struct rocm_ernic_qp **cur_qp, struct ib_wc *wc)
{
    struct rocm_ernic_dev *dev = to_vdev(cq->ibcq.device);
    int has_data;
    unsigned int head;
    bool tried = false;
    struct rocm_ernic_cqe *cqe;

retry:
    has_data =
        rocm_ernic_idx_ring_has_data(&cq->ring_state->rx, cq->ibcq.cqe, &head);
    if (has_data == 0) {
        if (tried)
            return -EAGAIN;

        rocm_ernic_write_uar_cq(dev, cq->cq_handle | ROCM_ERNIC_UAR_CQ_POLL);

        tried = true;
        goto retry;
    } else if (has_data == ROCM_ERNIC_INVALID_IDX) {
        dev_err(&dev->pdev->dev, "CQ ring state invalid\n");
        return -EAGAIN;
    }

    cqe = get_cqe(cq, head);

    /* Ensure cqe is valid. */
    rmb();
    if (dev->qp_tbl[cqe->qp & 0xffff])
        *cur_qp = (struct rocm_ernic_qp *)dev->qp_tbl[cqe->qp & 0xffff];
    else
        return -EAGAIN;

    wc->opcode = rocm_ernic_wc_opcode_to_ib(cqe->opcode);
    wc->status = rocm_ernic_wc_status_to_ib(cqe->status);
    wc->wr_id = cqe->wr_id;
    wc->qp = &(*cur_qp)->ibqp;
    wc->byte_len = cqe->byte_len;
    wc->ex.imm_data = cqe->imm_data;
    wc->src_qp = cqe->src_qp;
    wc->wc_flags = rocm_ernic_wc_flags_to_ib(cqe->wc_flags);
    wc->pkey_index = cqe->pkey_index;
    wc->slid = cqe->slid;
    wc->sl = cqe->sl;
    wc->dlid_path_bits = cqe->dlid_path_bits;
    wc->port_num = cqe->port_num;
    wc->vendor_err = cqe->vendor_err;
    wc->network_hdr_type = rocm_ernic_network_type_to_ib(cqe->network_hdr_type);

    /* Update shared ring state */
    rocm_ernic_idx_ring_inc(&cq->ring_state->rx.cons_head, cq->ibcq.cqe);

    return 0;
}

/**
 * rocm_ernic_poll_cq - poll for work completion queue entries
 * @ibcq: completion queue
 * @num_entries: the maximum number of entries
 * @wc: pointer to work completion array
 *
 * @return: number of polled completion entries
 */
int rocm_ernic_poll_cq(struct ib_cq *ibcq, int num_entries, struct ib_wc *wc)
{
    struct rocm_ernic_cq *cq = to_vcq(ibcq);
    struct rocm_ernic_qp *cur_qp = NULL;
    unsigned long flags;
    int npolled;

    if (num_entries < 1 || wc == NULL)
        return 0;

    spin_lock_irqsave(&cq->cq_lock, flags);
    for (npolled = 0; npolled < num_entries; ++npolled) {
        if (rocm_ernic_poll_one(cq, &cur_qp, wc + npolled))
            break;
    }

    spin_unlock_irqrestore(&cq->cq_lock, flags);

    /* Ensure we do not return errors from poll_cq */
    return npolled;
}
