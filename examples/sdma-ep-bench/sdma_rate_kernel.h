/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <hip/hip_runtime.h>

#include "endpoints/sdma-ep/sdma_device.hpp"

__global__ void packetRateKernel(void* srcBuf, void* dstBuf, size_t copySize,
                                 size_t numCopyCommands,
                                 xio::sdma_ep::SdmaQueueHandle** deviceHandles,
                                 uint64_t* signals, uint64_t expectedSignal,
                                 int64_t* startClockCount,
                                 int64_t* endClockCount, uint64_t* sdmaStart,
                                 uint64_t* sdmaEnd, uint32_t* pollFlag,
                                 uint64_t** atomicTargets, bool copyAtomic);

__global__ void triggeredPacketRateKernel(uint32_t* trigger, uint64_t* signals,
                                          uint64_t expectedSignal,
                                          int64_t* startClockCount,
                                          int64_t* endClockCount);

__global__ void pollOnlyRateKernel(xio::sdma_ep::SdmaQueueHandle** handles,
                                   uint32_t* pollFlag, uint64_t* completion,
                                   size_t count, uint64_t expectedSignal,
                                   int64_t* startClockCount,
                                   int64_t* endClockCount);

__global__ void atomicOnlyRateKernel(xio::sdma_ep::SdmaQueueHandle** handles,
                                     uint64_t** targets, size_t count,
                                     uint64_t expectedSignal,
                                     int64_t* startClockCount,
                                     int64_t* endClockCount);
