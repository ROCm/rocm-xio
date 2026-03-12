/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/ionic/queue_pair_ionic.cpp, adapted for rocm-xio.
 * IONIC (Pensando) GPU-side device code: reserve/commit SQ model,
 * color-bit CQEs, CCQE mode, CQ doorbell ringing.
 * Single-endpoint model (no PE parameter, no Collectivity enum).
 * FreeList replaced with simple index-based fetch buffer management.
 */

#include "queue-pair.hpp"

#if defined(GDA_IONIC)

namespace rdma_ep {

// --- IONIC locking helpers ---

__device__ static inline void ionic_lock_acquire(uint32_t *lock) {
  while (__hip_atomic_exchange(lock, 1u, __ATOMIC_ACQUIRE,
                              __HIP_MEMORY_SCOPE_AGENT) != 0u) {
    __builtin_amdgcn_s_sleep(1);
  }
}

__device__ static inline void ionic_lock_release(uint32_t *lock) {
  __hip_atomic_store(lock, 0u, __ATOMIC_RELEASE, __HIP_MEMORY_SCOPE_AGENT);
}

__device__ static inline bool ionic_lock_try_acquire(uint32_t *lock) {
  return __hip_atomic_exchange(lock, 1u, __ATOMIC_ACQUIRE,
                              __HIP_MEMORY_SCOPE_AGENT) == 0u;
}

namespace ionic {

// --- SQ reserve / commit ---

__device__ uint32_t Ops::reserve_sq(QueuePair &qp, uint64_t activemask,
                                    uint32_t num_wqes) {
  uint32_t my_sq_prod = 0;
  int lane = get_lane_id();
  int first = first_lane(activemask);

  if (lane == first) {
    my_sq_prod = __hip_atomic_fetch_add(&qp.sq_prod_, num_wqes,
                                        __ATOMIC_RELAXED,
                                        __HIP_MEMORY_SCOPE_AGENT);
  }
  my_sq_prod = __shfl(my_sq_prod, first);

  quiet_internal(qp, activemask, my_sq_prod + num_wqes - qp.sq_mask_);
  return my_sq_prod;
}

__device__ uint32_t Ops::reserve_sq_single(QueuePair &qp, uint32_t num_wqes) {
  uint32_t my_sq_prod = __hip_atomic_fetch_add(&qp.sq_prod_, num_wqes,
                                               __ATOMIC_RELAXED,
                                               __HIP_MEMORY_SCOPE_AGENT);
  quiet_internal_ccqe_single(qp, my_sq_prod + num_wqes - qp.sq_mask_);
  return my_sq_prod;
}

__device__ uint32_t Ops::commit_sq(QueuePair &qp, uint64_t activemask,
                                   uint32_t my_sq_prod, uint32_t my_sq_pos,
                                   uint32_t num_wqes) {
  uint32_t dbprod = my_sq_prod + num_wqes;
  int lane = get_lane_id();
  int first = first_lane(activemask);

  ionic_lock_acquire(&qp.sq_lock_);

  if (lane == first && ((qp.sq_dbprod_ - dbprod) & (1u << 31))) {
    qp.sq_dbprod_ = dbprod;
    ring_doorbell(qp, dbprod);
  }

  ionic_lock_release(&qp.sq_lock_);
  return dbprod;
}

__device__ uint32_t Ops::commit_sq_single(QueuePair &qp, uint32_t my_sq_prod,
                                          uint32_t my_sq_pos,
                                          uint32_t num_wqes) {
  uint32_t dbprod = my_sq_prod + num_wqes;

  ionic_lock_acquire(&qp.sq_lock_);

  if ((qp.sq_dbprod_ - dbprod) & (1u << 31)) {
    qp.sq_dbprod_ = dbprod;
    ring_doorbell_single(qp, dbprod);
  }

  ionic_lock_release(&qp.sq_lock_);
  return dbprod;
}

// --- CQ polling ---

__device__ void Ops::poll_wave_cqes(QueuePair &qp, uint64_t activemask) {
  int lane = get_lane_id();
  int my_logical_lane_id =
    popcount64(activemask & ((1ULL << lane) - 1));
  uint32_t my_cq_pos = qp.cq_pos_ + my_logical_lane_id;

  struct ionic_v1_cqe *cqe = &qp.ionic_cq_buf_[my_cq_pos & qp.cq_mask_];

  uint32_t qtf_color_bit = byteswap<uint32_t>(IONIC_V1_CQE_COLOR);
  uint32_t qtf_color_exp = qtf_color_bit;
  if (my_cq_pos & (qp.cq_mask_ + 1))
    qtf_color_exp = 0;

  uint32_t qtf_be = *(volatile uint32_t *)(&cqe->qid_type_flags);
  if ((qtf_be & qtf_color_bit) != qtf_color_exp)
    return;

  uint32_t msn = byteswap<uint32_t>(cqe->send.msg_msn);

  if (!!(qtf_be & byteswap<uint32_t>(IONIC_V1_CQE_ERROR))) {
#ifdef DEBUG
    printf("rdma_ep::ionic: QUIET ERROR\n");
#endif
    abort();
  }

  uint64_t my_lane_mask = 1ull << lane;
  uint64_t lesser_lane_mask = my_lane_mask - 1;
  if (my_lane_mask != (__ballot(true) & activemask & ~lesser_lane_mask))
    return;

  qp.cq_pos_ = my_cq_pos + 1;

  if (((qp.cq_pos_ - qp.cq_dbpos_) & qp.cq_mask_) >= 100) {
    qp.cq_dbpos_ = qp.cq_pos_;
    __atomic_store_n(qp.cq_dbreg_,
                     qp.cq_dbval_ | (qp.cq_mask_ & qp.cq_dbpos_),
                     __ATOMIC_SEQ_CST);
  }

  qp.sq_msn_ = msn;
}

__device__ void
Ops::quiet_internal_ccqe(QueuePair &qp, uint64_t activemask, uint32_t cons) {
  int lane = get_lane_id();
  int first = first_lane(activemask);
  if (lane != first)
    return;

  volatile struct ionic_v1_cqe *cqe = &qp.ionic_cq_buf_[0];
  uint32_t qtf_be = cqe->qid_type_flags;
  uint32_t msn = byteswap<uint32_t>(cqe->send.msg_msn);
  while ((msn - cons) & 0x800000) {
    if (!!(qtf_be & byteswap<uint32_t>(IONIC_V1_CQE_ERROR)))
      break;
    qtf_be = cqe->qid_type_flags;
    msn = byteswap<uint32_t>(cqe->send.msg_msn);
  }

  if (!!(qtf_be & byteswap<uint32_t>(IONIC_V1_CQE_ERROR))) {
#ifdef DEBUG
    printf("rdma_ep::ionic: QUIET ERROR (CCQE)\n");
#endif
    abort();
  }
}

__device__ void
Ops::quiet_internal_ccqe_single(QueuePair &qp, uint32_t cons) {
  volatile struct ionic_v1_cqe *cqe = &qp.ionic_cq_buf_[0];
  uint32_t qtf_be = cqe->qid_type_flags;
  uint32_t msn = byteswap<uint32_t>(cqe->send.msg_msn);
  while ((msn - cons) & 0x800000) {
    if (!!(qtf_be & byteswap<uint32_t>(IONIC_V1_CQE_ERROR)))
      break;
    qtf_be = cqe->qid_type_flags;
    msn = byteswap<uint32_t>(cqe->send.msg_msn);
  }

  if (!!(qtf_be & byteswap<uint32_t>(IONIC_V1_CQE_ERROR))) {
#ifdef DEBUG
    printf("rdma_ep::ionic: QUIET ERROR (CCQE single)\n");
#endif
    abort();
  }
}

__device__ void Ops::quiet_internal(QueuePair &qp, uint64_t activemask,
                                    uint32_t cons) {
  uint32_t greed = 10;

  if (!qp.cq_mask_) {
    quiet_internal_ccqe(qp, activemask, cons);
    return;
  }

  while ((qp.sq_msn_ - cons) & 0x800000) {
    if (!ionic_lock_try_acquire(&qp.cq_lock_))
      continue;

    while ((qp.sq_msn_ - cons) & 0x800000) {
      uint32_t old_sq_msn = qp.sq_msn_;
      poll_wave_cqes(qp, activemask);

      if (!((qp.sq_msn_ - cons) & 0x800000)) {
        if (qp.sq_msn_ == old_sq_msn)
          break;
        if (!greed)
          break;
        --greed;
      }
    }

    ionic_lock_release(&qp.cq_lock_);
    break;
  }
}

// --- Doorbell ---

__device__ void Ops::ring_doorbell(QueuePair &qp, uint32_t pos) {
  uint32_t activemask = __activemask();
  int lane = get_lane_id();
  int my_lane_num =
    popcount64(static_cast<uint64_t>(activemask) & ((1ULL << lane) - 1));
  int lane_count = __popc(activemask);

  for (int i = 0; i < lane_count; ++i) {
    if (my_lane_num == i) {
      __threadfence();
      __atomic_store_n(qp.sq_dbreg_,
                       qp.sq_dbval_ | (qp.sq_mask_ & pos),
                       __ATOMIC_SEQ_CST);
    }
  }
  __threadfence();
}

__device__ void Ops::ring_doorbell_single(QueuePair &qp, uint32_t pos) {
  __threadfence();
  __atomic_store_n(&qp.sq_dbreg_[8 * get_lane_id()],
                   qp.sq_dbval_ | (qp.sq_mask_ & pos), __ATOMIC_SEQ_CST);
}

// --- Quiet ---

__device__ void Ops::quiet(QueuePair &qp) {
  quiet_internal(qp, qp.get_same_qp_lane_mask(), qp.sq_prod_);
}

__device__ void Ops::quiet_single(QueuePair &qp) {
  quiet_internal_ccqe_single(qp, qp.sq_prod_);
}

// --- RMA posting ---

__device__ void Ops::post_wqe_rma(QueuePair &qp, int32_t size, uintptr_t laddr,
                                   uintptr_t raddr, uint8_t opcode) {
  uint64_t activemask = qp.get_same_qp_lane_mask();
  int lane = get_lane_id();
  int my_logical_lane_id =
    popcount64(activemask & ((1ULL << lane) - 1));
  uint32_t num_wqes = popcount64(activemask);

  uint32_t my_sq_prod = reserve_sq(qp, activemask, num_wqes);
  uint32_t my_sq_pos = my_sq_prod + my_logical_lane_id;

  struct ionic_v1_wqe *wqe = &qp.ionic_sq_buf_[my_sq_pos & qp.sq_mask_];
  uint16_t wqe_flags = 0;

  if (!(my_sq_pos & (qp.sq_mask_ + 1)))
    wqe_flags |= byteswap<uint16_t>(IONIC_V1_FLAG_COLOR);

  if (lane == last_lane(activemask))
    wqe_flags |= byteswap<uint16_t>(IONIC_V1_FLAG_SIG);

  if (size && !laddr && opcode == qp.op_rdma_write_)
    size = 1;

  wqe->base.wqe_idx = my_sq_pos;
  wqe->base.op = opcode;
  wqe->base.num_sge_key = size ? 1 : 0;
  wqe->base.imm_data_key = byteswap<uint32_t>(0);

  wqe->common.rdma.remote_va_high = byteswap<uint32_t>(raddr >> 32);
  wqe->common.rdma.remote_va_low = byteswap<uint32_t>(raddr);
  wqe->common.rdma.remote_rkey = byteswap<uint32_t>(qp.rkey_);
  wqe->common.length = byteswap<uint32_t>(size);

  if (size) {
    if (opcode == qp.op_rdma_write_ &&
        size <= static_cast<int32_t>(qp.inline_threshold_)) {
      wqe_flags |= byteswap<uint16_t>(IONIC_V1_FLAG_INL);
      wqe->base.num_sge_key = 0;
      if (!laddr) {
        wqe->common.pld.data[0] = 1;
      } else {
        memcpy(wqe->common.pld.data, reinterpret_cast<const void *>(laddr),
               size);
      }
    } else {
      wqe->common.pld.sgl[0].va = byteswap<uint64_t>(laddr);
      wqe->common.pld.sgl[0].len = byteswap<uint32_t>(size);
      wqe->common.pld.sgl[0].lkey = byteswap<uint32_t>(qp.lkey_);
    }
  }

  __hip_atomic_store(&wqe->base.flags, wqe_flags, __ATOMIC_RELEASE,
                     __HIP_MEMORY_SCOPE_AGENT);

  commit_sq(qp, activemask, my_sq_prod, my_sq_pos, num_wqes);
}

__device__ void Ops::post_wqe_rma_single(QueuePair &qp, int32_t size,
                                          uintptr_t laddr, uintptr_t raddr,
                                          uint8_t opcode, bool ring_db) {
  (void)ring_db;
  uint32_t num_wqes = 1;
  uint32_t my_sq_prod = reserve_sq_single(qp, num_wqes);
  uint32_t my_sq_pos = my_sq_prod;

  struct ionic_v1_wqe *wqe = &qp.ionic_sq_buf_[my_sq_pos & qp.sq_mask_];
  uint16_t wqe_flags = 0;

  if (!(my_sq_pos & (qp.sq_mask_ + 1)))
    wqe_flags |= byteswap<uint16_t>(IONIC_V1_FLAG_COLOR);

  wqe_flags |= byteswap<uint16_t>(IONIC_V1_FLAG_SIG);

  if (size && !laddr && opcode == qp.op_rdma_write_)
    size = 1;

  wqe->base.wqe_idx = my_sq_pos;
  wqe->base.op = opcode;
  wqe->base.num_sge_key = size ? 1 : 0;
  wqe->base.imm_data_key = byteswap<uint32_t>(0);

  wqe->common.rdma.remote_va_high = byteswap<uint32_t>(raddr >> 32);
  wqe->common.rdma.remote_va_low = byteswap<uint32_t>(raddr);
  wqe->common.rdma.remote_rkey = byteswap<uint32_t>(qp.rkey_);
  wqe->common.length = byteswap<uint32_t>(size);

  if (size) {
    if (opcode == qp.op_rdma_write_ &&
        size <= static_cast<int32_t>(qp.inline_threshold_)) {
      wqe_flags |= byteswap<uint16_t>(IONIC_V1_FLAG_INL);
      wqe->base.num_sge_key = 0;
      if (!laddr) {
        wqe->common.pld.data[0] = 1;
      } else {
        memcpy(wqe->common.pld.data, reinterpret_cast<const void *>(laddr),
               size);
      }
    } else {
      wqe->common.pld.sgl[0].va = byteswap<uint64_t>(laddr);
      wqe->common.pld.sgl[0].len = byteswap<uint32_t>(size);
      wqe->common.pld.sgl[0].lkey = byteswap<uint32_t>(qp.lkey_);
    }
  }

  __hip_atomic_store(&wqe->base.flags, wqe_flags, __ATOMIC_RELEASE,
                     __HIP_MEMORY_SCOPE_AGENT);

  commit_sq_single(qp, my_sq_prod, my_sq_pos, num_wqes);
}

// --- AMO posting ---

__device__ uint64_t Ops::post_wqe_amo(QueuePair &qp, uintptr_t raddr,
                                       uint8_t opcode, int64_t atomic_data,
                                       int64_t atomic_cmp, bool fetching) {
  uint64_t activemask = qp.get_same_qp_lane_mask();
  int lane = get_lane_id();
  int my_logical_lane_id =
    popcount64(activemask & ((1ULL << lane) - 1));
  uint32_t num_wqes = popcount64(activemask);
  int first = first_lane(activemask);

  uint32_t my_sq_prod = reserve_sq(qp, activemask, num_wqes);
  uint32_t my_sq_pos = my_sq_prod + my_logical_lane_id;

  struct ionic_v1_wqe *wqe = &qp.ionic_sq_buf_[my_sq_pos & qp.sq_mask_];
  uint16_t wqe_flags = 0;

  uint64_t *fetch_buf = nullptr;
  if (fetching) {
    if (lane == first) {
      uint32_t idx = qp.fetching_atomic_idx_;
      qp.fetching_atomic_idx_ += num_wqes;
      fetch_buf = &qp.fetching_atomic_[idx % QueuePair::FETCHING_ATOMIC_CNT];
    }
    fetch_buf =
      (uint64_t *)__shfl((uint64_t)fetch_buf, first);
  }

  if (!(my_sq_pos & (qp.sq_mask_ + 1)))
    wqe_flags |= byteswap<uint16_t>(IONIC_V1_FLAG_COLOR);

  if (lane == last_lane(activemask))
    wqe_flags |= byteswap<uint16_t>(IONIC_V1_FLAG_SIG);

  wqe->base.wqe_idx = my_sq_pos;
  wqe->base.op = opcode;
  wqe->base.num_sge_key = 1;
  wqe->base.imm_data_key = byteswap<uint32_t>(0);

  wqe->atomic_v2.remote_va_high = byteswap<uint32_t>(raddr >> 32);
  wqe->atomic_v2.remote_va_low = byteswap<uint32_t>(raddr);
  wqe->atomic_v2.remote_rkey = byteswap<uint32_t>(qp.rkey_);
  wqe->atomic_v2.swap_add_high = byteswap<uint32_t>(atomic_data >> 32);
  wqe->atomic_v2.swap_add_low = byteswap<uint32_t>(atomic_data);
  wqe->atomic_v2.compare_high = byteswap<uint32_t>(atomic_cmp >> 32);
  wqe->atomic_v2.compare_low = byteswap<uint32_t>(atomic_cmp);

  if (fetching) {
    wqe->atomic_v2.local_va = byteswap<uint64_t>(
      reinterpret_cast<uint64_t>(fetch_buf + my_logical_lane_id));
    wqe->atomic_v2.lkey = byteswap<uint32_t>(qp.fetching_atomic_lkey_);
  } else {
    wqe->atomic_v2.local_va =
      byteswap<uint64_t>(reinterpret_cast<uint64_t>(qp.nonfetching_atomic_));
    wqe->atomic_v2.lkey = byteswap<uint32_t>(qp.nonfetching_atomic_lkey_);
  }

  __hip_atomic_store(&wqe->base.flags, wqe_flags, __ATOMIC_RELEASE,
                     __HIP_MEMORY_SCOPE_AGENT);

  uint32_t cons =
    commit_sq(qp, activemask, my_sq_prod, my_sq_pos, num_wqes);

  uint64_t ret = 0;
  if (fetching) {
    quiet_internal(qp, activemask, cons);
    ret = fetch_buf[my_logical_lane_id];
    __atomic_signal_fence(__ATOMIC_SEQ_CST);
  }
  return ret;
}

__device__ uint64_t Ops::post_wqe_amo_single(QueuePair &qp, uintptr_t raddr,
                                              uint8_t opcode,
                                              int64_t atomic_data,
                                              int64_t atomic_cmp,
                                              bool fetching) {
  uint32_t num_wqes = 1;
  uint32_t my_sq_prod = reserve_sq_single(qp, num_wqes);
  uint32_t my_sq_pos = my_sq_prod;

  struct ionic_v1_wqe *wqe = &qp.ionic_sq_buf_[my_sq_pos & qp.sq_mask_];
  uint16_t wqe_flags = 0;

  uint64_t *fetch_buf = nullptr;
  if (fetching) {
    uint32_t idx = qp.fetching_atomic_idx_++ % QueuePair::FETCHING_ATOMIC_CNT;
    fetch_buf = &qp.fetching_atomic_[idx];
  }

  if (!(my_sq_pos & (qp.sq_mask_ + 1)))
    wqe_flags |= byteswap<uint16_t>(IONIC_V1_FLAG_COLOR);

  wqe_flags |= byteswap<uint16_t>(IONIC_V1_FLAG_SIG);

  wqe->base.wqe_idx = my_sq_pos;
  wqe->base.op = opcode;
  wqe->base.num_sge_key = 1;
  wqe->base.imm_data_key = byteswap<uint32_t>(0);

  wqe->atomic_v2.remote_va_high = byteswap<uint32_t>(raddr >> 32);
  wqe->atomic_v2.remote_va_low = byteswap<uint32_t>(raddr);
  wqe->atomic_v2.remote_rkey = byteswap<uint32_t>(qp.rkey_);
  wqe->atomic_v2.swap_add_high = byteswap<uint32_t>(atomic_data >> 32);
  wqe->atomic_v2.swap_add_low = byteswap<uint32_t>(atomic_data);
  wqe->atomic_v2.compare_high = byteswap<uint32_t>(atomic_cmp >> 32);
  wqe->atomic_v2.compare_low = byteswap<uint32_t>(atomic_cmp);

  if (fetching) {
    wqe->atomic_v2.local_va =
      byteswap<uint64_t>(reinterpret_cast<uint64_t>(fetch_buf));
    wqe->atomic_v2.lkey = byteswap<uint32_t>(qp.fetching_atomic_lkey_);
  } else {
    wqe->atomic_v2.local_va =
      byteswap<uint64_t>(reinterpret_cast<uint64_t>(qp.nonfetching_atomic_));
    wqe->atomic_v2.lkey = byteswap<uint32_t>(qp.nonfetching_atomic_lkey_);
  }

  __hip_atomic_store(&wqe->base.flags, wqe_flags, __ATOMIC_RELEASE,
                     __HIP_MEMORY_SCOPE_AGENT);

  uint32_t cons =
    commit_sq_single(qp, my_sq_prod, my_sq_pos, num_wqes);

  uint64_t ret = 0;
  if (fetching) {
    quiet_internal_ccqe_single(qp, cons);
    ret = fetch_buf[0];
    __atomic_signal_fence(__ATOMIC_SEQ_CST);
  }
  return ret;
}

} // namespace ionic
} // namespace rdma_ep

#endif // defined(GDA_IONIC)
