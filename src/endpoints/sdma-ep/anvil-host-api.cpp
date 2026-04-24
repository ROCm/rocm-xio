#include "anvil-host-api.hpp"
#include "anvil.hpp"
#include "sdma_pkt_struct.h"
#include "sdma_opcodes.h"

#include <cstring>
#include <stdexcept>
#include <thread>

namespace anvil
{

// ==================== Host-Side Packet Creation Functions ====================
// These are host-only versions of the packet builders (unlike device-side __device__ versions)

static inline SDMA_PKT_COPY_LINEAR CreateCopyPacketHost(void* srcBuf, void* dstBuf, size_t packetSize)
{
   SDMA_PKT_COPY_LINEAR pkt = {};
   pkt.HEADER_UNION.op = SDMA_OP_COPY;
   pkt.HEADER_UNION.sub_op = SDMA_SUBOP_COPY_LINEAR;
   pkt.COUNT_UNION.count = static_cast<uint32_t>(packetSize - 1); // HW wants size - 1
   pkt.SRC_ADDR_LO_UNION.src_addr_31_0 = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(srcBuf));
   pkt.SRC_ADDR_HI_UNION.src_addr_63_32 = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(srcBuf) >> 32);
   pkt.DST_ADDR_LO_UNION.dst_addr_31_0 = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(dstBuf));
   pkt.DST_ADDR_HI_UNION.dst_addr_63_32 = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(dstBuf) >> 32);
   return pkt;
}

template <typename T> static inline SDMA_PKT_ATOMIC CreateAtomicAddPacketHost(T* ptr, T value)
{
   static_assert(sizeof(T) == 4 || sizeof(T) == 8, "atomic_add only supports 32-bit or 64-bit types");

   SDMA_PKT_ATOMIC pkt = {};
   pkt.HEADER_UNION.op = SDMA_OP_ATOMIC;
   pkt.HEADER_UNION.operation = (sizeof(T) == 8) ? SDMA_ATOMIC_ADD64 : SDMA_ATOMIC_ADD32;

   uintptr_t addr = reinterpret_cast<uintptr_t>(ptr);
   pkt.ADDR_LO_UNION.addr_31_0 = static_cast<uint32_t>(addr);
   pkt.ADDR_HI_UNION.addr_63_32 = static_cast<uint32_t>(addr >> 32);

   uint64_t val64 = static_cast<uint64_t>(value);
   pkt.SRC_DATA_LO_UNION.src_data_31_0 = static_cast<uint32_t>(val64);
   pkt.SRC_DATA_HI_UNION.src_data_63_32 = static_cast<uint32_t>(val64 >> 32);

   return pkt;
}

static inline SDMA_PKT_TIMESTAMP CreateTimestampPacketHost(uint64_t* timestamp_ptr)
{
   SDMA_PKT_TIMESTAMP pkt = {};
   pkt.HEADER_UNION.op = SDMA_OP_TIMESTAMP;
   pkt.HEADER_UNION.sub_op = SDMA_SUBOP_TIMESTAMP_GLOBAL; // 100MHz fixed clock for MI300X

   uintptr_t addr = reinterpret_cast<uintptr_t>(timestamp_ptr);
   pkt.ADDR_LO_UNION.addr_31_0 = static_cast<uint32_t>(addr);
   pkt.ADDR_HI_UNION.addr_63_32 = static_cast<uint32_t>(addr >> 32);

   return pkt;
}

