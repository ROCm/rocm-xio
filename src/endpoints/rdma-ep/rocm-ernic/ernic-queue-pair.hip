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
#include "xio.h"

#if defined(GDA_ERNIC)

namespace rdma_ep {

/* WQE opcode mapping for ERNIC PVRDMA-style ops */
constexpr uint32_t ERNIC_WR_RDMA_WRITE = 0;
constexpr uint32_t ERNIC_WR_RDMA_WRITE_IMM = 1;
constexpr uint32_t ERNIC_WR_RDMA_READ = 4;
constexpr uint32_t ERNIC_WR_ATOMIC_CS = 5;
constexpr uint32_t ERNIC_WR_ATOMIC_FA = 6;

/* Send flags */
constexpr uint32_t ERNIC_SEND_SIGNALED = (1 << 1);
constexpr uint32_t ERNIC_SEND_INLINE = (1 << 3);

/* UAR doorbell bits */
constexpr uint32_t ERNIC_UAR_QP_SEND = (1u << 30);

/* WQE header: must be 80 bytes to match the PVRDMA
 * pvrdma_sq_wqe_hdr ABI used by the emulated device. */
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
      uint8_t pad[4];
    } rdma;
    struct {
      uint64_t remote_addr;
      uint64_t compare_add;
      uint64_t swap;
      uint32_t rkey;
      uint32_t pad;
    } atomic;
    uint8_t _pad[48];
  } wr;
};
static_assert(sizeof(ernic_wqe_hdr) == 80,
              "ernic_wqe_hdr must match PVRDMA 80-byte WQE");

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
  uint8_t sl;
  uint8_t dlid_path_bits;
  uint8_t port_num;
  uint8_t smac[6];
  uint8_t network_hdr_type;
  uint8_t pad[6];
};

__device__ static inline void* ernic_get_sq_wqe(ernic_device_sq* sq,
                                                uint32_t idx) {
  return (void*)((char*)sq->buf + (idx * sq->wqe_size));
}

namespace ernic {

__device__ void Ops::ring_doorbell(QueuePair& qp, uint32_t slot_idx) {
  if (qp.ernic_sq_.sq_ring_prod_tail) {
    int32_t cur = *qp.ernic_sq_.sq_ring_prod_tail;
    int32_t next = (cur + 1) & ((qp.ernic_sq_.depth << 1) - 1);
    *qp.ernic_sq_.sq_ring_prod_tail = next;
  }
  uint32_t val = (qp.ernic_sq_.qp_handle & 0x00FFFFFF) | ERNIC_UAR_QP_SEND;
  __threadfence_system();

  if (qp.ernic_sq_.use_mmio_bridge && qp.ernic_sq_.mmio_bridge_shadow) {
    xio::genPciMmioBridgeCmd(qp.ernic_sq_.mmio_bridge_shadow,
                             qp.ernic_sq_.ernic_target_bdf, 2,
                             qp.ernic_sq_.uar_bar_offset, val,
                             PCI_MMIO_BRIDGE_CMD_WRITE, 4);
  } else if (qp.ernic_sq_.uar_ptr) {
    volatile uint32_t* db = qp.ernic_sq_.uar_ptr +
                            (qp.ernic_sq_.uar_qp_offset / 4);
    __hip_atomic_store(const_cast<uint32_t*>(db), val, __ATOMIC_SEQ_CST,
                       __HIP_MEMORY_SCOPE_SYSTEM);
  }
}

__device__ void Ops::ring_doorbell_only(QueuePair& qp) {
  ring_doorbell(qp, qp.ernic_sq_.tail);
}

__device__ void Ops::poll_cq_until(QueuePair& qp, uint32_t requested) {
  uint32_t sq_depth = qp.ernic_sq_.depth;
  do {
    /*
     * Check the CQ ring state to detect completions
     * written by the emulated device server.  The CQ
     * ring state lives at the start of the CQ buffer
     * using the PvrdmaRingState layout (two ring
     * pairs of {prod_tail, cons_head}).  The CQ uses
     * the second pair: cq_ring[2] = prod_tail
     * (server-written) and cq_ring[3] = cons_head
     * (GPU-advanced).
     *
     * Advance sq_head for each new CQ entry consumed.
     */
    volatile int32_t* cq_ring = (volatile int32_t*)qp.ernic_cq_.buf;
    if (cq_ring) {
      int32_t cq_prod = cq_ring[2];
      int32_t cq_cons = cq_ring[3];
      if (cq_prod != cq_cons) {
        uint32_t cq_mask = (qp.ernic_cq_.depth << 1) - 1;
        int32_t new_cons = (cq_cons + 1) & cq_mask;
        cq_ring[3] = new_cons;
        __threadfence_system();
        qp.ernic_sq_.head++;
        if (qp.ernic_sq_.head >= sq_depth)
          qp.ernic_sq_.head = 0;
      }
    }

    uint32_t sq_head = qp.ernic_sq_.head;
    uint32_t sq_tail = __hip_atomic_load(&qp.ernic_sq_.tail, __ATOMIC_SEQ_CST,
                                         __HIP_MEMORY_SCOPE_AGENT);
    uint32_t consumed = (sq_tail - sq_head + sq_depth) % sq_depth;
    uint32_t available = sq_depth - consumed;
    if (available >= requested)
      return;
  } while (true);
}

__device__ void Ops::quiet(QueuePair& qp) {
  uint64_t mask = qp.get_same_qp_lane_mask();
  if (get_lane_id() == first_lane(mask))
    poll_cq_until(qp, qp.ernic_sq_.depth);
}

__device__ void Ops::quiet_single(QueuePair& qp) {
  poll_cq_until(qp, qp.ernic_sq_.depth);
}

__device__ void Ops::write_rma_wqe(QueuePair& qp, uintptr_t raddr,
                                   uintptr_t laddr, int32_t length,
                                   uint8_t opcode, uint32_t imm_data) {
  poll_cq_until(qp, 1);

  void* wqe_ptr = ernic_get_sq_wqe(&qp.ernic_sq_, qp.ernic_sq_.tail);

  struct ernic_wqe_hdr hdr;
  memset(&hdr, 0, sizeof(hdr));
  hdr.wr_id = 0;
  hdr.num_sge = 1;
  hdr.total_len = length;
  hdr.opcode = opcode;
  hdr.send_flags = ERNIC_SEND_SIGNALED;
  hdr.ex.imm_data = imm_data;
  hdr.wr.rdma.remote_addr = raddr;
  hdr.wr.rdma.rkey = qp.rkey_;

  struct ernic_sge sge;
  sge.addr = laddr;
  sge.length = length;
  sge.lkey = qp.lkey_;

  xio::XioComEnqueue<sizeof(ernic_wqe_hdr)>(&hdr, wqe_ptr);
  volatile void* sge_dst = static_cast<volatile char*>(
    static_cast<volatile void*>(wqe_ptr)) + sizeof(hdr);
  xio::XioComEnqueue<sizeof(ernic_sge)>(&sge, sge_dst);

  qp.ernic_sq_.tail++;
  if (qp.ernic_sq_.tail >= qp.ernic_sq_.depth)
    qp.ernic_sq_.tail = 0;
  qp.ernic_sq_.psn++;
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
    qp.ernic_sq_.lock = 1;
    __threadfence();
  }

