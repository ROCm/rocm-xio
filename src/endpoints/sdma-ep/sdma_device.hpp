/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * SDMA Endpoint Device API
 *
 * Defines the GPU-facing queue handle structures and helper
 * operations used by kernels to interact with AMD SDMA engines.
 */

#pragma once

#include <cassert>
#include <cstdint>

#include <hip/hip_ext.h>
#include <hip/hip_runtime.h>

#include "sdma_constants.h"

#include "sdma_pkt_struct.h"
#include "sdma_pkt_struct_mi4.h"
#include "sdma_packets.hpp"

namespace xio {

struct XioEndpointConfig;

namespace sdma_ep {

/** Maximum spin-poll iterations before assert. */
constexpr int MAX_RETRIES = 1 << 30;

/** If true, assert on retry limit in device code. */
constexpr bool BREAK_ON_RETRIES = false;

/**
 * @brief Build an SDMA linear copy packet.
 *
 * @param srcBuf Source address (GPU virtual).
 * @param dstBuf Destination address (GPU virtual).
 * @param packetSize Number of bytes to copy. Must be
 *        in the range [1, UINT32_MAX] (the HW count
 *        field is 30 bits, so max single-packet
 *        transfer is 1 GiB).
 * @return Populated SDMA_PKT_COPY_LINEAR.
 *
 * @note Device-only. The count field stores size-1 per
 *       the HW spec (0 means 1 byte).
 */
__device__ __forceinline__ SDMA_PKT_COPY_LINEAR
CreateCopyPacket(void* srcBuf, void* dstBuf, long long int packetSize) {
  assert(packetSize > 0 && "CreateCopyPacket: packetSize must be > 0");
  assert(packetSize <= 0xFFFFFFFFLL &&
         "CreateCopyPacket: packetSize exceeds 4 GiB");
  anvil::packets::CopyLinearPacket pkt(srcBuf, dstBuf,
                                       static_cast<size_t>(packetSize));
  return pkt.value;
}

/**
 * @brief Build an SDMA 2D sub-window copy packet.
 *
 * @param srcBuf   Source buffer base address.
 * @param dstBuf   Destination buffer base address.
 * @param tile_width  Tile width in bytes.
 * @param tile_height Tile height in rows.
 * @param src_buffer_pitch Source row stride in bytes.
 * @param dst_buffer_pitch Destination row stride in bytes.
 * @param src_x Source X offset in bytes.
 * @param src_y Source Y offset in rows.
 * @param dst_x Destination X offset in bytes.
 * @param dst_y Destination Y offset in rows.
 * @return Populated sub-window copy packet.
 */
__device__ __forceinline__ SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY
CreateLargeSubWindowCopyPacket(void* srcBuf, void* dstBuf, uint32_t tile_width,
                               uint32_t tile_height, uint32_t src_buffer_pitch,
                               uint32_t dst_buffer_pitch, uint32_t src_x,
                               uint32_t src_y, uint32_t dst_x,
                               uint32_t dst_y) {
  anvil::packets::LargeSubWindowCopyPacket pkt(
      srcBuf, dstBuf, tile_width, tile_height, src_buffer_pitch,
      dst_buffer_pitch, src_x, src_y, dst_x, dst_y);
  return pkt.value;
}

/**
 * @brief Build an SDMA atomic increment packet.
 *
 * Atomically adds 1 to the 64-bit value at the given
 * address via the SDMA engine (not the shader ALU).
 *
 * @param addr Address of the 64-bit value to increment.
 * @return Populated SDMA_PKT_ATOMIC.
 */
__device__ __forceinline__ SDMA_PKT_ATOMIC
CreateAtomicIncPacket(uint64_t* addr) {
  anvil::packets::AtomicAddPacket<uint64_t> pkt(addr, 1);
  return pkt.value;
}

/**
 * @brief Build an SDMA fence packet.
 *
 * Writes a data value to a memory address after all
 * preceding SDMA operations on this queue have completed.
 *
 * @param address Address to write the fence value to.
 * @param data    Value to write (default: 1).
 * @return Populated SDMA_PKT_FENCE.
 */
__device__ __forceinline__ SDMA_PKT_FENCE CreateFencePacket(uint64_t* address,
                                                            uint32_t data = 1) {
  SDMA_PKT_FENCE pkt = {};
  pkt.HEADER_UNION.op = SDMA_OP_FENCE;
  pkt.ADDR_LO_UNION.addr_31_0 = (uint32_t)((uintptr_t)address);
  pkt.ADDR_HI_UNION.addr_63_32 = (uint32_t)((uintptr_t)address >> 32);
  pkt.DATA_UNION.data = data;
  return pkt;
}

/* ================================================================
 * Device-Side Poll Helpers
 * ================================================================ */

/**
 * @brief Spin-poll until *addr >= expected.
 *
 * @tparam MAX_SPIN_COUNT Maximum iterations before assert
 *         (-1 = unlimited).
 * @param addr    Address to poll (device memory).
 * @param expected Minimum value to wait for.
 *
 * @note Device-only. Uses agent-scope relaxed atomics.
 */
template <int64_t MAX_SPIN_COUNT = -1>
__device__ __forceinline__ void poll_until_ge(uint64_t* addr,
                                              uint64_t expected) {
  [[maybe_unused]] int64_t spin_count = 0;
  while (__hip_atomic_load(addr, __ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_AGENT) <
         expected) {
    spin_count++;
    assert(MAX_SPIN_COUNT < 0 || spin_count != MAX_SPIN_COUNT);
  }
}

/* ================================================================
 * Device Handle
 * ================================================================ */

/**
 * @brief GPU-visible SDMA queue state.
 *
 * Contains ring buffer pointers, doorbell, and read/write
 * tracking state. Created on the host via createQueue()
 * and passed to GPU kernels for device-side SDMA
 * operations (put, signal, flush, quiet).
 *
 * Multi-producer safe: uses atomic CAS on cachedWptr for
 * queue space reservation. For single-producer kernels,
 * use SdmaQueueSingleProducerHandle for lower overhead.
 *
 * @note This struct is allocated in device memory and
 *       must not be copied by value across host/device
 *       boundary after initialization.
 */
struct SdmaQueueHandle {
  /**
   * @brief Wrap a byte index into the ring buffer.
   * @param index Absolute byte index in the SDMA ring.
   * @return Ring-relative byte offset.
   */
  __device__ __forceinline__ uint64_t WrapIntoRing(uint64_t index) {
    return index % SDMA_QUEUE_SIZE;
  }

