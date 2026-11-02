/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <hip/hip_runtime.h>

#include "endpoints/sdma-ep/sdma_device.hpp"

// Whether this build has the OSS7 fused COPY_LINEAR_WAIT_SIGNAL packet. The
// host and the kernel translation units must agree, so XIO_SDMA_OSS7 has to
// reach both.
#if XIO_SDMA_OSS7
inline constexpr bool kFusedSupported = true;
#else
inline constexpr bool kFusedSupported = false;
#endif

// Bytes of one fused command: header and copy, plus the wait block and the
// signal block when used.
__host__ __device__ inline size_t fusedCommandBytes(bool wait, bool signal) {
  return (7 + (wait ? 7 : 0) + (signal ? 5 : 0)) * sizeof(uint32_t);
}

enum class RateMode : uint32_t {
  Copy = 0,
  PollCopy,
  CopyAtomic,
  PollCopyAtomic,
  PollOnly,
  AtomicOnly
};

struct RateKernelArgs {
  xio::sdma_ep::SdmaQueueHandle** deviceHandles;
  void* srcBuf;
  void* dstBuf;
  uint64_t* signals;
  uint64_t** atomicTargets;
  uint32_t* pollFlag;
  int64_t* startClockCount;
  int64_t* endClockCount;
  size_t copySize;
  size_t numCommands;
  uint64_t expectedSignal;
  RateMode mode;
  bool fused; // one OSS7 fused packet per command instead of separate poll,
              // copy and atomic packets
};

__global__ void sdmaRateKernel(const RateKernelArgs args);
