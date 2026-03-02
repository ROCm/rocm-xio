/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef ROCM_ERNIC_RDMA_H
#define ROCM_ERNIC_RDMA_H

#include "../rdma-ep.h"

/*
 * rocm-ernic (AMD Emulated RDMA NIC) Provider
 *
 * Reference: ../rocm-ernic/driver/rocm_ernic-abi.h
 * Driver headers located at ../rocm-ernic/driver/ relative to rocm-xio root
 */

// rocm-ernic-specific constants from rocm_ernic-abi.h
#define ROCM_ERNIC_MAX_SEND_WR 4096
#define ROCM_ERNIC_MAX_RECV_WR 4096
#define ROCM_ERNIC_MAX_SEND_SGE 4
#define ROCM_ERNIC_MAX_RECV_SGE 4

// rocm-ernic-specific WQE opcodes (from rocm_ernic_wr_opcode enum)
#define ROCM_ERNIC_WR_SEND 0x02
#define ROCM_ERNIC_WR_SEND_WITH_IMM 0x03
#define ROCM_ERNIC_WR_RDMA_WRITE 0x00
#define ROCM_ERNIC_WR_RDMA_WRITE_WITH_IMM 0x01
#define ROCM_ERNIC_WR_RDMA_READ 0x04

// rocm-ernic-specific completion status (from rocm_ernic_wc_status enum)
#define ROCM_ERNIC_WC_SUCCESS 0x00
#define ROCM_ERNIC_WC_LOC_LEN_ERR 0x01
#define ROCM_ERNIC_WC_LOC_QP_OP_ERR 0x02
#define ROCM_ERNIC_WC_LOC_PROT_ERR 0x04
#define ROCM_ERNIC_WC_REM_ACCESS_ERR 0x0C

// rocm-ernic WQE flags (send_flags field in rocm_ernic_sq_wqe_hdr)
// Based on IB verbs send flags, similar to PVRDMA
#define ROCM_ERNIC_SEND_SIGNALED (1 << 0)
#define ROCM_ERNIC_SEND_SOLICITED (1 << 1)
#define ROCM_ERNIC_SEND_INLINE (1 << 2)
#define ROCM_ERNIC_SEND_FENCE (1 << 3)

// Doorbell constants (from rocm_ernic-abi.h)
#define ROCM_ERNIC_UAR_QP_OFFSET 0
#define ROCM_ERNIC_UAR_QP_SEND (1 << 30)
#define ROCM_ERNIC_UAR_QP_RECV (1 << 31)
#define ROCM_ERNIC_UAR_CQ_OFFSET 4
#define ROCM_ERNIC_UAR_CQ_ARM (1 << 30)
#define ROCM_ERNIC_UAR_CQ_POLL (1 << 31)

// Helper function to set rocm-ernic-specific WQE fields
// Similar to PVRDMA: encode QP num in upper 32 bits, flags in lower 32 bits
__host__ __device__ static inline void rocm_ernic_wqe_set_vendor_specific(
  struct rdma_wqe* wqe, uint32_t qp_num, bool signaled, bool fence) {
  uint64_t flags = 0;
  if (signaled)
    flags |= ROCM_ERNIC_SEND_SIGNALED;
  if (fence)
    flags |= ROCM_ERNIC_SEND_FENCE;
  wqe->vendor_specific = (static_cast<uint64_t>(qp_num) << 32) | flags;
}

// Helper function to extract rocm-ernic-specific CQE fields
__host__ __device__ static inline uint32_t rocm_ernic_cqe_get_qpn(
  const struct rdma_cqe* cqe) {
  return cqe->rocm_ernic.qpn;
}

#endif // ROCM_ERNIC_RDMA_H