  /**
   * @brief Check if the queue has space up to uptoIndex.
   *
   * Uses a cached HW read index for fast-path; falls
   * back to reading the hardware register if the cached
   * value indicates the queue is full.
   *
   * @param uptoIndex Absolute byte index the producer wants to reach.
   * @return true when the ring has enough free space.
   */
  __device__ __forceinline__ bool CanWriteUpto(uint64_t uptoIndex) {
    if ((uptoIndex - cachedHwReadIndex) < SDMA_QUEUE_SIZE) {
      return true;
    }
    cachedHwReadIndex = __hip_atomic_load(rptr, __ATOMIC_RELAXED,
                                          __HIP_MEMORY_SCOPE_AGENT);
    __atomic_signal_fence(__ATOMIC_SEQ_CST);
    return (uptoIndex - cachedHwReadIndex) < SDMA_QUEUE_SIZE;
  }

  /**
   * @brief Reserve space in the queue ring buffer.
   *
   * Atomically advances cachedWptr. Handles ring
   * wraparound by padding with NOPs. Spins until space
   * is available.
   *
   * @param size_in_bytes Bytes to reserve.
   * @param offset Output: NOP padding bytes inserted
   *        before the reserved region (for wraparound).
   * @return Base index (byte offset) of the reserved
   *         region.
   */
  __device__ __forceinline__ uint64_t
  ReserveQueueSpace(const size_t size_in_bytes, uint64_t& offset) {
    uint64_t cur_index;
    int retries = 0;
    while (true) {
      cur_index = __hip_atomic_load(cachedWptr, __ATOMIC_RELAXED,
                                    __HIP_MEMORY_SCOPE_AGENT);
      offset = 0;
      if (WrapIntoRing(cur_index) + size_in_bytes > SDMA_QUEUE_SIZE) {
        offset = SDMA_QUEUE_SIZE - WrapIntoRing(cur_index);
      }
      uint64_t new_index = cur_index + size_in_bytes + offset;
      if (CanWriteUpto(new_index)) {
        if (__hip_atomic_compare_exchange_strong(cachedWptr, &cur_index,
                                                 new_index, __ATOMIC_RELAXED,
                                                 __ATOMIC_RELAXED,
                                                 __HIP_MEMORY_SCOPE_AGENT)) {
          break;
        }
      }
      if constexpr (BREAK_ON_RETRIES) {
        if (retries++ == MAX_RETRIES) {
          assert(false && "Retry limit on reserve queue space");
          break;
        }
      }
    }
    return cur_index;
  }

