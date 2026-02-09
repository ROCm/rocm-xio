/*
 * Minimal device struct definitions for DOCA-compatible verbs.
 * Full definitions are in the DOCA SDK; this allows the hipified headers to
 * compile when only the device API is used.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */
#ifndef DOCA_GPUNETIO_DEV_VERBS_STRUCTS_HIP_H
#define DOCA_GPUNETIO_DEV_VERBS_STRUCTS_HIP_H

/* Requires doca_gpunetio_verbs_def.hip.h (via common) for __be32 etc. */
#ifndef DOCA_GPUNETIO_VERBS_DEF_H
#include "doca_gpunetio_verbs_def.hip.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Ticket for async completion (WQE index or similar) */
typedef uint64_t radaki_dev_ticket_t;

/* Remote/local address + key (for RDMA) */
struct radaki_dev_addr {
    uint64_t addr;
    uint32_t key;
};

/* WQE wait segment (2x64-bit for store_wqe_seg) */
struct radaki_dev_wqe_wait_seg {
    __be32 max_index;
    __be32 qpn_cqn;
    uint8_t reserved[8];
} __attribute__((__packed__));

/* WQE control segment (same layout as doca_gpunetio_ib_mlx5_wqe_ctrl_seg, 16 bytes) */
struct radaki_dev_wqe_ctrl_seg {
    __be32 opmod_idx_opcode;
    __be32 qpn_ds;
    uint8_t signature;
    __be16 dci_stream_channel_id;
    uint8_t fm_ce_se;
    __be32 imm;
} __attribute__((__packed__)) __attribute__((__aligned__(4)));

/* WQE: segments are 2x64-bit each; dseg0 holds ctrl, dseg1 raddr, dseg2/dseg3 data segs */
struct radaki_dev_wqe {
    uint64_t dseg0[2];
    uint64_t dseg1[2];
    uint64_t dseg2[2];
    uint64_t dseg3[2];
};

struct radaki_dev_cq {
    uintptr_t cqe_daddr;
    uint32_t cqe_num;
    uint64_t cqe_ci;
    uint64_t cqe_rsvd;
    uint32_t cq_num;
    uintptr_t dbrec;
};

struct radaki_dev_qp {
    struct radaki_dev_cq cq_sq;
    uint16_t sq_wqe_mask;
    uintptr_t sq_wqe_daddr;
    uint16_t sq_wqe_num;
    uint64_t sq_rsvd_index;
    uint64_t sq_ready_index;
    uintptr_t sq_dbrec;
    uintptr_t sq_db;
    int sq_lock;
    uint64_t sq_wqe_pi;
    __be32 sq_num_shift8_be;
    uint32_t sq_num_shift8; /* non-BE form for qpn_ds construction */
    int nic_handler;
    __be32 sq_num_shift8_be_1ds;
    __be32 sq_num_shift8_be_3ds;
    __be32 sq_num_shift8_be_4ds;
};

#ifdef __cplusplus
}
#endif

#endif /* DOCA_GPUNETIO_DEV_VERBS_STRUCTS_HIP_H */
