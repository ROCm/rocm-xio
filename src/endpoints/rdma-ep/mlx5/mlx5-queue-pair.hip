/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/mlx5/queue_pair_mlx5.cpp, adapted for
 * rocm-xio. MLX5 (Mellanox ConnectX) GPU-side device code: WQE construction via
 * gda_mlx5_wqe constructors, BlueFlame doorbell, alternating CQ polling.
 * Single-endpoint model (no PE parameter).
 */

#include "queue-pair.hpp"

#if defined(GDA_MLX5)

namespace rdma_ep {

static constexpr int MLX5_LOCK_S_SLEEP_DELAY = 2;
static constexpr uint8_t MLX5_WQE_CTRL_CQ_UPDATE = 0x08;

__device__ static inline void mlx5_acquire_lock(uint32_t* lock) {
  while (__hip_atomic_exchange(lock, 1u, __ATOMIC_ACQUIRE,
                               __HIP_MEMORY_SCOPE_AGENT)) {
    __builtin_amdgcn_s_sleep(MLX5_LOCK_S_SLEEP_DELAY);
  }
}

__device__ static inline void mlx5_release_lock(uint32_t* lock) {
  __hip_atomic_store(lock, 0u, __ATOMIC_RELEASE, __HIP_MEMORY_SCOPE_AGENT);
}

__device__ static inline uint16_t mlx5_wqe_idx(const gda_mlx5_device_sq& sq,
                                               uint8_t lane_id) {
  return sq.tail + lane_id;
}

template <typename T>
__device__ static inline bool mlx5_atomic_compare(T* obj, T* expected,
                                                  int order, int scope) {
  T exp = *expected;
  T val = __hip_atomic_load(obj, order, scope);
  *expected = val;
  return val == exp;
}

namespace mlx5 {

__device__ void Ops::ring_doorbell(QueuePair& qp, uint16_t sq_wqebb_counter,
                                   const gda_mlx5_wqe& wqe) {
  gda_mlx5_db_register db_val{wqe};
  __be32 be_counter = endian::to_be<uint32_t>(sq_wqebb_counter);

  gda_mlx5_bf_buffer* bf = qp.mlx5_sq_.swap_bf_buffer();

  __hip_atomic_store(qp.mlx5_sq_.dbrec, be_counter, __ATOMIC_RELEASE,
                     __HIP_MEMORY_SCOPE_SYSTEM);
  __hip_atomic_store(&bf->db_reg, db_val, __ATOMIC_RELEASE,
                     __HIP_MEMORY_SCOPE_SYSTEM);
}

__device__ void Ops::check_cqe_error(QueuePair& qp, const mlx5_cqe64* cqe) {
  const mlx5_err_cqe* err_cqe = reinterpret_cast<const mlx5_err_cqe*>(cqe);

  uint8_t op_own = __hip_atomic_load(const_cast<uint8_t*>(&cqe->op_own),
                                     __ATOMIC_ACQUIRE,
                                     __HIP_MEMORY_SCOPE_SYSTEM);
  uint8_t opcode = op_own >> 4;

  if (opcode == MLX5_CQE_REQ)
    return;

  if (opcode == MLX5_CQE_REQ_ERR) {
    uint8_t syndrome = __hip_atomic_load(const_cast<uint8_t*>(
                                           &err_cqe->syndrome),
                                         __ATOMIC_ACQUIRE,
                                         __HIP_MEMORY_SCOPE_SYSTEM);
    printf("rdma_ep::mlx5: CQ requester error syndrome=0x%x\n", syndrome);
  } else if (opcode == MLX5_CQE_INVALID) {
    printf("rdma_ep::mlx5: CQ invalid completion\n");
  } else {
    printf("rdma_ep::mlx5: CQ unexpected opcode=0x%x\n", opcode);
  }
  abort();
}

__device__ void Ops::poll_cq_until(QueuePair& qp,
                                   uint16_t requested_available_slots) {
  uint16_t sq_depth = qp.mlx5_sq_.depth;

  uint64_t sq_post = __hip_atomic_load(&qp.mlx5_sq_.post, __ATOMIC_ACQUIRE,
                                       __HIP_MEMORY_SCOPE_AGENT);
  if (sq_post <= static_cast<uint64_t>((sq_depth - requested_available_slots)))
    return;

  uint16_t consumed_slots;
  uint16_t available_slots;

  do {
    struct mlx5_cqe64* cqe = &qp.mlx5_cq_.buf[1 - (sq_post % 2)];

    uint32_t wqecnt_sig_op_own = __hip_atomic_load(reinterpret_cast<uint32_t*>(
                                                     &cqe->wqe_counter),
                                                   __ATOMIC_ACQUIRE,
                                                   __HIP_MEMORY_SCOPE_SYSTEM);

    __be16 be_wqe_counter = static_cast<__be16>(wqecnt_sig_op_own);
    uint8_t opcode = static_cast<uint8_t>(wqecnt_sig_op_own >> 28);
    uint16_t sq_head = endian::from_be(be_wqe_counter);

    uint16_t sq_tail = __hip_atomic_load(&qp.mlx5_sq_.tail, __ATOMIC_ACQUIRE,
                                         __HIP_MEMORY_SCOPE_AGENT);

    if (opcode == MLX5_CQE_INVALID) {
      sq_post = __hip_atomic_load(&qp.mlx5_sq_.post, __ATOMIC_ACQUIRE,
                                  __HIP_MEMORY_SCOPE_AGENT);
      continue;
    }

#ifdef DEBUG
    check_cqe_error(qp, cqe);
#endif

    uint16_t posted = sq_tail;
    uint16_t completed = sq_head + 1;
    consumed_slots = posted - completed;
    available_slots = sq_depth - consumed_slots;

  } while (!mlx5_atomic_compare(&qp.mlx5_sq_.post, &sq_post, __ATOMIC_ACQUIRE,
                                __HIP_MEMORY_SCOPE_AGENT) ||
           available_slots < requested_available_slots);
}

__device__ void Ops::quiet(QueuePair& qp) {
  uint64_t qp_lane_mask = qp.get_same_qp_lane_mask();
  if (get_lane_id() == first_lane(qp_lane_mask))
    poll_cq_until(qp, qp.mlx5_sq_.depth);
}

__device__ void Ops::quiet_single(QueuePair& qp) {
  poll_cq_until(qp, qp.mlx5_sq_.depth);
}

__device__ void Ops::post_wqe_rma(QueuePair& qp, int32_t length,
                                  uintptr_t laddr, uintptr_t raddr,
                                  uint8_t opcode) {
  uint64_t qp_lane_mask = qp.get_same_qp_lane_mask();
  int qp_lane_count = popcount64(qp_lane_mask);
  int lane = get_lane_id();
  int qp_lane_id = popcount64(qp_lane_mask & ((1ULL << lane) - 1));

  bool is_leader = (qp_lane_id == qp_lane_count - 1);

  if (is_leader) {
    mlx5_acquire_lock(&qp.mlx5_sq_.lock);
    poll_cq_until(qp, qp_lane_count);
  }

  uint16_t wqe_idx = mlx5_wqe_idx(qp.mlx5_sq_, qp_lane_id);
  uint16_t sq_idx = wqe_idx % qp.mlx5_sq_.depth;

  bool send_inline = gda_mlx5_wqe_rma::can_inline(opcode, length,
                                                  qp.inline_threshold_);

  gda_mlx5_wqe wqe{
    wqe_idx,  opcode, qp.qp_num_, MLX5_WQE_CTRL_CQ_UPDATE,       raddr,
    qp.rkey_, laddr,  qp.lkey_,   static_cast<uint32_t>(length), send_inline};

  qp.mlx5_sq_.buf[sq_idx] = wqe;

  if (is_leader) {
    qp.mlx5_sq_.tail += qp_lane_count;
    qp.mlx5_sq_.post += qp_lane_count;
    ring_doorbell(qp, qp.mlx5_sq_.tail, wqe);
    mlx5_release_lock(&qp.mlx5_sq_.lock);
  }
}

__device__ void Ops::post_wqe_rma_single(QueuePair& qp, int32_t length,
                                         uintptr_t laddr, uintptr_t raddr,
                                         uint8_t opcode, bool ring_db) {
  mlx5_acquire_lock(&qp.mlx5_sq_.lock);
  poll_cq_until(qp, 1);

  uint16_t wqe_idx = qp.mlx5_sq_.tail;
  uint16_t sq_idx = wqe_idx % qp.mlx5_sq_.depth;

  bool send_inline = gda_mlx5_wqe_rma::can_inline(opcode, length,
                                                  qp.inline_threshold_);

  gda_mlx5_wqe wqe{
    wqe_idx,  opcode, qp.qp_num_, MLX5_WQE_CTRL_CQ_UPDATE,       raddr,
    qp.rkey_, laddr,  qp.lkey_,   static_cast<uint32_t>(length), send_inline};

  qp.mlx5_sq_.buf[sq_idx] = wqe;
  qp.mlx5_sq_.tail += 1;
  qp.mlx5_sq_.post += 1;

  if (ring_db)
    ring_doorbell(qp, qp.mlx5_sq_.tail, wqe);

  mlx5_release_lock(&qp.mlx5_sq_.lock);
}

__device__ uint64_t Ops::post_wqe_amo(QueuePair& qp, uintptr_t raddr,
                                      uint8_t opcode, int64_t atomic_data,
                                      int64_t atomic_cmp, bool fetching) {
  uint64_t qp_lane_mask = qp.get_same_qp_lane_mask();
  int qp_lane_count = popcount64(qp_lane_mask);
  int lane = get_lane_id();
  int qp_lane_id = popcount64(qp_lane_mask & ((1ULL << lane) - 1));

  bool is_leader = (qp_lane_id == qp_lane_count - 1);

  if (is_leader) {
    mlx5_acquire_lock(&qp.mlx5_sq_.lock);
    poll_cq_until(qp, qp_lane_count);
  }

  uint64_t* atomic_laddr = qp.nonfetching_atomic_;
  uint32_t atomic_lkey = qp.nonfetching_atomic_lkey_;
  if (fetching) {
    uint32_t atomic_idx = (qp.fetching_atomic_idx_ + qp_lane_id) %
                          QueuePair::FETCHING_ATOMIC_CNT;
    atomic_laddr = &qp.fetching_atomic_[atomic_idx];
    atomic_lkey = qp.fetching_atomic_lkey_;
  }

  uint16_t wqe_idx = mlx5_wqe_idx(qp.mlx5_sq_, qp_lane_id);
  uint16_t sq_idx = wqe_idx % qp.mlx5_sq_.depth;

  gda_mlx5_wqe wqe{wqe_idx,
                   opcode,
                   qp.qp_num_,
                   MLX5_WQE_CTRL_CQ_UPDATE,
                   raddr,
                   qp.rkey_,
                   static_cast<uint64_t>(atomic_data),
                   static_cast<uint64_t>(atomic_cmp),
                   reinterpret_cast<uintptr_t>(atomic_laddr),
                   atomic_lkey};

  qp.mlx5_sq_.buf[sq_idx] = wqe;

  if (is_leader) {
    qp.mlx5_sq_.tail += qp_lane_count;
    qp.mlx5_sq_.post += qp_lane_count;
    if (fetching)
      qp.fetching_atomic_idx_ += qp_lane_count;
    ring_doorbell(qp, qp.mlx5_sq_.tail, wqe);
    mlx5_release_lock(&qp.mlx5_sq_.lock);
  }

  if (fetching)
    quiet(qp);

  return fetching ? *atomic_laddr : 0;
}

__device__ uint64_t Ops::post_wqe_amo_single(QueuePair& qp, uintptr_t raddr,
                                             uint8_t opcode,
                                             int64_t atomic_data,
                                             int64_t atomic_cmp,
                                             bool fetching) {
  mlx5_acquire_lock(&qp.mlx5_sq_.lock);
  poll_cq_until(qp, 1);

  uint64_t* atomic_laddr = qp.nonfetching_atomic_;
  uint32_t atomic_lkey = qp.nonfetching_atomic_lkey_;
  if (fetching) {
    uint32_t atomic_idx = qp.fetching_atomic_idx_ %
                          QueuePair::FETCHING_ATOMIC_CNT;
    atomic_laddr = &qp.fetching_atomic_[atomic_idx];
    atomic_lkey = qp.fetching_atomic_lkey_;
  }

  uint16_t wqe_idx = qp.mlx5_sq_.tail;
  uint16_t sq_idx = wqe_idx % qp.mlx5_sq_.depth;

  gda_mlx5_wqe wqe{wqe_idx,
                   opcode,
                   qp.qp_num_,
                   MLX5_WQE_CTRL_CQ_UPDATE,
                   raddr,
                   qp.rkey_,
                   static_cast<uint64_t>(atomic_data),
                   static_cast<uint64_t>(atomic_cmp),
                   reinterpret_cast<uintptr_t>(atomic_laddr),
                   atomic_lkey};

  qp.mlx5_sq_.buf[sq_idx] = wqe;
  qp.mlx5_sq_.tail += 1;
  qp.mlx5_sq_.post += 1;
  if (fetching)
    qp.fetching_atomic_idx_ += 1;

  ring_doorbell(qp, qp.mlx5_sq_.tail, wqe);
  mlx5_release_lock(&qp.mlx5_sq_.lock);

  if (fetching)
    quiet_single(qp);

  return fetching ? *atomic_laddr : 0;
}

} // namespace mlx5
} // namespace rdma_ep

#endif // defined(GDA_MLX5)
