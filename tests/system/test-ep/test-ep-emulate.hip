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
#include <cstring>

#include <hip/hip_runtime.h>

#include "test-ep.h"
#include "xio.h"

#define ASSERT_EQ(a, b) assert((a) == (b))
#define ASSERT_TRUE(x) assert(x)

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
  sq = calloc(1, sqSize);
  cq = calloc(1, cqSize);
  if (!sq || !cq) {
    free(sq);
    free(cq);
    fprintf(stderr, "Allocation failed\n");
    return 1;
  }

  cfg.submissionQueue = sq;
  cfg.completionQueue = cq;

  hipError_t err = xio::test_ep::run(&cfg);

  free(sq);
  free(cq);

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
