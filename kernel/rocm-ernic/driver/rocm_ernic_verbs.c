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

#include <asm/page.h>
#include <linux/inet.h>
#include <linux/io.h>
#include <rdma/ib_addr.h>
#include <rdma/ib_smi.h>
#include <rdma/ib_user_verbs.h>
#include "rocm_ernic-abi.h"
#include <rdma/uverbs_ioctl.h>

#include "rocm_ernic.h"

/**
 * rocm_ernic_query_device - query device
 * @ibdev: the device to query
 * @props: the device properties
 * @uhw: user data
 *
 * @return: 0 on success, otherwise negative errno
 */
int rocm_ernic_query_device(struct ib_device *ibdev,
                            struct ib_device_attr *props, struct ib_udata *uhw)
{
    struct rocm_ernic_dev *dev = to_vdev(ibdev);

    if (uhw->inlen || uhw->outlen)
        return -EINVAL;

    props->fw_ver = dev->dsr->caps.fw_ver;
    props->sys_image_guid = dev->sys_image_guid;
    props->max_mr_size = dev->dsr->caps.max_mr_size;
    props->page_size_cap = dev->dsr->caps.page_size_cap;
    props->vendor_id = dev->dsr->caps.vendor_id;
    props->vendor_part_id = dev->pdev->device;
    props->hw_ver = dev->dsr->caps.hw_ver;
    props->max_qp = dev->dsr->caps.max_qp;
    props->max_qp_wr = dev->dsr->caps.max_qp_wr;
    props->device_cap_flags = dev->dsr->caps.device_cap_flags;
    props->max_send_sge = dev->dsr->caps.max_sge;
    props->max_recv_sge = dev->dsr->caps.max_sge;
    props->max_sge_rd = ROCM_ERNIC_GET_CAP(dev, dev->dsr->caps.max_sge,
                                           dev->dsr->caps.max_sge_rd);
    props->max_srq = dev->dsr->caps.max_srq;
    props->max_srq_wr = dev->dsr->caps.max_srq_wr;
    props->max_srq_sge = dev->dsr->caps.max_srq_sge;
    props->max_cq = dev->dsr->caps.max_cq;
    props->max_cqe = dev->dsr->caps.max_cqe;
    props->max_mr = dev->dsr->caps.max_mr;
    props->max_pd = dev->dsr->caps.max_pd;
    props->max_qp_rd_atom = dev->dsr->caps.max_qp_rd_atom;
    props->max_qp_init_rd_atom = dev->dsr->caps.max_qp_init_rd_atom;
    props->atomic_cap =
        dev->dsr->caps.atomic_ops & (ROCM_ERNIC_ATOMIC_OP_COMP_SWAP |
                                     ROCM_ERNIC_ATOMIC_OP_FETCH_ADD)
            ? IB_ATOMIC_HCA
            : IB_ATOMIC_NONE;
    props->masked_atomic_cap = props->atomic_cap;
    props->max_ah = dev->dsr->caps.max_ah;
    props->max_pkeys = dev->dsr->caps.max_pkeys;
    props->local_ca_ack_delay = dev->dsr->caps.local_ca_ack_delay;
    if ((dev->dsr->caps.bmme_flags & ROCM_ERNIC_BMME_FLAG_LOCAL_INV) &&
        (dev->dsr->caps.bmme_flags & ROCM_ERNIC_BMME_FLAG_REMOTE_INV) &&
        (dev->dsr->caps.bmme_flags & ROCM_ERNIC_BMME_FLAG_FAST_REG_WR)) {
        props->device_cap_flags |= IB_DEVICE_MEM_MGT_EXTENSIONS;
        props->max_fast_reg_page_list_len =
            ROCM_ERNIC_GET_CAP(dev, ROCM_ERNIC_MAX_FAST_REG_PAGES,
                               dev->dsr->caps.max_fast_reg_page_list_len);
    }

    props->device_cap_flags |=
        IB_DEVICE_PORT_ACTIVE_EVENT | IB_DEVICE_RC_RNR_NAK_GEN;

    return 0;
}

/**
 * rocm_ernic_query_port - query device port attributes
 * @ibdev: the device to query
 * @port: the port number
 * @props: the device properties
 *
 * @return: 0 on success, otherwise negative errno
 */
int rocm_ernic_query_port(struct ib_device *ibdev, u32 port,
                          struct ib_port_attr *props)
{
    struct rocm_ernic_dev *dev = to_vdev(ibdev);
    union rocm_ernic_cmd_req req;
    union rocm_ernic_cmd_resp rsp;
    struct rocm_ernic_cmd_query_port *cmd = &req.query_port;
    struct rocm_ernic_cmd_query_port_resp *resp = &rsp.query_port_resp;
    int err;

