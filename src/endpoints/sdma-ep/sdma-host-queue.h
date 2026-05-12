#pragma once

#include <vector>
#include <variant>
#include <initializer_list>
#include <cstddef>
#include <cstdint>

#include "sdma-ep.h"
#include "sdma_packets.hpp"

// Forward declaration for ::anvil::SdmaQueue
namespace anvil {
class SdmaQueue;
}

namespace xio {
namespace sdma_ep
{

// Variant type for heterogeneous packet collections
using SdmaPacket = std::variant<
    ::anvil::packets::CopyLinearPacket,
    ::anvil::packets::TimestampPacket,
    ::anvil::packets::LargeSubWindowCopyPacket,
    ::anvil::packets::AtomicAddPacket<uint32_t>,
    ::anvil::packets::AtomicAddPacket<uint64_t>,
    ::anvil::packets::PollRegmemPacket<uint32_t>
>;

// Host-side handle for CPU-initiated SDMA operations
class SdmaQueueHostHandle
{
 public:
   explicit SdmaQueueHostHandle(::anvil::SdmaQueue* q) : queue(q)
   {
   }

   // Host-initiated SDMA operations
   void put(void* src, void* dst, size_t size);

   template <typename T> void signal(T* ptr, T value);

   // Combined put + atomic_add in one SDMA submission (linear memory)
   template <typename T>
   void put_signal(void* src, void* dst, size_t size, T* flag_ptr, T flag_value);

   void put_tile(const Tile& tile, void* dst_ptr, size_t dst_stride);

   void put_tiles(const std::vector<Tile>& tiles, const std::vector<void*>& dst_ptrs,
                  const std::vector<size_t>& dst_strides);

   // Combined put_tile + atomic_add in one SDMA submission
   template <typename T>
   void put_tile_signal(const Tile& tile, void* dst_ptr, size_t dst_stride,
                        T* flag_ptr, T flag_value);

   // Combined put_tiles + atomic_add in one SDMA submission
   template <typename T>
   void put_tiles_signal(const std::vector<Tile>& tiles, const std::vector<void*>& dst_ptrs,
                         const std::vector<size_t>& dst_strides, T* flag_ptr, T flag_value);

   // Wait on flag, then perform put (POLL + COPY in one submission)
   template <typename T>
   void wait_flag_then_put(T* flag_ptr, T expected_value, void* src, void* dst, size_t size);

   // Wait on flag, then perform put_tile (POLL + SUB_WINDOW_COPY in one submission)
   template <typename T>
   void wait_flag_then_put_tile(T* flag_ptr, T expected_value, const Tile& tile,
                                void* dst_ptr, size_t dst_stride);

   // Wait on flag, then perform many put_tile operations in one submission
   template <typename T>
   void wait_flag_then_put_tiles(T* flag_ptr, T expected_value, const std::vector<Tile>& tiles,
                                 const std::vector<void*>& dst_ptrs,
                                 const std::vector<size_t>& dst_strides);

   // Wait for all submitted SDMA operations to complete
   void quiet();
   // Write GPU timestamp to memory location
   void timestamp(uint64_t* timestamp_ptr);

   // Submit a batch of heterogeneous packets (vector)
   void submit(const std::vector<SdmaPacket>& packets);

   // Submit a batch of heterogeneous packets (initializer_list)
   void submit(std::initializer_list<SdmaPacket> packets);

 private:
   // Queue management helpers
   uint64_t reserveQueueSpace(size_t size_in_bytes);
   void placePacket(const void* packet, size_t packet_size, uint64_t offset);
   void submitPacket(uint64_t base, uint64_t pending_wptr);
   bool canWriteUpto(uint64_t uptoIndex);
   uint64_t wrapIntoRing(uint64_t index) const;
   void padRingToEnd(uint64_t cur_index);

   ::anvil::SdmaQueue* queue;
};

} // namespace sdma_ep
} // namespace xio
