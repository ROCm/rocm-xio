/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for vendor detection and vendor-ops structures.
 */

#include <cassert>
#include <cstdio>
#include <cstring>

#include <hip/hip_runtime.h>

#include "vendor-ops.hpp"

#define ASSERT_EQ(a, b) assert((a) == (b))
#define ASSERT_TRUE(x) assert(x)

int test_vendor_ids() {
  ASSERT_EQ(rdma_ep::VENDOR_ID_BROADCOM, 0x14E4u);
  ASSERT_EQ(rdma_ep::VENDOR_ID_MELLANOX, 0x02C9u);
  ASSERT_EQ(rdma_ep::VENDOR_ID_PENSANDO, 0x1DD8u);
  return 0;
}

int test_rma_descriptor() {
  rdma_ep::RmaDescriptor desc{};
  desc.local_addr = 0x1000;
  desc.remote_addr = 0x2000;
  desc.length = 4096;
  desc.lkey = 0xABCD;
  desc.rkey = 0x1234;
  desc.opcode = 0x04;
  desc.send_inline = false;

  ASSERT_EQ(desc.local_addr, 0x1000u);
  ASSERT_EQ(desc.remote_addr, 0x2000u);
  ASSERT_EQ(desc.length, 4096u);
  ASSERT_EQ(desc.lkey, 0xABCDu);
  ASSERT_EQ(desc.rkey, 0x1234u);
  ASSERT_EQ(desc.opcode, 0x04);
  ASSERT_TRUE(!desc.send_inline);
  return 0;
}

int test_amo_descriptor() {
  rdma_ep::AmoDescriptor desc{};
  desc.remote_addr = 0x3000;
  desc.rkey = 0x5678;
  desc.opcode = 0x0B;
  desc.swap_add = 42;
  desc.compare = 0;
  desc.fetching = true;
  desc.fetch_addr = 0x4000;
  desc.fetch_lkey = 0x9ABC;

  ASSERT_EQ(desc.remote_addr, 0x3000u);
  ASSERT_EQ(desc.swap_add, 42);
  ASSERT_TRUE(desc.fetching);
  return 0;
}

int test_constants() {
  ASSERT_EQ(rdma_ep::WF_SIZE, 64u);
  ASSERT_EQ(rdma_ep::SPIN_LOCK_UNLOCKED, 0u);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_vendor_ids();
  failures += test_rma_descriptor();
  failures += test_amo_descriptor();
  failures += test_constants();

  if (failures == 0) {
    printf("All vendor-ops tests passed.\n");
    return 0;
  }
  printf("%d vendor-ops test(s) failed.\n", failures);
  return 1;
}
