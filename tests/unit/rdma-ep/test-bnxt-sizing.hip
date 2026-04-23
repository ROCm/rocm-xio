/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for BNXT DV queue sizing helpers. CPU-only: exercises pure
 * arithmetic, no GPU or NIC required.
 */

#include <cassert>
#include <cstdio>
#include <cstdlib>

#include <unistd.h>

#include "bnxt/bnxt-dv-sizing.hpp"
#include "xio-test-assert.h"

using namespace xio::rdma_ep::bnxt_sizing;

int test_roundup_pow2() {
  ASSERT_EQ(roundup_pow2(0), 1u);
  ASSERT_EQ(roundup_pow2(1), 1u);
  ASSERT_EQ(roundup_pow2(2), 2u);
  ASSERT_EQ(roundup_pow2(3), 4u);
  ASSERT_EQ(roundup_pow2(4), 4u);
  ASSERT_EQ(roundup_pow2(5), 8u);
  ASSERT_EQ(roundup_pow2(255), 256u);
  ASSERT_EQ(roundup_pow2(256), 256u);
  ASSERT_EQ(roundup_pow2(257), 512u);
  ASSERT_EQ(roundup_pow2(1023), 1024u);
  ASSERT_EQ(roundup_pow2(1024), 1024u);
  return 0;
}

int test_align_up() {
  ASSERT_EQ(align_up(0, 256), 0u);
  ASSERT_EQ(align_up(1, 256), 256u);
  ASSERT_EQ(align_up(255, 256), 256u);
  ASSERT_EQ(align_up(256, 256), 256u);
  ASSERT_EQ(align_up(257, 256), 512u);
  ASSERT_EQ(align_up(0, 16), 0u);
  ASSERT_EQ(align_up(1, 16), 16u);
  ASSERT_EQ(align_up(15, 16), 16u);
  ASSERT_EQ(align_up(16, 16), 16u);
  ASSERT_EQ(align_up(17, 16), 32u);
  return 0;
}

int test_calc_wqe_sz() {
  ASSERT_EQ(calc_wqe_sz(0), SQE_HDR_SZ);
  ASSERT_EQ(calc_wqe_sz(1), STRIDE + SQE_HDR_SZ);
  ASSERT_EQ(calc_wqe_sz(2), 2 * STRIDE + SQE_HDR_SZ);
  return 0;
}

int test_compute_sq() {
  sq_sizing s = compute_sq(256, 1, 28);

  ASSERT_GT(s.slots, 0u);
  ASSERT_GT(s.wqe_sz, 0u);
  ASSERT_GT(s.npsn, 0u);
  ASSERT_EQ(s.psn_sz, MSN_ENTRY_SZ);
  ASSERT_GT(s.len, 0u);

  uint32_t pg = static_cast<uint32_t>(sysconf(_SC_PAGESIZE));
  ASSERT_EQ(s.len % pg, 0u);

  ASSERT_EQ(s.slots % VAR_SLOT_ALIGN, 0u);

  ASSERT_EQ(s.npsn, static_cast<uint32_t>(roundup_pow2(s.slots)));

  sq_sizing s0 = compute_sq(256, 1, 0);
  ASSERT_GT(s0.len, 0u);
  return 0;
}

int test_compute_rq() {
  rq_sizing r0 = compute_rq(0, 1);
  ASSERT_EQ(r0.slots, 0u);
  ASSERT_EQ(r0.wqe_sz, 0u);
  ASSERT_EQ(r0.len, 0u);

  rq_sizing r1 = compute_rq(1, 1);
  ASSERT_GT(r1.slots, 0u);
  ASSERT_GT(r1.wqe_sz, 0u);
  ASSERT_GT(r1.len, 0u);

  uint32_t pg = static_cast<uint32_t>(sysconf(_SC_PAGESIZE));
  ASSERT_EQ(r1.len % pg, 0u);

  rq_sizing r256 = compute_rq(256, 2);
  ASSERT_GT(r256.len, r1.len);
  return 0;
}

int test_cqe_size() {
  ASSERT_EQ(cqe_size(), CQE_SZ);
  ASSERT_GT(cqe_size(), 0u);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_roundup_pow2();
  failures += test_align_up();
  failures += test_calc_wqe_sz();
  failures += test_compute_sq();
  failures += test_compute_rq();
  failures += test_cqe_size();

  if (failures == 0) {
    printf("All BNXT sizing tests passed.\n");
    return 0;
  }
  printf("%d BNXT sizing test(s) failed.\n", failures);
  return 1;
}