    memset(cmd, 0, sizeof(*cmd));
    cmd->hdr.cmd = ROCM_ERNIC_CMD_QUERY_PORT;
    cmd->port_num = port;

    err = rocm_ernic_cmd_post(dev, &req, &rsp, ROCM_ERNIC_CMD_QUERY_PORT_RESP);
    if (err < 0) {
        dev_warn(&dev->pdev->dev, "could not query port, error: %d\n", err);
        return err;
    }

    /* props being zeroed by the caller, avoid zeroing it here */

    props->state = rocm_ernic_port_state_to_ib(resp->attrs.state);
    props->max_mtu = rocm_ernic_mtu_to_ib(resp->attrs.max_mtu);
    props->active_mtu = rocm_ernic_mtu_to_ib(resp->attrs.active_mtu);
    props->gid_tbl_len = resp->attrs.gid_tbl_len;
    props->port_cap_flags =
        rocm_ernic_port_cap_flags_to_ib(resp->attrs.port_cap_flags);
    props->port_cap_flags |= IB_PORT_CM_SUP;
    props->ip_gids = true;

    dev_info(&dev->pdev->dev, "query_port: state=%d gid_tbl_len=%d\n",
             props->state, props->gid_tbl_len);
    props->max_msg_sz = resp->attrs.max_msg_sz;
    props->bad_pkey_cntr = resp->attrs.bad_pkey_cntr;
    props->qkey_viol_cntr = resp->attrs.qkey_viol_cntr;
    props->pkey_tbl_len = resp->attrs.pkey_tbl_len;
    props->lid = resp->attrs.lid;
    props->sm_lid = resp->attrs.sm_lid;
    props->lmc = resp->attrs.lmc;
    props->max_vl_num = resp->attrs.max_vl_num;
    props->sm_sl = resp->attrs.sm_sl;
    props->subnet_timeout = resp->attrs.subnet_timeout;
    props->init_type_reply = resp->attrs.init_type_reply;
    props->active_width = rocm_ernic_port_width_to_ib(resp->attrs.active_width);
    props->active_speed = rocm_ernic_port_speed_to_ib(resp->attrs.active_speed);
    props->phys_state = resp->attrs.phys_state;

    return 0;
}

/**
 * rocm_ernic_query_gid - query device gid
 * @ibdev: the device to query
 * @port: the port number
 * @index: the index
 * @gid: the device gid value
 *
 * @return: 0 on success, otherwise negative errno
 */
int rocm_ernic_query_gid(struct ib_device *ibdev, u32 port, int index,
                         union ib_gid *gid)
{
    struct rocm_ernic_dev *dev = to_vdev(ibdev);
    bool is_loopback = dev->netdev && (dev->netdev->flags & IFF_LOOPBACK);

    if (index >= dev->dsr->caps.gid_tbl_len)
        return -EINVAL;

    if (!dev->sgid_tbl) {
        dev_err(&dev->pdev->dev, "query_gid: sgid_tbl is NULL!\n");
        memset(gid, 0, sizeof(union ib_gid));
        return -EINVAL;
    }

    memcpy(gid, &dev->sgid_tbl[index], sizeof(union ib_gid));

    /* If GID is zero in loopback mode, return deterministic GID */
    if (is_loopback && !memcmp(gid, &(union ib_gid){0}, sizeof(*gid))) {
        memset(gid, 0, sizeof(*gid));
        gid->raw[0] = 0xfe;
        gid->raw[1] = 0x80;
        gid->raw[8] = 0x02;
        gid->raw[11] = 0xff;
        gid->raw[12] = 0xfe;
        gid->raw[15] = dev->mesh_enabled ? dev->mesh_node_id : 0;
        dev_info(&dev->pdev->dev,
                 "query_gid: returning deterministic GID %pI6c for loopback "
                 "mode (index=%d)\n",
                 gid, index);
    }

    dev_info(&dev->pdev->dev,
             "query_gid: port=%u index=%d sgid_tbl[0]=%02x%02x::%02x "
             "gid=%02x%02x::%02x\n",
             port, index, dev->sgid_tbl[0].raw[0], dev->sgid_tbl[0].raw[1],
             dev->sgid_tbl[0].raw[15], gid->raw[0], gid->raw[1], gid->raw[15]);

    return 0;
}

