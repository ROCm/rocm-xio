/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "sdma_rate_kernel.h"

__global__ void sdmaRateKernel(const RateKernelArgs args) {
  const int warpId = threadIdx.x / warpSize;
  const int laneId = threadIdx.x % warpSize;
  const size_t totalSize = args.copySize * args.numCommands;
  const size_t offset = warpId * totalSize;
  uint64_t* signal = args.signals + warpId;

  if (laneId != 0)
    return;

  xio::sdma_ep::SdmaQueueHandle handle = *args.deviceHandles[warpId];
  xio::sdma_ep::SdmaQueueState state;
  state.init(handle);

  char* src = static_cast<char*>(args.srcBuf) + offset;
  char* dst = static_cast<char*>(args.dstBuf) + offset;
  uint64_t firstBase = 0;
  uint64_t pendingWptr = 0;
  bool hasPacket = false;

  const bool hasPoll = args.mode == RateMode::PollCopy ||
                       args.mode == RateMode::PollCopyAtomic ||
                       args.mode == RateMode::PollOnly;
  const bool hasCopy = args.mode == RateMode::Copy ||
                       args.mode == RateMode::PollCopy ||
                       args.mode == RateMode::CopyAtomic ||
                       args.mode == RateMode::PollCopyAtomic;
  const bool hasAtomic = args.mode == RateMode::CopyAtomic ||
                         args.mode == RateMode::PollCopyAtomic ||
                         args.mode == RateMode::AtomicOnly;

  const bool fusedCommand = kFusedSupported && args.fused && hasCopy;

  size_t commandBytes = 0;
  if (fusedCommand) {
    commandBytes = fusedCommandBytes(hasPoll, hasAtomic);
  } else {
    if (hasPoll) {
      commandBytes += sizeof(SDMA_PKT_POLL_REGMEM);
    }
    if (hasCopy) {
      commandBytes += sizeof(SDMA_PKT_COPY_LINEAR);
    }
    if (hasAtomic) {
      commandBytes += sizeof(SDMA_PKT_ATOMIC);
    }
  }

  for (size_t c = 0; c < args.numCommands; ++c) {
    uint64_t padding = 0;
    uint64_t base = handle.ReserveQueueSpace(commandBytes, padding, &state);
    if (c == 0) {
      firstBase = base;
    }
    pendingWptr = base;

    if (fusedCommand) {
#if XIO_SDMA_OSS7
      // One packet: wait until the flag reaches 1, copy, then add 1 to the target.
      auto packet = xio::sdma_ep::CreateCopyWaitSignalPacketMI4(
        src, dst, static_cast<long long>(args.copySize),
        hasAtomic ? args.atomicTargets[warpId] : nullptr, 1, hasPoll,
        hasPoll ? reinterpret_cast<uint64_t*>(args.pollFlag) : nullptr, 1,
        ~0ull);
      uint32_t dwords[19];
      const uint32_t numDwords =
        xio::sdma_ep::CompactCopyWaitSignalMI4(packet, dwords);
      handle.placeDwords(dwords, numDwords, pendingWptr, padding);
      padding = 0;
#endif
    } else {
      if (hasPoll) {
        auto packet = xio::sdma_ep::CreatePollPacket(args.pollFlag);
        handle.placePacket(packet, pendingWptr, padding);
        padding = 0;
      }

      if (hasCopy) {
        auto packet = xio::sdma_ep::CreateCopyPacket(src, dst, args.copySize);
        handle.placePacket(packet, pendingWptr, padding);
        padding = 0;
      }
      if (hasAtomic) {
        auto packet = xio::sdma_ep::CreateAtomicIncPacket(
          args.atomicTargets[warpId]);
        handle.placePacket(packet, pendingWptr, padding);
      }
    }

    src += args.copySize;
    dst += args.copySize;
  }

  {
    uint64_t padding = 0;
    uint64_t base = handle.ReserveQueueSpace(sizeof(SDMA_PKT_ATOMIC), padding,
                                             &state);
    pendingWptr = base;
    auto packet = xio::sdma_ep::CreateAtomicIncPacket(signal);
    handle.placePacket(packet, pendingWptr, padding);
  }

  args.startClockCount[warpId] = wall_clock64();
  handle.submitPacket(firstBase, pendingWptr, &state);
  xio::sdma_ep::waitSignal(signal, args.expectedSignal);
  args.endClockCount[warpId] = wall_clock64();
}
