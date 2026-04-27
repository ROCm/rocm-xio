#include "anvil-host-api.hpp"
#include "anvil.hpp"
#include "sdma_packets.hpp"

#include <cstring>
#include <limits>
#include <stdexcept>
#include <thread>
#include <string>
#include <type_traits>

namespace anvil
{

namespace
{
constexpr uint64_t kMaxSdmaDword = std::numeric_limits<uint32_t>::max();
constexpr uint64_t kMaxLinearSize = 0x1'0000'0000ULL; // 32-bit count field -> size-1 fits in uint32_t

inline void validate_linear_args(void* src, void* dst, size_t size, const char* fn_name)
{
   if (!src || !dst || size == 0)
   {
      throw std::invalid_argument(std::string(fn_name) + ": invalid nullptr/size arguments");
   }
   if (size > kMaxLinearSize)
   {
      throw std::invalid_argument(std::string(fn_name) + ": size exceeds SDMA linear packet limit (4 GiB)");
   }
}

inline void validate_tile_geometry(const Tile& tile, const char* fn_name)
{
   if (!tile.data)
   {
      throw std::invalid_argument(std::string(fn_name) + ": tile.data is null");
   }
   if (tile.block_m <= 0 || tile.block_n <= 0 || tile.elem_size == 0)
   {
      throw std::invalid_argument(std::string(fn_name) + ": tile has invalid block or element size");
   }
   if (tile.pid_m < 0 || tile.pid_n < 0)
   {
      throw std::invalid_argument(std::string(fn_name) + ": negative tile coordinates are unsupported");
   }
}

inline packets::LargeSubWindowCopyPacket build_tile_packet(const Tile& tile, void* dst_ptr, size_t dst_stride,
                                                           const char* fn_name)
{
   validate_tile_geometry(tile, fn_name);
   if (!dst_ptr)
   {
      throw std::invalid_argument(std::string(fn_name) + ": destination pointer is null");
   }
   if (dst_stride == 0 || dst_stride > kMaxSdmaDword)
   {
      throw std::invalid_argument(std::string(fn_name) + ": destination stride exceeds SDMA limits");
   }

   const size_t tile_width_bytes = tile.width_bytes();
   const size_t tile_height = tile.height();
   const size_t src_pitch = tile.src_pitch();
   const uint64_t src_x = static_cast<uint64_t>(tile.offset_n()) * tile.elem_size;
   const uint64_t src_y = static_cast<uint64_t>(tile.offset_m());

   if (tile_width_bytes == 0 || tile_height == 0)
   {
      throw std::invalid_argument(std::string(fn_name) + ": tile has zero extent");
   }
   if (tile_width_bytes > kMaxSdmaDword || tile_height > kMaxSdmaDword)
   {
      throw std::invalid_argument(std::string(fn_name) + ": tile dimensions exceed SDMA limits");
   }
   if (src_pitch == 0 || src_pitch > kMaxSdmaDword)
   {
      throw std::invalid_argument(std::string(fn_name) + ": source pitch exceeds SDMA limits");
   }
   if (src_x > kMaxSdmaDword || src_y > kMaxSdmaDword)
   {
      throw std::invalid_argument(std::string(fn_name) + ": source offsets exceed SDMA limits");
   }

   return packets::LargeSubWindowCopyPacket(tile.data, dst_ptr, static_cast<uint32_t>(tile_width_bytes),
                                            static_cast<uint32_t>(tile_height), static_cast<uint32_t>(src_pitch),
                                            static_cast<uint32_t>(dst_stride), static_cast<uint32_t>(src_x),
                                            static_cast<uint32_t>(src_y), 0, 0);
}

template <typename T> inline packets::AtomicAddPacket<T> build_atomic_packet(T* ptr, T value, const char* fn_name)
{
   if (!ptr)
   {
      throw std::invalid_argument(std::string(fn_name) + ": flag pointer is null");
   }
   return packets::AtomicAddPacket<T>(ptr, value);
}

template <typename T>
inline packets::PollRegmemPacket<T> build_poll_packet(T* ptr, T expected, const char* fn_name, uint32_t interval = 10,
                                                      uint32_t retry = 0xFFF)
{
   if (!ptr)
   {
      throw std::invalid_argument(std::string(fn_name) + ": flag pointer is null");
   }
   return packets::PollRegmemPacket<T>(ptr, expected, interval, retry);
}
} // namespace

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
   validate_linear_args(src, dst, size, "put");
   submit({packets::CopyLinearPacket(src, dst, size)});
}

template <typename T>
void SdmaQueueHostHandle::signal(T* ptr, T value)
{
   static_assert(sizeof(T) == 4 || sizeof(T) == 8, "signal only supports 32-bit or 64-bit types");
   submit({build_atomic_packet(ptr, value, "signal")});
}

