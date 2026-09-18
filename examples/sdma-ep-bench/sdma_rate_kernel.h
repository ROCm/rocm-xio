/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <hip/hip_runtime.h>

#include "endpoints/sdma-ep/sdma_device.hpp"

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
};

__global__ void sdmaRateKernel(const RateKernelArgs args);