static inline SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY CreateLargeSubWindowCopyPacketHost(void* srcBuf, void* dstBuf,
                                                                                         uint32_t tile_width,
                                                                                         uint32_t tile_height,
                                                                                         uint32_t src_buffer_pitch,
                                                                                         uint32_t dst_buffer_pitch,
                                                                                         uint32_t src_x, uint32_t src_y,
                                                                                         uint32_t dst_x, uint32_t dst_y)
{
   SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY pkt = {};
   pkt.HEADER_UNION.op = SDMA_OP_COPY;
   pkt.HEADER_UNION.sub_op = SDMA_SUBOP_COPY_LINEAR_SUB_WINDOW;

   // Source buffer base address
   pkt.SRC_ADDR_LO_UNION.src_base_addr_31_0 = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(srcBuf));
   pkt.SRC_ADDR_HI_UNION.src_base_addr_63_32 = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(srcBuf) >> 32);

   // Source offset
   pkt.SRC_X_UNION.src_x = src_x;
   pkt.SRC_Y_UNION.src_y = src_y;
   pkt.SRC_Z_UNION.src_z = 0;

   // Source pitch (1-based, so subtract 1)
   pkt.SRC_PITCH_UNION.src_pitch = src_buffer_pitch - 1;

   // Source slice pitch (for 2D, use 0 which means slice_pitch of 1)
   uint64_t src_slice_pitch = 0;
   pkt.SRC_SLICE_PITCH_LO_UNION.src_slice_pitch_31_0 = static_cast<uint32_t>(src_slice_pitch & 0xFFFFFFFF);
   pkt.SRC_SLICE_PITCH_HI_UNION.src_slice_pitch_47_32 = static_cast<uint16_t>((src_slice_pitch >> 32) & 0xFFFF);

   // Destination buffer base address
   pkt.DST_ADDR_LO_UNION.dst_data_31_0 = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(dstBuf));
   pkt.DST_ADDR_HI_UNION.src_data_63_32 = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(dstBuf) >> 32);

   // Destination offset
   pkt.DST_X_UNION.dst_x = dst_x;
   pkt.DST_Y_UNION.dst_y = dst_y;
   pkt.DST_Z_UNION.dst_z = 0;

   // Destination pitch (1-based, so subtract 1)
   pkt.DST_PITCH_UNION.dst_pitch = dst_buffer_pitch - 1;

   // Destination slice pitch (for 2D, use 0)
   uint64_t dst_slice_pitch = 0;
   pkt.DST_SLICE_PITCH_LO_UNION.dst_slice_pitch_31_0 = static_cast<uint32_t>(dst_slice_pitch & 0xFFFFFFFF);
   pkt.DST_SLICE_PITCH_HI_UNION.dst_slice_pitch_47_32 = static_cast<uint16_t>((dst_slice_pitch >> 32) & 0xFFFF);

   // Rectangle dimensions (1-based, so subtract 1)
   pkt.RECT_X_UNION.rect_x = tile_width - 1;
   pkt.RECT_Y_UNION.rect_y = tile_height - 1;
   pkt.RECT_Z_UNION.rect_z = 0; // 2D copy, depth is 1, subtract 1 gives 0

   return pkt;
}

template <typename T>
static inline SDMA_PKT_POLL_REGMEM CreatePollRegmemPacketHost(T* flag_ptr, T expected_value, uint32_t interval = 10,
                                                                uint32_t retry_count = 0xFFF)
{
   static_assert(sizeof(T) == 4, "CreatePollRegmemPacket only supports 32-bit types");

   SDMA_PKT_POLL_REGMEM pkt = {};
   pkt.HEADER_UNION.op = SDMA_OP_POLL_REGMEM;
   pkt.HEADER_UNION.func = 5;       // Greater than or EQUAL
   pkt.HEADER_UNION.mem_poll = 1;   // Poll memory (not register)

   uintptr_t flag_addr = reinterpret_cast<uintptr_t>(flag_ptr);
   pkt.ADDR_LO_UNION.addr_31_0 = static_cast<uint32_t>(flag_addr);
   pkt.ADDR_HI_UNION.addr_63_32 = static_cast<uint32_t>(flag_addr >> 32);

   pkt.VALUE_UNION.value = static_cast<uint32_t>(expected_value);
   pkt.MASK_UNION.mask = 0xFFFFFFFF; // Match all bits

   pkt.DW5_UNION.interval = interval;         // Polling interval
   pkt.DW5_UNION.retry_count = retry_count;   // Retry count (0xFFF = infinite)

   return pkt;
}

// ==================== SdmaQueueHostHandle Implementation ====================

uint64_t SdmaQueueHostHandle::wrapIntoRing(uint64_t index) const
{
   return index % SDMA_QUEUE_SIZE;
}

void SdmaQueueHostHandle::padRingToEnd(uint64_t cur_index)
{
   const uint32_t queue_size_in_bytes = SDMA_QUEUE_SIZE;
   uint64_t padding_size = queue_size_in_bytes - wrapIntoRing(cur_index);
   uint64_t new_index = cur_index + padding_size;

   if (!canWriteUpto(new_index))
   {
      return;
   }

   // Atomic compare-and-swap to claim space for padding
   if (queue->hostCachedWptr_.compare_exchange_weak(cur_index, new_index, std::memory_order_release,
                                                     std::memory_order_relaxed))
   {
      uint64_t num_nops = padding_size / sizeof(uint32_t);
      uint32_t* queueBuf = static_cast<uint32_t*>(queue->queueBuffer_);
      uint64_t offset_dwords = wrapIntoRing(cur_index) / sizeof(uint32_t);

      // Fill with NOP packets
      for (uint64_t i = 0; i < num_nops; i++)
      {
         queueBuf[offset_dwords + i] = SDMA_OP_NOP;
      }

      // Submit NOP packets
      submitPacket(cur_index, new_index);
   }
}

