#pragma once

#include <vector>
#include <cstddef>
#include <cstdint>

namespace anvil
{

// Forward declaration
class SdmaQueue;

// Tile representation for 2D transfers
struct Tile
{
   int32_t pid_m;     // Tile coordinate in M dimension
   int32_t pid_n;     // Tile coordinate in N dimension
   int32_t block_m;   // Block size in M dimension
   int32_t block_n;   // Block size in N dimension
   void* data;        // Pointer to tile data
   size_t elem_size;  // Element size in bytes (e.g., 4 for float)
   size_t src_stride; // Source row stride in bytes (0 = contiguous)

   size_t width_bytes() const
   {
      return block_n * elem_size;
   }
   size_t height() const
   {
      return block_m;
   }
   size_t offset_m() const
   {
      return pid_m * block_m;
   }
   size_t offset_n() const
   {
      return pid_n * block_n;
   }
   size_t src_pitch() const
   {
      return src_stride > 0 ? src_stride : width_bytes();
   }
};

// Python device context structure (uintptr_t-based for Python bindings)
struct SdmaQueuePythonDeviceCtx
{
   uintptr_t queueBuf;
   uintptr_t rptr;
   uintptr_t wptr;
   uintptr_t doorbell;

   // Shared variables
   uintptr_t cachedWptr;
   uintptr_t committedWptr;
};
static_assert(sizeof(SdmaQueuePythonDeviceCtx) == 48,
              "SdmaQueuePythonDeviceCtx must be 48 bytes (6 * sizeof(uintptr_t))");

// Host-side handle for CPU-initiated SDMA operations
class SdmaQueueHostHandle
{
 public:
   explicit SdmaQueueHostHandle(SdmaQueue* q) : queue(q)
   {
   }

   // Host-initiated SDMA operations
   void put(void* src, void* dst, size_t size);

   template <typename T> void atomic_add(T* ptr, T value);

   void put_tile(const Tile& tile, void* dst_ptr, size_t dst_stride);

   // Write GPU timestamp to memory location
   void timestamp(uint64_t* timestamp_ptr);

   // Combined put + atomic_add in one SDMA submission (linear memory)
   template <typename T>
   void put_signal(void* src, void* dst, size_t size, T* flag_ptr, T flag_value);

   // Combined put_tile + atomic_add in one SDMA submission
   template <typename T>
   void put_tile_signal(const Tile& tile, void* dst_ptr, size_t dst_stride,
                        T* flag_ptr, T flag_value);

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

 private:
   // Queue management helpers
   uint64_t reserveQueueSpace(size_t size_in_bytes);
   void placePacket(const void* packet, size_t packet_size, uint64_t offset);
   void submitPacket(uint64_t base, uint64_t pending_wptr);
   bool canWriteUpto(uint64_t uptoIndex);
   uint64_t wrapIntoRing(uint64_t index) const;
   void padRingToEnd(uint64_t cur_index);

   SdmaQueue* queue;
};

} // namespace anvil
