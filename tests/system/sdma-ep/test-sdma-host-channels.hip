/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * System test: host-initiated SDMA channels.
 *
 * Checks the channel bookkeeping of initHostQueue()/getHostChannelCount()
 * and that channels are independent: a copy that waits on a flag, parked on
 * channel 0, must not hold back a copy on channel 1 of the same GPU pair.
 *
 * Needs two GPUs with peer access and /dev/kfd (run as root). Skips
 * (exit code 77) otherwise.
 */

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <thread>
#include <vector>

#include <hip/hip_ext.h>
#include <hip/hip_runtime.h>

#include "sdma-ep.h"
#include "sdma-host-queue.h"
#include "xio.h"

using namespace xio;

static constexpr int SRC_GPU = 0;
static constexpr int DST_GPU = 1;
static constexpr size_t SIZE = 4096;
static constexpr int INDEPENDENCE_TIMEOUT_MS = 5000;

static int g_failures = 0;

#define CHECK(cond, msg)                                                       \
  do {                                                                         \
    if (!(cond)) {                                                             \
      fprintf(stderr, "FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__);          \
      ++g_failures;                                                            \
    }                                                                          \
  } while (0)

static bool bufferIs(const void* devPtr, uint8_t value) {
  std::vector<uint8_t> host(SIZE);
  HIP_CHECK(hipMemcpy(host.data(), devPtr, SIZE, hipMemcpyDeviceToHost));
  for (size_t i = 0; i < SIZE; ++i) {
    if (host[i] != value) {
      return false;
    }
  }
  return true;
}

static void testChannelCounts() {
  CHECK(sdma_ep::getHostChannelCount(SRC_GPU, DST_GPU) == 0,
        "no host channels before any host queue is created");

  CHECK(sdma_ep::initHostQueue(SRC_GPU, DST_GPU, 0) < 0,
        "numChannels == 0 is rejected");
  CHECK(sdma_ep::initHostQueue(SRC_GPU, DST_GPU, -1) < 0,
        "negative numChannels is rejected");
  CHECK(sdma_ep::getHostChannelCount(SRC_GPU, DST_GPU) == 0,
        "a rejected request creates nothing");

  CHECK(sdma_ep::initHostQueue(SRC_GPU, DST_GPU) == 0,
        "two-argument initHostQueue succeeds");
  CHECK(sdma_ep::getHostChannelCount(SRC_GPU, DST_GPU) == 1,
        "two-argument initHostQueue creates one channel");

  CHECK(sdma_ep::initHostQueue(SRC_GPU, DST_GPU, 3) == 0,
        "growing to 3 channels succeeds");
  CHECK(sdma_ep::getHostChannelCount(SRC_GPU, DST_GPU) == 3,
        "pair has 3 channels");

  CHECK(sdma_ep::initHostQueue(SRC_GPU, DST_GPU, 3) == 0,
        "asking for the same count again succeeds");
  CHECK(sdma_ep::getHostChannelCount(SRC_GPU, DST_GPU) == 3,
        "asking for the same count again creates nothing");

  CHECK(sdma_ep::initHostQueue(SRC_GPU, DST_GPU, 2) == 0,
        "asking for fewer channels succeeds");
  CHECK(sdma_ep::getHostChannelCount(SRC_GPU, DST_GPU) == 3,
        "channels are never removed");

  CHECK(sdma_ep::getHostChannelCount(DST_GPU, SRC_GPU) == 0,
        "the reverse direction is a different pair");

  bool threw = false;
  try {
    (void)sdma_ep::getHostHandle(SRC_GPU, DST_GPU, 2);
  } catch (const std::exception&) {
    threw = true;
  }
  CHECK(!threw, "the last channel has a handle");

  threw = false;
  try {
    (void)sdma_ep::getHostHandle(SRC_GPU, DST_GPU, 3);
  } catch (const std::runtime_error&) {
    threw = true;
  }
  CHECK(threw, "a channel past the count has no handle");
}

// A copy that waits on a flag parks channel 0. A copy on channel 1 must still
// complete; the parked copy must run once the flag is set.
static void testChannelsAreIndependent() {
  HIP_CHECK(hipSetDevice(SRC_GPU));
  uint8_t *srcA = nullptr, *srcB = nullptr;
  HIP_CHECK(hipMalloc(&srcA, SIZE));
  HIP_CHECK(hipMalloc(&srcB, SIZE));
  HIP_CHECK(hipMemset(srcA, 0xAA, SIZE));
  HIP_CHECK(hipMemset(srcB, 0xBB, SIZE));
  uint32_t* flag = nullptr;
  HIP_CHECK(hipExtMallocWithFlags(reinterpret_cast<void**>(&flag),
                                  sizeof(uint32_t), hipDeviceMallocUncached));
  HIP_CHECK(hipMemset(flag, 0, sizeof(uint32_t)));

  HIP_CHECK(hipSetDevice(DST_GPU));
  uint8_t *dstA = nullptr, *dstB = nullptr;
  HIP_CHECK(hipMalloc(&dstA, SIZE));
  HIP_CHECK(hipMalloc(&dstB, SIZE));
  HIP_CHECK(hipMemset(dstA, 0x00, SIZE));
  HIP_CHECK(hipMemset(dstB, 0x00, SIZE));
  HIP_CHECK(hipDeviceSynchronize());

  auto channel0 = sdma_ep::getHostHandle(SRC_GPU, DST_GPU, 0);
  auto channel1 = sdma_ep::getHostHandle(SRC_GPU, DST_GPU, 1);

  // Channel 0 parks until *flag == 1; channel 1 copies immediately
  channel0.wait_flag_then_put<uint32_t>(flag, 1u, dstA, srcA, SIZE);
  channel1.put(dstB, srcB, SIZE);

  bool channel1Done = false;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(INDEPENDENCE_TIMEOUT_MS);
  while (std::chrono::steady_clock::now() < deadline) {
    if (bufferIs(dstB, 0xBB)) {
      channel1Done = true;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  CHECK(channel1Done,
        "copy on channel 1 completed while channel 0 waits on a flag");
  CHECK(bufferIs(dstA, 0x00), "the copy parked on channel 0 has not run yet");

  // Release channel 0 whatever happened above, so the queues drain
  const uint32_t one = 1;
  HIP_CHECK(hipMemcpy(flag, &one, sizeof(one), hipMemcpyHostToDevice));
  channel0.quiet();
  channel1.quiet();
  CHECK(bufferIs(dstA, 0xAA), "the parked copy ran after the flag was set");
  CHECK(bufferIs(dstB, 0xBB), "channel 1 data is intact");

  HIP_CHECK(hipFree(dstA));
  HIP_CHECK(hipFree(dstB));
  HIP_CHECK(hipSetDevice(SRC_GPU));
  HIP_CHECK(hipFree(srcA));
  HIP_CHECK(hipFree(srcB));
  HIP_CHECK(hipFree(flag));
}

int main() {
  int deviceCount = 0;
  HIP_CHECK(hipGetDeviceCount(&deviceCount));
  if (deviceCount < 2) {
    printf("SKIP: need >= 2 GPUs, found %d\n", deviceCount);
    return 77;
  }
  int canAccess = 0;
  HIP_CHECK(hipDeviceCanAccessPeer(&canAccess, SRC_GPU, DST_GPU));
  if (!canAccess) {
    printf("SKIP: GPU %d cannot access GPU %d\n", SRC_GPU, DST_GPU);
    return 77;
  }

  if (sdma_ep::initEndpoint() != 0) {
    printf("SKIP: SDMA endpoint unavailable (needs /dev/kfd access)\n");
    return 77;
  }
  xio::enablePeerAccess(SRC_GPU, DST_GPU);

  testChannelCounts();
  if (g_failures == 0) {
    testChannelsAreIndependent();
  }

  sdma_ep::shutdownEndpoint();
  if (g_failures != 0) {
    fprintf(stderr, "%d check(s) failed\n", g_failures);
    return 1;
  }
  printf("PASS: host channel counts and independence\n");
  return 0;
}