bool SdmaQueueHostHandle::canWriteUpto(uint64_t uptoIndex)
{
   const uint64_t queue_size_in_bytes = SDMA_QUEUE_SIZE;
   uint64_t hw_read_index = *queue->queue_.Queue_read_ptr_aql;
   return (uptoIndex - hw_read_index) < queue_size_in_bytes;
}

uint64_t SdmaQueueHostHandle::reserveQueueSpace(size_t size_in_bytes)
{
   const uint32_t queue_size_in_bytes = SDMA_QUEUE_SIZE;
   uint64_t cur_index;

   while (true)
   {
      cur_index = queue->hostCachedWptr_.load(std::memory_order_relaxed);
      uint64_t new_index = cur_index + size_in_bytes;

      // Check if packet would cross ring boundary
      if (wrapIntoRing(cur_index) + size_in_bytes > queue_size_in_bytes)
      {
         // Pad to end and try again
         padRingToEnd(cur_index);
         continue;
      }

      // Check if hardware has space
      if (!canWriteUpto(new_index))
      {
         std::this_thread::yield();
         continue; // Queue full, spin
      }

      // Atomic compare-and-swap to claim space
      if (queue->hostCachedWptr_.compare_exchange_weak(cur_index, new_index, std::memory_order_release,
                                                        std::memory_order_relaxed))
      {
         break;
      }
      std::this_thread::yield();
   }

   return cur_index;
}

void SdmaQueueHostHandle::placePacket(const void* packet, size_t packet_size, uint64_t index)
{
   uint64_t wrapped_index = wrapIntoRing(index);
   char* queueBuf = static_cast<char*>(queue->queueBuffer_) + wrapped_index;

   // Copy packet to queue buffer
   std::memcpy(queueBuf, packet, packet_size);
}

void SdmaQueueHostHandle::submitPacket(uint64_t base, uint64_t pending_wptr)
{
   // Wait for previous packet to complete (serialization)
   while (queue->hostCommittedWptr_.load(std::memory_order_acquire) != base)
   {
      std::this_thread::yield();
   }

   // Memory fence
   std::atomic_thread_fence(std::memory_order_release);

   // Update hardware write pointer
   *queue->queue_.Queue_write_ptr_aql = pending_wptr;
   std::atomic_thread_fence(std::memory_order_release);

   // Ring the doorbell
   *queue->queue_.Queue_DoorBell_aql = pending_wptr;

   // Update committed write pointer
   queue->hostCommittedWptr_.store(pending_wptr, std::memory_order_release);
}

void SdmaQueueHostHandle::put(void* src, void* dst, size_t size)
{
   if (!src || !dst || size == 0)
   {
      throw std::invalid_argument("Invalid put() parameters");
   }

   // Reserve space for SDMA_PKT_COPY_LINEAR (7 dwords = 28 bytes)
   uint64_t base = reserveQueueSpace(sizeof(SDMA_PKT_COPY_LINEAR));

   // Create copy packet
   SDMA_PKT_COPY_LINEAR packet = CreateCopyPacketHost(src, dst, size);

   // Place and submit packet
   placePacket(&packet, sizeof(packet), base);
   submitPacket(base, base + sizeof(packet));
}

template <typename T> void SdmaQueueHostHandle::atomic_add(T* ptr, T value)
{
   static_assert(sizeof(T) == 4 || sizeof(T) == 8, "atomic_add only supports 32-bit or 64-bit types");

   if (!ptr)
   {
      throw std::invalid_argument("Invalid atomic_add() parameters");
   }

   // Reserve space for SDMA_PKT_ATOMIC (8 dwords = 32 bytes)
   uint64_t base = reserveQueueSpace(sizeof(SDMA_PKT_ATOMIC));

   // Create atomic packet
   SDMA_PKT_ATOMIC packet = CreateAtomicAddPacketHost(ptr, value);

   // Place and submit packet
   placePacket(&packet, sizeof(packet), base);
   submitPacket(base, base + sizeof(packet));
}

