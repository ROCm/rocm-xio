/* SPDX-License-Identifier: ((GPL-2.0 WITH Linux-syscall-note) OR BSD-2-Clause)
 */
/*
 * Copyright (c) 2012-2016 AMD, Inc.  All rights reserved.
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

#ifndef __ROCM_ERNIC_ABI_H__
#define __ROCM_ERNIC_ABI_H__

#include <linux/types.h>

#define ROCM_ERNIC_UVERBS_ABI_VERSION 3          /* ABI Version. */
#define ROCM_ERNIC_UAR_HANDLE_MASK    0x00FFFFFF /* Bottom 24 bits. */
#define ROCM_ERNIC_UAR_QP_OFFSET      0          /* QP doorbell. */
#define ROCM_ERNIC_UAR_QP_SEND        (1 << 30)  /* Send bit. */
#define ROCM_ERNIC_UAR_QP_RECV        (1 << 31)  /* Recv bit. */
#define ROCM_ERNIC_UAR_CQ_OFFSET      4          /* CQ doorbell. */
#define ROCM_ERNIC_UAR_CQ_ARM_SOL     (1 << 29)  /* Arm solicited bit. */
#define ROCM_ERNIC_UAR_CQ_ARM         (1 << 30)  /* Arm bit. */
#define ROCM_ERNIC_UAR_CQ_POLL        (1 << 31)  /* Poll bit. */
#define ROCM_ERNIC_UAR_SRQ_OFFSET     8          /* SRQ doorbell. */
#define ROCM_ERNIC_UAR_SRQ_RECV       (1 << 30)  /* Recv bit. */

enum rocm_ernic_wr_opcode {
    ROCM_ERNIC_WR_RDMA_WRITE,
    ROCM_ERNIC_WR_RDMA_WRITE_WITH_IMM,
    ROCM_ERNIC_WR_SEND,
    ROCM_ERNIC_WR_SEND_WITH_IMM,
    ROCM_ERNIC_WR_RDMA_READ,
    ROCM_ERNIC_WR_ATOMIC_CMP_AND_SWP,
    ROCM_ERNIC_WR_ATOMIC_FETCH_AND_ADD,
    ROCM_ERNIC_WR_LSO,
    ROCM_ERNIC_WR_SEND_WITH_INV,
    ROCM_ERNIC_WR_RDMA_READ_WITH_INV,
    ROCM_ERNIC_WR_LOCAL_INV,
    ROCM_ERNIC_WR_FAST_REG_MR,
    ROCM_ERNIC_WR_MASKED_ATOMIC_CMP_AND_SWP,
    ROCM_ERNIC_WR_MASKED_ATOMIC_FETCH_AND_ADD,
    ROCM_ERNIC_WR_BIND_MW,
    ROCM_ERNIC_WR_REG_SIG_MR,
    ROCM_ERNIC_WR_ERROR,
};

enum rocm_ernic_wc_status {
    ROCM_ERNIC_WC_SUCCESS,
    ROCM_ERNIC_WC_LOC_LEN_ERR,
    ROCM_ERNIC_WC_LOC_QP_OP_ERR,
    ROCM_ERNIC_WC_LOC_EEC_OP_ERR,
    ROCM_ERNIC_WC_LOC_PROT_ERR,
    ROCM_ERNIC_WC_WR_FLUSH_ERR,
    ROCM_ERNIC_WC_MW_BIND_ERR,
    ROCM_ERNIC_WC_BAD_RESP_ERR,
    ROCM_ERNIC_WC_LOC_ACCESS_ERR,
    ROCM_ERNIC_WC_REM_INV_REQ_ERR,
    ROCM_ERNIC_WC_REM_ACCESS_ERR,
    ROCM_ERNIC_WC_REM_OP_ERR,
    ROCM_ERNIC_WC_RETRY_EXC_ERR,
    ROCM_ERNIC_WC_RNR_RETRY_EXC_ERR,
    ROCM_ERNIC_WC_LOC_RDD_VIOL_ERR,
    ROCM_ERNIC_WC_REM_INV_RD_REQ_ERR,
    ROCM_ERNIC_WC_REM_ABORT_ERR,
    ROCM_ERNIC_WC_INV_EECN_ERR,
    ROCM_ERNIC_WC_INV_EEC_STATE_ERR,
    ROCM_ERNIC_WC_FATAL_ERR,
    ROCM_ERNIC_WC_RESP_TIMEOUT_ERR,
    ROCM_ERNIC_WC_GENERAL_ERR,
};

