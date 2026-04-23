/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * QP / CQ memory sizing helpers for the v11 Direct
 * Verbs API.  The v11 fork removed qp_mem_alloc() and
 * cq_mem_alloc(); the caller is now responsible for
 * computing buffer sizes.
 *
 * Formulas are derived from
 *   providers/bnxt_re/verbs.c
 * in the rdma-core DV fork.
 *
 * Assumptions (Thor 2 / gen_p5_p7):
 *   - VARIABLE WQE mode
 *   - MSN table enabled (psn entry = 8 B)
 *   - Power-of-two depth rounding enabled
 */

#ifndef RDMA_EP_BNXT_DV_SIZING_HPP
#define RDMA_EP_BNXT_DV_SIZING_HPP

#include <cstddef>
#include <cstdint>

#include <unistd.h>

extern "C" {
#include "bnxt/bnxt-re-hsi.h"
}

namespace xio { namespace rdma_ep {
namespace bnxt_sizing {

static constexpr uint32_t STRIDE = sizeof(struct bnxt_re_sge); /* 16 */
static constexpr uint32_t SQE_HDR_SZ = sizeof(struct bnxt_re_bsqe) +
                                       sizeof(struct bnxt_re_send); /* 32 */
static constexpr uint32_t CQE_SZ = sizeof(struct bnxt_re_req_cqe) +
                                   sizeof(struct bnxt_re_bcqe);       /* 32 */
static constexpr uint32_t MSN_ENTRY_SZ = sizeof(struct bnxt_re_msns); /* 8  */
static constexpr uint32_t FULL_FLAG_DELTA = 0x80;
static constexpr uint32_t VAR_SLOT_ALIGN = 256;

inline uint64_t roundup_pow2(uint64_t n) {
  if (n <= 1)
    return 1;
  n--;
  n |= n >> 1;
  n |= n >> 2;
  n |= n >> 4;
  n |= n >> 8;
  n |= n >> 16;
  n |= n >> 32;
  return n + 1;
}

inline uint32_t align_up(uint32_t val, uint32_t a) {
  return (val + a - 1) & ~(a - 1);
}

inline uint32_t calc_wqe_sz(uint32_t nsge) {
  return STRIDE * nsge + SQE_HDR_SZ;
}

struct sq_sizing {
  uint32_t slots;
  uint32_t wqe_sz;
  uint32_t npsn;
  uint32_t psn_sz;
  uint32_t len;
};

inline sq_sizing compute_sq(uint32_t max_send_wr, uint32_t max_send_sge,
                            uint32_t max_inline_data) {
  sq_sizing s{};
  uint32_t nswr = max_send_wr + 1 + FULL_FLAG_DELTA;
  nswr = static_cast<uint32_t>(roundup_pow2(nswr));

  s.wqe_sz = calc_wqe_sz(max_send_sge);

  if (max_inline_data > 0) {
    uint32_t il_aligned = align_up(max_inline_data, STRIDE);
    uint32_t cal = SQE_HDR_SZ + il_aligned;
    if (cal > s.wqe_sz)
      s.wqe_sz = cal;
    s.wqe_sz = align_up(s.wqe_sz, STRIDE);
  }

  s.slots = (nswr * s.wqe_sz) / STRIDE;
  s.slots = align_up(s.slots, VAR_SLOT_ALIGN);

  s.npsn = static_cast<uint32_t>(roundup_pow2(s.slots));
  s.psn_sz = MSN_ENTRY_SZ;

  uint32_t pg = static_cast<uint32_t>(sysconf(_SC_PAGESIZE));
  uint32_t ring = s.slots * STRIDE;
  uint32_t psn = s.npsn * s.psn_sz;
  s.len = align_up(ring + psn, pg);
  return s;
}

struct rq_sizing {
  uint32_t slots;
  uint32_t wqe_sz;
  uint32_t len;
};

inline rq_sizing compute_rq(uint32_t max_recv_wr, uint32_t max_recv_sge) {
  rq_sizing r{};
  if (max_recv_wr == 0) {
    r.slots = 0;
    r.wqe_sz = 0;
    r.len = 0;
    return r;
  }
  uint32_t nrwr = max_recv_wr + 1;
  nrwr = static_cast<uint32_t>(roundup_pow2(nrwr));

  r.wqe_sz = calc_wqe_sz(max_recv_sge);

  r.slots = (nrwr * r.wqe_sz) / STRIDE;

  uint32_t pg = static_cast<uint32_t>(sysconf(_SC_PAGESIZE));
  r.len = align_up(r.slots * STRIDE, pg);
  return r;
}

inline uint32_t cqe_size() {
  return CQE_SZ;
}

} // namespace bnxt_sizing
} // namespace rdma_ep
} // namespace xio

#endif // RDMA_EP_BNXT_DV_SIZING_HPP
