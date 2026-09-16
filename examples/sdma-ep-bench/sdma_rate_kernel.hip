/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "sdma_rate_kernel.h"

__global__ void packetRateKernel(void* srcBuf, void* dstBuf, size_t copySize,
                                 size_t numCopyCommands,
                                 xio::sdma_ep::SdmaQueueHandle** deviceHandles,
                                 uint64_t* signals, uint64_t expectedSignal,
                                 int64_t* startClockCount,
                                 int64_t* endClockCount, uint64_t* sdmaStart,
                                 uint64_t* sdmaEnd, uint32_t* pollFlag,
                                 uint64_t** atomicTargets, bool copyAtomic) {
  const int warpId = threadIdx.x / warpSize;
  const int laneId = threadIdx.x % warpSize;
  const size_t totalSize = copySize * numCopyCommands;
  const size_t offset = warpId * totalSize;
  uint64_t* signal = signals + warpId;

  if (laneId != 0)
    return;

  xio::sdma_ep::SdmaQueueHandle handle = *deviceHandles[warpId];
  xio::sdma_ep::SdmaQueueState state;
  state.init(handle);

  char* src = static_cast<char*>(srcBuf) + offset;
  char* dst = static_cast<char*>(dstBuf) + offset;
  uint64_t firstBase = 0;
  uint64_t pendingWptr = 0;
  bool hasPacket = false;

  if (sdmaStart) {
    uint64_t padding = 0;
    uint64_t base = handle.ReserveQueueSpace(sizeof(SDMA_PKT_TIMESTAMP),
                                             padding, &state);
    firstBase = base;
    hasPacket = true;
    pendingWptr = base;
    auto packet = xio::sdma_ep::CreateTimestampPacket(sdmaStart + warpId);
    handle.placePacket(packet, pendingWptr, padding);
  }

  for (size_t command = 0; command < numCopyCommands; ++command) {
    if (pollFlag) {
      uint64_t padding = 0;
      uint64_t base = handle.ReserveQueueSpace(sizeof(SDMA_PKT_POLL_REGMEM),
                                               padding, &state);
      if (!hasPacket) {
        firstBase = base;
        hasPacket = true;
      }
      pendingWptr = base;
      auto poll = xio::sdma_ep::CreatePollPacket(pollFlag);
      handle.placePacket(poll, pendingWptr, padding);
    }
    uint64_t padding = 0;
    uint64_t base = handle.ReserveQueueSpace(sizeof(SDMA_PKT_COPY_LINEAR),
                                             padding, &state);
    if (!hasPacket) {
      firstBase = base;
      hasPacket = true;
    }
    pendingWptr = base;
    auto packet = xio::sdma_ep::CreateCopyPacket(src, dst, copySize);
    handle.placePacket(packet, pendingWptr, padding);
    if (copyAtomic) {
      uint64_t atomicPadding = 0;
      uint64_t atomicBase = handle.ReserveQueueSpace(sizeof(SDMA_PKT_ATOMIC),
                                                     atomicPadding, &state);
      pendingWptr = atomicBase;
      auto atomicPacket = xio::sdma_ep::CreateAtomicIncPacket(
        atomicTargets[warpId]);
      handle.placePacket(atomicPacket, pendingWptr, atomicPadding);
    }
    src += copySize;
    dst += copySize;
  }

  if (sdmaEnd) {
    uint64_t padding = 0;
    uint64_t base = handle.ReserveQueueSpace(sizeof(SDMA_PKT_TIMESTAMP),
                                             padding, &state);
    pendingWptr = base;
    auto packet = xio::sdma_ep::CreateTimestampPacket(sdmaEnd + warpId);
    handle.placePacket(packet, pendingWptr, padding);
  }

  uint64_t padding = 0;
  uint64_t base = handle.ReserveQueueSpace(sizeof(SDMA_PKT_ATOMIC), padding,
                                           &state);
  pendingWptr = base;
  auto signalPacket = xio::sdma_ep::CreateAtomicIncPacket(signal);
  handle.placePacket(signalPacket, pendingWptr, padding);

  startClockCount[warpId] = wall_clock64();
  handle.submitPacket(firstBase, pendingWptr, &state);
  xio::sdma_ep::waitSignal(signal, expectedSignal);
  endClockCount[warpId] = wall_clock64();
}

