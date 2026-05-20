/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * CPU-only unit tests for xio::test_ep::launchCpuThreads().
 *
 * These tests stand the polling threads up directly from the test
 * binary and then play the role of the GPU: they write SQEs into
 * the queue and wait for the CPU thread to publish a matching CQE.
 * The whole flow is host-only -- no HIP kernel launch happens here,
 * so the suite runs cleanly under the "unit" CTest label.
 */

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

#include <hip/hip_runtime.h>

#include "test-ep.h"
#include "xio-test-assert.h"

namespace {

using xio::test_ep::cqeMagicId;
using xio::test_ep::cqeType;
using xio::test_ep::magicId;
using xio::test_ep::sqeType;

constexpr std::chrono::seconds kJoinTimeout{20};

void waitForThreads(std::vector<std::thread>& threads) {
  for (auto& t : threads) {
    if (t.joinable()) {
      t.join();
    }
  }
}

// Poll a CQE until magic is published and cpuTime advances past
// lastSeen.  Returns the newly-observed CQE.
cqeType waitForCqe(volatile cqeType* slot, uint64_t lastSeen) {
  auto start = std::chrono::steady_clock::now();
  while (true) {
    cqeType obs;
    obs.magic = slot->magic;
    obs.cpuTime = slot->cpuTime;
    if (obs.magic == cqeMagicId && obs.cpuTime != 0 &&
        obs.cpuTime != lastSeen) {
      return obs;
    }
    if (std::chrono::steady_clock::now() - start > kJoinTimeout) {
      printf("Timed out waiting for CQE (lastSeen=%lu)\n",
             (unsigned long)lastSeen);
      abort();
    }
    std::this_thread::yield();
  }
}

} // namespace

// Single-thread polling round-trip.  One CPU thread services one
// SQE/CQE pair, we push N SQEs from the test thread and verify a
// CQE with a fresh, monotonic cpuTime comes back for each one.
int test_single_thread_round_trip() {
  constexpr unsigned kIterations = 8;

  sqeType sqe = {};
  cqeType cqe = {};

  auto threads = xio::test_ep::launchCpuThreads(&sqe, &cqe, /*numThreads=*/1,
                                                kIterations, /*delayNs=*/0,
                                                /*doorbell=*/0,
                                                /*doorbellAddr=*/nullptr,
                                                /*queueSize=*/0);
  ASSERT_EQ(threads.size(), 1u);

  uint64_t lastCpuTime = 0;
  for (unsigned i = 0; i < kIterations; ++i) {
    sqeType msg = {};
    msg.magic = magicId;
    msg.iteration = (static_cast<uint64_t>(0) << 32) | i;
    msg.gpuTime = 0x1000ULL + i; // strictly monotonic
    msg.data[0] = 0;             // zero delay
    sqe.data[1] = 0;
    sqe.data[2] = 0;
    sqe.data[3] = 0;
    sqe.data[4] = 0;
    sqe.gpuTime = msg.gpuTime;
    sqe.iteration = msg.iteration;
    std::atomic_thread_fence(std::memory_order_release);
    sqe.magic = msg.magic;
    std::atomic_thread_fence(std::memory_order_release);

    cqeType resp = waitForCqe(&cqe, lastCpuTime);
    ASSERT_EQ(resp.magic, cqeMagicId);
    ASSERT_TRUE(resp.cpuTime != lastCpuTime);
    lastCpuTime = resp.cpuTime;
  }

  waitForThreads(threads);
  return 0;
}

// Multi-thread polling round-trip with one CPU thread per "GPU"
// thread.  Each producer thread plays the role of one GPU work
// item.
int test_multi_thread_round_trip() {
  constexpr unsigned kNumThreads = 4;
  constexpr unsigned kIterations = 6;

  std::vector<sqeType> sqes(kNumThreads);
  std::vector<cqeType> cqes(kNumThreads);
  for (unsigned t = 0; t < kNumThreads; ++t) {
    std::memset(&sqes[t], 0, sizeof(sqeType));
    std::memset(&cqes[t], 0, sizeof(cqeType));
  }

  auto threads = xio::test_ep::launchCpuThreads(
    sqes.data(), cqes.data(), kNumThreads, kIterations, /*delayNs=*/0,
    /*doorbell=*/0, /*doorbellAddr=*/nullptr, /*queueSize=*/0);
  ASSERT_EQ(threads.size(), kNumThreads);

  std::vector<std::thread> producers;
  std::atomic<unsigned> errorCount{0};
  for (unsigned t = 0; t < kNumThreads; ++t) {
    producers.emplace_back([&, t]() {
      uint64_t lastCpuTime = 0;
      for (unsigned i = 0; i < kIterations; ++i) {
        sqeType msg = {};
        msg.magic = magicId;
        msg.iteration = (static_cast<uint64_t>(t) << 32) | i;
        // gpuTime must change every iteration; offset by thread so
        // two threads never collide on the same value.
        msg.gpuTime = (static_cast<uint64_t>(t) << 24) | (0x1000 + i);
        msg.data[0] = 0;
        sqes[t] = msg;
        std::atomic_thread_fence(std::memory_order_release);

        cqeType resp = waitForCqe(&cqes[t], lastCpuTime);
        if (resp.magic != cqeMagicId || resp.cpuTime == lastCpuTime) {
          errorCount.fetch_add(1, std::memory_order_relaxed);
        }
        lastCpuTime = resp.cpuTime;
      }
    });
  }
  for (auto& p : producers) {
    p.join();
  }
  waitForThreads(threads);

  ASSERT_EQ(errorCount.load(), 0u);
  return 0;
}