  for (int i = 0; i < count; i++) {
    if (i == my_num) {
      write_rma_wqe(qp, raddr, laddr, length, opcode, imm_data);
      ring_doorbell(qp, qp.ernic_sq_.tail);
    }
  }

  if (lane == first) {
    __threadfence();
    qp.ernic_sq_.lock = 0;
  }
}

__device__ void Ops::post_wqe_rma_single(QueuePair& qp, int32_t length,
                                         uintptr_t laddr, uintptr_t raddr,
                                         uint8_t opcode, bool ring_db,
                                         uint32_t imm_data) {
  write_rma_wqe(qp, raddr, laddr, length, opcode, imm_data);
  if (ring_db)
    ring_doorbell(qp, qp.ernic_sq_.tail);
}

__device__ uint32_t Ops::write_amo_wqe(QueuePair& qp, uintptr_t raddr,
                                       uint8_t opcode, int64_t atomic_data,
                                       int64_t atomic_cmp, bool fetching) {
  uint32_t atomic_idx = 0;

  poll_cq_until(qp, 1);

  void* wqe_ptr = ernic_get_sq_wqe(&qp.ernic_sq_, qp.ernic_sq_.tail);

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
    atomic_idx = qp.fetching_atomic_idx_++ % QueuePair::FETCHING_ATOMIC_CNT;
    sge.addr = (uint64_t)&qp.fetching_atomic_[atomic_idx];
    sge.lkey = qp.fetching_atomic_lkey_;
  } else {
    sge.addr = (uint64_t)qp.nonfetching_atomic_;
    sge.lkey = qp.nonfetching_atomic_lkey_;
  }
  sge.length = sizeof(uint64_t);

  xio::XioComEnqueue<sizeof(ernic_wqe_hdr)>(&hdr, wqe_ptr);
  volatile void* sge_dst = static_cast<volatile char*>(
    static_cast<volatile void*>(wqe_ptr)) + sizeof(hdr);
  xio::XioComEnqueue<sizeof(ernic_sge)>(&sge, sge_dst);

  qp.ernic_sq_.tail++;
  if (qp.ernic_sq_.tail >= qp.ernic_sq_.depth)
    qp.ernic_sq_.tail = 0;
  qp.ernic_sq_.psn++;

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
    qp.ernic_sq_.lock = 1;
    __threadfence();
  }

  for (int i = 0; i < count; i++) {
    if (i == my_num) {
      atomic_idx = write_amo_wqe(qp, raddr, opcode, atomic_data, atomic_cmp,
                                 fetching);
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

__device__ uint64_t Ops::post_wqe_amo_single(QueuePair& qp, uintptr_t raddr,
                                             uint8_t opcode,
                                             int64_t atomic_data,
                                             int64_t atomic_cmp,
                                             bool fetching) {
  uint32_t atomic_idx = write_amo_wqe(qp, raddr, opcode, atomic_data,
                                      atomic_cmp, fetching);
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