void SdmaQueueHostHandle::timestamp(uint64_t* timestamp_ptr)
{
   if (!timestamp_ptr)
   {
      throw std::invalid_argument("Invalid timestamp() parameters");
   }

   submit({packets::TimestampPacket(timestamp_ptr)});
}

template <typename T>
void SdmaQueueHostHandle::put_signal(void* src, void* dst, size_t size, T* flag_ptr, T flag_value)
{
   validate_linear_args(src, dst, size, "put_signal");

   submit({
      packets::CopyLinearPacket(src, dst, size),
      build_atomic_packet(flag_ptr, flag_value, "put_signal")
   });
}

void SdmaQueueHostHandle::put_tile(const Tile& tile, void* dst_ptr, size_t dst_stride)
{
   submit({build_tile_packet(tile, dst_ptr, dst_stride, "put_tile")});
}

template <typename T>
void SdmaQueueHostHandle::put_tile_signal(const Tile& tile, void* dst_ptr, size_t dst_stride, T* flag_ptr,
                                          T flag_value)
{
   submit({
      build_tile_packet(tile, dst_ptr, dst_stride, "put_tile_signal"),
      build_atomic_packet(flag_ptr, flag_value, "put_tile_signal")
   });
}

// Explicit template instantiations
template void SdmaQueueHostHandle::signal<uint32_t>(uint32_t* ptr, uint32_t value);
template void SdmaQueueHostHandle::signal<uint64_t>(uint64_t* ptr, uint64_t value);

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
   validate_linear_args(src, dst, size, "wait_flag_then_put");

   submit({
      build_poll_packet(flag_ptr, expected_value, "wait_flag_then_put"),
      packets::CopyLinearPacket(src, dst, size)
   });
}

template <typename T>
void SdmaQueueHostHandle::wait_flag_then_put_tile(T* flag_ptr, T expected_value, const Tile& tile, void* dst_ptr,
                                                   size_t dst_stride)
{
   submit({
      build_poll_packet(flag_ptr, expected_value, "wait_flag_then_put_tile"),
      build_tile_packet(tile, dst_ptr, dst_stride, "wait_flag_then_put_tile")
   });
}

template <typename T>
void SdmaQueueHostHandle::wait_flag_then_put_tiles(T* flag_ptr, T expected_value, const std::vector<Tile>& tiles,
                                                    const std::vector<void*>& dst_ptrs,
                                                    const std::vector<size_t>& dst_strides)
{
   static_assert(sizeof(T) == 4, "wait_flag_then_put_tiles only supports 32-bit types");

   if (tiles.empty() || tiles.size() != dst_ptrs.size() || tiles.size() != dst_strides.size())
   {
      throw std::invalid_argument("Invalid wait_flag_then_put_tiles() parameters");
   }

   std::vector<SdmaPacket> packets;
   packets.reserve(1 + tiles.size());

   packets.emplace_back(build_poll_packet(flag_ptr, expected_value, "wait_flag_then_put_tiles"));

   for (size_t i = 0; i < tiles.size(); ++i)
   {
      packets.emplace_back(build_tile_packet(tiles[i], dst_ptrs[i], dst_strides[i], "wait_flag_then_put_tiles"));
   }

   submit(packets);
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

void SdmaQueueHostHandle::submit(const std::vector<SdmaPacket>& packets)
{
   if (packets.empty())
   {
      return;
   }

   // Calculate total size
   size_t total_size = 0;
   for (const auto& pkt : packets)
   {
      total_size += std::visit([](const auto& p) { return p.size_bytes(); }, pkt);
   }

   // Reserve, place, submit
   uint64_t offset = reserveQueueSpace(total_size);
   uint64_t current = offset;

   for (const auto& pkt : packets)
   {
      std::visit([&](const auto& p) {
         placePacket(p.data(), p.size_bytes(), current);
         current += p.size_bytes();
      }, pkt);
   }

   submitPacket(offset, offset + total_size);
}

void SdmaQueueHostHandle::submit(std::initializer_list<SdmaPacket> packets)
{
   if (packets.size() == 0)
   {
      return;
   }

   // Calculate total size
   size_t total_size = 0;
   for (const auto& pkt : packets)
   {
      total_size += std::visit([](const auto& p) { return p.size_bytes(); }, pkt);
   }

   // Reserve, place, submit
   uint64_t offset = reserveQueueSpace(total_size);
   uint64_t current = offset;

   for (const auto& pkt : packets)
   {
      std::visit([&](const auto& p) {
         placePacket(p.data(), p.size_bytes(), current);
         current += p.size_bytes();
      }, pkt);
   }

   submitPacket(offset, offset + total_size);
}

} // namespace anvil
