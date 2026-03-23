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

#ifndef __ROCM_ERNIC_VERBS_H__
#define __ROCM_ERNIC_VERBS_H__

#include <linux/version.h>
#include <linux/types.h>

union rocm_ernic_gid {
    u8 raw[16];
    struct {
        __be64 subnet_prefix;
        __be64 interface_id;
    } global;
};

enum rocm_ernic_link_layer {
    ROCM_ERNIC_LINK_LAYER_UNSPECIFIED,
    ROCM_ERNIC_LINK_LAYER_INFINIBAND,
    ROCM_ERNIC_LINK_LAYER_ETHERNET,
};

enum rocm_ernic_mtu {
    ROCM_ERNIC_MTU_256 = 1,
    ROCM_ERNIC_MTU_512 = 2,
    ROCM_ERNIC_MTU_1024 = 3,
    ROCM_ERNIC_MTU_2048 = 4,
    ROCM_ERNIC_MTU_4096 = 5,
};

enum rocm_ernic_port_state {
    ROCM_ERNIC_PORT_NOP = 0,
    ROCM_ERNIC_PORT_DOWN = 1,
    ROCM_ERNIC_PORT_INIT = 2,
    ROCM_ERNIC_PORT_ARMED = 3,
    ROCM_ERNIC_PORT_ACTIVE = 4,
    ROCM_ERNIC_PORT_ACTIVE_DEFER = 5,
};

enum rocm_ernic_port_cap_flags {
    ROCM_ERNIC_PORT_SM = 1 << 1,
    ROCM_ERNIC_PORT_NOTICE_SUP = 1 << 2,
    ROCM_ERNIC_PORT_TRAP_SUP = 1 << 3,
    ROCM_ERNIC_PORT_OPT_IPD_SUP = 1 << 4,
    ROCM_ERNIC_PORT_AUTO_MIGR_SUP = 1 << 5,
    ROCM_ERNIC_PORT_SL_MAP_SUP = 1 << 6,
    ROCM_ERNIC_PORT_MKEY_NVRAM = 1 << 7,
    ROCM_ERNIC_PORT_PKEY_NVRAM = 1 << 8,
    ROCM_ERNIC_PORT_LED_INFO_SUP = 1 << 9,
    ROCM_ERNIC_PORT_SM_DISABLED = 1 << 10,
    ROCM_ERNIC_PORT_SYS_IMAGE_GUID_SUP = 1 << 11,
    ROCM_ERNIC_PORT_PKEY_SW_EXT_PORT_TRAP_SUP = 1 << 12,
    ROCM_ERNIC_PORT_EXTENDED_SPEEDS_SUP = 1 << 14,
    ROCM_ERNIC_PORT_CM_SUP = 1 << 16,
    ROCM_ERNIC_PORT_SNMP_TUNNEL_SUP = 1 << 17,
    ROCM_ERNIC_PORT_REINIT_SUP = 1 << 18,
    ROCM_ERNIC_PORT_DEVICE_MGMT_SUP = 1 << 19,
    ROCM_ERNIC_PORT_VENDOR_CLASS_SUP = 1 << 20,
    ROCM_ERNIC_PORT_DR_NOTICE_SUP = 1 << 21,
    ROCM_ERNIC_PORT_CAP_MASK_NOTICE_SUP = 1 << 22,
    ROCM_ERNIC_PORT_BOOT_MGMT_SUP = 1 << 23,
    ROCM_ERNIC_PORT_LINK_LATENCY_SUP = 1 << 24,
    ROCM_ERNIC_PORT_CLIENT_REG_SUP = 1 << 25,
    ROCM_ERNIC_PORT_IP_BASED_GIDS = 1 << 26,
    ROCM_ERNIC_PORT_CAP_FLAGS_MAX = ROCM_ERNIC_PORT_IP_BASED_GIDS,
};

