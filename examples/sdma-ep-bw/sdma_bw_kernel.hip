/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "sdma_bw_kernel.h"

__global__ void multiQueueSDMATransferQueueMapWG(
  size_t iteration_id, void* srcBuf, void** dstBufs, size_t copy_size,
  size_t numCopyCommands, int numOfDestinations, int numOfQueues,
  int numOfWGPerQueue, xio::sdma_ep::SdmaQueueHandle** deviceHandle,
  uint64_t* signals, uint64_t expectedSignal, int64_t* start_clock_count,
  int64_t* end_clock_count) {
  const int warpId = threadIdx.x / warpSize;
  const int laneId = threadIdx.x % warpSize;
  const int nWarps = blockDim.x / warpSize;

  const int numOfWGPerDst = numOfWGPerQueue * numOfQueues;
  const int blockIdWithInDst = blockIdx.x % numOfWGPerDst;

  const int queueSelector = blockIdWithInDst / numOfWGPerQueue;
  const int dstIdx = blockIdx.x % numOfDestinations;
  const int queueIdx = (dstIdx * numOfQueues) + queueSelector;

  const size_t total_size = copy_size * numCopyCommands;
  const size_t offset = ((blockIdWithInDst * nWarps) + warpId) * total_size;

  xio::sdma_ep::SdmaQueueHandle handle = *deviceHandle[queueIdx];

  char* srcPtr = reinterpret_cast<char*>(srcBuf) + offset;
  char* dstPtr = reinterpret_cast<char*>(dstBufs[dstIdx]) + offset;

  const int signalIdx = blockIdx.x * nWarps + warpId;
  uint64_t* signal = signals + signalIdx;

  if (laneId == 0) {
    start_clock_count[signalIdx] = wall_clock64();
  }

  for (size_t c = 0; c < numCopyCommands; ++c) {
    if (laneId == 0) {
      xio::sdma_ep::put(handle, dstPtr, srcPtr, copy_size);
    }
    srcPtr += copy_size;
    dstPtr += copy_size;
  }

  if (laneId == 0) {
    xio::sdma_ep::signal(handle, signal);
  }

  if (laneId == 0) {
    xio::sdma_ep::waitSignal(signal, expectedSignal);
    end_clock_count[signalIdx] = wall_clock64();
  }

  return;
}
