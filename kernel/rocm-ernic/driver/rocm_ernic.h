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

#ifndef __ROCM_ERNIC_H__
#define __ROCM_ERNIC_H__

#include <linux/compiler.h>
#include <linux/interrupt.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/semaphore.h>
#include <linux/workqueue.h>
#include <rdma/ib_umem.h>
#include <rdma/ib_verbs.h>
#include "rocm_ernic-abi.h"

#include "rocm_ernic_pci_ids.h"
#include "rocm_ernic_ring.h"
#include "rocm_ernic_dev_api.h"
#include "rocm_ernic_verbs.h"

/* NOT the same as BIT_MASK(). */
#define ROCM_ERNIC_MASK(n) ((n << 1) - 1)

#define ROCM_ERNIC_NUM_RING_PAGES      4
#define ROCM_ERNIC_QP_NUM_HEADER_PAGES 1

struct rocm_ernic_dev;

struct rocm_ernic_page_dir {
    dma_addr_t dir_dma;
    u64 *dir;
    int ntables;
    u64 **tables;
    u64 npages;
    void **pages;
};

struct rocm_ernic_cq {
    struct ib_cq ibcq;
    int offset;
    spinlock_t cq_lock; /* Poll lock. */
    struct rocm_ernic_uar_map *uar;
    struct ib_umem *umem;
    struct rocm_ernic_ring_state *ring_state;
    struct rocm_ernic_page_dir pdir;
    u32 cq_handle;
    bool is_kernel;
    refcount_t refcnt;
    struct completion free;
};

struct rocm_ernic_id_table {
    u32 last;
    u32 top;
    u32 max;
    u32 mask;
    spinlock_t lock; /* Table lock. */
    unsigned long *table;
};

struct rocm_ernic_uar_map {
    unsigned long pfn;
    void __iomem *map;
    int index;
};

struct rocm_ernic_uar_table {
    struct rocm_ernic_id_table tbl;
    int size;
};

struct rocm_ernic_ucontext {
    struct ib_ucontext ibucontext;
    struct rocm_ernic_dev *dev;
    struct rocm_ernic_uar_map uar;
    u64 ctx_handle;
};

struct rocm_ernic_pd {
    struct ib_pd ibpd;
    u32 pdn;
    u32 pd_handle;
    int privileged;
};

struct rocm_ernic_mr {
    u32 mr_handle;
    u64 iova;
    u64 size;
};

struct rocm_ernic_user_mr {
    struct ib_mr ibmr;
    struct ib_umem *umem;
    struct rocm_ernic_mr mmr;
    struct rocm_ernic_page_dir pdir;
    u64 *pages;
    u32 npages;
    u32 max_pages;
    u32 page_shift;
};

struct rocm_ernic_wq {
    struct rocm_ernic_ring *ring;
    spinlock_t lock; /* Work queue lock. */
    int wqe_cnt;
    int wqe_size;
    int max_sg;
    int offset;
};

struct rocm_ernic_ah {
    struct ib_ah ibah;
    struct rocm_ernic_av av;
};

struct rocm_ernic_srq {
    struct ib_srq ibsrq;
    int offset;
    spinlock_t lock; /* SRQ lock. */
    int wqe_cnt;
    int wqe_size;
    int max_gs;
    struct ib_umem *umem;
    struct rocm_ernic_ring_state *ring;
    struct rocm_ernic_page_dir pdir;
    u32 srq_handle;
    int npages;
    refcount_t refcnt;
    struct completion free;
};