/**
 * rocm_ernic_query_pkey - query device port's P_Key table
 * @ibdev: the device to query
 * @port: the port number
 * @index: the index
 * @pkey: the device P_Key value
 *
 * @return: 0 on success, otherwise negative errno
 */
int rocm_ernic_query_pkey(struct ib_device *ibdev, u32 port, u16 index,
                          u16 *pkey)
{
    int err = 0;
    union rocm_ernic_cmd_req req;
    union rocm_ernic_cmd_resp rsp;
    struct rocm_ernic_cmd_query_pkey *cmd = &req.query_pkey;

    memset(cmd, 0, sizeof(*cmd));
    cmd->hdr.cmd = ROCM_ERNIC_CMD_QUERY_PKEY;
    cmd->port_num = port;
    cmd->index = index;

    err = rocm_ernic_cmd_post(to_vdev(ibdev), &req, &rsp,
                              ROCM_ERNIC_CMD_QUERY_PKEY_RESP);
    if (err < 0) {
        dev_warn(&to_vdev(ibdev)->pdev->dev,
                 "could not query pkey, error: %d\n", err);
        return err;
    }

    *pkey = rsp.query_pkey_resp.pkey;

    return 0;
}

enum rdma_link_layer rocm_ernic_port_link_layer(struct ib_device *ibdev,
                                                u32 port)
{
    /* Always report as Ethernet/RoCE to enable proper GID management */
    return IB_LINK_LAYER_ETHERNET;
}

/**
 * rocm_ernic_modify_port - modify device port attributes
 * @ibdev: the device to modify
 * @port: the port number
 * @mask: attributes to modify
 * @props: the device properties
 *
 * @return: 0 on success, otherwise negative errno
 */
int rocm_ernic_modify_port(struct ib_device *ibdev, u32 port, int mask,
                           struct ib_port_modify *props)
{
    struct ib_port_attr attr;
    struct rocm_ernic_dev *vdev = to_vdev(ibdev);
    int ret;

    if (mask & ~IB_PORT_SHUTDOWN) {
        dev_warn(&vdev->pdev->dev, "unsupported port modify mask %#x\n", mask);
        return -EOPNOTSUPP;
    }

    mutex_lock(&vdev->port_mutex);
    ret = ib_query_port(ibdev, port, &attr);
    if (ret)
        goto out;

    vdev->port_cap_mask |= props->set_port_cap_mask;
    vdev->port_cap_mask &= ~props->clr_port_cap_mask;

    if (mask & IB_PORT_SHUTDOWN)
        vdev->ib_active = false;

out:
    mutex_unlock(&vdev->port_mutex);
    return ret;
}

/**
 * rocm_ernic_alloc_ucontext - allocate ucontext
 * @uctx: the uverbs countext
 * @udata: user data
 *
 * @return:  zero on success, otherwise errno.
 */
int rocm_ernic_alloc_ucontext(struct ib_ucontext *uctx, struct ib_udata *udata)
{
    struct ib_device *ibdev = uctx->device;
    struct rocm_ernic_dev *vdev = to_vdev(ibdev);
    struct rocm_ernic_ucontext *context = to_vucontext(uctx);
    union rocm_ernic_cmd_req req = {};
    union rocm_ernic_cmd_resp rsp = {};
    struct rocm_ernic_cmd_create_uc *cmd = &req.create_uc;
    struct rocm_ernic_cmd_create_uc_resp *resp = &rsp.create_uc_resp;
    struct rocm_ernic_alloc_ucontext_resp uresp = {};
    int ret;

    dev_info(&vdev->pdev->dev,
             "alloc_ucontext: ib_active=%d "
             "dsr_version=%d\n",
             vdev->ib_active,
             vdev->dsr_version);

    if (!vdev->ib_active)
        return -EAGAIN;

    context->dev = vdev;
    ret = rocm_ernic_uar_alloc(vdev, &context->uar);
    if (ret) {
        dev_warn(&vdev->pdev->dev,
                 "alloc_ucontext: "
                 "uar_alloc failed: %d\n", ret);
        return -ENOMEM;
    }

    dev_info(&vdev->pdev->dev,
             "alloc_ucontext: UAR pfn=%llu "
             "index=%d\n",
             (unsigned long long)context->uar.pfn,
             context->uar.index);

    /* get ctx_handle from host */
    if (vdev->dsr_version < ROCM_ERNIC_PPN64_VERSION)
        cmd->pfn = context->uar.pfn;
    else
        cmd->pfn64 = context->uar.pfn;

    cmd->hdr.cmd = ROCM_ERNIC_CMD_CREATE_UC;
    dev_info(&vdev->pdev->dev,
             "alloc_ucontext: posting "
             "CREATE_UC cmd...\n");
    ret = rocm_ernic_cmd_post(vdev, &req, &rsp,
                              ROCM_ERNIC_CMD_CREATE_UC_RESP);
    if (ret < 0) {
        dev_warn(&vdev->pdev->dev,
                 "alloc_ucontext: "
                 "CREATE_UC failed: %d\n", ret);
        goto err;
    }
    dev_info(&vdev->pdev->dev,
             "alloc_ucontext: CREATE_UC "
             "succeeded, ctx_handle=%u\n",
             resp->ctx_handle);

    context->ctx_handle = resp->ctx_handle;

    /* copy back to user */
    uresp.qp_tab_size = vdev->dsr->caps.max_qp;
    ret = ib_copy_to_udata(udata, &uresp, sizeof(uresp));
    if (ret) {
        rocm_ernic_uar_free(vdev, &context->uar);
        rocm_ernic_dealloc_ucontext(&context->ibucontext);
        return -EFAULT;
    }

    return 0;

err:
    rocm_ernic_uar_free(vdev, &context->uar);
    return ret;
}