// Explicit template instantiations
template void SdmaQueueHostHandle::atomic_add<uint32_t>(uint32_t* ptr, uint32_t value);
template void SdmaQueueHostHandle::atomic_add<uint64_t>(uint64_t* ptr, uint64_t value);
template void SdmaQueueHostHandle::atomic_add<int32_t>(int32_t* ptr, int32_t value);
template void SdmaQueueHostHandle::atomic_add<int64_t>(int64_t* ptr, int64_t value);

void SdmaQueueHostHandle::timestamp(uint64_t* timestamp_ptr)
{
   if (!timestamp_ptr)
   {
      throw std::invalid_argument("Invalid timestamp() parameters");
   }

   // Reserve space for SDMA_PKT_TIMESTAMP (3 dwords = 12 bytes)
   uint64_t base = reserveQueueSpace(sizeof(SDMA_PKT_TIMESTAMP));

   // Create timestamp packet
   SDMA_PKT_TIMESTAMP packet = CreateTimestampPacketHost(timestamp_ptr);

   // Place and submit packet
   placePacket(&packet, sizeof(packet), base);
   submitPacket(base, base + sizeof(packet));
}

void SdmaQueueHostHandle::put_tile(const Tile& tile, void* dst_ptr, size_t dst_stride)
{
   if (!tile.data || !dst_ptr)
   {
      throw std::invalid_argument("Invalid put_tile() parameters");
   }

   // Reserve space for SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY
   uint64_t base = reserveQueueSpace(sizeof(SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY));

   // Create sub-window copy packet
   SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY packet =
       CreateLargeSubWindowCopyPacketHost(tile.data,                        // srcBuf
                                          dst_ptr,                          // dstBuf
                                          tile.width_bytes(),               // tile_width
                                          tile.height(),                    // tile_height
                                          tile.src_pitch(),                 // src_buffer_pitch
                                          dst_stride,                       // dst_buffer_pitch
                                          tile.offset_n() * tile.elem_size, // src_x
                                          tile.offset_m(),                  // src_y
                                          0,                                // dst_x
                                          0                                 // dst_y
       );

   // Place and submit packet
   placePacket(&packet, sizeof(packet), base);
   submitPacket(base, base + sizeof(packet));
}

template <typename T>
void SdmaQueueHostHandle::put_signal(void* src, void* dst, size_t size, T* flag_ptr, T flag_value)
{
   static_assert(sizeof(T) == 4 || sizeof(T) == 8, "put_signal only supports 32-bit or 64-bit types");

   if (!src || !dst || !flag_ptr || size == 0)
   {
      throw std::invalid_argument("Invalid put_signal() parameters");
   }

   // Reserve space for BOTH packets in one call
   constexpr size_t LINEAR_SIZE = sizeof(SDMA_PKT_COPY_LINEAR);
   constexpr size_t ATOMIC_SIZE = sizeof(SDMA_PKT_ATOMIC);
   constexpr size_t TOTAL_SIZE = LINEAR_SIZE + ATOMIC_SIZE;

   uint64_t base = reserveQueueSpace(TOTAL_SIZE);

   // Build copy packet
   SDMA_PKT_COPY_LINEAR linear_pkt = CreateCopyPacketHost(src, dst, size);

   // Build atomic packet
   SDMA_PKT_ATOMIC atomic_pkt = CreateAtomicAddPacketHost(flag_ptr, flag_value);

   // Place both packets
   placePacket(&linear_pkt, sizeof(linear_pkt), base);
   placePacket(&atomic_pkt, sizeof(atomic_pkt), base + sizeof(linear_pkt));

   // Submit both packets together
   submitPacket(base, base + TOTAL_SIZE);
}