enum rocm_ernic_wc_opcode {
    ROCM_ERNIC_WC_SEND,
    ROCM_ERNIC_WC_RDMA_WRITE,
    ROCM_ERNIC_WC_RDMA_READ,
    ROCM_ERNIC_WC_COMP_SWAP,
    ROCM_ERNIC_WC_FETCH_ADD,
    ROCM_ERNIC_WC_BIND_MW,
    ROCM_ERNIC_WC_LSO,
    ROCM_ERNIC_WC_LOCAL_INV,
    ROCM_ERNIC_WC_FAST_REG_MR,
    ROCM_ERNIC_WC_MASKED_COMP_SWAP,
    ROCM_ERNIC_WC_MASKED_FETCH_ADD,
    ROCM_ERNIC_WC_RECV = 1 << 7,
    ROCM_ERNIC_WC_RECV_RDMA_WITH_IMM,
};

enum rocm_ernic_wc_flags {
    ROCM_ERNIC_WC_GRH = 1 << 0,
    ROCM_ERNIC_WC_WITH_IMM = 1 << 1,
    ROCM_ERNIC_WC_WITH_INVALIDATE = 1 << 2,
    ROCM_ERNIC_WC_IP_CSUM_OK = 1 << 3,
    ROCM_ERNIC_WC_WITH_SMAC = 1 << 4,
    ROCM_ERNIC_WC_WITH_VLAN = 1 << 5,
    ROCM_ERNIC_WC_WITH_NETWORK_HDR_TYPE = 1 << 6,
    ROCM_ERNIC_WC_FLAGS_MAX = ROCM_ERNIC_WC_WITH_NETWORK_HDR_TYPE,
};

enum rocm_ernic_network_type {
    ROCM_ERNIC_NETWORK_IB,
    ROCM_ERNIC_NETWORK_ROCE_V1 = ROCM_ERNIC_NETWORK_IB,
    ROCM_ERNIC_NETWORK_IPV4,
    ROCM_ERNIC_NETWORK_IPV6
};

struct rocm_ernic_alloc_ucontext_resp {
    __u32 qp_tab_size;
    __u32 reserved;
};

struct rocm_ernic_alloc_pd_resp {
    __u32 pdn;
    __u32 reserved;
};

struct rocm_ernic_create_cq {
    __aligned_u64 buf_addr;
    __u32 buf_size;
    __u32 reserved;
    __aligned_u64 comp_mask;
    __u32 ncqe;
    __u32 cqe_size;
};

struct rocm_ernic_create_cq_resp {
    __u32 cqn;
    __u32 ncqe;
    __u32 cqe_size;
    __u32 reserved;
};

struct rocm_ernic_resize_cq {
    __aligned_u64 buf_addr;
    __u32 buf_size;
    __u32 reserved;
};

struct rocm_ernic_create_srq {
    __aligned_u64 buf_addr;
    __u32 buf_size;
    __u32 reserved;
};

struct rocm_ernic_create_srq_resp {
    __u32 srqn;
    __u32 reserved;
};

struct rocm_ernic_create_qp {
    __aligned_u64 rbuf_addr;
    __aligned_u64 sbuf_addr;
    __u32 rbuf_size;
    __u32 sbuf_size;
    __aligned_u64 qp_addr;
    __aligned_u64 comp_mask;
    __u32 sq_wqe_size;
    __u32 sq_depth;
    __u32 rq_wqe_size;
    __u32 rq_depth;
};