struct rocm_ernic_qp {
    struct ib_qp ibqp;
    u32 qp_handle;
    u32 qkey;
    struct rocm_ernic_wq sq;
    struct rocm_ernic_wq rq;
    struct ib_umem *rumem;
    struct ib_umem *sumem;
    struct rocm_ernic_page_dir pdir;
    struct rocm_ernic_srq *srq;
    int npages;
    int npages_send;
    int npages_recv;
    u32 flags;
    u8 port;
    u8 state;
    bool is_kernel;
    struct mutex mutex; /* QP state mutex. */
    refcount_t refcnt;
    struct completion free;
    /* Vendor-specific: remote connection info for rdma_cm support */
    u64 remote_addr; /* Remote virtual address for RDMA ops */
    u32 remote_rkey; /* Remote rkey for RDMA ops */
};

struct rocm_ernic_dev {
    /* PCI device-related information. */
    struct ib_device ib_dev;
    struct pci_dev *pdev;
    void __iomem *regs;
    struct rocm_ernic_device_shared_region *dsr; /* Shared region pointer */
    dma_addr_t dsrbase; /* Shared region base address */
    void *cmd_slot;
    void *resp_slot;
    unsigned long flags;
    struct list_head device_link;
    unsigned int dsr_version;
    bool mesh_enabled;
    u8 mesh_node_id;
    u8 mesh_num_nodes;

    /* Locking and interrupt information. */
    spinlock_t cmd_lock; /* Command lock. */
    struct semaphore cmd_sema;
    struct completion cmd_done;
    unsigned int nr_vectors;

    /* RDMA-related device information. */
    union ib_gid *sgid_tbl;
    struct rocm_ernic_ring_state *async_ring_state;
    struct rocm_ernic_page_dir async_pdir;
    struct rocm_ernic_ring_state *cq_ring_state;
    struct rocm_ernic_page_dir cq_pdir;
    struct rocm_ernic_cq **cq_tbl;
    spinlock_t cq_tbl_lock;
    struct rocm_ernic_srq **srq_tbl;
    spinlock_t srq_tbl_lock;
    struct rocm_ernic_qp **qp_tbl;
    spinlock_t qp_tbl_lock;
    struct rocm_ernic_uar_table uar_table;
    struct rocm_ernic_uar_map driver_uar;
    __be64 sys_image_guid;
    spinlock_t desc_lock; /* Device modification lock. */
    u32 port_cap_mask;
    struct mutex port_mutex; /* Port modification mutex. */
    bool ib_active;
    atomic_t num_qps;
    atomic_t num_cqs;
    atomic_t num_srqs;
    atomic_t num_pds;
    atomic_t num_ahs;

    /* Network device information. */
    struct net_device *netdev;
    struct net_device *mesh_dummy_netdev;
    struct notifier_block nb_netdev;
};

struct rocm_ernic_netdevice_work {
    struct work_struct work;
    struct net_device *event_netdev;
    unsigned long event;
};

static inline struct rocm_ernic_dev *to_vdev(struct ib_device *ibdev)
{
    return container_of(ibdev, struct rocm_ernic_dev, ib_dev);
}

static inline struct rocm_ernic_ucontext *to_vucontext(
    struct ib_ucontext *ibucontext)
{
    return container_of(ibucontext, struct rocm_ernic_ucontext, ibucontext);
}

static inline struct rocm_ernic_pd *to_vpd(struct ib_pd *ibpd)
{
    return container_of(ibpd, struct rocm_ernic_pd, ibpd);
}

static inline struct rocm_ernic_cq *to_vcq(struct ib_cq *ibcq)
{
    return container_of(ibcq, struct rocm_ernic_cq, ibcq);
}

static inline struct rocm_ernic_srq *to_vsrq(struct ib_srq *ibsrq)
{
    return container_of(ibsrq, struct rocm_ernic_srq, ibsrq);
}

static inline struct rocm_ernic_user_mr *to_vmr(struct ib_mr *ibmr)
{
    return container_of(ibmr, struct rocm_ernic_user_mr, ibmr);
}

static inline struct rocm_ernic_qp *to_vqp(struct ib_qp *ibqp)
{
    return container_of(ibqp, struct rocm_ernic_qp, ibqp);
}

