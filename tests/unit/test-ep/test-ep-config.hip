/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for test-ep configuration, struct sizes,
 * and magic constants.
 */

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include <hip/hip_runtime.h>

#include "test-ep.h"

#define ASSERT_EQ(a, b)                                                        \
  do {                                                                         \
    if ((a) != (b)) {                                                          \
      printf("ASSERT_EQ failed: %s:%d\n", __FILE__, __LINE__);                 \
      abort();                                                                 \
    }                                                                          \
  } while (0)
#define ASSERT_TRUE(x)                                                         \
  do {                                                                         \
    if (!(x)) {                                                                \
      printf("ASSERT_TRUE failed: %s:%d\n", __FILE__, __LINE__);               \
      abort();                                                                 \
    }                                                                          \
  } while (0)

int test_magic_constants() {
  ASSERT_EQ(xio::test_ep::magicId, 0xDEADBEEFCAFEBABEULL);
  ASSERT_EQ(xio::test_ep::cqeMagicId, 0xBABECAFEBEEFDEADULL);
  ASSERT_TRUE(xio::test_ep::magicId != xio::test_ep::cqeMagicId);
  return 0;
}

int test_queue_entry_sizes() {
  ASSERT_EQ(xio::test_ep::sqeSize, 64u);
  ASSERT_EQ(xio::test_ep::cqeSize, 16u);
  return 0;
}

int test_sqe_struct_layout() {
  ASSERT_EQ(sizeof(xio::test_ep::test_sqe), xio::test_ep::sqeSize);
  ASSERT_EQ(sizeof(xio::test_ep::test_sqe), 64u);

  xio::test_ep::test_sqe sqe = {};
  sqe.magic = xio::test_ep::magicId;
  sqe.iteration = 42;
  sqe.gpuTime = 12345;
  ASSERT_EQ(sqe.magic, xio::test_ep::magicId);
  ASSERT_EQ(sqe.iteration, 42u);
  ASSERT_EQ(sqe.gpuTime, 12345u);
  return 0;
}

int test_cqe_struct_layout() {
  ASSERT_EQ(sizeof(xio::test_ep::test_cqe), xio::test_ep::cqeSize);
  ASSERT_EQ(sizeof(xio::test_ep::test_cqe), 16u);

  xio::test_ep::test_cqe cqe = {};
  cqe.magic = xio::test_ep::cqeMagicId;
  cqe.cpuTime = 67890;
  ASSERT_EQ(cqe.magic, xio::test_ep::cqeMagicId);
  ASSERT_EQ(cqe.cpuTime, 67890u);
  return 0;
}

int test_config_defaults() {
  xio::test_ep::TestEpConfig cfg;
  ASSERT_TRUE(cfg.enableCpuThreads);
  ASSERT_EQ(cfg.doorbell, 0u);
  ASSERT_TRUE(!cfg.emulate);
  ASSERT_EQ(cfg.iterations, 128u);
  return 0;
}

int test_type_aliases() {
  ASSERT_EQ(sizeof(xio::test_ep::sqeType), sizeof(xio::test_ep::test_sqe));
  ASSERT_EQ(sizeof(xio::test_ep::cqeType), sizeof(xio::test_ep::test_cqe));
  return 0;
}

int main() {
  int failures = 0;
  failures += test_magic_constants();
  failures += test_queue_entry_sizes();
  failures += test_sqe_struct_layout();
  failures += test_cqe_struct_layout();
  failures += test_config_defaults();
  failures += test_type_aliases();

  if (failures == 0) {
    printf("All test-ep config tests passed.\n");
    return 0;
  }
  printf("%d test-ep config test(s) failed.\n", failures);
  return 1;
}
