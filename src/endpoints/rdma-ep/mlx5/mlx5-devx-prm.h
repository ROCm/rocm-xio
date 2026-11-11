/* SPDX-License-Identifier: GPL-2.0 OR Linux-OpenIB */
/*
 * Copyright (c) 2013-2015, Mellanox Technologies. All rights reserved.
 * Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 */

/**
 * @file mlx5-devx-prm.h
 * @brief mlx5 command layouts used to create a QP and CQ through DevX.
 *
 * Layouts follow the kernel's mlx5_ifc.h in DEVX_SET form; the umem fields
 * are named where the kernel leaves reserved gaps.
 */

#ifndef RDMA_EP_MLX5_DEVX_PRM_H
#define RDMA_EP_MLX5_DEVX_PRM_H

#include <cstdint>

// Command opcodes
enum {
  XIO_MLX5_CMD_OP_CREATE_CQ = 0x400,
  XIO_MLX5_CMD_OP_CREATE_QP = 0x500,
  XIO_MLX5_CMD_OP_RST2INIT_QP = 0x502,
  XIO_MLX5_CMD_OP_INIT2RTR_QP = 0x503,
  XIO_MLX5_CMD_OP_RTR2RTS_QP = 0x504,
};

// qpc field values
enum {
  XIO_MLX5_QPC_ST_RC = 0x0,
  XIO_MLX5_QPC_PM_STATE_MIGRATED = 0x3,
  XIO_MLX5_QPC_RQ_TYPE_ZERO_LEN_RQ = 0x3,
  XIO_MLX5_QPC_ATOMIC_MODE_UP_TO_8B = 0x3,
};

struct mlx5_ifc_ads_bits {
  uint8_t reserved_at_0[0x28];
  uint8_t grh[0x1];
  uint8_t reserved_at_29[0x7];
  uint8_t rlid[0x10];

  uint8_t ack_timeout[0x5];
  uint8_t reserved_at_45[0x3];
  uint8_t src_addr_index[0x8];
  uint8_t reserved_at_50[0x8];
  uint8_t hop_limit[0x8];

  uint8_t reserved_at_60[0x4];
  uint8_t tclass[0x8];
  uint8_t reserved_at_6c[0x14];
  uint8_t rgid_rip[16][0x8];

  uint8_t reserved_at_100[0x28];
  uint8_t vhca_port_num[0x8];
  uint8_t reserved_at_130[0x30];
};

struct mlx5_ifc_cqc_bits {
  uint8_t reserved_at_0[0x6];
  uint8_t dbr_umem_valid[0x1];
  uint8_t reserved_at_7[0x19];
  uint8_t dbr_umem_id[0x20];

  uint8_t reserved_at_40[0x23];
  uint8_t log_cq_size[0x5];
  uint8_t uar_page[0x18];

  uint8_t reserved_at_80[0x20];
  uint8_t c_eqn_or_apu_element[0x20];

  uint8_t reserved_at_c0[0x100];
  uint8_t dbr_addr[0x40];
};

struct mlx5_ifc_qpc_bits {
  uint8_t reserved_at_0[0x8];
  uint8_t st[0x8];
  uint8_t reserved_at_10[0x3];
  uint8_t pm_state[0x2];
  uint8_t reserved_at_15[0x13];
  uint8_t pd[0x18];

  uint8_t mtu[0x3];
  uint8_t log_msg_max[0x5];
  uint8_t reserved_at_48[0x9];
  uint8_t log_sq_size[0x4];
  uint8_t reserved_at_55[0x13];
  uint8_t uar_page[0x18];

  uint8_t reserved_at_80[0x28];
  uint8_t remote_qpn[0x18];

  struct mlx5_ifc_ads_bits primary_address_path;

  uint8_t reserved_at_220[0x168];
  uint8_t log_sra_max[0x3];
  uint8_t reserved_at_38b[0x2];
  uint8_t retry_count[0x3];
  uint8_t rnr_retry[0x3];
  uint8_t reserved_at_393[0x55];
  uint8_t cqn_snd[0x18];

  uint8_t reserved_at_400[0x88];
  uint8_t log_rra_max[0x3];
  uint8_t reserved_at_48b[0x1];
  uint8_t atomic_mode[0x4];
  uint8_t rre[0x1];
  uint8_t rwe[0x1];
  uint8_t rae[0x1];
  uint8_t reserved_at_493[0x10];
  uint8_t min_rnr_nak[0x5];
  uint8_t next_rcv_psn[0x18];

  uint8_t reserved_at_4c0[0x28];
  uint8_t cqn_rcv[0x18];

  uint8_t dbr_addr[0x40];

  uint8_t reserved_at_540[0x25];
  uint8_t rq_type[0x3];
  uint8_t reserved_at_568[0x11b];
  uint8_t dbr_umem_valid[0x1];

  uint8_t reserved_at_684[0x9c];
  uint8_t dbr_umem_id[0x20];
};

struct mlx5_ifc_create_cq_in_bits {
  uint8_t opcode[0x10];
  uint8_t reserved_at_10[0x70];
  struct mlx5_ifc_cqc_bits cq_context;

  uint8_t cq_umem_offset[0x40];
  uint8_t cq_umem_id[0x20];

  uint8_t cq_umem_valid[0x1];
  uint8_t reserved_at_2e1[0x59f];
};

struct mlx5_ifc_create_cq_out_bits {
  uint8_t status[0x8];
  uint8_t reserved_at_8[0x18];
  uint8_t syndrome[0x20];

  uint8_t reserved_at_40[0x8];
  uint8_t cqn[0x18];

  uint8_t reserved_at_60[0x20];
};

struct mlx5_ifc_create_qp_in_bits {
  uint8_t opcode[0x10];
  uint8_t reserved_at_10[0xb0];
  struct mlx5_ifc_qpc_bits qpc;

  uint8_t wq_umem_offset[0x40];
  uint8_t wq_umem_id[0x20];

  uint8_t wq_umem_valid[0x1];
  uint8_t reserved_at_861[0x1f];
};

struct mlx5_ifc_create_qp_out_bits {
  uint8_t status[0x8];
  uint8_t reserved_at_8[0x18];
  uint8_t syndrome[0x20];

  uint8_t reserved_at_40[0x8];
  uint8_t qpn[0x18];

  uint8_t reserved_at_60[0x20];
};

// RST2INIT, INIT2RTR and RTR2RTS share one shape
#define XIO_MLX5_MODIFY_QP_BITS(name)                                          \
  struct mlx5_ifc_##name##_qp_in_bits {                                        \
    uint8_t opcode[0x10];                                                      \
    uint8_t reserved_at_10[0x38];                                              \
    uint8_t qpn[0x18];                                                         \
    uint8_t reserved_at_60[0x60];                                              \
    struct mlx5_ifc_qpc_bits qpc;                                              \
    uint8_t reserved_at_800[0x80];                                             \
  };                                                                           \
  struct mlx5_ifc_##name##_qp_out_bits {                                       \
    uint8_t status[0x8];                                                       \
    uint8_t reserved_at_8[0x18];                                               \
    uint8_t syndrome[0x20];                                                    \
    uint8_t reserved_at_40[0x40];                                              \
  }

XIO_MLX5_MODIFY_QP_BITS(rst2init);
XIO_MLX5_MODIFY_QP_BITS(init2rtr);
XIO_MLX5_MODIFY_QP_BITS(rtr2rts);

#endif // RDMA_EP_MLX5_DEVX_PRM_H