static inline struct rocm_ernic_ah *to_vah(struct ib_ah *ibah)
{
    return container_of(ibah, struct rocm_ernic_ah, ibah);
}

static inline void rocm_ernic_write_reg(struct rocm_ernic_dev *dev, u32 reg,
                                        u32 val)
{
    writel(cpu_to_le32(val), dev->regs + reg);
}

static inline u32 rocm_ernic_read_reg(struct rocm_ernic_dev *dev, u32 reg)
{
    return le32_to_cpu(readl(dev->regs + reg));
}

static inline void rocm_ernic_write_uar_cq(struct rocm_ernic_dev *dev, u32 val)
{
    writel(cpu_to_le32(val), dev->driver_uar.map + ROCM_ERNIC_UAR_CQ_OFFSET);
}

static inline void rocm_ernic_write_uar_qp(struct rocm_ernic_dev *dev, u32 val)
{
    writel(cpu_to_le32(val), dev->driver_uar.map + ROCM_ERNIC_UAR_QP_OFFSET);
}

static inline void *rocm_ernic_page_dir_get_ptr(
    struct rocm_ernic_page_dir *pdir, u64 offset)
{
    return pdir->pages[offset / PAGE_SIZE] + (offset % PAGE_SIZE);
}

static inline enum rocm_ernic_mtu ib_mtu_to_rocm_ernic(enum ib_mtu mtu)
{
    return (enum rocm_ernic_mtu)mtu;
}

static inline enum ib_mtu rocm_ernic_mtu_to_ib(enum rocm_ernic_mtu mtu)
{
    return (enum ib_mtu)mtu;
}

static inline enum rocm_ernic_port_state ib_port_state_to_rocm_ernic(
    enum ib_port_state state)
{
    return (enum rocm_ernic_port_state)state;
}

static inline enum ib_port_state rocm_ernic_port_state_to_ib(
    enum rocm_ernic_port_state state)
{
    return (enum ib_port_state)state;
}

static inline int rocm_ernic_port_cap_flags_to_ib(int flags)
{
    return flags;
}

static inline enum rocm_ernic_port_width ib_port_width_to_rocm_ernic(
    enum ib_port_width width)
{
    return (enum rocm_ernic_port_width)width;
}

static inline enum ib_port_width rocm_ernic_port_width_to_ib(
    enum rocm_ernic_port_width width)
{
    return (enum ib_port_width)width;
}

static inline enum rocm_ernic_port_speed ib_port_speed_to_rocm_ernic(
    enum ib_port_speed speed)
{
    return (enum rocm_ernic_port_speed)speed;
}

static inline enum ib_port_speed rocm_ernic_port_speed_to_ib(
    enum rocm_ernic_port_speed speed)
{
    return (enum ib_port_speed)speed;
}

static inline int ib_qp_attr_mask_to_rocm_ernic(int attr_mask)
{
    return attr_mask & ROCM_ERNIC_MASK(ROCM_ERNIC_QP_ATTR_MASK_MAX);
}

static inline enum rocm_ernic_mig_state ib_mig_state_to_rocm_ernic(
    enum ib_mig_state state)
{
    return (enum rocm_ernic_mig_state)state;
}

static inline enum ib_mig_state rocm_ernic_mig_state_to_ib(
    enum rocm_ernic_mig_state state)
{
    return (enum ib_mig_state)state;
}

static inline int ib_access_flags_to_rocm_ernic(int flags)
{
    return flags;
}

static inline int rocm_ernic_access_flags_to_ib(int flags)
{
    return flags & ROCM_ERNIC_MASK(ROCM_ERNIC_ACCESS_FLAGS_MAX);
}

static inline enum rocm_ernic_qp_type ib_qp_type_to_rocm_ernic(
    enum ib_qp_type type)
{
    return (enum rocm_ernic_qp_type)type;
}

static inline enum rocm_ernic_qp_state ib_qp_state_to_rocm_ernic(
    enum ib_qp_state state)
{
    return (enum rocm_ernic_qp_state)state;
}