enum rocm_ernic_port_width {
    ROCM_ERNIC_WIDTH_1X = 1,
    ROCM_ERNIC_WIDTH_4X = 2,
    ROCM_ERNIC_WIDTH_8X = 4,
    ROCM_ERNIC_WIDTH_12X = 8,
};

enum rocm_ernic_port_speed {
    ROCM_ERNIC_SPEED_SDR = 1,
    ROCM_ERNIC_SPEED_DDR = 2,
    ROCM_ERNIC_SPEED_QDR = 4,
    ROCM_ERNIC_SPEED_FDR10 = 8,
    ROCM_ERNIC_SPEED_FDR = 16,
    ROCM_ERNIC_SPEED_EDR = 32,
};

struct rocm_ernic_port_attr {
    enum rocm_ernic_port_state state;
    enum rocm_ernic_mtu max_mtu;
    enum rocm_ernic_mtu active_mtu;
    u32 gid_tbl_len;
    u32 port_cap_flags;
    u32 max_msg_sz;
    u32 bad_pkey_cntr;
    u32 qkey_viol_cntr;
    u16 pkey_tbl_len;
    u16 lid;
    u16 sm_lid;
    u8 lmc;
    u8 max_vl_num;
    u8 sm_sl;
    u8 subnet_timeout;
    u8 init_type_reply;
    u8 active_width;
    u8 active_speed;
    u8 phys_state;
    u8 reserved[2];
};

struct rocm_ernic_global_route {
    union rocm_ernic_gid dgid;
    u32 flow_label;
    u8 sgid_index;
    u8 hop_limit;
    u8 traffic_class;
    u8 reserved;
};

struct rocm_ernic_grh {
    __be32 version_tclass_flow;
    __be16 paylen;
    u8 next_hdr;
    u8 hop_limit;
    union rocm_ernic_gid sgid;
    union rocm_ernic_gid dgid;
};

enum rocm_ernic_ah_flags {
    ROCM_ERNIC_AH_GRH = 1,
};

enum rocm_ernic_rate {
    ROCM_ERNIC_RATE_PORT_CURRENT = 0,
    ROCM_ERNIC_RATE_2_5_GBPS = 2,
    ROCM_ERNIC_RATE_5_GBPS = 5,
    ROCM_ERNIC_RATE_10_GBPS = 3,
    ROCM_ERNIC_RATE_20_GBPS = 6,
    ROCM_ERNIC_RATE_30_GBPS = 4,
    ROCM_ERNIC_RATE_40_GBPS = 7,
    ROCM_ERNIC_RATE_60_GBPS = 8,
    ROCM_ERNIC_RATE_80_GBPS = 9,
    ROCM_ERNIC_RATE_120_GBPS = 10,
    ROCM_ERNIC_RATE_14_GBPS = 11,
    ROCM_ERNIC_RATE_56_GBPS = 12,
    ROCM_ERNIC_RATE_112_GBPS = 13,
    ROCM_ERNIC_RATE_168_GBPS = 14,
    ROCM_ERNIC_RATE_25_GBPS = 15,
    ROCM_ERNIC_RATE_100_GBPS = 16,
    ROCM_ERNIC_RATE_200_GBPS = 17,
    ROCM_ERNIC_RATE_300_GBPS = 18,
};

struct rocm_ernic_ah_attr {
    struct rocm_ernic_global_route grh;
    u16 dlid;
    u16 vlan_id;
    u8 sl;
    u8 src_path_bits;
    u8 static_rate;
    u8 ah_flags;
    u8 port_num;
    u8 dmac[6];
    u8 reserved;
};

enum rocm_ernic_cq_notify_flags {
    ROCM_ERNIC_CQ_SOLICITED = 1 << 0,
    ROCM_ERNIC_CQ_NEXT_COMP = 1 << 1,
    ROCM_ERNIC_CQ_SOLICITED_MASK =
        ROCM_ERNIC_CQ_SOLICITED | ROCM_ERNIC_CQ_NEXT_COMP,
    ROCM_ERNIC_CQ_REPORT_MISSED_EVENTS = 1 << 2,
};

