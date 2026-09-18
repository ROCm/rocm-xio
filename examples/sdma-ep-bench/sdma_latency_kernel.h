/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <hip/hip_runtime.h>

#include "endpoints/sdma-ep/sdma_device.hpp"

struct LatencyBreakdown {
  int64_t* reserveStart;
  int64_t* reserveEnd;
  int64_t* buildStart;
  int64_t* buildEnd;
  int64_t* submitStart;
  int64_t* submitEnd;
  int64_t* atomicReserveStart;
  int64_t* atomicReserveEnd;
  int64_t* atomicBuildStart;
  int64_t* atomicBuildEnd;
  int64_t* atomicSubmitStart;
  int64_t* atomicSubmitEnd;
  int64_t* transferStart;
  int64_t* transferEnd;
};

template <bool TIMESTAMPING_EN>
__global__ void sdmaLatencyKernel(void* src, void* dst, size_t copySize,
                                  size_t numCopyCommands,
                                  xio::sdma_ep::SdmaQueueHandle** handles,
                                  uint64_t* signal, uint64_t expectedSignal,
                                  int64_t* start, int64_t* end,
                                  LatencyBreakdown* breakdown,
                                  bool useQueueState);
