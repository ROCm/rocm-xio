/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Flat device ABI for the XIO SDMA endpoint. Keep these functions scalar/raw
 * pointer only: consumers such as Triton declare them without C++ type info.
 */

#include <cstddef>
#include <cstdint>

#include "sdma_device.hpp"

using xio::sdma_ep::SdmaQueueHandle;

__device__ __forceinline__ bool xio_is_lane_zero() {
  return __lane_id() == 0;
}

extern "C" __device__ __attribute__((used)) void xio_sdma_put(
  void* queue_handle, void* dst, const void* src, size_t size) {
  if (!xio_is_lane_zero())
    return;
  const auto* handle = reinterpret_cast<const SdmaQueueHandle*>(queue_handle);
  xio::sdma_ep::put(*handle, dst, const_cast<void*>(src), size);
}

extern "C" __device__ __attribute__((used)) void xio_sdma_put_tile(
  void* queue_handle, void* dst, const void* src, uint32_t tile_width,
  uint32_t tile_height, uint32_t src_pitch, uint32_t dst_pitch, uint32_t src_x,
  uint32_t src_y, uint32_t dst_x, uint32_t dst_y) {
  if (!xio_is_lane_zero())
    return;
  const auto* handle = reinterpret_cast<const SdmaQueueHandle*>(queue_handle);
  xio::sdma_ep::putTile(*handle, dst, const_cast<void*>(src), tile_width,
                        tile_height, src_pitch, dst_pitch, src_x, src_y, dst_x,
                        dst_y);
}

extern "C" __device__ __attribute__((used)) void xio_sdma_put_signal(
  void* queue_handle, void* dst, const void* src, size_t size,
  uint64_t* signal) {
  if (!xio_is_lane_zero())
    return;
  const auto* handle = reinterpret_cast<const SdmaQueueHandle*>(queue_handle);
  xio::sdma_ep::putSignal(*handle, dst, const_cast<void*>(src), size, signal);
}

extern "C" __device__ __attribute__((used)) void xio_sdma_put_signal_counter(
  void* queue_handle, void* dst, const void* src, size_t size, uint64_t* signal,
  uint64_t* counter) {
  if (!xio_is_lane_zero())
    return;
  const auto* handle = reinterpret_cast<const SdmaQueueHandle*>(queue_handle);
  xio::sdma_ep::putSignalCounter(*handle, dst, const_cast<void*>(src), size,
                                 signal, counter);
}

extern "C" __device__ __attribute__((used)) void xio_sdma_put_counter(
  void* queue_handle, void* dst, const void* src, size_t size,
  uint64_t* counter) {
  if (!xio_is_lane_zero())
    return;
  const auto* handle = reinterpret_cast<const SdmaQueueHandle*>(queue_handle);
  xio::sdma_ep::putCounter(*handle, dst, const_cast<void*>(src), size, counter);
}

extern "C" __device__ __attribute__((used)) void xio_sdma_signal(
  void* queue_handle, uint64_t* signal) {
  if (!xio_is_lane_zero())
    return;
  const auto* handle = reinterpret_cast<const SdmaQueueHandle*>(queue_handle);
  xio::sdma_ep::signal(*handle, signal);
}

extern "C" __device__ __attribute__((used)) void xio_sdma_signal_counter(
  void* queue_handle, uint64_t* signal, uint64_t* counter) {
  if (!xio_is_lane_zero())
    return;
  const auto* handle = reinterpret_cast<const SdmaQueueHandle*>(queue_handle);
  xio::sdma_ep::signalCounter(*handle, signal, counter);
}

extern "C" __device__ __attribute__((used)) void xio_sdma_poll_until_ge(
  uint64_t* address, uint64_t expected) {
  if (!xio_is_lane_zero())
    return;
  xio::sdma_ep::poll_until_ge(address, expected);
}

extern "C" __device__ __attribute__((used)) void xio_sdma_quiet(
  void* queue_handle) {
  if (!xio_is_lane_zero())
    return;
  const auto* handle = reinterpret_cast<const SdmaQueueHandle*>(queue_handle);
  xio::sdma_ep::quiet(*handle);
}
