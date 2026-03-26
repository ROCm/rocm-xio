#pragma once

/* Backward-compatibility shim.
 *
 * All public types and device-side operations have moved
 * to sdma-ep.h under namespace sdma_ep. This header
 * provides anvil:: aliases so existing internal code
 * (sdma-ep.hip, anvil.hip) compiles without changes.
 */

#include "hsakmt/hsakmt.h"
#include "hsakmt/hsakmttypes.h"
#include "sdma-ep.h"

namespace anvil {

constexpr uint64_t SDMA_QUEUE_SIZE = sdma_ep::SDMA_QUEUE_SIZE;
constexpr HSA_QUEUE_PRIORITY DEFAULT_PRIORITY = HSA_QUEUE_PRIORITY_NORMAL;
constexpr unsigned int DEFAULT_QUEUE_PERCENTAGE = 100;
constexpr int MAX_RETRIES = sdma_ep::MAX_RETRIES;
constexpr bool BREAK_ON_RETRIES = sdma_ep::BREAK_ON_RETRIES;

using SdmaQueueDeviceHandle = sdma_ep::SdmaQueueHandle;
using SdmaQueueSingleProducerDeviceHandle =
  sdma_ep::SdmaQueueSingleProducerHandle;

__device__ __forceinline__ SDMA_PKT_COPY_LINEAR
CreateCopyPacket(void* srcBuf, void* dstBuf, long long int packetSize) {
  return sdma_ep::CreateCopyPacket(srcBuf, dstBuf, packetSize);
}

__device__ __forceinline__ SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY
CreateLargeSubWindowCopyPacket(void* srcBuf, void* dstBuf, uint32_t tile_width,
                               uint32_t tile_height, uint32_t src_buffer_pitch,
                               uint32_t dst_buffer_pitch, uint32_t src_x,
                               uint32_t src_y, uint32_t dst_x, uint32_t dst_y) {
  return sdma_ep::CreateLargeSubWindowCopyPacket(srcBuf, dstBuf, tile_width,
                                                 tile_height, src_buffer_pitch,
                                                 dst_buffer_pitch, src_x, src_y,
                                                 dst_x, dst_y);
}

__device__ __forceinline__ SDMA_PKT_ATOMIC
CreateAtomicIncPacket(HSAuint64* signal) {
  return sdma_ep::CreateAtomicIncPacket(reinterpret_cast<uint64_t*>(signal));
}

__device__ __forceinline__ SDMA_PKT_FENCE CreateFencePacket(HSAuint64* address,
                                                            uint32_t data = 1) {
  return sdma_ep::CreateFencePacket(reinterpret_cast<uint64_t*>(address), data);
}

// Original anvil name was poll_until_lt but the semantics
// are "poll until *addr >= expected" (ge). Both aliases are
// provided for backward compatibility.
template <int64_t MAX_SPIN_COUNT = -1>
__device__ __forceinline__ void poll_until_lt(uint64_t* addr,
                                              uint64_t expected) {
  sdma_ep::poll_until_ge<MAX_SPIN_COUNT>(addr, expected);
}

template <int64_t MAX_SPIN_COUNT = -1>
__device__ __forceinline__ void poll_until_ge(uint64_t* addr,
                                              uint64_t expected) {
  sdma_ep::poll_until_ge<MAX_SPIN_COUNT>(addr, expected);
}

__device__ __forceinline__ void waitSignal(uint64_t* addr, uint64_t expected) {
  sdma_ep::waitSignal(addr, expected);
}

__device__ __forceinline__ void waitCounter(uint64_t* addr, uint64_t expected) {
  sdma_ep::waitCounter(addr, expected);
}

template <bool PUT_EN, bool SIGNAL_EN, bool COUNTER_EN>
__device__ __forceinline__ void put_signal_counter_impl(
  SdmaQueueDeviceHandle& handle, void* dst, void* src, size_t size,
  uint64_t* signal, uint64_t* counter, uint64_t* put_index = nullptr) {
  sdma_ep::put_signal_counter_impl<PUT_EN, SIGNAL_EN, COUNTER_EN>(
    handle, dst, src, size, signal, counter, put_index);
}

__device__ __forceinline__ void put(SdmaQueueDeviceHandle& handle, void* dst,
                                    void* src, size_t size) {
  sdma_ep::put(handle, dst, src, size);
}

__device__ __forceinline__ void signal(SdmaQueueDeviceHandle& handle,
                                       uint64_t* signal) {
  sdma_ep::signal(handle, signal);
}

__device__ __forceinline__ void put_tile(
  SdmaQueueDeviceHandle& handle, void* dst, void* src, uint32_t tile_width,
  uint32_t tile_height, uint32_t src_buffer_pitch, uint32_t dst_buffer_pitch,
  uint32_t src_x, uint32_t src_y, uint32_t dst_x, uint32_t dst_y) {
  sdma_ep::putTile(handle, dst, src, tile_width, tile_height, src_buffer_pitch,
                   dst_buffer_pitch, src_x, src_y, dst_x, dst_y);
}

__device__ __forceinline__ void put_signal(SdmaQueueDeviceHandle& handle,
                                           void* dst, void* src, size_t size,
                                           uint64_t* signal) {
  sdma_ep::putSignal(handle, dst, src, size, signal);
}

__device__ __forceinline__ void put_signal_counter(
  SdmaQueueDeviceHandle& handle, void* dst, void* src, size_t size,
  uint64_t* signal, uint64_t* counter) {
  sdma_ep::putSignalCounter(handle, dst, src, size, signal, counter);
}

__device__ __forceinline__ void put_counter(SdmaQueueDeviceHandle& handle,
                                            void* dst, void* src, size_t size,
                                            uint64_t* counter) {
  sdma_ep::putCounter(handle, dst, src, size, counter);
}

__device__ __forceinline__ void signal_counter(SdmaQueueDeviceHandle& handle,
                                               uint64_t* signal,
                                               uint64_t* counter) {
  sdma_ep::signalCounter(handle, signal, counter);
}

__device__ __forceinline__ void flush(SdmaQueueDeviceHandle& handle,
                                      uint64_t up_to_index) {
  sdma_ep::flush(handle, up_to_index);
}

__device__ __forceinline__ void quiet(SdmaQueueDeviceHandle& handle) {
  sdma_ep::quiet(handle);
}

} // namespace anvil
