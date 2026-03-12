/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/queue_pair.cpp, adapted for rocm-xio.
 * Simplified for single-endpoint model. Vendor-specific WQE posting,
 * doorbell ringing, and CQ polling are dispatched through the provider
 * field. Each vendor implementation is in its own subdirectory.
 */

#include "queue-pair.hpp"

#include <hip/hip_runtime.h>

#include "ibv-wrapper.hpp"

#if defined(GDA_BNXT)
#include "bnxt/bnxt-queue-pair.hip"
#endif

#if defined(GDA_MLX5)
#include "mlx5/mlx5-queue-pair.hip"
#endif

#if defined(GDA_IONIC)
#include "ionic/ionic-queue-pair.hip"
#endif

namespace rdma_ep {

#ifndef __HIP_DEVICE_COMPILE__

QueuePair::QueuePair(struct ibv_pd *pd, Provider provider)
  : provider_(provider) {
  int access = IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE |
               IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_ATOMIC;

  (void)hipMalloc(&nonfetching_atomic_, 8);
  (void)hipMalloc(&fetching_atomic_, 8 * FETCHING_ATOMIC_CNT);
  (void)hipMemset(nonfetching_atomic_, 0, 8);
  (void)hipMemset(fetching_atomic_, 0, 8 * FETCHING_ATOMIC_CNT);

  mr_nonfetching_atomic_ = ibv.reg_mr(pd, nonfetching_atomic_, 8, access);
  mr_fetching_atomic_ =
    ibv.reg_mr(pd, fetching_atomic_, 8 * FETCHING_ATOMIC_CNT, access);

  switch (provider) {
#if defined(GDA_BNXT)
  case Provider::BNXT:
    op_rdma_write_ = BNXT_RE_WR_OPCD_RDMA_WRITE;
    op_rdma_read_ = BNXT_RE_WR_OPCD_RDMA_READ;
    op_atomic_fa_ = BNXT_RE_WR_OPCD_ATOMIC_FA;
    op_atomic_cs_ = BNXT_RE_WR_OPCD_ATOMIC_CS;
    nonfetching_atomic_lkey_ = mr_nonfetching_atomic_->lkey;
    fetching_atomic_lkey_ = mr_fetching_atomic_->lkey;
    break;
#endif
#if defined(GDA_MLX5)
  case Provider::MLX5:
    // MLX5 uses big-endian keys; will be set in mlx5_initialize_gpu_qp
    op_rdma_write_ = 0x08; // MLX5_OPCODE_RDMA_WRITE
    op_rdma_read_ = 0x10;  // MLX5_OPCODE_RDMA_READ
    op_atomic_fa_ = 0x13;  // MLX5_OPCODE_ATOMIC_FA
    op_atomic_cs_ = 0x12;  // MLX5_OPCODE_ATOMIC_CS
    nonfetching_atomic_lkey_ = htobe32(mr_nonfetching_atomic_->lkey);
    fetching_atomic_lkey_ = htobe32(mr_fetching_atomic_->lkey);
    break;
#endif
#if defined(GDA_IONIC)
  case Provider::IONIC:
    op_rdma_write_ = 0x00; // IONIC_V2_OP_RDMA_WRITE
    op_rdma_read_ = 0x01;  // IONIC_V2_OP_RDMA_READ
    op_atomic_fa_ = 0x03;  // IONIC_V2_OP_ATOMIC_FA
    op_atomic_cs_ = 0x04;  // IONIC_V2_OP_ATOMIC_CS
    nonfetching_atomic_lkey_ = mr_nonfetching_atomic_->lkey;
    fetching_atomic_lkey_ = mr_fetching_atomic_->lkey;
    break;
#endif
  default:
    break;
  }
}

QueuePair::~QueuePair() {
  if (mr_nonfetching_atomic_)
    ibv.dereg_mr(mr_nonfetching_atomic_);
  if (mr_fetching_atomic_)
    ibv.dereg_mr(mr_fetching_atomic_);
  if (nonfetching_atomic_)
    (void)hipFree(nonfetching_atomic_);
  if (fetching_atomic_)
    (void)hipFree(fetching_atomic_);
}

#endif // !__HIP_DEVICE_COMPILE__

// --- Wave-level helper ---

__device__ uint64_t QueuePair::get_same_qp_lane_mask() {
  uint64_t active = get_active_lane_mask();
  uintptr_t this_qp = reinterpret_cast<uintptr_t>(this);
  return __match_any_sync(active, this_qp);
}

// --- Public device API ---

__device__ void QueuePair::put_nbi(void *dest, const void *source,
                                   size_t nelems) {
  uintptr_t src = reinterpret_cast<uintptr_t>(source);
  uintptr_t dst = reinterpret_cast<uintptr_t>(dest);
  post_wqe_rma(nelems, src, dst, op_rdma_write_);
}

__device__ void QueuePair::put_nbi_single(void *dest, const void *source,
                                          size_t nelems, bool ring_db) {
  uintptr_t src = reinterpret_cast<uintptr_t>(source);
  uintptr_t dst = reinterpret_cast<uintptr_t>(dest);
  post_wqe_rma_single(nelems, src, dst, op_rdma_write_, ring_db);
}

__device__ void QueuePair::get_nbi(void *dest, const void *source,
                                   size_t nelems) {
  uintptr_t src = reinterpret_cast<uintptr_t>(source);
  uintptr_t dst = reinterpret_cast<uintptr_t>(dest);
  post_wqe_rma(nelems, dst, src, op_rdma_read_);
}

__device__ void QueuePair::get_nbi_single(void *dest, const void *source,
                                          size_t nelems, bool ring_db) {
  uintptr_t src = reinterpret_cast<uintptr_t>(source);
  uintptr_t dst = reinterpret_cast<uintptr_t>(dest);
  post_wqe_rma_single(nelems, dst, src, op_rdma_read_, ring_db);
}

__device__ int64_t QueuePair::atomic_cas(void *dest, int64_t data,
                                         int64_t cmp) {
  uintptr_t dst = reinterpret_cast<uintptr_t>(dest);
  return post_wqe_amo(sizeof(int64_t), dst, op_atomic_cs_, data, cmp, true);
}

__device__ int64_t QueuePair::atomic_fetch(void *dest, int64_t value,
                                           int64_t cond) {
  uintptr_t dst = reinterpret_cast<uintptr_t>(dest);
  return post_wqe_amo(sizeof(int64_t), dst, op_atomic_fa_, value, cond, true);
}

__device__ void QueuePair::atomic_nofetch(void *dest, int64_t value,
                                          int64_t cond) {
  uintptr_t dst = reinterpret_cast<uintptr_t>(dest);
  post_wqe_amo(sizeof(int64_t), dst, op_atomic_fa_, value, cond, false);
}

// --- Vendor dispatch: RMA ---

// --- Vendor dispatch via rdma_ep::<vendor>::Ops ---

__device__ void QueuePair::post_wqe_rma(int32_t size, uintptr_t laddr,
                                         uintptr_t raddr, uint8_t opcode) {
#if defined(GDA_BNXT)
  if (provider_ == Provider::BNXT) { bnxt::Ops::post_wqe_rma(*this, size, laddr, raddr, opcode); return; }
#endif
#if defined(GDA_MLX5)
  if (provider_ == Provider::MLX5) { mlx5::Ops::post_wqe_rma(*this, size, laddr, raddr, opcode); return; }
#endif
#if defined(GDA_IONIC)
  if (provider_ == Provider::IONIC) { ionic::Ops::post_wqe_rma(*this, size, laddr, raddr, opcode); return; }
#endif
}

__device__ void QueuePair::post_wqe_rma_single(int32_t size, uintptr_t laddr,
                                                uintptr_t raddr,
                                                uint8_t opcode, bool ring_db) {
#if defined(GDA_BNXT)
  if (provider_ == Provider::BNXT) { bnxt::Ops::post_wqe_rma_single(*this, size, laddr, raddr, opcode, ring_db); return; }
#endif
#if defined(GDA_MLX5)
  if (provider_ == Provider::MLX5) { mlx5::Ops::post_wqe_rma_single(*this, size, laddr, raddr, opcode, ring_db); return; }
#endif
#if defined(GDA_IONIC)
  if (provider_ == Provider::IONIC) { ionic::Ops::post_wqe_rma_single(*this, size, laddr, raddr, opcode, ring_db); return; }
#endif
}

__device__ uint64_t QueuePair::post_wqe_amo(int32_t size, uintptr_t raddr,
                                             uint8_t opcode,
                                             int64_t atomic_data,
                                             int64_t atomic_cmp,
                                             bool fetching) {
  (void)size;
#if defined(GDA_BNXT)
  if (provider_ == Provider::BNXT) return bnxt::Ops::post_wqe_amo(*this, raddr, opcode, atomic_data, atomic_cmp, fetching);
#endif
#if defined(GDA_MLX5)
  if (provider_ == Provider::MLX5) return mlx5::Ops::post_wqe_amo(*this, raddr, opcode, atomic_data, atomic_cmp, fetching);
#endif
#if defined(GDA_IONIC)
  if (provider_ == Provider::IONIC) return ionic::Ops::post_wqe_amo(*this, raddr, opcode, atomic_data, atomic_cmp, fetching);
#endif
  return 0;
}

__device__ void QueuePair::quiet() {
#if defined(GDA_BNXT)
  if (provider_ == Provider::BNXT) { bnxt::Ops::quiet(*this); return; }
#endif
#if defined(GDA_MLX5)
  if (provider_ == Provider::MLX5) { mlx5::Ops::quiet(*this); return; }
#endif
#if defined(GDA_IONIC)
  if (provider_ == Provider::IONIC) { ionic::Ops::quiet(*this); return; }
#endif
}

__device__ void QueuePair::quiet_single() {
#if defined(GDA_BNXT)
  if (provider_ == Provider::BNXT) { bnxt::Ops::quiet_single(*this); return; }
#endif
#if defined(GDA_MLX5)
  if (provider_ == Provider::MLX5) { mlx5::Ops::quiet_single(*this); return; }
#endif
#if defined(GDA_IONIC)
  if (provider_ == Provider::IONIC) { ionic::Ops::quiet_single(*this); return; }
#endif
}

} // namespace rdma_ep