template <typename T>
void SdmaQueueHostHandle::put_tile_signal(const Tile& tile, void* dst_ptr, size_t dst_stride, T* flag_ptr,
                                          T flag_value)
{
   static_assert(sizeof(T) == 4 || sizeof(T) == 8, "put_tile_signal only supports 32-bit or 64-bit types");

   if (!tile.data || !dst_ptr || !flag_ptr)
   {
      throw std::invalid_argument("Invalid put_tile_signal() parameters");
   }

   // Reserve space for BOTH packets in one call
   constexpr size_t SUBWIN_SIZE = sizeof(SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY);
   constexpr size_t ATOMIC_SIZE = sizeof(SDMA_PKT_ATOMIC);
   constexpr size_t TOTAL_SIZE = SUBWIN_SIZE + ATOMIC_SIZE;

   uint64_t base = reserveQueueSpace(TOTAL_SIZE);

   // Build SUB_WINDOW packet
   SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY subwin_pkt =
       CreateLargeSubWindowCopyPacketHost(tile.data,                        // srcBuf
                                          dst_ptr,                          // dstBuf
                                          tile.width_bytes(),               // tile_width
                                          tile.height(),                    // tile_height
                                          tile.src_pitch(),                 // src_buffer_pitch
                                          dst_stride,                       // dst_buffer_pitch
                                          tile.offset_n() * tile.elem_size, // src_x
                                          tile.offset_m(),                  // src_y
                                          0,                                // dst_x
                                          0                                 // dst_y
       );

   // Build ATOMIC packet
   SDMA_PKT_ATOMIC atomic_pkt = CreateAtomicAddPacketHost(flag_ptr, flag_value);

   // Place both packets sequentially
   placePacket(&subwin_pkt, SUBWIN_SIZE, base);
   placePacket(&atomic_pkt, ATOMIC_SIZE, base + SUBWIN_SIZE);

   // Submit both packets in one doorbell ring
   submitPacket(base, base + TOTAL_SIZE);
}

// Explicit template instantiations
template void SdmaQueueHostHandle::put_signal<uint32_t>(void* src, void* dst, size_t size, uint32_t* flag_ptr,
                                                        uint32_t flag_value);
template void SdmaQueueHostHandle::put_signal<uint64_t>(void* src, void* dst, size_t size, uint64_t* flag_ptr,
                                                        uint64_t flag_value);

template void SdmaQueueHostHandle::put_tile_signal<uint32_t>(const Tile& tile, void* dst_ptr, size_t dst_stride,
                                                             uint32_t* flag_ptr, uint32_t flag_value);
template void SdmaQueueHostHandle::put_tile_signal<uint64_t>(const Tile& tile, void* dst_ptr, size_t dst_stride,
                                                             uint64_t* flag_ptr, uint64_t flag_value);

template <typename T>
void SdmaQueueHostHandle::wait_flag_then_put(T* flag_ptr, T expected_value, void* src, void* dst, size_t size)
{
   static_assert(sizeof(T) == 4, "wait_flag_then_put only supports 32-bit types");

   if (!flag_ptr || !src || !dst || size == 0)
   {
      throw std::invalid_argument("Invalid wait_flag_then_put() parameters");
   }

   // Reserve space for BOTH packets in one call
   constexpr size_t POLL_SIZE = sizeof(SDMA_PKT_POLL_REGMEM);
   constexpr size_t COPY_SIZE = sizeof(SDMA_PKT_COPY_LINEAR);
   constexpr size_t TOTAL_SIZE = POLL_SIZE + COPY_SIZE;

   uint64_t base = reserveQueueSpace(TOTAL_SIZE);

   // Build POLL packet
   SDMA_PKT_POLL_REGMEM poll_pkt = CreatePollRegmemPacketHost(flag_ptr, expected_value);

   // Build COPY packet
   SDMA_PKT_COPY_LINEAR copy_pkt = CreateCopyPacketHost(src, dst, size);

   // Place both packets sequentially
   placePacket(&poll_pkt, sizeof(poll_pkt), base);
   placePacket(&copy_pkt, sizeof(copy_pkt), base + POLL_SIZE);

   // Submit both packets in one doorbell ring
   submitPacket(base, base + TOTAL_SIZE);
}

template <typename T>
void SdmaQueueHostHandle::wait_flag_then_put_tile(T* flag_ptr, T expected_value, const Tile& tile, void* dst_ptr,
                                                   size_t dst_stride)
{
   static_assert(sizeof(T) == 4, "wait_flag_then_put_tile only supports 32-bit types");

   if (!flag_ptr || !tile.data || !dst_ptr)
   {
      throw std::invalid_argument("Invalid wait_flag_then_put_tile() parameters");
   }

   // Reserve space for BOTH packets in one call
   constexpr size_t POLL_SIZE = sizeof(SDMA_PKT_POLL_REGMEM);
   constexpr size_t SUBWIN_SIZE = sizeof(SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY);
   constexpr size_t TOTAL_SIZE = POLL_SIZE + SUBWIN_SIZE;

   uint64_t base = reserveQueueSpace(TOTAL_SIZE);

   // Build POLL packet
   SDMA_PKT_POLL_REGMEM poll_pkt = CreatePollRegmemPacketHost(flag_ptr, expected_value);

   // Build SUB_WINDOW_COPY packet
   SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY subwin_pkt =
       CreateLargeSubWindowCopyPacketHost(tile.data,                        // srcBuf
                                          dst_ptr,                          // dstBuf
                                          tile.width_bytes(),               // tile_width
                                          tile.height(),                    // tile_height
                                          tile.src_pitch(),                 // src_buffer_pitch
                                          dst_stride,                       // dst_buffer_pitch
                                          tile.offset_n() * tile.elem_size, // src_x
                                          tile.offset_m(),                  // src_y
                                          0,                                // dst_x
                                          0                                 // dst_y
       );

   // Place both packets sequentially
   placePacket(&poll_pkt, sizeof(poll_pkt), base);
   placePacket(&subwin_pkt, sizeof(subwin_pkt), base + POLL_SIZE);

   // Submit both packets in one doorbell ring
   submitPacket(base, base + TOTAL_SIZE);
}