/**
 * rocm_ernic_dealloc_ucontext - deallocate ucontext
 * @ibcontext: the ucontext
 */
void rocm_ernic_dealloc_ucontext(struct ib_ucontext *ibcontext)
{
    struct rocm_ernic_ucontext *context = to_vucontext(ibcontext);
    union rocm_ernic_cmd_req req = {};
    struct rocm_ernic_cmd_destroy_uc *cmd = &req.destroy_uc;
    int ret;

    cmd->hdr.cmd = ROCM_ERNIC_CMD_DESTROY_UC;
    cmd->ctx_handle = context->ctx_handle;

    ret = rocm_ernic_cmd_post(context->dev, &req, NULL, 0);
    if (ret < 0)
        dev_warn(&context->dev->pdev->dev,
                 "destroy ucontext failed, error: %d\n", ret);

    /* Free the UAR even if the device command failed */
    rocm_ernic_uar_free(to_vdev(ibcontext->device), &context->uar);
}

/**
 * rocm_ernic_mmap - create mmap region
 * @ibcontext: the user context
 * @vma: the VMA
 *
 * @return: 0 on success, otherwise errno.
 */
int rocm_ernic_mmap(struct ib_ucontext *ibcontext, struct vm_area_struct *vma)
{
    struct rocm_ernic_ucontext *context = to_vucontext(ibcontext);
    unsigned long start = vma->vm_start;
    unsigned long size = vma->vm_end - vma->vm_start;
    unsigned long offset = vma->vm_pgoff << PAGE_SHIFT;

    dev_dbg(&context->dev->pdev->dev, "create mmap region\n");

    if ((size != PAGE_SIZE) || (offset & ~PAGE_MASK)) {
        dev_warn(&context->dev->pdev->dev, "invalid params for mmap region\n");
        return -EINVAL;
    }

    /* Map UAR to kernel space, VM_LOCKED? */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
    vm_flags_set(vma, VM_DONTCOPY | VM_DONTEXPAND);
#else
    vma->vm_flags |= VM_DONTCOPY | VM_DONTEXPAND;
#endif
    vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);
    if (io_remap_pfn_range(vma, start, context->uar.pfn, size,
                           vma->vm_page_prot))
        return -EAGAIN;

    return 0;
}

/**
 * rocm_ernic_alloc_pd - allocate protection domain
 * @ibpd: PD pointer
 * @udata: user data
 *
 * @return: the ib_pd protection domain pointer on success, otherwise errno.
 */
