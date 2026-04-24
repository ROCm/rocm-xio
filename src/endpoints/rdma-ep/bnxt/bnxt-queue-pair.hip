/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/bnxt/queue_pair_bnxt.cpp, adapted for
 * rocm-xio. BNXT (Broadcom Thor 2) GPU-side device code in rdma_ep::bnxt
 * namespace.
 */

#include "queue-pair.hpp"

#if defined(GDA_BNXT)

namespace xio {
namespace rdma_ep {

// --- BNXT SQ helpers ---

__device__ static inline struct bnxt_re_msns* bnxt_re_pull_psn_buff(
  bnxt_device_sq* sq) {
  return (struct bnxt_re_msns*)(((char*)sq->msntbl) +
                                ((sq->msn) << sq->psn_sz_log2));
}

__device__ static inline uint64_t bnxt_re_update_msn_tbl(uint32_t st_idx,
                                                         uint32_t npsn,
                                                         uint32_t start_psn) {
  return ((((uint64_t)(st_idx) << BNXT_RE_SQ_MSN_SEARCH_START_IDX_SHIFT) &
           BNXT_RE_SQ_MSN_SEARCH_START_IDX_MASK) |
          (((uint64_t)(npsn) << BNXT_RE_SQ_MSN_SEARCH_NEXT_PSN_SHIFT) &
           BNXT_RE_SQ_MSN_SEARCH_NEXT_PSN_MASK) |
          (((start_psn) << BNXT_RE_SQ_MSN_SEARCH_START_PSN_SHIFT) &
           BNXT_RE_SQ_MSN_SEARCH_START_PSN_MASK));
}

__device__ static inline void bnxt_re_fill_psns_for_msntbl(bnxt_device_sq* sq,
                                                           uint32_t msg_len) {
  struct bnxt_re_msns msns;
  uint64_t* msns_ptr = (uint64_t*)bnxt_re_pull_psn_buff(sq);
  msns.start_idx_next_psn_start_psn = 0;
  uint32_t st_idx = sq->tail;
  uint32_t start_psn = sq->psn;
  uint32_t pkt_cnt = (msg_len / sq->mtu);
  if (msg_len % sq->mtu)
    pkt_cnt++;
  if (msg_len == 0)
    pkt_cnt = 1;
  uint32_t next_psn = sq->psn + pkt_cnt;
  sq->psn = next_psn;
  msns.start_idx_next_psn_start_psn |= bnxt_re_update_msn_tbl(st_idx, next_psn,
                                                              start_psn);
  sq->msn++;
  sq->msn %= sq->msn_tbl_sz;
  memcpy(msns_ptr, &msns, sizeof(uint64_t));
}

__device__ static inline void bnxt_re_incr_tail(bnxt_device_sq* sq,
                                                uint8_t cnt) {
  sq->tail += cnt;
  if (sq->tail >= sq->depth) {
    sq->tail %= sq->depth;
    sq->flags ^= 1UL << BNXT_RE_FLAG_EPOCH_TAIL_SHIFT;
  }
}

__device__ static inline void* bnxt_re_get_hwqe(bnxt_device_sq* sq,
                                                uint32_t idx) {
  idx += sq->tail;
  if (idx >= sq->depth)
    idx -= sq->depth;
  return (void*)((char*)sq->buf + (idx << 4));
}

// --- rdma_ep::bnxt::Ops ---

namespace bnxt {

__device__ void Ops::ring_doorbell(QueuePair& qp, uint32_t slot_idx) {
  struct bnxt_re_db_hdr hdr;
  uint32_t epoch = (qp.bnxt_sq_.flags & BNXT_RE_FLAG_EPOCH_TAIL_MASK)
                   << BNXT_RE_DB_EPOCH_TAIL_SHIFT;
  uint64_t key_lo = (slot_idx | epoch);
  uint64_t key_hi = (qp.bnxt_sq_.id & BNXT_RE_DB_QID_MASK) |
                    (((uint64_t)BNXT_RE_QUE_TYPE_SQ & BNXT_RE_DB_TYP_MASK)
                     << BNXT_RE_DB_TYP_SHIFT) |
                    (0x1UL << BNXT_RE_DB_VALID_SHIFT);
  hdr.typ_qid_indx = (key_lo | (key_hi << 32));
  __threadfence_system();
  __hip_atomic_store(qp.bnxt_dbr_, hdr.typ_qid_indx, __ATOMIC_SEQ_CST,
                     __HIP_MEMORY_SCOPE_SYSTEM);
}

__device__ void Ops::ring_doorbell_only(QueuePair& qp) {
  ring_doorbell(qp, qp.bnxt_sq_.tail);
}

__device__ void Ops::check_cqe_error(QueuePair& qp,
                                     struct bnxt_re_req_cqe* cqe) {
  (void)qp;
  struct bnxt_re_bcqe* hdr =
    (struct bnxt_re_bcqe*)((char*)cqe + sizeof(struct bnxt_re_req_cqe));
  uint32_t flg_val = hdr->flg_st_typ_ph;
  __threadfence();
  uint8_t status = (flg_val >> BNXT_RE_BCQE_STATUS_SHIFT) &
                   BNXT_RE_BCQE_STATUS_MASK;
  if (status != BNXT_RE_REQ_ST_OK) {
    printf("rdma_ep::bnxt: CQ Error status=0x%x\n", status);
    abort();
  }
}

__device__ void Ops::ack_cq(QueuePair& qp, uint32_t db_idx) {
  struct bnxt_re_db_hdr hdr;
  uint64_t key_lo = db_idx;
  uint64_t key_hi = (qp.bnxt_cq_.id & BNXT_RE_DB_QID_MASK) |
                    (((uint64_t)BNXT_RE_QUE_TYPE_CQ & BNXT_RE_DB_TYP_MASK)
                     << BNXT_RE_DB_TYP_SHIFT) |
                    (0x1UL << BNXT_RE_DB_VALID_SHIFT);
  hdr.typ_qid_indx = (key_lo | (key_hi << 32));
  __threadfence_system();
  __hip_atomic_store(qp.bnxt_dbr_, hdr.typ_qid_indx, __ATOMIC_SEQ_CST,
                     __HIP_MEMORY_SCOPE_SYSTEM);
}

__device__ void Ops::poll_cq_until(QueuePair& qp,
                                   uint32_t requested_available_slots) {
  uint32_t sq_depth = qp.bnxt_sq_.depth;
  uint32_t cq_depth = qp.bnxt_cq_.depth;
  uint32_t cq_cons = qp.bnxt_cq_.head;
  uint32_t cq_epoch = qp.bnxt_cq_.flags & 1;
  bool cq_dirty = false;
  unsigned poll_count = 0;
  constexpr uint32_t cqe_bytes = sizeof(struct bnxt_re_req_cqe) +
                                 sizeof(struct bnxt_re_bcqe);

  do {
    if (qp.stopRequested_ && poll_count % 100 == 0 && *qp.stopRequested_)
      return;
    poll_count++;

    uint32_t sq_tail = __hip_atomic_load(&qp.bnxt_sq_.tail, __ATOMIC_SEQ_CST,
                                         __HIP_MEMORY_SCOPE_AGENT);
    uint32_t sq_head = qp.bnxt_sq_.head;
    uint32_t consumed = (sq_tail - sq_head + sq_depth) % sq_depth;
    uint32_t available = sq_depth - consumed;
    if (available >= requested_available_slots) {
      if (cq_dirty) {
        uint32_t db_idx = (cq_cons % cq_depth) | (cq_epoch << 24);
        ack_cq(qp, db_idx);
        qp.bnxt_cq_.head = cq_cons;
        qp.bnxt_cq_.flags = (qp.bnxt_cq_.flags & ~1u) | cq_epoch;
      }
      return;
    }

    uint32_t cq_idx = cq_cons % cq_depth;
    uint8_t phase_exp = !((cq_cons / cq_depth) & 1);

    auto* base = (volatile uint8_t*)qp.bnxt_cq_.buf;
    auto* cqe = (volatile struct bnxt_re_req_cqe*)(base + cq_idx * cqe_bytes);
    auto* hdr = (volatile struct bnxt_re_bcqe*)(base + cq_idx * cqe_bytes +
                                                sizeof(struct bnxt_re_req_cqe));

    uint32_t flg = hdr->flg_st_typ_ph;
    uint8_t phase = flg & BNXT_RE_BCQE_PH_MASK;

    if (phase != phase_exp)
      continue;

    uint32_t con = cqe->con_indx & 0xFFFF;
    uint32_t new_head = (con * GDA_BNXT_WQE_SLOT_COUNT) % sq_depth;
    qp.bnxt_sq_.head = new_head;
    cq_cons++;
    if (cq_cons % cq_depth == 0)
      cq_epoch ^= 1;
    cq_dirty = true;
  } while (true);
}

__device__ void Ops::quiet(QueuePair& qp) {
  uint64_t mask = qp.get_same_qp_lane_mask();
  if (get_lane_id() == first_lane(mask))
    poll_cq_until(qp, qp.bnxt_sq_.depth);
}

__device__ void Ops::quiet_single(QueuePair& qp) {
  poll_cq_until(qp, qp.bnxt_sq_.depth);
}

__device__ void Ops::write_rma_wqe(QueuePair& qp, uintptr_t raddr,
                                   uintptr_t laddr, int32_t length,
                                   uint8_t opcode, uint32_t imm_data) {
  struct bnxt_re_bsqe hdr;
  struct bnxt_re_rdma rdma;
  struct bnxt_re_sge sge;
  bool is_write = opcode == qp.op_rdma_write_ ||
                  opcode == qp.op_rdma_write_imm_;
  uint32_t inline_msg = length <= static_cast<int32_t>(qp.inline_threshold_) &&
                        is_write;

  poll_cq_until(qp, GDA_BNXT_WQE_SLOT_COUNT);

  auto* hdr_ptr = (struct bnxt_re_bsqe*)bnxt_re_get_hwqe(&qp.bnxt_sq_, 0);
  auto* rdma_ptr = (struct bnxt_re_rdma*)bnxt_re_get_hwqe(&qp.bnxt_sq_, 1);
  auto* sge_ptr = (struct bnxt_re_sge*)bnxt_re_get_hwqe(&qp.bnxt_sq_, 2);

  uint32_t wqe_type = BNXT_RE_HDR_WT_MASK & opcode;
  uint32_t wqe_size = BNXT_RE_HDR_WS_MASK & GDA_BNXT_WQE_SLOT_COUNT;
  uint32_t hdr_flags = ((uint32_t)BNXT_RE_HDR_FLAGS_MASK) &
                       ((uint32_t)BNXT_RE_WR_FLAGS_SIGNALED);
  if (inline_msg)
    hdr_flags |= ((uint32_t)BNXT_RE_WR_FLAGS_INLINE);

  hdr.rsv_ws_fl_wt = (wqe_size << BNXT_RE_HDR_WS_SHIFT) |
                     (hdr_flags << BNXT_RE_HDR_FLAGS_SHIFT) | wqe_type;
  hdr.key_immd = (opcode == qp.op_rdma_write_imm_) ? imm_data : 0;
  hdr.lhdr.qkey_len = length;
  rdma.rva = raddr;
  rdma.rkey = qp.rkey_;
  if (!inline_msg) {
    sge.pa = laddr;
    sge.lkey = qp.lkey_;
    sge.length = length;
  }

  xio::XioComEnqueue<sizeof(struct bnxt_re_bsqe)>(&hdr, hdr_ptr);
  xio::XioComEnqueue<sizeof(struct bnxt_re_rdma)>(&rdma, rdma_ptr);
  if (inline_msg)
    memcpy(sge_ptr, reinterpret_cast<const void*>(laddr), length);
  else
    xio::XioComEnqueue<sizeof(struct bnxt_re_sge)>(&sge, sge_ptr);

  bnxt_re_fill_psns_for_msntbl(&qp.bnxt_sq_, length);
  bnxt_re_incr_tail(&qp.bnxt_sq_, GDA_BNXT_WQE_SLOT_COUNT);
}

__device__ void Ops::post_wqe_rma(QueuePair& qp, int32_t length,
                                  uintptr_t laddr, uintptr_t raddr,
                                  uint8_t opcode, uint32_t imm_data) {
  uint64_t mask = qp.get_same_qp_lane_mask();
  int count = popcount64(mask);
  int lane = get_lane_id();
  int my_num = popcount64(mask & ((1ULL << lane) - 1));
  int first = first_lane(mask);

  if (lane == first) {
    qp.bnxt_sq_.lock = 1;
    __threadfence();
  }

  for (int i = 0; i < count; i++) {
    if (i == my_num) {
      write_rma_wqe(qp, raddr, laddr, length, opcode, imm_data);
      ring_doorbell(qp, qp.bnxt_sq_.tail);
    }
  }

  if (lane == first) {
    __threadfence();
    qp.bnxt_sq_.lock = 0;
  }
}

__device__ void Ops::post_wqe_rma_single(QueuePair& qp, int32_t length,
                                         uintptr_t laddr, uintptr_t raddr,
                                         uint8_t opcode, bool ring_db,
                                         uint32_t imm_data) {
  write_rma_wqe(qp, raddr, laddr, length, opcode, imm_data);
  if (ring_db)
    ring_doorbell(qp, qp.bnxt_sq_.tail);
}

__device__ uint32_t Ops::write_amo_wqe(QueuePair& qp, uintptr_t raddr,
                                       uint8_t opcode, int64_t atomic_data,
                                       int64_t atomic_cmp, bool fetching) {
  struct bnxt_re_bsqe hdr;
  struct bnxt_re_atomic amo;
  struct bnxt_re_sge sge;
  uint32_t atomic_idx = 0;
  uint32_t length = sizeof(uint64_t);

  poll_cq_until(qp, GDA_BNXT_WQE_SLOT_COUNT);

  auto* hdr_ptr = (struct bnxt_re_bsqe*)bnxt_re_get_hwqe(&qp.bnxt_sq_, 0);
  auto* amo_ptr = (struct bnxt_re_atomic*)bnxt_re_get_hwqe(&qp.bnxt_sq_, 1);
  auto* sge_ptr = (struct bnxt_re_sge*)bnxt_re_get_hwqe(&qp.bnxt_sq_, 2);

  uint32_t wqe_size = BNXT_RE_HDR_WS_MASK & GDA_BNXT_WQE_SLOT_COUNT;
  uint32_t hdr_flags = ((uint32_t)BNXT_RE_HDR_FLAGS_MASK) &
                       ((uint32_t)BNXT_RE_WR_FLAGS_SIGNALED);
  uint32_t wqe_type = BNXT_RE_HDR_WT_MASK & opcode;

  hdr.rsv_ws_fl_wt = (wqe_size << BNXT_RE_HDR_WS_SHIFT) |
                     (hdr_flags << BNXT_RE_HDR_FLAGS_SHIFT) | wqe_type;
  hdr.key_immd = qp.rkey_;
  hdr.lhdr.rva = raddr;
  amo.swp_dt = atomic_data;
  amo.cmp_dt = atomic_cmp;

  if (fetching) {
    atomic_idx = qp.fetching_atomic_idx_++ % QueuePair::FETCHING_ATOMIC_CNT;
    sge.pa = (uint64_t)&qp.fetching_atomic_[atomic_idx];
    sge.lkey = qp.fetching_atomic_lkey_;
  } else {
    sge.pa = (uint64_t)qp.nonfetching_atomic_;
    sge.lkey = qp.nonfetching_atomic_lkey_;
  }
  sge.length = length;

  xio::XioComEnqueue<sizeof(struct bnxt_re_bsqe)>(&hdr, hdr_ptr);
  xio::XioComEnqueue<sizeof(struct bnxt_re_atomic)>(&amo, amo_ptr);
  xio::XioComEnqueue<sizeof(struct bnxt_re_sge)>(&sge, sge_ptr);

  bnxt_re_fill_psns_for_msntbl(&qp.bnxt_sq_, length);
  bnxt_re_incr_tail(&qp.bnxt_sq_, GDA_BNXT_WQE_SLOT_COUNT);
  return atomic_idx;
}

__device__ uint64_t Ops::post_wqe_amo(QueuePair& qp, uintptr_t raddr,
                                      uint8_t opcode, int64_t atomic_data,
                                      int64_t atomic_cmp, bool fetching) {
  uint64_t mask = qp.get_same_qp_lane_mask();
  int count = popcount64(mask);
  int lane = get_lane_id();
  int my_num = popcount64(mask & ((1ULL << lane) - 1));
  int first = first_lane(mask);
  uint32_t atomic_idx = 0;

  if (lane == first) {
    qp.bnxt_sq_.lock = 1;
    __threadfence();
  }

  for (int i = 0; i < count; i++) {
    if (i == my_num) {
      atomic_idx = write_amo_wqe(qp, raddr, opcode, atomic_data, atomic_cmp,
                                 fetching);
      ring_doorbell(qp, qp.bnxt_sq_.tail);
    }
  }

  if (lane == first) {
    __threadfence();
    qp.bnxt_sq_.lock = 0;
  }

  if (fetching) {
    quiet(qp);
    return qp.fetching_atomic_[atomic_idx];
  }
  return 0;
}

__device__ uint64_t Ops::post_wqe_amo_single(QueuePair& qp, uintptr_t raddr,
                                             uint8_t opcode,
                                             int64_t atomic_data,
                                             int64_t atomic_cmp,
                                             bool fetching) {
  uint32_t atomic_idx = write_amo_wqe(qp, raddr, opcode, atomic_data,
                                      atomic_cmp, fetching);
  ring_doorbell(qp, qp.bnxt_sq_.tail);
  if (fetching) {
    quiet_single(qp);
    return qp.fetching_atomic_[atomic_idx];
  }
  return 0;
}

} // namespace bnxt
} // namespace rdma_ep
} // namespace xio

#endif // defined(GDA_BNXT)