  /**
   * @brief Place a packet into the queue ring buffer.
   *
   * Writes NOP padding (if offset > 0) followed by
   * the packet DWORDs using agent-scope relaxed stores.
   *
   * @tparam PacketType SDMA packet struct type.
   * @param packet      Reference to the packet data.
   * @param pendingWptr In/out write pointer tracking.
   * @param offset      NOP padding bytes before packet.
   */
  template <typename PacketType>
  __device__ __forceinline__ void placePacket(PacketType& packet,
                                              uint64_t& pendingWptr,
                                              uint64_t offset) {
    static_assert(sizeof(PacketType) / sizeof(uint32_t) <= 64);
    const uint32_t numOffsetDwords = offset / sizeof(uint32_t);
    const uint32_t numDwords = sizeof(PacketType) / sizeof(uint32_t);
    uint32_t* packetPtr = reinterpret_cast<uint32_t*>(&packet);
    uint64_t base_idx = WrapIntoRing(pendingWptr) / sizeof(uint32_t);
    for (uint32_t i = 0; i < numOffsetDwords; i++) {
      if (i == 0) {
        __hip_atomic_store(queueBuf + base_idx + i,
                           (((numOffsetDwords - 1) & 0xFFFF) << 16),
                           __ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_AGENT);
      } else {
        __hip_atomic_store(queueBuf + base_idx + i, 0, __ATOMIC_RELAXED,
                           __HIP_MEMORY_SCOPE_AGENT);
      }
    }
    pendingWptr += offset;
    base_idx = WrapIntoRing(pendingWptr) / sizeof(uint32_t);
    for (uint32_t i = 0; i < numDwords; i++) {
      __hip_atomic_store(queueBuf + base_idx + i, packetPtr[i],
                         __ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_AGENT);
    }
    pendingWptr += sizeof(PacketType);
  }

  /**
   * @brief Submit a packet to the SDMA engine.
   *
   * Waits for committedWptr to match base (serializes
   * multi-producer submissions), then updates wptr,
   * rings the doorbell, and advances committedWptr.
   *
   * @param base        Base index from ReserveQueueSpace.
   * @param pendingWptr End index after placePacket.
   */
  __device__ __forceinline__ void submitPacket(uint64_t base,
                                               uint64_t pendingWptr) {
    int retries = 0;
    while (true) {
      uint64_t val = __hip_atomic_load(committedWptr, __ATOMIC_RELAXED,
                                       __HIP_MEMORY_SCOPE_AGENT);
      __atomic_signal_fence(__ATOMIC_SEQ_CST);
      if (val == base)
        break;
      if constexpr (BREAK_ON_RETRIES) {
        if (retries++ == MAX_RETRIES) {
          assert(false && "submitPacket: Retry limit exceeded");
          break;
        }
      }
    }
    __builtin_amdgcn_s_waitcnt(0);
    __builtin_amdgcn_wave_barrier();
    __atomic_signal_fence(__ATOMIC_SEQ_CST);
    __hip_atomic_store(wptr, pendingWptr, __ATOMIC_RELAXED,
                       __HIP_MEMORY_SCOPE_AGENT);
    __builtin_amdgcn_s_waitcnt(0);
    __builtin_amdgcn_wave_barrier();
    __atomic_signal_fence(__ATOMIC_SEQ_CST);
    __hip_atomic_store(doorbell, pendingWptr, __ATOMIC_RELAXED,
                       __HIP_MEMORY_SCOPE_SYSTEM);
    __builtin_amdgcn_s_waitcnt(0);
    __builtin_amdgcn_wave_barrier();
    __atomic_signal_fence(__ATOMIC_SEQ_CST);
    __hip_atomic_store(committedWptr, pendingWptr, __ATOMIC_RELAXED,
                       __HIP_MEMORY_SCOPE_AGENT);
    maxWritePtr = pendingWptr;
  }

  /**
   * @brief Wait until HW has consumed up to upToIndex.
   *
   * Spin-polls the hardware read pointer until it
   * reaches or passes upToIndex.
   *
   * @param upToIndex Byte index to wait for.
   */
  __device__ __forceinline__ void flushTo(uint64_t upToIndex) {
    uint64_t hw_read_index;
    do {
      hw_read_index = __hip_atomic_load(rptr, __ATOMIC_RELAXED,
                                        __HIP_MEMORY_SCOPE_AGENT);
    } while (hw_read_index < upToIndex);
  }

  /**
   * @brief Wait for all submitted operations.
   *
   * Spin-polls the hardware read pointer until it
   * reaches maxWritePtr (the end of the last submitted
   * packet).
   */
  __device__ __forceinline__ void quietAll() {
    uint64_t hw_read_index;
    do {
      hw_read_index = __hip_atomic_load(rptr, __ATOMIC_RELAXED,
                                        __HIP_MEMORY_SCOPE_AGENT);
    } while (hw_read_index < maxWritePtr);
  }

