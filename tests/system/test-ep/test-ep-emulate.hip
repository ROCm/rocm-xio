/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * System-level test for test-ep in emulate mode.
 *
 * Validates the full SQE/CQE roundtrip using CPU
 * emulation threads. This exercises the same code path
 * as `xio-tester test-ep --emulate` but through the
 * library API with a minimal configuration.
 */

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <hip/hip_runtime.h>

#include "test-ep.h"
#include "xio.h"

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

int test_emulate_roundtrip() {
  const unsigned kIter = 10;
  const unsigned kThreads = 1;

  xio::XioEndpointConfig cfg(kIter, kThreads);

  xio::test_ep::TestEpConfig epCfg;
  epCfg.emulate = true;
  epCfg.enableCpuThreads = true;
  epCfg.iterations = kIter;
  cfg.endpointConfig = &epCfg;

  size_t sqSize = kThreads * sizeof(xio::test_ep::test_sqe);
  size_t cqSize = kThreads * sizeof(xio::test_ep::test_cqe);

  void *sq = nullptr, *cq = nullptr;
  hipError_t sq_err = xio::allocHostMemory(sqSize, &sq, "emulate SQ",
                                           XIO_HOST_MEM_PLAIN);
  hipError_t cq_err = xio::allocHostMemory(cqSize, &cq, "emulate CQ",
                                           XIO_HOST_MEM_PLAIN);
  if (sq_err != hipSuccess || cq_err != hipSuccess) {
    xio::freeHostMemory(sq, XIO_HOST_MEM_PLAIN);
    xio::freeHostMemory(cq, XIO_HOST_MEM_PLAIN);
    fprintf(stderr, "Allocation failed\n");
    return 1;
  }

  cfg.submissionQueue = sq;
  cfg.completionQueue = cq;

  hipError_t err = xio::test_ep::run(&cfg);

  xio::freeHostMemory(sq, XIO_HOST_MEM_PLAIN);
  xio::freeHostMemory(cq, XIO_HOST_MEM_PLAIN);

  if (err != hipSuccess) {
    fprintf(stderr, "test-ep emulate run failed: %d\n", static_cast<int>(err));
    return 1;
  }
  return 0;
}

int main() {
  int failures = 0;
  failures += test_emulate_roundtrip();

  if (failures == 0) {
    printf("All test-ep emulate tests passed.\n");
    return 0;
  }
  printf("%d test-ep emulate test(s) failed.\n", failures);
  return 1;
}
