/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

/**
 * @file mlx5-devx-prm.h
 * @brief Subset of the mlx5 device command layouts used to create a QP and CQ
 * through DevX.
 *
 * The bit layouts of the ads, cqc, qpc and the create/modify commands below
 * follow the Linux kernel's include/linux/mlx5/mlx5_ifc.h (dual licensed
 * GPL-2.0 or the OpenIB.org BSD license; the BSD terms: redistribution and use
 * in source and binary forms, with or without modification, are permitted
 * provided the copyright notice, this list of conditions and the disclaimer are
 * retained). They are written as `struct mlx5_ifc_<name>_bits` with one byte
 * per bit, the form libibverbs' DEVX_SET/DEVX_GET macros (infiniband/mlx5dv.h)
 * expect.
 *
 * Where the kernel header leaves a hole marked "reserved" that the device
 * defines for user-memory (umem) queues, the field is named here:
 * cqc.dbr_umem_id, create_cq_in.cq_umem_offset/cq_umem_id,
 * create_qp_in.wq_umem_offset/wq_umem_id and qpc.dbr_umem_id. The positions
 * were checked against the sizes of the kernel's reserved gaps (0x20, 0x60,
 * 0x60 and the last 0x20 bits of the 0x740-bit qpc).
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
  XIO_MLX5_QPC_MTU_256 = 0x1,
  XIO_MLX5_QPC_MTU_512 = 0x2,
  XIO_MLX5_QPC_MTU_1K = 0x3,
  XIO_MLX5_QPC_MTU_2K = 0x4,
  XIO_MLX5_QPC_MTU_4K = 0x5,
};

struct mlx5_ifc_ads_bits {
  uint8_t fl[0x1];
  uint8_t free_ar[0x1];
  uint8_t reserved_at_2[0xe];
  uint8_t pkey_index[0x10];

  uint8_t reserved_at_20[0x8];
  uint8_t grh[0x1];
  uint8_t mlid[0x7];
  uint8_t rlid[0x10];

  uint8_t ack_timeout[0x5];
  uint8_t reserved_at_45[0x3];
  uint8_t src_addr_index[0x8];
  uint8_t reserved_at_50[0x4];
  uint8_t stat_rate[0x4];
  uint8_t hop_limit[0x8];

  uint8_t reserved_at_60[0x4];
  uint8_t tclass[0x8];
  uint8_t flow_label[0x14];

  uint8_t rgid_rip[16][0x8];

  uint8_t reserved_at_100[0x4];
  uint8_t f_dscp[0x1];
  uint8_t f_ecn[0x1];
  uint8_t reserved_at_106[0x1];
  uint8_t f_eth_prio[0x1];
  uint8_t ecn[0x2];
  uint8_t dscp[0x6];
  uint8_t udp_sport[0x10];

  uint8_t dei_cfi[0x1];
  uint8_t eth_prio[0x3];
  uint8_t sl[0x4];
  uint8_t vhca_port_num[0x8];
  uint8_t rmac_47_32[0x10];

  uint8_t rmac_31_0[0x20];
};

struct mlx5_ifc_cqc_bits {
  uint8_t status[0x4];
  uint8_t reserved_at_4[0x2];
  uint8_t dbr_umem_valid[0x1];
  uint8_t apu_cq[0x1];
  uint8_t cqe_sz[0x3];
  uint8_t cc[0x1];
  uint8_t reserved_at_c[0x1];
  uint8_t scqe_break_moderation_en[0x1];
  uint8_t oi[0x1];
  uint8_t cq_period_mode[0x2];
  uint8_t cqe_comp_en[0x1];
  uint8_t mini_cqe_res_format[0x2];
  uint8_t st[0x4];
  uint8_t reserved_at_18[0x6];
  uint8_t cqe_compression_layout[0x2];

  uint8_t dbr_umem_id[0x20];

  uint8_t reserved_at_40[0x14];
  uint8_t page_offset[0x6];
  uint8_t reserved_at_5a[0x6];

  uint8_t reserved_at_60[0x3];
  uint8_t log_cq_size[0x5];
  uint8_t uar_page[0x18];

  uint8_t reserved_at_80[0x4];
  uint8_t cq_period[0xc];
  uint8_t cq_max_count[0x10];

  uint8_t c_eqn_or_apu_element[0x20];

  uint8_t reserved_at_c0[0x3];
  uint8_t log_page_size[0x5];
  uint8_t reserved_at_c8[0x18];

  uint8_t reserved_at_e0[0x20];

  uint8_t reserved_at_100[0x8];
  uint8_t last_notified_index[0x18];

  uint8_t reserved_at_120[0x8];
  uint8_t last_solicit_index[0x18];

  uint8_t reserved_at_140[0x8];
  uint8_t consumer_counter[0x18];

  uint8_t reserved_at_160[0x8];
  uint8_t producer_counter[0x18];

  uint8_t reserved_at_180[0x40];

  uint8_t dbr_addr[0x40];
};

struct mlx5_ifc_qpc_bits {
  uint8_t state[0x4];
  uint8_t lag_tx_port_affinity[0x4];
  uint8_t st[0x8];
  uint8_t reserved_at_10[0x2];
  uint8_t isolate_vl_tc[0x1];
  uint8_t pm_state[0x2];
  uint8_t reserved_at_15[0x1];
  uint8_t req_e2e_credit_mode[0x2];
  uint8_t offload_type[0x4];
  uint8_t end_padding_mode[0x2];
  uint8_t reserved_at_1e[0x2];

  uint8_t wq_signature[0x1];
  uint8_t block_lb_mc[0x1];
  uint8_t atomic_like_write_en[0x1];
  uint8_t latency_sensitive[0x1];
  uint8_t reserved_at_24[0x1];
  uint8_t drain_sigerr[0x1];
  uint8_t reserved_at_26[0x2];
  uint8_t pd[0x18];

  uint8_t mtu[0x3];
  uint8_t log_msg_max[0x5];
  uint8_t reserved_at_48[0x1];
  uint8_t log_rq_size[0x4];
  uint8_t log_rq_stride[0x3];
  uint8_t no_sq[0x1];
  uint8_t log_sq_size[0x4];
  uint8_t reserved_at_55[0x1];
  uint8_t retry_mode[0x2];
  uint8_t ts_format[0x2];
  uint8_t reserved_at_5a[0x1];
  uint8_t rlky[0x1];
  uint8_t ulp_stateless_offload_mode[0x4];

  uint8_t counter_set_id[0x8];
  uint8_t uar_page[0x18];

  uint8_t reserved_at_80[0x8];
  uint8_t user_index[0x18];

  uint8_t reserved_at_a0[0x3];
  uint8_t log_page_size[0x5];
  uint8_t remote_qpn[0x18];

  struct mlx5_ifc_ads_bits primary_address_path;

  struct mlx5_ifc_ads_bits secondary_address_path;

  uint8_t log_ack_req_freq[0x4];
  uint8_t reserved_at_384[0x4];
  uint8_t log_sra_max[0x3];
  uint8_t reserved_at_38b[0x2];
  uint8_t retry_count[0x3];
  uint8_t rnr_retry[0x3];
  uint8_t reserved_at_393[0x1];
  uint8_t fre[0x1];
  uint8_t cur_rnr_retry[0x3];
  uint8_t cur_retry_count[0x3];
  uint8_t reserved_at_39b[0x5];

  uint8_t reserved_at_3a0[0x20];

  uint8_t reserved_at_3c0[0x8];
  uint8_t next_send_psn[0x18];

  uint8_t reserved_at_3e0[0x8];
  uint8_t cqn_snd[0x18];

  uint8_t reserved_at_400[0x8];
  uint8_t deth_sqpn[0x18];

  uint8_t reserved_at_420[0x20];

  uint8_t reserved_at_440[0x8];
  uint8_t last_acked_psn[0x18];

  uint8_t reserved_at_460[0x8];
  uint8_t ssn[0x18];

  uint8_t reserved_at_480[0x8];
  uint8_t log_rra_max[0x3];
  uint8_t reserved_at_48b[0x1];
  uint8_t atomic_mode[0x4];
  uint8_t rre[0x1];
  uint8_t rwe[0x1];
  uint8_t rae[0x1];
  uint8_t reserved_at_493[0x1];
  uint8_t page_offset[0x6];
  uint8_t reserved_at_49a[0x3];
  uint8_t cd_slave_receive[0x1];
  uint8_t cd_slave_send[0x1];
  uint8_t cd_master[0x1];

  uint8_t reserved_at_4a0[0x3];
  uint8_t min_rnr_nak[0x5];
  uint8_t next_rcv_psn[0x18];

  uint8_t reserved_at_4c0[0x8];
  uint8_t xrcd[0x18];

  uint8_t reserved_at_4e0[0x8];
  uint8_t cqn_rcv[0x18];

  uint8_t dbr_addr[0x40];

  uint8_t q_key[0x20];

  uint8_t reserved_at_560[0x5];
  uint8_t rq_type[0x3];
  uint8_t srqn_rmpn_xrqn[0x18];

  uint8_t reserved_at_580[0x8];
  uint8_t rmsn[0x18];

  uint8_t hw_sq_wqebb_counter[0x10];
  uint8_t sw_sq_wqebb_counter[0x10];

  uint8_t hw_rq_counter[0x20];

  uint8_t sw_rq_counter[0x20];

  uint8_t reserved_at_600[0x20];

  uint8_t reserved_at_620[0xf];
  uint8_t cgs[0x1];
  uint8_t cs_req[0x8];
  uint8_t cs_res[0x8];

  uint8_t dc_access_key[0x40];

  uint8_t reserved_at_680[0x3];
  uint8_t dbr_umem_valid[0x1];

  uint8_t reserved_at_684[0x9c];
  uint8_t dbr_umem_id[0x20];
};

struct mlx5_ifc_create_cq_in_bits {
  uint8_t opcode[0x10];
  uint8_t uid[0x10];

  uint8_t reserved_at_20[0x10];
  uint8_t op_mod[0x10];

  uint8_t reserved_at_40[0x40];

  struct mlx5_ifc_cqc_bits cq_context;

  uint8_t cq_umem_offset[0x40];
  uint8_t cq_umem_id[0x20];

  uint8_t cq_umem_valid[0x1];
  uint8_t reserved_at_2e1[0x59f];

  uint8_t pas[0][0x40];
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
  uint8_t uid[0x10];

  uint8_t reserved_at_20[0x10];
  uint8_t op_mod[0x10];

  uint8_t qpc_ext[0x1];
  uint8_t reserved_at_41[0x7];
  uint8_t input_qpn[0x18];

  uint8_t reserved_at_60[0x20];
  uint8_t opt_param_mask[0x20];

  uint8_t ece[0x20];

  struct mlx5_ifc_qpc_bits qpc;

  uint8_t wq_umem_offset[0x40];
  uint8_t wq_umem_id[0x20];

  uint8_t wq_umem_valid[0x1];
  uint8_t reserved_at_861[0x1f];

  uint8_t pas[0][0x40];
};

struct mlx5_ifc_create_qp_out_bits {
  uint8_t status[0x8];
  uint8_t reserved_at_8[0x18];

  uint8_t syndrome[0x20];

  uint8_t reserved_at_40[0x8];
  uint8_t qpn[0x18];

  uint8_t ece[0x20];
};

// RST2INIT, INIT2RTR and RTR2RTS share one shape
#define XIO_MLX5_MODIFY_QP_BITS(name)                                          \
  struct mlx5_ifc_##name##_qp_in_bits {                                        \
    uint8_t opcode[0x10];                                                      \
    uint8_t uid[0x10];                                                         \
    uint8_t reserved_at_20[0x10];                                              \
    uint8_t op_mod[0x10];                                                      \
    uint8_t reserved_at_40[0x8];                                               \
    uint8_t qpn[0x18];                                                         \
    uint8_t reserved_at_60[0x20];                                              \
    uint8_t opt_param_mask[0x20];                                              \
    uint8_t ece[0x20];                                                         \
    struct mlx5_ifc_qpc_bits qpc;                                              \
    uint8_t reserved_at_800[0x80];                                             \
  };                                                                           \
  struct mlx5_ifc_##name##_qp_out_bits {                                       \
    uint8_t status[0x8];                                                       \
    uint8_t reserved_at_8[0x18];                                               \
    uint8_t syndrome[0x20];                                                    \
    uint8_t reserved_at_40[0x20];                                              \
    uint8_t ece[0x20];                                                         \
  }

XIO_MLX5_MODIFY_QP_BITS(rst2init);
XIO_MLX5_MODIFY_QP_BITS(init2rtr);
XIO_MLX5_MODIFY_QP_BITS(rtr2rts);

#endif // RDMA_EP_MLX5_DEVX_PRM_H