template <typename T>
void SdmaQueueHostHandle::wait_flag_then_put_tiles(T* flag_ptr, T expected_value, const std::vector<Tile>& tiles,
                                                    const std::vector<void*>& dst_ptrs,
                                                    const std::vector<size_t>& dst_strides)
{
   static_assert(sizeof(T) == 4, "wait_flag_then_put_tiles only supports 32-bit types");

   if (!flag_ptr || tiles.empty() || tiles.size() != dst_ptrs.size() || tiles.size() != dst_strides.size())
   {
      throw std::invalid_argument("Invalid wait_flag_then_put_tiles() parameters");
   }

   for (size_t i = 0; i < tiles.size(); ++i)
   {
      if (!tiles[i].data || !dst_ptrs[i])
      {
         throw std::invalid_argument("Invalid wait_flag_then_put_tiles() tile parameters");
      }
   }

   constexpr size_t POLL_SIZE = sizeof(SDMA_PKT_POLL_REGMEM);
   constexpr size_t SUBWIN_SIZE = sizeof(SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY);
   const size_t total_size = POLL_SIZE + tiles.size() * SUBWIN_SIZE;

   uint64_t base = reserveQueueSpace(total_size);

   SDMA_PKT_POLL_REGMEM poll_pkt = CreatePollRegmemPacketHost(flag_ptr, expected_value);
   placePacket(&poll_pkt, sizeof(poll_pkt), base);

   uint64_t offset = base + POLL_SIZE;
   for (size_t i = 0; i < tiles.size(); ++i)
   {
      const Tile& tile = tiles[i];
      SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY subwin_pkt =
          CreateLargeSubWindowCopyPacketHost(tile.data, dst_ptrs[i], tile.width_bytes(), tile.height(),
                                             tile.src_pitch(), dst_strides[i], tile.offset_n() * tile.elem_size,
                                             tile.offset_m(), 0, 0);
      placePacket(&subwin_pkt, sizeof(subwin_pkt), offset);
      offset += SUBWIN_SIZE;
   }

   submitPacket(base, base + total_size);
}

// Explicit template instantiations
template void SdmaQueueHostHandle::wait_flag_then_put<uint32_t>(uint32_t* flag_ptr, uint32_t expected_value,
                                                                void* src, void* dst, size_t size);

template void SdmaQueueHostHandle::wait_flag_then_put_tile<uint32_t>(uint32_t* flag_ptr, uint32_t expected_value,
                                                                     const Tile& tile, void* dst_ptr,
                                                                     size_t dst_stride);

template void SdmaQueueHostHandle::wait_flag_then_put_tiles<uint32_t>(uint32_t* flag_ptr, uint32_t expected_value,
                                                                      const std::vector<Tile>& tiles,
                                                                      const std::vector<void*>& dst_ptrs,
                                                                      const std::vector<size_t>& dst_strides);

void SdmaQueueHostHandle::quiet()
{
   // Get the committed write pointer (what's been submitted to hardware)
   uint64_t target_wptr = queue->hostCommittedWptr_.load(std::memory_order_acquire);

   // Spin until hardware read pointer catches up to write pointer
   while (*queue->queue_.Queue_read_ptr_aql != target_wptr)
   {
      std::atomic_thread_fence(std::memory_order_acquire);
      std::this_thread::yield();
   }

   // Ensure all memory operations from SDMA are visible
   std::atomic_thread_fence(std::memory_order_seq_cst);
}

} // namespace anvil