struct rocm_ernic_qp_cap {
    u32 max_send_wr;
    u32 max_recv_wr;
    u32 max_send_sge;
    u32 max_recv_sge;
    u32 max_inline_data;
    u32 reserved;
};

enum rocm_ernic_sig_type {
    ROCM_ERNIC_SIGNAL_ALL_WR,
    ROCM_ERNIC_SIGNAL_REQ_WR,
};

enum rocm_ernic_qp_type {
    ROCM_ERNIC_QPT_SMI,
    ROCM_ERNIC_QPT_GSI,
    ROCM_ERNIC_QPT_RC,
    ROCM_ERNIC_QPT_UC,
    ROCM_ERNIC_QPT_UD,
    ROCM_ERNIC_QPT_RAW_IPV6,
    ROCM_ERNIC_QPT_RAW_ETHERTYPE,
    ROCM_ERNIC_QPT_RAW_PACKET = 8,
    ROCM_ERNIC_QPT_XRC_INI = 9,
    ROCM_ERNIC_QPT_XRC_TGT,
    ROCM_ERNIC_QPT_MAX,
};

enum rocm_ernic_qp_create_flags {
    ROCM_ERNIC_QP_CREATE_IPOROCM_ERNIC_UD_LSO = 1 << 0,
    ROCM_ERNIC_QP_CREATE_BLOCK_MULTICAST_LOOPBACK = 1 << 1,
};

enum rocm_ernic_qp_attr_mask {
    ROCM_ERNIC_QP_STATE = 1 << 0,
    ROCM_ERNIC_QP_CUR_STATE = 1 << 1,
    ROCM_ERNIC_QP_EN_SQD_ASYNC_NOTIFY = 1 << 2,
    ROCM_ERNIC_QP_ACCESS_FLAGS = 1 << 3,
    ROCM_ERNIC_QP_PKEY_INDEX = 1 << 4,
    ROCM_ERNIC_QP_PORT = 1 << 5,
    ROCM_ERNIC_QP_QKEY = 1 << 6,
    ROCM_ERNIC_QP_AV = 1 << 7,
    ROCM_ERNIC_QP_PATH_MTU = 1 << 8,
    ROCM_ERNIC_QP_TIMEOUT = 1 << 9,
    ROCM_ERNIC_QP_RETRY_CNT = 1 << 10,
    ROCM_ERNIC_QP_RNR_RETRY = 1 << 11,
    ROCM_ERNIC_QP_RQ_PSN = 1 << 12,
    ROCM_ERNIC_QP_MAX_QP_RD_ATOMIC = 1 << 13,
    ROCM_ERNIC_QP_ALT_PATH = 1 << 14,
    ROCM_ERNIC_QP_MIN_RNR_TIMER = 1 << 15,
    ROCM_ERNIC_QP_SQ_PSN = 1 << 16,
    ROCM_ERNIC_QP_MAX_DEST_RD_ATOMIC = 1 << 17,
    ROCM_ERNIC_QP_PATH_MIG_STATE = 1 << 18,
    ROCM_ERNIC_QP_CAP = 1 << 19,
    ROCM_ERNIC_QP_DEST_QPN = 1 << 20,
    ROCM_ERNIC_QP_REMOTE_ADDR = 1 << 21, /* Vendor-specific: remote_addr */
    ROCM_ERNIC_QP_REMOTE_RKEY = 1 << 22, /* Vendor-specific: remote_rkey */
    ROCM_ERNIC_QP_ATTR_MASK_MAX = ROCM_ERNIC_QP_REMOTE_RKEY,
};

