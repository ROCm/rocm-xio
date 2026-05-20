/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * System-level test for test-ep emulate mode with a non-zero
 * fixed CPU response delay.  Verifies that:
 *
 *   - The CPU thread honours the per-SQE delay value placed in
 *     `data[0]` by the producer kernel.
 *   - The end-to-end duration clears a loose floor (20 µs, i.e. 10% of
 *     the 200 µs request) so CI tolerates scheduling jitter, while a
 *     regression that ignores `data[0]` still fails because `minDuration`
 *     would drop far below that floor.
 */

#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include <hip/hip_runtime.h>

#include "test-ep.h"
#include "xio-test-assert.h"
#include "xio.h"

int test_emulate_fixed_delay() {
  const unsigned kIter = 8;
  const unsigned kThreads = 1;
  // Negative delay => fixed delay of |delay| ns in the producer.
  // The CPU thread reads the value from data[0] each iteration.
  const long long kDelayNs = -200000; // 200 us

  xio::XioEndpointConfig cfg(kIter, kThreads);
  cfg.delayNs = kDelayNs;

  xio::test_ep::TestEpConfig epCfg;
  epCfg.emulate = true;
  epCfg.enableCpuThreads = true;
  epCfg.iterations = kIter;
  cfg.endpointConfig = &epCfg;

  size_t sqSize = kThreads * sizeof(xio::test_ep::test_sqe);
  size_t cqSize = kThreads * sizeof(xio::test_ep::test_cqe);

  void *sq = nullptr, *cq = nullptr;
  xio::XioTimingStats* stats = nullptr;
  hipError_t e1 = xio::allocHostMemory(sqSize, &sq, "delay SQ",
                                       XIO_HOST_MEM_PLAIN);
  hipError_t e2 = xio::allocHostMemory(cqSize, &cq, "delay CQ",
                                       XIO_HOST_MEM_PLAIN);
  hipError_t e3 = xio::allocHostMemory(sizeof(xio::XioTimingStats),
                                       (void**)&stats, "delay stats",
                                       XIO_HOST_MEM_PLAIN);
  if (e1 != hipSuccess || e2 != hipSuccess || e3 != hipSuccess) {
    xio::freeHostMemory(sq, XIO_HOST_MEM_PLAIN);
    xio::freeHostMemory(cq, XIO_HOST_MEM_PLAIN);
    xio::freeHostMemory(stats, XIO_HOST_MEM_PLAIN);
    fprintf(stderr, "Allocation failed\n");
    return 1;
  }

  stats->minDuration = ULLONG_MAX;
  stats->maxDuration = 0;
  stats->sumDuration = 0;
  stats->count = 0;

  cfg.submissionQueue = sq;
  cfg.completionQueue = cq;
  cfg.timingStats = stats;

  hipError_t err = xio::test_ep::run(&cfg);

  unsigned long long minD = stats->minDuration;
  unsigned long long count = stats->count;

  xio::freeHostMemory(sq, XIO_HOST_MEM_PLAIN);
  xio::freeHostMemory(cq, XIO_HOST_MEM_PLAIN);
  xio::freeHostMemory(stats, XIO_HOST_MEM_PLAIN);

  ASSERT_EQ(err, hipSuccess);
  ASSERT_GE(count, 1ULL);
  // CPU clock is nanoseconds (CLOCK_MONOTONIC), so minDuration is
  // directly comparable to the requested delay.  Use a floor at 10% of
  // the request (20 us vs. 200 us) to absorb jitter while still catching
  // a regression that ignores the delay entirely.
  const unsigned long long kFloorNs = 20000; // 20 us
  ASSERT_GE(minD, kFloorNs);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_emulate_fixed_delay();

  if (failures == 0) {
    printf("All test-ep emulate-delay tests passed.\n");
    return 0;
  }
  printf("%d test-ep emulate-delay test(s) failed.\n", failures);
  return 1;
}
