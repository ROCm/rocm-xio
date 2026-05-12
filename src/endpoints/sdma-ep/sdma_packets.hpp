#pragma once

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <type_traits>

#if defined(__host__) && defined(__device__)
#define SDMA_HOST_DEVICE __host__ __device__
#else
#define SDMA_HOST_DEVICE
#endif

#if defined(__forceinline__)
#define SDMA_FORCEINLINE __forceinline__
#else
#define SDMA_FORCEINLINE inline
#endif

#include "sdma_opcodes.h"
#include "sdma_pkt_struct.h"

namespace xio {
namespace sdma_ep {
/** SDMA queue size in bytes (8 MiB). */
constexpr uint64_t SDMA_QUEUE_SIZE = 8 * 1024 * 1024;
} // namespace sdma_ep
} // namespace xio

namespace anvil {
namespace packets {

struct CopyLinearPacket {
  SDMA_PKT_COPY_LINEAR value{};

  SDMA_HOST_DEVICE SDMA_FORCEINLINE explicit CopyLinearPacket(void* src,
                                                              void* dst,
                                                              size_t size) {
    assert(src != nullptr && dst != nullptr &&
           "CopyLinearPacket: nullptr address");
    assert(size > 0 && size <= 0x100000000ull &&
           "CopyLinearPacket: size out of range");

    value.HEADER_UNION.op = SDMA_OP_COPY;
    value.HEADER_UNION.sub_op = SDMA_SUBOP_COPY_LINEAR;
    value.COUNT_UNION.count = static_cast<uint32_t>(size - 1);

    uintptr_t src_addr = reinterpret_cast<uintptr_t>(src);
    value.SRC_ADDR_LO_UNION.src_addr_31_0 = static_cast<uint32_t>(src_addr);
    value.SRC_ADDR_HI_UNION.src_addr_63_32 = static_cast<uint32_t>(src_addr >>
                                                                   32);

    uintptr_t dst_addr = reinterpret_cast<uintptr_t>(dst);
    value.DST_ADDR_LO_UNION.dst_addr_31_0 = static_cast<uint32_t>(dst_addr);
    value.DST_ADDR_HI_UNION.dst_addr_63_32 = static_cast<uint32_t>(dst_addr >>
                                                                   32);
  }

  SDMA_HOST_DEVICE SDMA_FORCEINLINE const SDMA_PKT_COPY_LINEAR* data() const {
    return &value;
  }
  SDMA_HOST_DEVICE SDMA_FORCEINLINE SDMA_PKT_COPY_LINEAR* data() {
    return &value;
  }
  SDMA_HOST_DEVICE SDMA_FORCEINLINE static constexpr size_t size_bytes() {
    return sizeof(SDMA_PKT_COPY_LINEAR);
  }
};

struct TimestampPacket {
  SDMA_PKT_TIMESTAMP value{};

  SDMA_HOST_DEVICE SDMA_FORCEINLINE explicit TimestampPacket(uint64_t* addr) {
    assert(addr != nullptr && "TimestampPacket: nullptr address");
    value.HEADER_UNION.op = SDMA_OP_TIMESTAMP;
    value.HEADER_UNION.sub_op = SDMA_SUBOP_TIMESTAMP_GLOBAL;

    uintptr_t ts_addr = reinterpret_cast<uintptr_t>(addr);
    value.ADDR_LO_UNION.addr_31_0 = static_cast<uint32_t>(ts_addr);
    value.ADDR_HI_UNION.addr_63_32 = static_cast<uint32_t>(ts_addr >> 32);
  }

  SDMA_HOST_DEVICE SDMA_FORCEINLINE const SDMA_PKT_TIMESTAMP* data() const {
    return &value;
  }
  SDMA_HOST_DEVICE SDMA_FORCEINLINE SDMA_PKT_TIMESTAMP* data() {
    return &value;
  }
  SDMA_HOST_DEVICE SDMA_FORCEINLINE static constexpr size_t size_bytes() {
    return sizeof(SDMA_PKT_TIMESTAMP);
  }
};

struct LargeSubWindowCopyPacket {
  SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY value{};

  SDMA_HOST_DEVICE SDMA_FORCEINLINE LargeSubWindowCopyPacket(
    void* srcBuf, void* dstBuf, uint32_t tile_width, uint32_t tile_height,
    uint32_t src_buffer_pitch, uint32_t dst_buffer_pitch, uint32_t src_x,
    uint32_t src_y, uint32_t dst_x, uint32_t dst_y) {
    assert(srcBuf != nullptr && dstBuf != nullptr &&
           "LargeSubWindowCopyPacket: nullptr buffer");
    assert(tile_width > 0 && tile_height > 0 &&
           "LargeSubWindowCopyPacket: zero tile dimension");

    value.HEADER_UNION.op = SDMA_OP_COPY;
    value.HEADER_UNION.sub_op = SDMA_SUBOP_COPY_LINEAR_SUB_WINDOW;

    uintptr_t src_addr = reinterpret_cast<uintptr_t>(srcBuf);
    value.SRC_ADDR_LO_UNION.src_base_addr_31_0 = static_cast<uint32_t>(
      src_addr);
    value.SRC_ADDR_HI_UNION.src_base_addr_63_32 = static_cast<uint32_t>(
      src_addr >> 32);

    value.SRC_X_UNION.src_x = src_x;
    value.SRC_Y_UNION.src_y = src_y;
    value.SRC_Z_UNION.src_z = 0;
    value.SRC_PITCH_UNION.src_pitch = src_buffer_pitch - 1;

    const uint64_t src_slice_pitch = 0;
    value.SRC_SLICE_PITCH_LO_UNION.src_slice_pitch_31_0 = static_cast<uint32_t>(
      src_slice_pitch & 0xFFFFFFFF);
    value.SRC_SLICE_PITCH_HI_UNION.src_slice_pitch_47_32 =
      static_cast<uint16_t>((src_slice_pitch >> 32) & 0xFFFF);

    uintptr_t dst_addr = reinterpret_cast<uintptr_t>(dstBuf);
    value.DST_ADDR_LO_UNION.dst_data_31_0 = static_cast<uint32_t>(dst_addr);
    value.DST_ADDR_HI_UNION.src_data_63_32 = static_cast<uint32_t>(dst_addr >>
                                                                   32);

    value.DST_X_UNION.dst_x = dst_x;
    value.DST_Y_UNION.dst_y = dst_y;
    value.DST_Z_UNION.dst_z = 0;
    value.DST_PITCH_UNION.dst_pitch = dst_buffer_pitch - 1;

    const uint64_t dst_slice_pitch = 0;
    value.DST_SLICE_PITCH_LO_UNION.dst_slice_pitch_31_0 = static_cast<uint32_t>(
      dst_slice_pitch & 0xFFFFFFFF);
    value.DST_SLICE_PITCH_HI_UNION.dst_slice_pitch_47_32 =
      static_cast<uint16_t>((dst_slice_pitch >> 32) & 0xFFFF);

    value.RECT_X_UNION.rect_x = tile_width - 1;
    value.RECT_Y_UNION.rect_y = tile_height - 1;
    value.RECT_Z_UNION.rect_z = 0;
  }

