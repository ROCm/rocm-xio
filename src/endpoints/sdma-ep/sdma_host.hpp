/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * SDMA Endpoint Host Runtime API
 *
 * Declares the host-side connection and queue management
 * helpers used to set up SDMA engines for GPU-initiated
 * transfers.
 */

#pragma once

#include <cstdint>

#include <hip/hip_runtime.h>

namespace sdma_ep {

/**
 * @brief Information about an established SDMA connection.
 *
 * Returned by createConnection(). Contains the resolved
 * SDMA engine ID for the GPU pair, which is determined by
 * the XGMI/Infinity Fabric topology (MI300X OAM map).
 */
struct SdmaConnectionInfo {
  int srcDeviceId;   /**< Source HIP device ID. */
  int dstDeviceId;   /**< Destination HIP device ID. */
  uint32_t engineId; /**< XGMI-optimal SDMA engine ID
                          for this GPU pair. */
};

/**
 * @brief Information about a created SDMA queue.
 *
 * Returned by createQueue(). The deviceHandle pointer
 * is GPU-accessible and should be passed to GPU kernels
 * that use the device-side SDMA operations (put, signal,
 * waitSignal, flush, quiet).
 */
struct SdmaQueueInfo {
  void* deviceHandle; /**< GPU-accessible pointer to a
                           SdmaQueueHandle. Cast to
                           SdmaQueueHandle* in kernel
                           code. */
  int srcDeviceId;    /**< Source HIP device ID. */
  int dstDeviceId;    /**< Destination HIP device ID. */
  int channelIdx;     /**< Channel index within the
                           connection (0-based). */
};

/* ================================================================
 * Host-Side Setup Functions
 * ================================================================ */

__host__ int initEndpoint();
__host__ void shutdownEndpoint();
__host__ int createConnection(int srcDeviceId, int dstDeviceId,
                              SdmaConnectionInfo* info);
__host__ int createQueue(int srcDeviceId, int dstDeviceId, SdmaQueueInfo* info);
__host__ int createHostQueue(int srcDeviceId, int dstDeviceId, SdmaQueueInfo* info);
__host__ void destroyQueue(SdmaQueueInfo* info);

/* ================================================================
 * Host-Side Data Transfer Operations
 * ================================================================ */

__host__ void put_signal(int srcDeviceId, int dstDeviceId, int channelIdx,
                         void* src, void* dst, size_t size,
                         void* flag_ptr, uint64_t flag_value, int flag_bits = 64);
__host__ void quiet(int srcDeviceId, int dstDeviceId, int channelIdx);

} // namespace sdma_ep