// Doorbell-mode round trip.  One CPU thread services a shared
// circular SQ/CQ; the producer writes SQEs in submission order and
// rings the doorbell after each write.
int test_doorbell_round_trip() {
  constexpr unsigned kNumThreads = 1;
  constexpr unsigned kIterations = 8;
  constexpr unsigned kQueueSize = 16;

  std::vector<sqeType> sqes(kQueueSize);
  std::vector<cqeType> cqes(kQueueSize);
  for (unsigned i = 0; i < kQueueSize; ++i) {
    std::memset(&sqes[i], 0, sizeof(sqeType));
    std::memset(&cqes[i], 0, sizeof(cqeType));
  }
  // The CPU polling thread reads the doorbell with __atomic_load_n
  // on a volatile uint32_t*, so use a plain uint32_t and mirror
  // the production-side protocol with __atomic_store_n.
  alignas(4) uint32_t doorbell = 0;

  auto threads = xio::test_ep::launchCpuThreads(sqes.data(), cqes.data(),
                                                kNumThreads, kIterations,
                                                /*delayNs=*/0,
                                                /*doorbell=*/kQueueSize,
                                                /*doorbellAddr=*/&doorbell,
                                                /*queueSize=*/kQueueSize);
  ASSERT_EQ(threads.size(), 1u);

  for (unsigned i = 0; i < kIterations; ++i) {
    unsigned slot = i % kQueueSize;
    sqeType msg = {};
    msg.magic = magicId;
    msg.iteration = i;
    msg.gpuTime = 0x2000ULL + i;
    msg.data[0] = 0;
    sqes[slot] = msg;
    std::atomic_thread_fence(std::memory_order_release);
    __atomic_store_n(&doorbell, i + 1, __ATOMIC_RELEASE);

    // The CPU thread writes the CQE for seq=i into slot=i%kQueueSize.
    // The sequence number is encoded in the upper half of cpuTime.
    auto start = std::chrono::steady_clock::now();
    while (true) {
      uint64_t magic = cqes[slot].magic;
      uint64_t value = cqes[slot].cpuTime;
      if (magic == cqeMagicId && value != 0) {
        uint32_t cqeSeq = (value >> 32) & 0xFFFFFFFFu;
        ASSERT_EQ(cqeSeq, i);
        cqes[slot].cpuTime = 0;
        cqes[slot].magic = 0;
        break;
      }
      if (std::chrono::steady_clock::now() - start > kJoinTimeout) {
        printf("Timed out waiting for doorbell CQE i=%u\n", i);
        abort();
      }
      std::this_thread::yield();
    }
  }

  waitForThreads(threads);
  return 0;
}

// Fixed-delay round trip.  Exercises the slow path of the CPU
// polling thread that sleeps before emitting the CQE.
int test_fixed_delay_round_trip() {
  constexpr unsigned kIterations = 3;
  constexpr long long kDelayNs = -200000; // 200 us fixed delay

  sqeType sqe = {};
  cqeType cqe = {};

  auto threads = xio::test_ep::launchCpuThreads(&sqe, &cqe, /*numThreads=*/1,
                                                kIterations, kDelayNs,
                                                /*doorbell=*/0,
                                                /*doorbellAddr=*/nullptr,
                                                /*queueSize=*/0);
  ASSERT_EQ(threads.size(), 1u);

  uint64_t lastCpuTime = 0;
  for (unsigned i = 0; i < kIterations; ++i) {
    sqeType msg = {};
    msg.magic = magicId;
    msg.iteration = i;
    msg.gpuTime = 0x3000ULL + i;
    // `cpuThread` does not use the `launchCpuThreads()` delayNs argument for
    // the sleep path; it reads only `currentMsg.data[0]` as the per-SQE
    // delay in nanoseconds.  Set data[0] to 200000 (200 us) here so each SQE
    // explicitly carries the fixed delay the poller applies.
    msg.data[0] = 200000;
    sqe = msg;
    std::atomic_thread_fence(std::memory_order_release);

    cqeType resp = waitForCqe(&cqe, lastCpuTime);
    ASSERT_EQ(resp.magic, cqeMagicId);
    lastCpuTime = resp.cpuTime;
  }

  waitForThreads(threads);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_single_thread_round_trip();
  failures += test_multi_thread_round_trip();
  failures += test_doorbell_round_trip();
  failures += test_fixed_delay_round_trip();

  if (failures == 0) {
    printf("All test-ep launchCpuThreads tests passed.\n");
    return 0;
  }
  printf("%d test-ep launchCpuThreads test(s) failed.\n", failures);
  return 1;
}
