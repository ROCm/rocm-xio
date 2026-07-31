/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef SDMA_BW_KERNEL_H
#define SDMA_BW_KERNEL_H

#include <cstdint>

#include <hip/hip_runtime.h>

#include "endpoints/sdma-ep/sdma_device.hpp"

__global__ void multiQueueSDMATransferQueueMapWG(
  size_t iteration_id, void* srcBuf, void** dstBufs, size_t copy_size,
  size_t numCopyCommands, int numOfDestinations, int numOfQueues,
  int numOfWGPerQueue, xio::sdma_ep::SdmaQueueHandle** deviceHandle,
  uint64_t* signals, uint64_t expectedSignal, int64_t* start_clock_count,
  int64_t* end_clock_count);

#endif // SDMA_BW_KERNEL_H
