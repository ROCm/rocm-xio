#include <cstddef>

#include <nanobind/nanobind.h>
#include <nanobind/stl/vector.h>

#include "sdma-ep.h"
#include "sdma-host-queue.h"
#include "sdma_packets.hpp"

namespace nb = nanobind;
using namespace nb::literals;
using namespace xio;

namespace {
constexpr int kQueueDeviceCtxSize = sizeof(sdma_ep::SdmaQueuePythonDeviceCtx) /
                                    sizeof(uintptr_t);
constexpr std::size_t kCopyLinearCommandBytes = sizeof(SDMA_PKT_COPY_LINEAR);
constexpr std::size_t kCopyLinearSubWindowCommandBytes = sizeof(
  SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY);
constexpr std::size_t kAtomicCommandBytes = sizeof(SDMA_PKT_ATOMIC);
} // namespace

void register_sdma_ep(nb::module_& m) {
  // Setup functions
  m.def("init", &sdma_ep::initEndpoint, "Initialize SDMA endpoint");
  m.def("shutdown", &sdma_ep::shutdownEndpoint, "Shutdown SDMA endpoint");

  m.def(
    "create_queue",
    [](int srcDevice, int dstDevice) {
      // Use idempotent init for Python path
      int rc = sdma_ep::initQueue(srcDevice, dstDevice);
      if (rc != 0) {
        throw std::runtime_error("initQueue failed");
      }
      return 0; // Always channel 0 for Python
    },
    "src_device"_a, "dst_device"_a,
    "Create device-initiated SDMA queue (idempotent)");

  m.def(
    "create_host_queue",
    [](int srcDevice, int dstDevice) {
      // Use idempotent init for Python path
      int rc = sdma_ep::initHostQueue(srcDevice, dstDevice);
      if (rc != 0) {
        throw std::runtime_error("initHostQueue failed");
      }
      return 0; // Always channel 0 for Python
    },
    "src_device"_a, "dst_device"_a,
    "Create host-initiated SDMA queue (idempotent)");

  m.def(
    "get_queue_device_ctx",
    [](int srcDevice, int dstDevice) {
      return sdma_ep::getPythonDeviceContext(srcDevice, dstDevice);
    },
    "src_device"_a, "dst_device"_a,
    "Get device context handles for the queue (queue 0)");

  // Host-initiated data transfer functions
  m.def(
    "put",
    [](int srcDevice, int dstDevice, int channelIdx, uintptr_t dst,
       uintptr_t src, size_t size) {
      auto handle = sdma_ep::getHostHandle(srcDevice, dstDevice, channelIdx);
      handle.put(reinterpret_cast<void*>(dst),
                 reinterpret_cast<const void*>(src), size);
    },
    "src_device"_a, "dst_device"_a, "channel_idx"_a, "dst"_a, "src"_a, "size"_a,
    "Host-initiated 1D memory copy");

  m.def(
    "put_signal",
    [](int srcDevice, int dstDevice, int channelIdx, uintptr_t dst,
       uintptr_t src, size_t size, uintptr_t flag_ptr, uint64_t flag_value,
       int flag_bits) {
      auto handle = sdma_ep::getHostHandle(srcDevice, dstDevice, channelIdx);
      if (flag_bits == 32) {
        handle.put_signal(reinterpret_cast<void*>(dst),
                          reinterpret_cast<const void*>(src), size,
                          reinterpret_cast<uint32_t*>(flag_ptr),
                          static_cast<uint32_t>(flag_value));
      } else if (flag_bits == 64) {
        handle.put_signal(reinterpret_cast<void*>(dst),
                          reinterpret_cast<const void*>(src), size,
                          reinterpret_cast<uint64_t*>(flag_ptr), flag_value);
      } else {
        throw std::invalid_argument("put_signal: flag_bits must be 32 or 64");
      }
    },
    "src_device"_a, "dst_device"_a, "channel_idx"_a, "dst"_a, "src"_a, "size"_a,
    "flag_ptr"_a, "flag_value"_a, "flag_bits"_a = 64,
    "Host-initiated linear memory copy with atomic signal in one submission");

  m.def(
    "put_tile",
    [](int srcDevice, int dstDevice, int channelIdx, uintptr_t dst_ptr,
       uintptr_t src_ptr, size_t data_size, size_t tile_height,
       size_t tile_width, size_t dst_stride, size_t src_stride) {
      auto handle = sdma_ep::getHostHandle(srcDevice, dstDevice, channelIdx);
      handle.put_tile(reinterpret_cast<void*>(dst_ptr),
                      reinterpret_cast<const void*>(src_ptr), data_size,
                      tile_height, tile_width, src_stride, dst_stride);
    },
    "src_device"_a, "dst_device"_a, "channel_idx"_a, "dst_addr"_a,
    "global_addr"_a, "data_size"_a, "tile_height"_a, "tile_width"_a,
    "dst_stride"_a, "src_stride"_a,
    "Host-initiated 2D tile transfer using sub-window copy");

  m.def(
    "put_tiles",
    [](int srcDevice, int dstDevice, int channelIdx,
       const std::vector<uintptr_t>& dst_ptrs_uintptr,
       const std::vector<uintptr_t>& src_ptrs_uintptr, size_t data_size,
       const std::vector<size_t>& tile_heights,
       const std::vector<size_t>& tile_widths,
       const std::vector<size_t>& dst_strides,
       const std::vector<size_t>& src_strides) {
      auto handle = sdma_ep::getHostHandle(srcDevice, dstDevice, channelIdx);
      std::vector<const void*> src_ptrs;
      src_ptrs.reserve(src_ptrs_uintptr.size());
      for (uintptr_t ptr : src_ptrs_uintptr) {
        src_ptrs.push_back(reinterpret_cast<const void*>(ptr));
      }
      std::vector<void*> dst_ptrs;
      dst_ptrs.reserve(dst_ptrs_uintptr.size());
      for (uintptr_t ptr : dst_ptrs_uintptr) {
        dst_ptrs.push_back(reinterpret_cast<void*>(ptr));
      }
      handle.put_tiles(dst_ptrs, src_ptrs, data_size, tile_heights, tile_widths,
                       src_strides, dst_strides);
    },
    "src_device"_a, "dst_device"_a, "channel_idx"_a, "dst_addrs"_a,
    "global_addrs"_a, "data_size"_a, "tile_heights"_a, "tile_widths"_a,
    "dst_strides"_a, "src_strides"_a,
    "Host-initiated batched 2D tile transfers");

  m.def(
    "put_tile_signal",
    [](int srcDevice, int dstDevice, int channelIdx, uintptr_t dst_ptr,
       uintptr_t src_ptr, size_t data_size, size_t tile_height,
       size_t tile_width, size_t dst_stride, size_t src_stride,
       uintptr_t flag_ptr, uint64_t flag_value, int flag_bits) {
      auto handle = sdma_ep::getHostHandle(srcDevice, dstDevice, channelIdx);
      if (flag_bits == 32) {
        handle.put_tile_signal(reinterpret_cast<void*>(dst_ptr),
                               reinterpret_cast<const void*>(src_ptr),
                               data_size, tile_height, tile_width, src_stride,
                               dst_stride,
                               reinterpret_cast<uint32_t*>(flag_ptr),
                               static_cast<uint32_t>(flag_value));
      } else if (flag_bits == 64) {
        handle.put_tile_signal(reinterpret_cast<void*>(dst_ptr),
                               reinterpret_cast<const void*>(src_ptr),
                               data_size, tile_height, tile_width, src_stride,
                               dst_stride,
                               reinterpret_cast<uint64_t*>(flag_ptr),
                               flag_value);
      } else {
        throw std::invalid_argument(
          "put_tile_signal: flag_bits must be 32 or 64");
      }
    },
    "src_device"_a, "dst_device"_a, "channel_idx"_a, "dst_addr"_a,
    "global_addr"_a, "data_size"_a, "tile_height"_a, "tile_width"_a,
    "dst_stride"_a, "src_stride"_a, "flag_ptr"_a, "flag_value"_a,
    "flag_bits"_a = 32,
    "Host-initiated 2D tile transfer with atomic signal in one submission");

  m.def(
    "put_tiles_signal",
    [](int srcDevice, int dstDevice, int channelIdx,
       const std::vector<uintptr_t>& dst_ptrs_uintptr,
       const std::vector<uintptr_t>& src_ptrs_uintptr, size_t data_size,
       const std::vector<size_t>& tile_heights,
       const std::vector<size_t>& tile_widths,
       const std::vector<size_t>& dst_strides,
       const std::vector<size_t>& src_strides, uintptr_t flag_ptr,
       uint64_t flag_value, int flag_bits) {
      auto handle = sdma_ep::getHostHandle(srcDevice, dstDevice, channelIdx);
      std::vector<const void*> src_ptrs;
      src_ptrs.reserve(src_ptrs_uintptr.size());
      for (uintptr_t ptr : src_ptrs_uintptr) {
        src_ptrs.push_back(reinterpret_cast<const void*>(ptr));
      }
      std::vector<void*> dst_ptrs;
      dst_ptrs.reserve(dst_ptrs_uintptr.size());
      for (uintptr_t ptr : dst_ptrs_uintptr) {
        dst_ptrs.push_back(reinterpret_cast<void*>(ptr));
      }
      if (flag_bits == 32) {
        handle.put_tiles_signal(dst_ptrs, src_ptrs, data_size, tile_heights,
                                tile_widths, src_strides, dst_strides,
                                reinterpret_cast<uint32_t*>(flag_ptr),
                                static_cast<uint32_t>(flag_value));
      } else if (flag_bits == 64) {
        handle.put_tiles_signal(dst_ptrs, src_ptrs, data_size, tile_heights,
                                tile_widths, src_strides, dst_strides,
                                reinterpret_cast<uint64_t*>(flag_ptr),
                                flag_value);
      } else {
        throw std::invalid_argument(
          "put_tiles_signal: flag_bits must be 32 or 64");
      }
    },
    "src_device"_a, "dst_device"_a, "channel_idx"_a, "dst_addrs"_a,
    "global_addrs"_a, "data_size"_a, "tile_heights"_a, "tile_widths"_a,
    "dst_strides"_a, "src_strides"_a, "flag_ptr"_a, "flag_value"_a,
    "flag_bits"_a = 32,
    "Host-initiated batched 2D tile transfers with atomic signal in one "
    "submission");

  m.def(
    "wait_flag_then_put",
    [](int srcDevice, int dstDevice, int channelIdx, uintptr_t flag_ptr,
       uint32_t expected_value, uintptr_t dst, uintptr_t src, size_t size,
       int flag_bits) {
      auto handle = sdma_ep::getHostHandle(srcDevice, dstDevice, channelIdx);
      if (flag_bits == 32) {
        handle.wait_flag_then_put(reinterpret_cast<uint32_t*>(flag_ptr),
                                  expected_value, reinterpret_cast<void*>(dst),
                                  reinterpret_cast<const void*>(src), size);
      } else {
        throw std::invalid_argument("wait_flag_then_put: flag_bits must be 32");
      }
    },
    "src_device"_a, "dst_device"_a, "channel_idx"_a, "flag_ptr"_a,
    "expected_value"_a, "dst"_a, "src"_a, "size"_a, "flag_bits"_a = 32,
    "Host-initiated wait-on-flag then linear memory copy (POLL + COPY in one "
    "submission)");

  m.def(
    "wait_flag_then_put_tile",
    [](int srcDevice, int dstDevice, int channelIdx, uintptr_t flag_ptr,
       uint32_t expected_value, uintptr_t dst_ptr, uintptr_t src_ptr,
       size_t data_size, size_t tile_height, size_t tile_width,
       size_t dst_stride, size_t src_stride, int flag_bits) {
      auto handle = sdma_ep::getHostHandle(srcDevice, dstDevice, channelIdx);
      if (flag_bits == 32) {
        handle.wait_flag_then_put_tile(reinterpret_cast<uint32_t*>(flag_ptr),
                                       expected_value,
                                       reinterpret_cast<void*>(dst_ptr),
                                       reinterpret_cast<const void*>(src_ptr),
                                       data_size, tile_height, tile_width,
                                       src_stride, dst_stride);
      } else {
        throw std::invalid_argument(
          "wait_flag_then_put_tile: flag_bits must be 32");
      }
    },
    "src_device"_a, "dst_device"_a, "channel_idx"_a, "flag_ptr"_a,
    "expected_value"_a, "dst_addr"_a, "global_addr"_a, "data_size"_a,
    "tile_height"_a, "tile_width"_a, "dst_stride"_a, "src_stride"_a,
    "flag_bits"_a = 32,
    "Host-initiated wait-on-flag then 2D tile transfer (POLL + SUB_WINDOW_COPY "
    "in one submission)");

  m.def(
    "wait_flag_then_put_tiles",
    [](int srcDevice, int dstDevice, int channelIdx, uintptr_t flag_ptr,
       uint32_t expected_value, const std::vector<uintptr_t>& dst_ptrs_uintptr,
       const std::vector<uintptr_t>& src_ptrs_uintptr, size_t data_size,
       const std::vector<size_t>& tile_heights,
       const std::vector<size_t>& tile_widths,
       const std::vector<size_t>& dst_strides,
       const std::vector<size_t>& src_strides, int flag_bits) {
      auto handle = sdma_ep::getHostHandle(srcDevice, dstDevice, channelIdx);
      if (flag_bits == 32) {
        std::vector<const void*> src_ptrs;
        src_ptrs.reserve(src_ptrs_uintptr.size());
        for (uintptr_t ptr : src_ptrs_uintptr) {
          src_ptrs.push_back(reinterpret_cast<const void*>(ptr));
        }
        std::vector<void*> dst_ptrs;
        dst_ptrs.reserve(dst_ptrs_uintptr.size());
        for (uintptr_t ptr : dst_ptrs_uintptr) {
          dst_ptrs.push_back(reinterpret_cast<void*>(ptr));
        }
        handle.wait_flag_then_put_tiles(reinterpret_cast<uint32_t*>(flag_ptr),
                                        expected_value, dst_ptrs, src_ptrs,
                                        data_size, tile_heights, tile_widths,
                                        src_strides, dst_strides);
      } else {
        throw std::invalid_argument(
          "wait_flag_then_put_tiles: flag_bits must be 32");
      }
    },
    "src_device"_a, "dst_device"_a, "channel_idx"_a, "flag_ptr"_a,
    "expected_value"_a, "dst_addrs"_a, "global_addrs"_a, "data_size"_a,
    "tile_heights"_a, "tile_widths"_a, "dst_strides"_a, "src_strides"_a,
    "flag_bits"_a = 32,
    "Host-initiated wait-on-flag then batched 2D tile transfers");

  m.def(
    "signal",
    [](int srcDevice, int dstDevice, int channelIdx, uintptr_t flag_ptr,
       uint64_t value, int flag_bits) {
      auto handle = sdma_ep::getHostHandle(srcDevice, dstDevice, channelIdx);
      if (flag_bits == 32) {
        handle.signal(reinterpret_cast<uint32_t*>(flag_ptr),
                      static_cast<uint32_t>(value));
      } else if (flag_bits == 64) {
        handle.signal(reinterpret_cast<uint64_t*>(flag_ptr), value);
      } else {
        throw std::invalid_argument("signal: flag_bits must be 32 or 64");
      }
    },
    "src_device"_a, "dst_device"_a, "channel_idx"_a, "flag_ptr"_a,
    "value"_a = 1, "flag_bits"_a = 32,
    "Atomic increment of a flag (32- or 64-bit)");

  m.def(
    "timestamp",
    [](int srcDevice, int dstDevice, int channelIdx, uintptr_t timestamp_ptr) {
      auto handle = sdma_ep::getHostHandle(srcDevice, dstDevice, channelIdx);
      handle.timestamp(reinterpret_cast<uint64_t*>(timestamp_ptr));
    },
    "src_device"_a, "dst_device"_a, "channel_idx"_a, "timestamp_ptr"_a,
    "Host-initiated timestamp write to 64-bit memory location");

  m.def(
    "quiet",
    [](int srcDevice, int dstDevice, int channelIdx) {
      auto handle = sdma_ep::getHostHandle(srcDevice, dstDevice, channelIdx);
      handle.quiet();
    },
    "src_device"_a, "dst_device"_a, "channel_idx"_a,
    "Wait for all SDMA operations to complete");

  // SdmaQueuePythonDeviceCtx struct
  nb::class_<sdma_ep::SdmaQueuePythonDeviceCtx>(m, "SdmaQueuePythonDeviceCtx")
    .def(nb::init<>())
    .def_rw("queue_buf", &sdma_ep::SdmaQueuePythonDeviceCtx::queueBuf,
            "Queue buffer pointer")
    .def_rw("rptr", &sdma_ep::SdmaQueuePythonDeviceCtx::rptr, "Read pointer")
    .def_rw("wptr", &sdma_ep::SdmaQueuePythonDeviceCtx::wptr, "Write pointer")
    .def_rw("doorbell", &sdma_ep::SdmaQueuePythonDeviceCtx::doorbell,
            "Doorbell pointer")
    .def_rw("cached_wptr", &sdma_ep::SdmaQueuePythonDeviceCtx::cachedWptr,
            "Cached write pointer")
    .def_rw("committed_wptr", &sdma_ep::SdmaQueuePythonDeviceCtx::committedWptr,
            "Committed write pointer");

  // Constants
  m.attr("QUEUE_DEVICE_CTX_SIZE") = kQueueDeviceCtxSize;
  m.attr("COPY_LINEAR_COMMAND_BYTES") = kCopyLinearCommandBytes;
  m.attr(
    "COPY_LINEAR_SUB_WINDOW_COMMAND_BYTES") = kCopyLinearSubWindowCommandBytes;
  m.attr("ATOMIC_COMMAND_BYTES") = kAtomicCommandBytes;
  m.attr("SDMA_QUEUE_SIZE") = sdma_ep::SDMA_QUEUE_SIZE;
}

NB_MODULE(sdma_ep_py, m) {
  register_sdma_ep(m);
}