static inline enum ib_qp_state rocm_ernic_qp_state_to_ib(
    enum rocm_ernic_qp_state state)
{
    return (enum ib_qp_state)state;
}

static inline enum rocm_ernic_wr_opcode ib_wr_opcode_to_rocm_ernic(
    enum ib_wr_opcode op)
{
    switch (op) {
    case IB_WR_RDMA_WRITE:
        return ROCM_ERNIC_WR_RDMA_WRITE;
    case IB_WR_RDMA_WRITE_WITH_IMM:
        return ROCM_ERNIC_WR_RDMA_WRITE_WITH_IMM;
    case IB_WR_SEND:
        return ROCM_ERNIC_WR_SEND;
    case IB_WR_SEND_WITH_IMM:
        return ROCM_ERNIC_WR_SEND_WITH_IMM;
    case IB_WR_RDMA_READ:
        return ROCM_ERNIC_WR_RDMA_READ;
    case IB_WR_ATOMIC_CMP_AND_SWP:
        return ROCM_ERNIC_WR_ATOMIC_CMP_AND_SWP;
    case IB_WR_ATOMIC_FETCH_AND_ADD:
        return ROCM_ERNIC_WR_ATOMIC_FETCH_AND_ADD;
    case IB_WR_LSO:
        return ROCM_ERNIC_WR_LSO;
    case IB_WR_SEND_WITH_INV:
        return ROCM_ERNIC_WR_SEND_WITH_INV;
    case IB_WR_RDMA_READ_WITH_INV:
        return ROCM_ERNIC_WR_RDMA_READ_WITH_INV;
    case IB_WR_LOCAL_INV:
        return ROCM_ERNIC_WR_LOCAL_INV;
    case IB_WR_REG_MR:
        return ROCM_ERNIC_WR_FAST_REG_MR;
    case IB_WR_MASKED_ATOMIC_CMP_AND_SWP:
        return ROCM_ERNIC_WR_MASKED_ATOMIC_CMP_AND_SWP;
    case IB_WR_MASKED_ATOMIC_FETCH_AND_ADD:
        return ROCM_ERNIC_WR_MASKED_ATOMIC_FETCH_AND_ADD;
    case IB_WR_REG_MR_INTEGRITY:
        return ROCM_ERNIC_WR_REG_SIG_MR;
    default:
        return ROCM_ERNIC_WR_ERROR;
    }
}

static inline enum ib_wc_status rocm_ernic_wc_status_to_ib(
    enum rocm_ernic_wc_status status)
{
    return (enum ib_wc_status)status;
}

static inline int rocm_ernic_wc_opcode_to_ib(unsigned int opcode)
{
    switch (opcode) {
    case ROCM_ERNIC_WC_SEND:
        return IB_WC_SEND;
    case ROCM_ERNIC_WC_RDMA_WRITE:
        return IB_WC_RDMA_WRITE;
    case ROCM_ERNIC_WC_RDMA_READ:
        return IB_WC_RDMA_READ;
    case ROCM_ERNIC_WC_COMP_SWAP:
        return IB_WC_COMP_SWAP;
    case ROCM_ERNIC_WC_FETCH_ADD:
        return IB_WC_FETCH_ADD;
    case ROCM_ERNIC_WC_LOCAL_INV:
        return IB_WC_LOCAL_INV;
    case ROCM_ERNIC_WC_FAST_REG_MR:
        return IB_WC_REG_MR;
    case ROCM_ERNIC_WC_MASKED_COMP_SWAP:
        return IB_WC_MASKED_COMP_SWAP;
    case ROCM_ERNIC_WC_MASKED_FETCH_ADD:
        return IB_WC_MASKED_FETCH_ADD;
    case ROCM_ERNIC_WC_RECV:
        return IB_WC_RECV;
    case ROCM_ERNIC_WC_RECV_RDMA_WITH_IMM:
        return IB_WC_RECV_RDMA_WITH_IMM;
    default:
        return IB_WC_SEND;
    }
}

