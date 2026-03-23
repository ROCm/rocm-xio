/* SPDX-License-Identifier: ((GPL-2.0 WITH Linux-syscall-note) OR
 *                          BSD-2-Clause)
 */
/*
 * Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * Direct Verbs UAPI header for the rocm_ernic RDMA driver.
 * Structures shared between kernel driver and rdma-core
 * provider (librocm_ernic.so).
 *
 * Modeled after the bnxt_re DV UAPI
 * (include/uapi/rdma/bnxt_re-abi.h).
 */

#ifndef __ROCM_ERNIC_DV_UAPI_H__
#define __ROCM_ERNIC_DV_UAPI_H__

#include <linux/types.h>

#define ROCM_ERNIC_DV_ABI_VERSION 1

/*
 * DV comp_mask bits for rocm_ernic_create_qp.
 * When ROCM_ERNIC_QP_DV_ENABLE is set in the extended
 * create_qp udata, the kernel uses DV-provided SQ/RQ
 * buffer sizing instead of computing from QP caps.
 */
enum rocm_ernic_qp_dv_mask {
    ROCM_ERNIC_QP_DV_ENABLE = 1 << 0,
};

/*
 * Extended create_qp request for DV.  Appended after
 * the standard rocm_ernic_create_qp fields when
 * comp_mask has ROCM_ERNIC_QP_DV_ENABLE set.
 */
struct rocm_ernic_create_qp_dv {
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

/*
 * Extended create_qp response for DV.  Returns UAR
 * mmap info so the provider can expose doorbell pages.
 */
struct rocm_ernic_create_qp_dv_resp {
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

/*
 * Extended create_cq request for DV.  Carries a
 * comp_mask to distinguish DV from standard path.
 */
enum rocm_ernic_cq_dv_mask {
    ROCM_ERNIC_CQ_DV_ENABLE = 1 << 0,
};

struct rocm_ernic_create_cq_dv {
    __aligned_u64 buf_addr;
    __u32 buf_size;
    __u32 reserved;
    __aligned_u64 comp_mask;
    __u32 ncqe;
    __u32 cqe_size;
};

struct rocm_ernic_create_cq_dv_resp {
    __u32 cqn;
    __u32 ncqe;
    __u32 cqe_size;
    __u32 reserved;
};

#endif /* __ROCM_ERNIC_DV_UAPI_H__ */