enum rocm_ernic_qp_state {
    ROCM_ERNIC_QPS_RESET,
    ROCM_ERNIC_QPS_INIT,
    ROCM_ERNIC_QPS_RTR,
    ROCM_ERNIC_QPS_RTS,
    ROCM_ERNIC_QPS_SQD,
    ROCM_ERNIC_QPS_SQE,
    ROCM_ERNIC_QPS_ERR,
};

enum rocm_ernic_mig_state {
    ROCM_ERNIC_MIG_MIGRATED,
    ROCM_ERNIC_MIG_REARM,
    ROCM_ERNIC_MIG_ARMED,
};

enum rocm_ernic_mw_type {
    ROCM_ERNIC_MW_TYPE_1 = 1,
    ROCM_ERNIC_MW_TYPE_2 = 2,
};

struct rocm_ernic_srq_attr {
    u32 max_wr;
    u32 max_sge;
    u32 srq_limit;
    u32 reserved;
};

struct rocm_ernic_qp_attr {
    enum rocm_ernic_qp_state qp_state;
    enum rocm_ernic_qp_state cur_qp_state;
    enum rocm_ernic_mtu path_mtu;
    enum rocm_ernic_mig_state path_mig_state;
    u32 qkey;
    u32 rq_psn;
    u32 sq_psn;
    u32 dest_qp_num;
    u32 qp_access_flags;
    u16 pkey_index;
    u16 alt_pkey_index;
    u8 en_sqd_async_notify;
    u8 sq_draining;
    u8 max_rd_atomic;
    u8 max_dest_rd_atomic;
    u8 min_rnr_timer;
    u8 port_num;
    u8 timeout;
    u8 retry_cnt;
    u8 rnr_retry;
    u8 alt_port_num;
    u8 alt_timeout;
    u8 reserved[1];
    /* Vendor-specific extensions for rdma_cm support */
    u64 remote_addr; /* Remote virtual address for RDMA ops */
    u32 remote_rkey; /* Remote rkey for RDMA ops */
    struct rocm_ernic_qp_cap cap;
    struct rocm_ernic_ah_attr ah_attr;
    struct rocm_ernic_ah_attr alt_ah_attr;
};

enum rocm_ernic_send_flags {
    ROCM_ERNIC_SEND_FENCE = 1 << 0,
    ROCM_ERNIC_SEND_SIGNALED = 1 << 1,
    ROCM_ERNIC_SEND_SOLICITED = 1 << 2,
    ROCM_ERNIC_SEND_INLINE = 1 << 3,
    ROCM_ERNIC_SEND_IP_CSUM = 1 << 4,
    ROCM_ERNIC_SEND_FLAGS_MAX = ROCM_ERNIC_SEND_IP_CSUM,
};

enum rocm_ernic_access_flags {
    ROCM_ERNIC_ACCESS_LOCAL_WRITE = 1 << 0,
    ROCM_ERNIC_ACCESS_REMOTE_WRITE = 1 << 1,
    ROCM_ERNIC_ACCESS_REMOTE_READ = 1 << 2,
    ROCM_ERNIC_ACCESS_REMOTE_ATOMIC = 1 << 3,
    ROCM_ERNIC_ACCESS_MW_BIND = 1 << 4,
    ROCM_ERNIC_ZERO_BASED = 1 << 5,
    ROCM_ERNIC_ACCESS_ON_DEMAND = 1 << 6,
    ROCM_ERNIC_ACCESS_FLAGS_MAX = ROCM_ERNIC_ACCESS_ON_DEMAND,
};

int rocm_ernic_query_device(struct ib_device *ibdev,
                            struct ib_device_attr *props,
                            struct ib_udata *udata);
int rocm_ernic_query_port(struct ib_device *ibdev, u32 port,
                          struct ib_port_attr *props);
int rocm_ernic_query_gid(struct ib_device *ibdev, u32 port, int index,
                         union ib_gid *gid);
int rocm_ernic_query_pkey(struct ib_device *ibdev, u32 port, u16 index,
                          u16 *pkey);