static inline int rocm_ernic_wc_flags_to_ib(int flags)
{
    return flags;
}

static inline int ib_send_flags_to_rocm_ernic(int flags)
{
    return flags & ROCM_ERNIC_MASK(ROCM_ERNIC_SEND_FLAGS_MAX);
}

static inline int rocm_ernic_network_type_to_ib(
    enum rocm_ernic_network_type type)
{
    switch (type) {
    case ROCM_ERNIC_NETWORK_ROCE_V1:
        return RDMA_NETWORK_ROCE_V1;
    case ROCM_ERNIC_NETWORK_IPV4:
        return RDMA_NETWORK_IPV4;
    case ROCM_ERNIC_NETWORK_IPV6:
        return RDMA_NETWORK_IPV6;
    default:
        return RDMA_NETWORK_IPV6;
    }
}

void rocm_ernic_qp_cap_to_ib(struct ib_qp_cap *dst,
                             const struct rocm_ernic_qp_cap *src);
void ib_qp_cap_to_rocm_ernic(struct rocm_ernic_qp_cap *dst,
                             const struct ib_qp_cap *src);
void rocm_ernic_gid_to_ib(union ib_gid *dst, const union rocm_ernic_gid *src);
void ib_gid_to_rocm_ernic(union rocm_ernic_gid *dst, const union ib_gid *src);
void rocm_ernic_global_route_to_ib(struct ib_global_route *dst,
                                   const struct rocm_ernic_global_route *src);
void ib_global_route_to_rocm_ernic(struct rocm_ernic_global_route *dst,
                                   const struct ib_global_route *src);
void rocm_ernic_ah_attr_to_rdma(struct rdma_ah_attr *dst,
                                const struct rocm_ernic_ah_attr *src);
void rdma_ah_attr_to_rocm_ernic(struct rocm_ernic_ah_attr *dst,
                                const struct rdma_ah_attr *src);
u8 ib_gid_type_to_rocm_ernic(enum ib_gid_type gid_type);

int rocm_ernic_uar_table_init(struct rocm_ernic_dev *dev);
void rocm_ernic_uar_table_cleanup(struct rocm_ernic_dev *dev);

int rocm_ernic_uar_alloc(struct rocm_ernic_dev *dev,
                         struct rocm_ernic_uar_map *uar);
void rocm_ernic_uar_free(struct rocm_ernic_dev *dev,
                         struct rocm_ernic_uar_map *uar);

void _rocm_ernic_flush_cqe(struct rocm_ernic_qp *qp, struct rocm_ernic_cq *cq);

int rocm_ernic_page_dir_init(struct rocm_ernic_dev *dev,
                             struct rocm_ernic_page_dir *pdir, u64 npages,
                             bool alloc_pages);
void rocm_ernic_page_dir_cleanup(struct rocm_ernic_dev *dev,
                                 struct rocm_ernic_page_dir *pdir);
int rocm_ernic_page_dir_insert_dma(struct rocm_ernic_page_dir *pdir, u64 idx,
                                   dma_addr_t daddr);
int rocm_ernic_page_dir_insert_umem(struct rocm_ernic_page_dir *pdir,
                                    struct ib_umem *umem, u64 offset);
dma_addr_t rocm_ernic_page_dir_get_dma(struct rocm_ernic_page_dir *pdir,
                                       u64 idx);
int rocm_ernic_page_dir_insert_page_list(struct rocm_ernic_page_dir *pdir,
                                         u64 *page_list, int num_pages);

int rocm_ernic_cmd_post(struct rocm_ernic_dev *dev,
                        union rocm_ernic_cmd_req *req,
                        union rocm_ernic_cmd_resp *rsp, unsigned resp_code);

#endif /* __ROCM_ERNIC_H__ */