  uint32_t* queueBuf;         /**< Ring buffer base. */
  uint64_t* rptr;             /**< HW read pointer. */
  uint64_t* wptr;             /**< HW write pointer. */
  uint64_t* doorbell;         /**< Doorbell register. */
  uint64_t* cachedWptr;       /**< Cached write pointer
                                   (shared, device mem). */
  uint64_t* committedWptr;    /**< Committed write pointer
                                   (shared, device mem). */
  uint64_t cachedHwReadIndex; /**< Cached HW read index
                                   (local). */
  uint64_t maxWritePtr;       /**< End of last submitted
                                   packet (local). */
};

/**
 * @brief Single-producer variant of SdmaQueueHandle.
 *
 * Avoids atomic CAS overhead in ReserveQueueSpace by
 * using direct pointer writes. Only safe when exactly
 * one thread submits to the queue.
 *
 * @note Same binary layout as SdmaQueueHandle (verified
 *       by static_assert).
 */
struct SdmaQueueSingleProducerHandle : SdmaQueueHandle {
  /**
   * @brief Pad remaining ring space with NOPs and submit.
   * @param cur_index Current absolute write pointer before wrap padding.
   */
  __device__ __forceinline__ void PadRingToEnd(uint64_t cur_index) {
    uint64_t new_index = cur_index +
                         (SDMA_QUEUE_SIZE - WrapIntoRing(cur_index));
    if (!CanWriteUpto(new_index))
      return;
    *cachedWptr = new_index;
    uint64_t idx = WrapIntoRing(cur_index) / sizeof(uint32_t);
    int nDwords = (new_index - cur_index) / sizeof(uint32_t);
    for (int i = 0; i < nDwords; i++) {
      queueBuf[idx + i] = (uint32_t)0;
    }
    submitPacket(cur_index, new_index);
  }

  /**
   * @brief Reserve space (single-producer, no CAS).
   * @param size_in_bytes Bytes to reserve.
   * @return Base index of the reserved region.
   */
  __device__ __forceinline__ uint64_t
  ReserveQueueSpace(const size_t size_in_bytes) {
    const uint32_t queue_size = SDMA_QUEUE_SIZE;
    uint64_t cur_index;
    while (true) {
      cur_index = *cachedWptr;
      uint64_t new_index = cur_index + size_in_bytes;
      if (WrapIntoRing(cur_index) + size_in_bytes > queue_size) {
        PadRingToEnd(cur_index);
        continue;
      }
      if (!CanWriteUpto(new_index))
        continue;
      *cachedWptr = new_index;
      break;
    }
    return cur_index;
  }

