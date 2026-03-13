/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * ROCm ERNIC GPU-side device code for rdma-ep.
 * Implements WQE posting, doorbell ringing, and
 * CQ polling for the rocm_ernic provider.
 *
 * The ERNIC WQE format uses rocm_ernic_sq_wqe_hdr
 * + rocm_ernic_sge, and CQEs use rocm_ernic_cqe
 * (both 64-byte aligned).
 *
 * UAR doorbells are at BAR2 offsets:
 *   QP: ROCM_ERNIC_UAR_QP_OFFSET (0x00)
 *   CQ: ROCM_ERNIC_UAR_CQ_OFFSET (0x04)
 */

#include "queue-pair.hpp"

#if defined(GDA_ERNIC)

namespace rdma_ep {

/* WQE opcode mapping for ERNIC PVRDMA-style ops */
constexpr uint32_t ERNIC_WR_RDMA_WRITE = 0;
constexpr uint32_t ERNIC_WR_RDMA_READ  = 4;
constexpr uint32_t ERNIC_WR_ATOMIC_CS  = 5;
constexpr uint32_t ERNIC_WR_ATOMIC_FA  = 6;

/* Send flags */
constexpr uint32_t ERNIC_SEND_SIGNALED = (1 << 1);
constexpr uint32_t ERNIC_SEND_INLINE   = (1 << 3);

/* UAR doorbell bits */
constexpr uint32_t ERNIC_UAR_QP_SEND   = (1u << 30);

/* WQE header: matches rocm_ernic_sq_wqe_hdr */
struct ernic_wqe_hdr {
  uint64_t wr_id;
  uint32_t num_sge;
  uint32_t total_len;
  uint32_t opcode;
  uint32_t send_flags;
  union {
    uint32_t imm_data;
    uint32_t invalidate_rkey;
  } ex;
  uint32_t reserved;
  union {
    struct {
      uint64_t remote_addr;
      uint32_t rkey;
      uint8_t  pad[4];
    } rdma;
    struct {
      uint64_t remote_addr;
      uint64_t compare_add;
      uint64_t swap;
      uint32_t rkey;
      uint32_t pad;
    } atomic;
  } wr;
};

/* SGE: matches rocm_ernic_sge */
struct ernic_sge {
  uint64_t addr;
  uint32_t length;
  uint32_t lkey;
};

/* CQE: matches rocm_ernic_cqe (64 bytes) */
struct ernic_cqe {
  uint64_t wr_id;
  uint64_t qp;
  uint32_t opcode;
  uint32_t status;
  uint32_t byte_len;
  uint32_t imm_data;
  uint32_t src_qp;
  uint32_t wc_flags;
  uint32_t vendor_err;
  uint16_t pkey_index;
  uint16_t slid;
  uint8_t  sl;
  uint8_t  dlid_path_bits;
  uint8_t  port_num;
  uint8_t  smac[6];
  uint8_t  network_hdr_type;
  uint8_t  pad[6];
};

__device__ static inline void *
ernic_get_sq_wqe(ernic_device_sq *sq,
                 uint32_t idx) {
  return (void *)((char *)sq->buf +
      (idx * sq->wqe_size));
}

namespace ernic {

__device__ void Ops::ring_doorbell(
    QueuePair &qp, uint32_t slot_idx) {
  if (!qp.ernic_sq_.uar_ptr)
    return;
  uint32_t val =
      (qp.ernic_sq_.qpn & 0x00FFFFFF) |
      ERNIC_UAR_QP_SEND;
  __threadfence_system();
  volatile uint32_t *db =
      qp.ernic_sq_.uar_ptr +
      (qp.ernic_sq_.uar_qp_offset / 4);
  __hip_atomic_store(
      const_cast<uint32_t *>(db), val,
      __ATOMIC_SEQ_CST,
      __HIP_MEMORY_SCOPE_SYSTEM);
}

__device__ void Ops::poll_cq_until(
    QueuePair &qp, uint32_t requested) {
  uint32_t sq_depth = qp.ernic_sq_.depth;
  do {
    auto *cqe = (struct ernic_cqe *)
        qp.ernic_cq_.buf;
    (void)cqe;
    uint32_t sq_head =
        qp.ernic_sq_.head;
    uint32_t sq_tail =
        __hip_atomic_load(
            &qp.ernic_sq_.tail,
            __ATOMIC_SEQ_CST,
            __HIP_MEMORY_SCOPE_AGENT);
    uint32_t consumed =
        (sq_tail - sq_head + sq_depth) %
        sq_depth;
    uint32_t available = sq_depth - consumed;
    if (available >= requested)
      return;
  } while (true);
}

__device__ void Ops::quiet(QueuePair &qp) {
  uint64_t mask = qp.get_same_qp_lane_mask();
  if (get_lane_id() == first_lane(mask))
    poll_cq_until(qp, qp.ernic_sq_.depth);
}

__device__ void Ops::quiet_single(
    QueuePair &qp) {
  poll_cq_until(qp, qp.ernic_sq_.depth);
}

__device__ void Ops::write_rma_wqe(
    QueuePair &qp, uintptr_t raddr,
    uintptr_t laddr, int32_t length,
    uint8_t opcode) {
  poll_cq_until(qp, 1);

  void *wqe_ptr = ernic_get_sq_wqe(
      &qp.ernic_sq_, qp.ernic_sq_.tail);

  struct ernic_wqe_hdr hdr;
  memset(&hdr, 0, sizeof(hdr));
  hdr.wr_id = 0;
  hdr.num_sge = 1;
  hdr.total_len = length;
  hdr.opcode = opcode;
  hdr.send_flags = ERNIC_SEND_SIGNALED;
  hdr.wr.rdma.remote_addr = raddr;
  hdr.wr.rdma.rkey = qp.rkey_;

  struct ernic_sge sge;
  sge.addr = laddr;
  sge.length = length;
  sge.lkey = qp.lkey_;

  memcpy(wqe_ptr, &hdr, sizeof(hdr));
  memcpy((char *)wqe_ptr + sizeof(hdr),
         &sge, sizeof(sge));

  qp.ernic_sq_.tail++;
  if (qp.ernic_sq_.tail >= qp.ernic_sq_.depth)
    qp.ernic_sq_.tail = 0;
  qp.ernic_sq_.psn++;
}

__device__ void Ops::post_wqe_rma(
    QueuePair &qp, int32_t length,
    uintptr_t laddr, uintptr_t raddr,
    uint8_t opcode) {
  uint64_t mask = qp.get_same_qp_lane_mask();
  int count = popcount64(mask);
  int lane = get_lane_id();
  int my_num = popcount64(
      mask & ((1ULL << lane) - 1));
  int first = first_lane(mask);

  if (lane == first) {
    qp.ernic_sq_.lock = 1;
    __threadfence();
  }

  for (int i = 0; i < count; i++) {
    if (i == my_num) {
      write_rma_wqe(qp, raddr, laddr,
                    length, opcode);
      ring_doorbell(qp, qp.ernic_sq_.tail);
    }
  }

  if (lane == first) {
    __threadfence();
    qp.ernic_sq_.lock = 0;
  }
}

__device__ void Ops::post_wqe_rma_single(
    QueuePair &qp, int32_t length,
    uintptr_t laddr, uintptr_t raddr,
    uint8_t opcode, bool ring_db) {
  write_rma_wqe(qp, raddr, laddr,
                length, opcode);
  if (ring_db)
    ring_doorbell(qp, qp.ernic_sq_.tail);
}

__device__ uint32_t Ops::write_amo_wqe(
    QueuePair &qp, uintptr_t raddr,
    uint8_t opcode, int64_t atomic_data,
    int64_t atomic_cmp, bool fetching) {
  uint32_t atomic_idx = 0;

  poll_cq_until(qp, 1);

  void *wqe_ptr = ernic_get_sq_wqe(
      &qp.ernic_sq_, qp.ernic_sq_.tail);

  struct ernic_wqe_hdr hdr;
  memset(&hdr, 0, sizeof(hdr));
  hdr.wr_id = 0;
  hdr.num_sge = 1;
  hdr.total_len = sizeof(uint64_t);
  hdr.opcode = opcode;
  hdr.send_flags = ERNIC_SEND_SIGNALED;
  hdr.wr.atomic.remote_addr = raddr;
  hdr.wr.atomic.compare_add = atomic_cmp;
  hdr.wr.atomic.swap = atomic_data;
  hdr.wr.atomic.rkey = qp.rkey_;

  struct ernic_sge sge;
  if (fetching) {
    atomic_idx = qp.fetching_atomic_idx_++ %
        QueuePair::FETCHING_ATOMIC_CNT;
    sge.addr = (uint64_t)
        &qp.fetching_atomic_[atomic_idx];
    sge.lkey = qp.fetching_atomic_lkey_;
  } else {
    sge.addr = (uint64_t)
        qp.nonfetching_atomic_;
    sge.lkey = qp.nonfetching_atomic_lkey_;
  }
  sge.length = sizeof(uint64_t);

  memcpy(wqe_ptr, &hdr, sizeof(hdr));
  memcpy((char *)wqe_ptr + sizeof(hdr),
         &sge, sizeof(sge));

  qp.ernic_sq_.tail++;
  if (qp.ernic_sq_.tail >= qp.ernic_sq_.depth)
    qp.ernic_sq_.tail = 0;
  qp.ernic_sq_.psn++;

  return atomic_idx;
}

__device__ uint64_t Ops::post_wqe_amo(
    QueuePair &qp, uintptr_t raddr,
    uint8_t opcode, int64_t atomic_data,
    int64_t atomic_cmp, bool fetching) {
  uint64_t mask = qp.get_same_qp_lane_mask();
  int count = popcount64(mask);
  int lane = get_lane_id();
  int my_num = popcount64(
      mask & ((1ULL << lane) - 1));
  int first = first_lane(mask);
  uint32_t atomic_idx = 0;

  if (lane == first) {
    qp.ernic_sq_.lock = 1;
    __threadfence();
  }

  for (int i = 0; i < count; i++) {
    if (i == my_num) {
      atomic_idx = write_amo_wqe(
          qp, raddr, opcode,
          atomic_data, atomic_cmp, fetching);
      ring_doorbell(qp, qp.ernic_sq_.tail);
    }
  }

  if (lane == first) {
    __threadfence();
    qp.ernic_sq_.lock = 0;
  }

  if (fetching) {
    quiet(qp);
    return qp.fetching_atomic_[atomic_idx];
  }
  return 0;
}

__device__ uint64_t Ops::post_wqe_amo_single(
    QueuePair &qp, uintptr_t raddr,
    uint8_t opcode, int64_t atomic_data,
    int64_t atomic_cmp, bool fetching) {
  uint32_t atomic_idx = write_amo_wqe(
      qp, raddr, opcode,
      atomic_data, atomic_cmp, fetching);
  ring_doorbell(qp, qp.ernic_sq_.tail);
  if (fetching) {
    quiet_single(qp);
    return qp.fetching_atomic_[atomic_idx];
  }
  return 0;
}

} // namespace ernic
} // namespace rdma_ep

#endif // defined(GDA_ERNIC)
