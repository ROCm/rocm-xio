/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for updateTimingStats() and the XioTimingStats accumulator
 * defined in xio-timing.h. These exercise the host (std::atomic) path that
 * every endpoint uses to aggregate per-iteration durations into a single
 * XioTimingStats instance.
 */

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

#include <hip/hip_runtime.h>

#include "xio-test-assert.h"
#include "xio-timing.h"

namespace {

constexpr unsigned long long ULL_MAX = static_cast<unsigned long long>(-1);

void reset_stats(xio::XioTimingStats& s) {
  s.minDuration = ULL_MAX;
  s.maxDuration = 0;
  s.sumDuration = 0;
  s.count = 0;
}

} // namespace

int test_initial_state_after_reset() {
  xio::XioTimingStats s;
  ASSERT_EQ(s.minDuration, ULL_MAX);
  ASSERT_EQ(s.maxDuration, 0ULL);
  ASSERT_EQ(s.sumDuration, 0ULL);
  ASSERT_EQ(s.count, 0ULL);
  return 0;
}

int test_null_stats_is_noop() {
  /* Must not crash and must not write through. */
  updateTimingStats(nullptr, 100ULL);
  updateTimingStats(nullptr, 0ULL);
  updateTimingStats(nullptr, ULL_MAX);
  return 0;
}

int test_single_sample() {
  xio::XioTimingStats s;
  reset_stats(s);
  updateTimingStats(&s, 250ULL);
  ASSERT_EQ(s.count, 1ULL);
  ASSERT_EQ(s.sumDuration, 250ULL);
  ASSERT_EQ(s.minDuration, 250ULL);
  ASSERT_EQ(s.maxDuration, 250ULL);
  return 0;
}

int test_min_max_track_extremes() {
  xio::XioTimingStats s;
  reset_stats(s);
  updateTimingStats(&s, 500ULL);
  updateTimingStats(&s, 100ULL);
  updateTimingStats(&s, 800ULL);
  updateTimingStats(&s, 300ULL);
  updateTimingStats(&s, 200ULL);
  ASSERT_EQ(s.count, 5ULL);
  ASSERT_EQ(s.sumDuration, 500ULL + 100ULL + 800ULL + 300ULL + 200ULL);
  ASSERT_EQ(s.minDuration, 100ULL);
  ASSERT_EQ(s.maxDuration, 800ULL);
  return 0;
}

int test_monotonic_increasing() {
  xio::XioTimingStats s;
  reset_stats(s);
  for (unsigned long long i = 1; i <= 10; i++)
    updateTimingStats(&s, i * 10ULL);
  ASSERT_EQ(s.count, 10ULL);
  ASSERT_EQ(s.sumDuration, 550ULL);
  ASSERT_EQ(s.minDuration, 10ULL);
  ASSERT_EQ(s.maxDuration, 100ULL);
  return 0;
}

int test_monotonic_decreasing() {
  xio::XioTimingStats s;
  reset_stats(s);
  for (unsigned long long i = 10; i >= 1; i--)
    updateTimingStats(&s, i * 10ULL);
  ASSERT_EQ(s.count, 10ULL);
  ASSERT_EQ(s.sumDuration, 550ULL);
  ASSERT_EQ(s.minDuration, 10ULL);
  ASSERT_EQ(s.maxDuration, 100ULL);
  return 0;
}

int test_zero_duration_allowed() {
  xio::XioTimingStats s;
  reset_stats(s);
  updateTimingStats(&s, 0ULL);
  ASSERT_EQ(s.count, 1ULL);
  ASSERT_EQ(s.minDuration, 0ULL);
  ASSERT_EQ(s.maxDuration, 0ULL);
  return 0;
}

int test_concurrent_updates() {
  xio::XioTimingStats s;
  reset_stats(s);

  constexpr unsigned kThreads = 8;
  constexpr unsigned kPerThread = 1000;
  std::vector<std::thread> threads;
  threads.reserve(kThreads);
  for (unsigned t = 0; t < kThreads; t++) {
    threads.emplace_back([&s, t]() {
      for (unsigned i = 0; i < kPerThread; i++) {
        unsigned long long sample = static_cast<unsigned long long>(t + 1) *
                                      1000ULL +
                                    i;
        updateTimingStats(&s, sample);
      }
    });
  }
  for (auto& th : threads)
    th.join();

  ASSERT_EQ(s.count, static_cast<unsigned long long>(kThreads) *
                       static_cast<unsigned long long>(kPerThread));

  /* Min/Max are determined by the smallest/largest sample we generated. */
  ASSERT_EQ(s.minDuration, 1000ULL);
  ASSERT_EQ(s.maxDuration, static_cast<unsigned long long>(kThreads) * 1000ULL +
                             (kPerThread - 1));
  return 0;
}

int main() {
  int failures = 0;
  failures += test_initial_state_after_reset();
  failures += test_null_stats_is_noop();
  failures += test_single_sample();
  failures += test_min_max_track_extremes();
  failures += test_monotonic_increasing();
  failures += test_monotonic_decreasing();
  failures += test_zero_duration_allowed();
  failures += test_concurrent_updates();

  if (failures == 0) {
    printf("All xio-timing tests passed.\n");
    return 0;
  }
  printf("%d xio-timing test(s) failed.\n", failures);
  return 1;
}