enum rdma_link_layer rocm_ernic_port_link_layer(struct ib_device *ibdev,
                                                u32 port);
int rocm_ernic_modify_port(struct ib_device *ibdev, u32 port, int mask,
                           struct ib_port_modify *props);
int rocm_ernic_mmap(struct ib_ucontext *context, struct vm_area_struct *vma);
int rocm_ernic_alloc_ucontext(struct ib_ucontext *uctx, struct ib_udata *udata);
void rocm_ernic_dealloc_ucontext(struct ib_ucontext *context);
int rocm_ernic_alloc_pd(struct ib_pd *pd, struct ib_udata *udata);
int rocm_ernic_dealloc_pd(struct ib_pd *ibpd, struct ib_udata *udata);
struct ib_mr *rocm_ernic_get_dma_mr(struct ib_pd *pd, int acc);
struct ib_mr *rocm_ernic_reg_user_mr(struct ib_pd *pd, u64 start, u64 length,
                                     u64 virt_addr, int access_flags,
                                     struct ib_udata *udata);
int rocm_ernic_dereg_mr(struct ib_mr *mr, struct ib_udata *udata);
struct ib_mr *rocm_ernic_alloc_mr(struct ib_pd *pd, enum ib_mr_type mr_type,
                                  u32 max_num_sg);
int rocm_ernic_map_mr_sg(struct ib_mr *ibmr, struct scatterlist *sg,
                         int sg_nents, unsigned int *sg_offset);
int rocm_ernic_create_cq(struct ib_cq *ibcq, const struct ib_cq_init_attr *attr,
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 11, 0)
                         struct uverbs_attr_bundle *attrs);
#else
                         struct ib_udata *udata);
#endif
int rocm_ernic_destroy_cq(struct ib_cq *cq, struct ib_udata *udata);
int rocm_ernic_poll_cq(struct ib_cq *ibcq, int num_entries, struct ib_wc *wc);
int rocm_ernic_req_notify_cq(struct ib_cq *cq, enum ib_cq_notify_flags flags);
int rocm_ernic_create_ah(struct ib_ah *ah, struct rdma_ah_init_attr *init_attr,
                         struct ib_udata *udata);
int rocm_ernic_destroy_ah(struct ib_ah *ah, u32 flags);

int rocm_ernic_create_srq(struct ib_srq *srq,
                          struct ib_srq_init_attr *init_attr,
                          struct ib_udata *udata);
int rocm_ernic_modify_srq(struct ib_srq *ibsrq, struct ib_srq_attr *attr,
                          enum ib_srq_attr_mask attr_mask,
                          struct ib_udata *udata);
int rocm_ernic_query_srq(struct ib_srq *srq, struct ib_srq_attr *srq_attr);
int rocm_ernic_destroy_srq(struct ib_srq *srq, struct ib_udata *udata);

int rocm_ernic_create_qp(struct ib_qp *qp, struct ib_qp_init_attr *init_attr,
                         struct ib_udata *udata);
int rocm_ernic_modify_qp(struct ib_qp *ibqp, struct ib_qp_attr *attr,
                         int attr_mask, struct ib_udata *udata);
int rocm_ernic_query_qp(struct ib_qp *ibqp, struct ib_qp_attr *qp_attr,
                        int qp_attr_mask, struct ib_qp_init_attr *qp_init_attr);
int rocm_ernic_destroy_qp(struct ib_qp *qp, struct ib_udata *udata);
int rocm_ernic_post_send(struct ib_qp *ibqp, const struct ib_send_wr *wr,
                         const struct ib_send_wr **bad_wr);
int rocm_ernic_post_recv(struct ib_qp *ibqp, const struct ib_recv_wr *wr,
                         const struct ib_recv_wr **bad_wr);

#endif /* __ROCM_ERNIC_VERBS_H__ */
