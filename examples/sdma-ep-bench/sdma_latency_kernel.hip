/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "sdma_latency_kernel.h"

__global__ void sdmaLatencyKernel(void* src, void* dst, size_t copySize,
                                  size_t numCopyCommands,
                                  xio::sdma_ep::SdmaQueueHandle** handles,
                                  uint64_t* signal, uint64_t expectedSignal,
                                  int64_t* start, int64_t* end,
                                  LatencyBreakdown* breakdown, bool fineGrained,
                                  bool useQueueState) {
  if (threadIdx.x != 0)
    return;

  xio::sdma_ep::SdmaQueueHandle handle = *handles[0];
  xio::sdma_ep::SdmaQueueState state;
  if (useQueueState)
    state.init(handle);
  char* srcPtr = static_cast<char*>(src);
  char* dstPtr = static_cast<char*>(dst);
  uint64_t pendingWptr = 0;

  start[0] = wall_clock64();
  for (size_t command = 0; command < numCopyCommands; ++command) {
    uint64_t padding = 0;
    int64_t reserveStart = wall_clock64();
    uint64_t base = handle.ReserveQueueSpace(sizeof(SDMA_PKT_COPY_LINEAR),
                                             padding,
                                             useQueueState ? &state : nullptr);
    int64_t reserveEnd = wall_clock64();
    pendingWptr = base;
    int64_t buildStart = wall_clock64();
    auto packet = xio::sdma_ep::CreateCopyPacket(srcPtr, dstPtr, copySize);
    handle.placePacket(packet, pendingWptr, padding);
    int64_t buildEnd = wall_clock64();
    int64_t submitStart = wall_clock64();
    handle.submitPacket(base, pendingWptr, useQueueState ? &state : nullptr);
    int64_t submitEnd = wall_clock64();

    if (fineGrained) {
      breakdown->reserveStart[command] = reserveStart;
      breakdown->reserveEnd[command] = reserveEnd;
      breakdown->buildStart[command] = buildStart;
      breakdown->buildEnd[command] = buildEnd;
      breakdown->submitStart[command] = submitStart;
      breakdown->submitEnd[command] = submitEnd;
    }
    srcPtr += copySize;
    dstPtr += copySize;
  }

  uint64_t padding = 0;
  int64_t atomicReserveStart = wall_clock64();
  uint64_t base = handle.ReserveQueueSpace(sizeof(SDMA_PKT_ATOMIC), padding,
                                           useQueueState ? &state : nullptr);
  int64_t atomicReserveEnd = wall_clock64();
  pendingWptr = base;
  int64_t atomicBuildStart = wall_clock64();
  auto signalPacket = xio::sdma_ep::CreateAtomicIncPacket(signal);
  handle.placePacket(signalPacket, pendingWptr, padding);
  int64_t atomicBuildEnd = wall_clock64();
  int64_t atomicSubmitStart = wall_clock64();
  handle.submitPacket(base, pendingWptr, useQueueState ? &state : nullptr);
  int64_t atomicSubmitEnd = wall_clock64();
  if (fineGrained) {
    breakdown->atomicReserveStart[0] = atomicReserveStart;
    breakdown->atomicReserveEnd[0] = atomicReserveEnd;
    breakdown->atomicBuildStart[0] = atomicBuildStart;
    breakdown->atomicBuildEnd[0] = atomicBuildEnd;
    breakdown->atomicSubmitStart[0] = atomicSubmitStart;
    breakdown->atomicSubmitEnd[0] = atomicSubmitEnd;
  }
  if (fineGrained)
    breakdown->transferStart[0] = wall_clock64();
  xio::sdma_ep::waitSignal(signal, expectedSignal);
  end[0] = wall_clock64();
  if (fineGrained)
    breakdown->transferEnd[0] = end[0];
}