int rocm_ernic_alloc_pd(struct ib_pd *ibpd, struct ib_udata *udata)
{
    struct ib_device *ibdev = ibpd->device;
    struct rocm_ernic_pd *pd = to_vpd(ibpd);
    struct rocm_ernic_dev *dev = to_vdev(ibdev);
    union rocm_ernic_cmd_req req = {};
    union rocm_ernic_cmd_resp rsp = {};
    struct rocm_ernic_cmd_create_pd *cmd = &req.create_pd;
    struct rocm_ernic_cmd_create_pd_resp *resp = &rsp.create_pd_resp;
    struct rocm_ernic_alloc_pd_resp pd_resp = {0};
    int ret;
    struct rocm_ernic_ucontext *context = rdma_udata_to_drv_context(
        udata, struct rocm_ernic_ucontext, ibucontext);

    /* Check allowed max pds */
    if (!atomic_add_unless(&dev->num_pds, 1, dev->dsr->caps.max_pd))
        return -ENOMEM;

    cmd->hdr.cmd = ROCM_ERNIC_CMD_CREATE_PD;
    cmd->ctx_handle = context ? context->ctx_handle : 0;
    ret = rocm_ernic_cmd_post(dev, &req, &rsp, ROCM_ERNIC_CMD_CREATE_PD_RESP);
    if (ret < 0) {
        dev_warn(&dev->pdev->dev,
                 "failed to allocate protection domain, error: %d\n", ret);
        goto err;
    }

    pd->privileged = !udata;
    pd->pd_handle = resp->pd_handle;
    pd->pdn = resp->pd_handle;
    pd_resp.pdn = resp->pd_handle;

    if (udata) {
        if (ib_copy_to_udata(udata, &pd_resp, sizeof(pd_resp))) {
            dev_warn(&dev->pdev->dev,
                     "failed to copy back protection domain\n");
            rocm_ernic_dealloc_pd(&pd->ibpd, udata);
            return -EFAULT;
        }
    }

    /* u32 pd handle */
    return 0;

err:
    atomic_dec(&dev->num_pds);
    return ret;
}

/**
 * rocm_ernic_dealloc_pd - deallocate protection domain
 * @pd: the protection domain to be released
 * @udata: user data or null for kernel object
 *
 * @return: Always 0
 */
int rocm_ernic_dealloc_pd(struct ib_pd *pd, struct ib_udata *udata)
{
    struct rocm_ernic_dev *dev = to_vdev(pd->device);
    union rocm_ernic_cmd_req req = {};
    struct rocm_ernic_cmd_destroy_pd *cmd = &req.destroy_pd;
    int ret;

    cmd->hdr.cmd = ROCM_ERNIC_CMD_DESTROY_PD;
    cmd->pd_handle = to_vpd(pd)->pd_handle;

    ret = rocm_ernic_cmd_post(dev, &req, NULL, 0);
    if (ret)
        dev_warn(&dev->pdev->dev,
                 "could not dealloc protection domain, error: %d\n", ret);

    atomic_dec(&dev->num_pds);
    return 0;
}

/**
 * rocm_ernic_create_ah - create an address handle
 * @ibah: the IB address handle
 * @init_attr: the attributes of the AH
 * @udata: pointer to user data
 *
 * @return: 0 on success, otherwise errno.
 */
int rocm_ernic_create_ah(struct ib_ah *ibah,
                         struct rdma_ah_init_attr *init_attr,
                         struct ib_udata *udata)
{
    struct rdma_ah_attr *ah_attr = init_attr->ah_attr;
    struct rocm_ernic_dev *dev = to_vdev(ibah->device);
    struct rocm_ernic_ah *ah = to_vah(ibah);
    const struct ib_global_route *grh;
    u32 port_num = rdma_ah_get_port_num(ah_attr);

    if (!(rdma_ah_get_ah_flags(ah_attr) & IB_AH_GRH))
        return -EINVAL;

    grh = rdma_ah_read_grh(ah_attr);
    if ((ah_attr->type != RDMA_AH_ATTR_TYPE_ROCE) ||
        rdma_is_multicast_addr((struct in6_addr *)grh->dgid.raw))
        return -EINVAL;

    if (!atomic_add_unless(&dev->num_ahs, 1, dev->dsr->caps.max_ah))
        return -ENOMEM;

    ah->av.port_pd = to_vpd(ibah->pd)->pd_handle | (port_num << 24);
    ah->av.src_path_bits = rdma_ah_get_path_bits(ah_attr);
    ah->av.src_path_bits |= 0x80;
    ah->av.gid_index = grh->sgid_index;
    ah->av.hop_limit = grh->hop_limit;
    ah->av.sl_tclass_flowlabel = (grh->traffic_class << 20) | grh->flow_label;
    memcpy(ah->av.dgid, grh->dgid.raw, 16);
    memcpy(ah->av.dmac, ah_attr->roce.dmac, ETH_ALEN);

    return 0;
}

/**
 * rocm_ernic_destroy_ah - destroy an address handle
 * @ah: the address handle to destroyed
 * @flags: destroy address handle flags (see enum rdma_destroy_ah_flags)
 *
 */
int rocm_ernic_destroy_ah(struct ib_ah *ah, u32 flags)
{
    struct rocm_ernic_dev *dev = to_vdev(ah->device);

    atomic_dec(&dev->num_ahs);
    return 0;
}
