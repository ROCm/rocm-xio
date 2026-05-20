/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * System-level test for test-ep in emulate mode with multiple
 * threads.  Exercises the per-thread SQE/CQE indexing path in
 * `endpoint_kernel_cpu_emulate`, which differs from the single-
 * thread fast path in how it dereferences the queue arrays.
 */

#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include <hip/hip_runtime.h>

#include "test-ep.h"
#include "xio-test-assert.h"
#include "xio.h"

int test_emulate_multithread() {
  const unsigned kIter = 16;
  const unsigned kThreads = 4;

  xio::XioEndpointConfig cfg(kIter, kThreads);

  xio::test_ep::TestEpConfig epCfg;
  epCfg.emulate = true;
  epCfg.enableCpuThreads = true;
  epCfg.iterations = kIter;
  cfg.endpointConfig = &epCfg;

  size_t sqSize = kThreads * sizeof(xio::test_ep::test_sqe);
  size_t cqSize = kThreads * sizeof(xio::test_ep::test_cqe);

  void *sq = nullptr, *cq = nullptr;
  hipError_t sqErr = xio::allocHostMemory(sqSize, &sq, "multithread SQ",
                                          XIO_HOST_MEM_PLAIN);
  hipError_t cqErr = xio::allocHostMemory(cqSize, &cq, "multithread CQ",
                                          XIO_HOST_MEM_PLAIN);
  if (sqErr != hipSuccess || cqErr != hipSuccess) {
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

  ASSERT_EQ(err, hipSuccess);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_emulate_multithread();

  if (failures == 0) {
    printf("All test-ep emulate-multithread tests passed.\n");
    return 0;
  }
  printf("%d test-ep emulate-multithread test(s) failed.\n", failures);
  return 1;
}
