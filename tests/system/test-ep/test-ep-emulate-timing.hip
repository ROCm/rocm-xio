/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * System-level test for test-ep emulate mode that asserts the
 * full timing-buffer path is wired up.  Two sub-tests run:
 *
 *   1. Per-operation `startTimes` / `endTimes` are populated and
 *      monotonic per thread.
 *   2. Aggregate `XioTimingStats` is populated and reports a
 *      positive count and non-decreasing min/max.
 */

#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include <hip/hip_runtime.h>

#include "test-ep.h"
#include "xio-test-assert.h"
#include "xio.h"

int test_emulate_full_timing() {
  const unsigned kIter = 16;
  const unsigned kThreads = 2;

  xio::XioEndpointConfig cfg(kIter, kThreads);

  xio::test_ep::TestEpConfig epCfg;
  epCfg.emulate = true;
  epCfg.enableCpuThreads = true;
  epCfg.iterations = kIter;
  cfg.endpointConfig = &epCfg;

  size_t sqSize = kThreads * sizeof(xio::test_ep::test_sqe);
  size_t cqSize = kThreads * sizeof(xio::test_ep::test_cqe);
  size_t timingSize = kIter * kThreads * sizeof(unsigned long long int);

  void *sq = nullptr, *cq = nullptr;
  unsigned long long int *startTimes = nullptr, *endTimes = nullptr;
  hipError_t e1 = xio::allocHostMemory(sqSize, &sq, "timing SQ",
                                       XIO_HOST_MEM_PLAIN);
  hipError_t e2 = xio::allocHostMemory(cqSize, &cq, "timing CQ",
                                       XIO_HOST_MEM_PLAIN);
  hipError_t e3 = xio::allocHostMemory(timingSize, (void**)&startTimes,
                                       "startTimes", XIO_HOST_MEM_PLAIN);
  hipError_t e4 = xio::allocHostMemory(timingSize, (void**)&endTimes,
                                       "endTimes", XIO_HOST_MEM_PLAIN);
  if (e1 != hipSuccess || e2 != hipSuccess || e3 != hipSuccess ||
      e4 != hipSuccess) {
    xio::freeHostMemory(sq, XIO_HOST_MEM_PLAIN);
    xio::freeHostMemory(cq, XIO_HOST_MEM_PLAIN);
    xio::freeHostMemory(startTimes, XIO_HOST_MEM_PLAIN);
    xio::freeHostMemory(endTimes, XIO_HOST_MEM_PLAIN);
    fprintf(stderr, "Allocation failed\n");
    return 1;
  }

  for (size_t i = 0; i < kIter * kThreads; ++i) {
    startTimes[i] = 0;
    endTimes[i] = 0;
  }

  cfg.submissionQueue = sq;
  cfg.completionQueue = cq;
  cfg.startTimes = startTimes;
  cfg.endTimes = endTimes;

  hipError_t err = xio::test_ep::run(&cfg);

  int populated = 0;
  int monotonic = 1;
  for (unsigned t = 0; t < kThreads; ++t) {
    for (unsigned i = 0; i < kIter; ++i) {
      size_t idx = static_cast<size_t>(t) * kIter + i;
      if (startTimes[idx] != 0 && endTimes[idx] != 0) {
        ++populated;
        if (endTimes[idx] < startTimes[idx]) {
          monotonic = 0;
        }
      }
    }
  }

  xio::freeHostMemory(sq, XIO_HOST_MEM_PLAIN);
  xio::freeHostMemory(cq, XIO_HOST_MEM_PLAIN);
  xio::freeHostMemory(startTimes, XIO_HOST_MEM_PLAIN);
  xio::freeHostMemory(endTimes, XIO_HOST_MEM_PLAIN);

  ASSERT_EQ(err, hipSuccess);
  ASSERT_GE(populated, static_cast<int>(kIter * kThreads));
  ASSERT_EQ(monotonic, 1);
  return 0;
}

int test_emulate_aggregate_timing() {
  const unsigned kIter = 16;
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
  xio::XioTimingStats* stats = nullptr;
  hipError_t e1 = xio::allocHostMemory(sqSize, &sq, "stats SQ",
                                       XIO_HOST_MEM_PLAIN);
  hipError_t e2 = xio::allocHostMemory(cqSize, &cq, "stats CQ",
                                       XIO_HOST_MEM_PLAIN);
  hipError_t e3 = xio::allocHostMemory(sizeof(xio::XioTimingStats),
                                       (void**)&stats, "timingStats",
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

  unsigned long long count = stats->count;
  unsigned long long minD = stats->minDuration;
  unsigned long long maxD = stats->maxDuration;

  xio::freeHostMemory(sq, XIO_HOST_MEM_PLAIN);
  xio::freeHostMemory(cq, XIO_HOST_MEM_PLAIN);
  xio::freeHostMemory(stats, XIO_HOST_MEM_PLAIN);

  ASSERT_EQ(err, hipSuccess);
  ASSERT_GE(count, 1ULL);
  ASSERT_LE(minD, maxD);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_emulate_full_timing();
  failures += test_emulate_aggregate_timing();

  if (failures == 0) {
    printf("All test-ep emulate-timing tests passed.\n");
    return 0;
  }
  printf("%d test-ep emulate-timing test(s) failed.\n", failures);
  return 1;
}