  /**
   * @brief Submit (single-producer, no committedWptr
   *        serialization).
   * @param base Base index returned by ReserveQueueSpace().
   * @param pendingWptr End index after packet placement.
   */
  __device__ __forceinline__ void submitPacket(uint64_t base,
                                               uint64_t pendingWptr) {
    *wptr = pendingWptr;
    __builtin_amdgcn_s_waitcnt(0);
    __builtin_amdgcn_wave_barrier();
    __atomic_signal_fence(__ATOMIC_SEQ_CST);
    *doorbell = pendingWptr;
  }
};

static_assert(sizeof(SdmaQueueSingleProducerHandle) == sizeof(SdmaQueueHandle),
              "Single-producer handle must match base layout");

/* ================================================================
 * Device-Side Composite Operation (internal template)
 * ================================================================ */

/**
 * @brief Combined put/signal/counter operation.
 *
 * Reserves queue space for the enabled operations,
 * places the packets, and submits them as a single
 * batch. Template parameters select which operations
 * are included.
 *
 * @tparam PUT_EN     Include a linear copy packet.
 * @tparam SIGNAL_EN  Include a signal (atomic inc).
 * @tparam COUNTER_EN Include a counter (atomic inc).
 */
template <bool PUT_EN, bool SIGNAL_EN, bool COUNTER_EN>
__device__ __forceinline__ void put_signal_counter_impl(
  SdmaQueueHandle& handle, void* dst, void* src, size_t size, uint64_t* signal,
  uint64_t* counter, uint64_t* put_index = nullptr) {
  constexpr size_t space_required =
    ((PUT_EN) ? sizeof(SDMA_PKT_COPY_LINEAR) : 0) +
    ((SIGNAL_EN) ? sizeof(SDMA_PKT_ATOMIC) : 0) +
    ((COUNTER_EN) ? sizeof(SDMA_PKT_ATOMIC) : 0);
  uint64_t offset = 0;
  auto base = handle.ReserveQueueSpace(space_required, offset);
  uint64_t pendingWptr = base;
  if constexpr (PUT_EN) {
    auto pkt = CreateCopyPacket(src, dst, size);
    handle.placePacket(pkt, pendingWptr, offset);
    if (put_index != nullptr)
      *put_index = pendingWptr;
    offset = 0;
  }
  if constexpr (SIGNAL_EN) {
    auto pkt = CreateAtomicIncPacket(signal);
    handle.placePacket(pkt, pendingWptr, offset);
    offset = 0;
  }
  if constexpr (COUNTER_EN) {
    auto pkt = CreateAtomicIncPacket(counter);
    handle.placePacket(pkt, pendingWptr, offset);
    offset = 0;
  }
  handle.submitPacket(base, pendingWptr);
}

/* ================================================================
 * Device-Side Operations -- Data Transfer
 * ================================================================ */

__device__ __forceinline__ void put(SdmaQueueHandle& handle, void* dst,
                                    void* src, size_t size) {
  put_signal_counter_impl<true, false, false>(handle, dst, src, size, nullptr,
                                              nullptr);
}

__device__ __forceinline__ void putTile(SdmaQueueHandle& handle, void* dst,
                                        void* src, uint32_t tileWidth,
                                        uint32_t tileHeight, uint32_t srcPitch,
                                        uint32_t dstPitch, uint32_t srcX,
                                        uint32_t srcY, uint32_t dstX,
                                        uint32_t dstY) {
  uint64_t offset = 0;
  auto base = handle.ReserveQueueSpace(sizeof(
                                         SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY),
                                       offset);
  auto pkt = CreateLargeSubWindowCopyPacket(src, dst, tileWidth, tileHeight,
                                            srcPitch, dstPitch, srcX, srcY,
                                            dstX, dstY);
  uint64_t pendingWptr = base;
  handle.placePacket(pkt, pendingWptr, offset);
  handle.submitPacket(base, pendingWptr);
}

/* ================================================================
 * Device-Side Operations -- Signaling
 * ================================================================ */

__device__ __forceinline__ void signal(SdmaQueueHandle& handle,
                                       uint64_t* signal) {
  put_signal_counter_impl<false, true, false>(handle, nullptr, nullptr, 0,
                                              signal, nullptr);
}

__device__ __forceinline__ void putSignal(SdmaQueueHandle& handle, void* dst,
                                          void* src, size_t size,
                                          uint64_t* signal) {
  put_signal_counter_impl<true, true, false>(handle, dst, src, size, signal,
                                             nullptr);
}

__device__ __forceinline__ void putSignalCounter(SdmaQueueHandle& handle,
                                                 void* dst, void* src,
                                                 size_t size, uint64_t* signal,
                                                 uint64_t* counter) {
  put_signal_counter_impl<true, true, true>(handle, dst, src, size, signal,
                                            counter);
}

__device__ __forceinline__ void putCounter(SdmaQueueHandle& handle, void* dst,
                                           void* src, size_t size,
                                           uint64_t* counter) {
  put_signal_counter_impl<true, false, true>(handle, dst, src, size, nullptr,
                                             counter);
}

__device__ __forceinline__ void signalCounter(SdmaQueueHandle& handle,
                                              uint64_t* signal,
                                              uint64_t* counter) {
  put_signal_counter_impl<false, true, true>(handle, nullptr, nullptr, 0,
                                             signal, counter);
}

/* ================================================================
 * Device-Side Operations -- Completion Tracking
 * ================================================================ */

__device__ __forceinline__ void waitSignal(uint64_t* addr, uint64_t expected) {
  if constexpr (BREAK_ON_RETRIES) {
    poll_until_ge<MAX_RETRIES>(addr, expected);
  } else {
    poll_until_ge<-1>(addr, expected);
  }
}

__device__ __forceinline__ void waitCounter(uint64_t* addr, uint64_t expected) {
  if constexpr (BREAK_ON_RETRIES) {
    poll_until_ge<MAX_RETRIES>(addr, expected);
  } else {
    poll_until_ge<-1>(addr, expected);
  }
}

__device__ __forceinline__ void flush(SdmaQueueHandle& handle,
                                      uint64_t upToIndex) {
  handle.flushTo(upToIndex);
}

__device__ __forceinline__ void quiet(SdmaQueueHandle& handle) {
  handle.quietAll();
}

} // namespace sdma_ep