__global__ void triggeredPacketRateKernel(uint32_t* trigger, uint64_t* signals,
                                          uint64_t expectedSignal,
                                          int64_t* startClockCount,
                                          int64_t* endClockCount) {
  const int warpId = threadIdx.x / warpSize;
  const int laneId = threadIdx.x % warpSize;
  uint64_t* signal = signals + warpId;

  if (laneId != 0)
    return;

  startClockCount[warpId] = wall_clock64();
  if (warpId == 0) {
    __hip_atomic_store(trigger, 1, __ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_AGENT);
  }
  xio::sdma_ep::waitSignal(signal, expectedSignal);
  endClockCount[warpId] = wall_clock64();
}

__global__ void pollOnlyRateKernel(xio::sdma_ep::SdmaQueueHandle** handles,
                                   uint32_t* pollFlag, uint64_t* completion,
                                   size_t count, uint64_t expectedSignal,
                                   int64_t* startClockCount,
                                   int64_t* endClockCount) {
  if (threadIdx.x % warpSize != 0)
    return;
  int warpId = threadIdx.x / warpSize;
  auto handle = *handles[warpId];
  xio::sdma_ep::SdmaQueueState state;
  state.init(handle);
  uint64_t firstBase = 0;
  uint64_t pending = 0;
  for (size_t i = 0; i < count; ++i) {
    uint64_t padding = 0;
    uint64_t base = handle.ReserveQueueSpace(sizeof(SDMA_PKT_POLL_REGMEM),
                                             padding, &state);
    if (i == 0)
      firstBase = base;
    pending = base;
    auto packet = xio::sdma_ep::CreatePollPacket(pollFlag);
    handle.placePacket(packet, pending, padding);
  }
  uint64_t padding = 0;
  uint64_t base = handle.ReserveQueueSpace(sizeof(SDMA_PKT_ATOMIC), padding,
                                           &state);
  pending = base;
  auto packet = xio::sdma_ep::CreateAtomicIncPacket(completion + warpId);
  handle.placePacket(packet, pending, padding);
  startClockCount[warpId] = wall_clock64();
  handle.submitPacket(firstBase, pending, &state);
  xio::sdma_ep::waitSignal(completion + warpId, expectedSignal);
  endClockCount[warpId] = wall_clock64();
}

__global__ void atomicOnlyRateKernel(xio::sdma_ep::SdmaQueueHandle** handles,
                                     uint64_t** targets, size_t count,
                                     uint64_t expectedSignal,
                                     int64_t* startClockCount,
                                     int64_t* endClockCount) {
  if (threadIdx.x % warpSize != 0)
    return;
  int warpId = threadIdx.x / warpSize;
  auto handle = *handles[warpId];
  uint64_t* target = targets[warpId];
  xio::sdma_ep::SdmaQueueState state;
  state.init(handle);
  uint64_t firstBase = 0;
  uint64_t pending = 0;
  for (size_t i = 0; i < count; ++i) {
    uint64_t padding = 0;
    uint64_t base = handle.ReserveQueueSpace(sizeof(SDMA_PKT_ATOMIC), padding,
                                             &state);
    if (i == 0)
      firstBase = base;
    pending = base;
    auto packet = xio::sdma_ep::CreateAtomicIncPacket(target);
    handle.placePacket(packet, pending, padding);
  }
  startClockCount[warpId] = wall_clock64();
  handle.submitPacket(firstBase, pending, &state);
  xio::sdma_ep::waitSignal(target, expectedSignal);
  endClockCount[warpId] = wall_clock64();
}