  SDMA_HOST_DEVICE SDMA_FORCEINLINE const SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY*
  data() const {
    return &value;
  }
  SDMA_HOST_DEVICE SDMA_FORCEINLINE SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY*
  data() {
    return &value;
  }
  SDMA_HOST_DEVICE SDMA_FORCEINLINE static constexpr size_t size_bytes() {
    return sizeof(SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY);
  }
};

template <typename T>
struct AtomicAddPacket {
  static_assert(std::is_integral_v<T>,
                "AtomicAddPacket requires integral type");
  static_assert(sizeof(T) == 4 || sizeof(T) == 8,
                "AtomicAddPacket supports 32- or 64-bit values");

  SDMA_PKT_ATOMIC value{};

  SDMA_HOST_DEVICE SDMA_FORCEINLINE AtomicAddPacket(T* ptr, T delta) {
    assert(ptr != nullptr && "AtomicAddPacket: nullptr address");

    value.HEADER_UNION.op = SDMA_OP_ATOMIC;
    value.HEADER_UNION.operation = (sizeof(T) == 8) ? SDMA_ATOMIC_ADD64
                                                    : SDMA_ATOMIC_ADD32;

    uintptr_t addr = reinterpret_cast<uintptr_t>(ptr);
    value.ADDR_LO_UNION.addr_31_0 = static_cast<uint32_t>(addr);
    value.ADDR_HI_UNION.addr_63_32 = static_cast<uint32_t>(addr >> 32);

    const uint64_t val64 = static_cast<uint64_t>(delta);
    value.SRC_DATA_LO_UNION.src_data_31_0 = static_cast<uint32_t>(val64);
    value.SRC_DATA_HI_UNION.src_data_63_32 = static_cast<uint32_t>(val64 >> 32);
  }

  SDMA_HOST_DEVICE SDMA_FORCEINLINE const SDMA_PKT_ATOMIC* data() const {
    return &value;
  }
  SDMA_HOST_DEVICE SDMA_FORCEINLINE SDMA_PKT_ATOMIC* data() {
    return &value;
  }
  SDMA_HOST_DEVICE SDMA_FORCEINLINE static constexpr size_t size_bytes() {
    return sizeof(SDMA_PKT_ATOMIC);
  }
};

template <typename T>
struct PollRegmemPacket {
  static_assert(std::is_integral_v<T>,
                "PollRegmemPacket requires integral type");
  static_assert(sizeof(T) == 4, "PollRegmemPacket supports 32-bit values only");

  SDMA_PKT_POLL_REGMEM value{};

  SDMA_HOST_DEVICE SDMA_FORCEINLINE
  PollRegmemPacket(T* flag_ptr, T expected_value, uint32_t interval = 10,
                   uint32_t retry_count = 0xFFF) {
    assert(flag_ptr != nullptr && "PollRegmemPacket: nullptr flag pointer");

    value.HEADER_UNION.op = SDMA_OP_POLL_REGMEM;
    value.HEADER_UNION.func = 5;
    value.HEADER_UNION.mem_poll = 1;

    uintptr_t addr = reinterpret_cast<uintptr_t>(flag_ptr);
    value.ADDR_LO_UNION.addr_31_0 = static_cast<uint32_t>(addr);
    value.ADDR_HI_UNION.addr_63_32 = static_cast<uint32_t>(addr >> 32);

    value.VALUE_UNION.value = static_cast<uint32_t>(expected_value);
    value.MASK_UNION.mask = 0xFFFFFFFFu;
    value.DW5_UNION.interval = interval;
    value.DW5_UNION.retry_count = retry_count;
  }

  SDMA_HOST_DEVICE SDMA_FORCEINLINE const SDMA_PKT_POLL_REGMEM* data() const {
    return &value;
  }
  SDMA_HOST_DEVICE SDMA_FORCEINLINE SDMA_PKT_POLL_REGMEM* data() {
    return &value;
  }
  SDMA_HOST_DEVICE SDMA_FORCEINLINE static constexpr size_t size_bytes() {
    return sizeof(SDMA_PKT_POLL_REGMEM);
  }
};

} // namespace packets
} // namespace anvil

#undef SDMA_FORCEINLINE
#undef SDMA_HOST_DEVICE