struct rocm_ernic_create_qp_resp {
    __u32 qpn;
    __u32 qp_handle;
    __u32 sq_depth;
    __u32 rq_depth;
    __u32 sq_wqe_size;
    __u32 rq_wqe_size;
    __aligned_u64 uar_mmap_offset;
    __u32 uar_qp_offset;
    __u32 uar_cq_offset;
};

/* ROCM_ERNIC masked atomic compare and swap */
struct rocm_ernic_ex_cmp_swap {
    __aligned_u64 swap_val;
    __aligned_u64 compare_val;
    __aligned_u64 swap_mask;
    __aligned_u64 compare_mask;
};

/* ROCM_ERNIC masked atomic fetch and add */
struct rocm_ernic_ex_fetch_add {
    __aligned_u64 add_val;
    __aligned_u64 field_boundary;
};

/* ROCM_ERNIC address vector. */
struct rocm_ernic_av {
    __u32 port_pd;
    __u32 sl_tclass_flowlabel;
    __u8 dgid[16];
    __u8 src_path_bits;
    __u8 gid_index;
    __u8 stat_rate;
    __u8 hop_limit;
    __u8 dmac[6];
    __u8 reserved[6];
};

/* ROCM_ERNIC scatter/gather entry */
struct rocm_ernic_sge {
    __aligned_u64 addr;
    __u32 length;
    __u32 lkey;
};

/* ROCM_ERNIC receive queue work request */
struct rocm_ernic_rq_wqe_hdr {
    __aligned_u64 wr_id; /* wr id */
    __u32 num_sge;       /* size of s/g array */
    __u32 total_len;     /* reserved */
};
/* Use rocm_ernic_sge (ib_sge) for receive queue s/g array elements. */

/* ROCM_ERNIC send queue work request */
struct rocm_ernic_sq_wqe_hdr {
    __aligned_u64 wr_id; /* wr id */
    __u32 num_sge;       /* size of s/g array */
    __u32 total_len;     /* reserved */
    __u32 opcode;        /* operation type */
    __u32 send_flags;    /* wr flags */
    union {
        __be32 imm_data;
        __u32 invalidate_rkey;
    } ex;
    __u32 reserved;
    union {
        struct {
            __aligned_u64 remote_addr;
            __u32 rkey;
            __u8 reserved[4];
        } rdma;
        struct {
            __aligned_u64 remote_addr;
            __aligned_u64 compare_add;
            __aligned_u64 swap;
            __u32 rkey;
            __u32 reserved;
        } atomic;
        struct {
            __aligned_u64 remote_addr;
            __u32 log_arg_sz;
            __u32 rkey;
            union {
                struct rocm_ernic_ex_cmp_swap cmp_swap;
                struct rocm_ernic_ex_fetch_add fetch_add;
            } wr_data;
        } masked_atomics;
        struct {
            __aligned_u64 iova_start;
            __aligned_u64 pl_pdir_dma;
            __u32 page_shift;
            __u32 page_list_len;
            __u32 length;
            __u32 access_flags;
            __u32 rkey;
            __u32 reserved;
        } fast_reg;
        struct {
            __u32 remote_qpn;
            __u32 remote_qkey;
            struct rocm_ernic_av av;
        } ud;
    } wr;
};
/* Use rocm_ernic_sge (ib_sge) for send queue s/g array elements. */

/* Completion queue element. */
struct rocm_ernic_cqe {
    __aligned_u64 wr_id;
    __aligned_u64 qp;
    __u32 opcode;
    __u32 status;
    __u32 byte_len;
    __be32 imm_data;
    __u32 src_qp;
    __u32 wc_flags;
    __u32 vendor_err;
    __u16 pkey_index;
    __u16 slid;
    __u8 sl;
    __u8 dlid_path_bits;
    __u8 port_num;
    __u8 smac[6];
    __u8 network_hdr_type;
    __u8 reserved2[6]; /* Pad to next power of 2 (64). */
};

#endif /* __ROCM_ERNIC_ABI_H__ */
