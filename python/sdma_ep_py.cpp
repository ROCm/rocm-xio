#include <nanobind/nanobind.h>
#include <nanobind/stl/vector.h>
#include <cstddef>

#include "sdma-ep.h"
#include "sdma_packets.hpp"

namespace nb = nanobind;
using namespace nb::literals;

namespace
{
constexpr int kQueueDeviceCtxSize = sizeof(sdma_ep::SdmaQueuePythonDeviceCtx) / sizeof(uintptr_t);
constexpr std::size_t kCopyLinearCommandBytes = sizeof(SDMA_PKT_COPY_LINEAR);
constexpr std::size_t kCopyLinearSubWindowCommandBytes = sizeof(SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY);
constexpr std::size_t kAtomicCommandBytes = sizeof(SDMA_PKT_ATOMIC);
} // namespace

void register_sdma_ep(nb::module_& m)
{
   // Setup functions
   m.def("init", &sdma_ep::initEndpoint, "Initialize SDMA endpoint");
   m.def("shutdown", &sdma_ep::shutdownEndpoint, "Shutdown SDMA endpoint");

   m.def("create_connection",
         [](int srcDevice, int dstDevice) {
            sdma_ep::SdmaConnectionInfo info;
            int rc = sdma_ep::createConnection(srcDevice, dstDevice, &info);
            if (rc != 0) {
               throw std::runtime_error("createConnection failed");
            }
            return std::make_tuple(info.srcDeviceId, info.dstDeviceId, info.engineId);
         },
         "src_device"_a, "dst_device"_a,
         "Create SDMA connection between two devices");

   m.def("create_queue",
         [](int srcDevice, int dstDevice) {
            sdma_ep::SdmaQueueInfo info;
            int rc = sdma_ep::createQueue(srcDevice, dstDevice, &info);
            if (rc != 0) {
               throw std::runtime_error("createQueue failed");
            }
            return info.channelIdx;
         },
         "src_device"_a, "dst_device"_a,
         "Create device-initiated SDMA queue");

   m.def("create_host_queue",
         [](int srcDevice, int dstDevice) {
            sdma_ep::SdmaQueueInfo info;
            int rc = sdma_ep::createHostQueue(srcDevice, dstDevice, &info);
            if (rc != 0) {
               throw std::runtime_error("createHostQueue failed");
            }
            return info.channelIdx;
         },
         "src_device"_a, "dst_device"_a,
         "Create host-initiated SDMA queue");

   m.def("get_queue_device_ctx",
         [](int srcDevice, int dstDevice) {
            return sdma_ep::get_queue_device_ctx(srcDevice, dstDevice);
         },
         "src_device"_a, "dst_device"_a,
         "Get device context handles for the queue (queue 0)");

   // Host-initiated data transfer functions
   m.def("put",
         [](int srcDevice, int dstDevice, int channelIdx, uintptr_t src, uintptr_t dst, size_t size) {
            sdma_ep::put(srcDevice, dstDevice, channelIdx,
                        reinterpret_cast<void*>(src),
                        reinterpret_cast<void*>(dst), size);
         },
         "src_device"_a, "dst_device"_a, "channel_idx"_a, "src"_a, "dst"_a, "size"_a,
         "Host-initiated 1D memory copy");

   m.def("put_signal",
         [](int srcDevice, int dstDevice, int channelIdx, uintptr_t src, uintptr_t dst, size_t size,
            uintptr_t flag_ptr, uint64_t flag_value, int flag_bits) {
            sdma_ep::put_signal(srcDevice, dstDevice, channelIdx,
                               reinterpret_cast<void*>(src),
                               reinterpret_cast<void*>(dst), size,
                               reinterpret_cast<void*>(flag_ptr),
                               flag_value, flag_bits);
         },
         "src_device"_a, "dst_device"_a, "channel_idx"_a, "src"_a, "dst"_a, "size"_a, "flag_ptr"_a,
         "flag_value"_a, "flag_bits"_a = 64,
         "Host-initiated linear memory copy with atomic signal in one submission");

   m.def("put_tile",
         [](int srcDevice, int dstDevice, int channelIdx, const sdma_ep::Tile& tile, uintptr_t dst_ptr,
            size_t dst_stride) {
            sdma_ep::put_tile(srcDevice, dstDevice, channelIdx, tile,
                             reinterpret_cast<void*>(dst_ptr), dst_stride);
         },
         "src_device"_a, "dst_device"_a, "channel_idx"_a, "tile"_a, "dst_ptr"_a, "dst_stride"_a,
         "Host-initiated 2D tile transfer using sub-window copy");

   m.def("put_tiles",
         [](int srcDevice, int dstDevice, int channelIdx, const std::vector<sdma_ep::Tile>& tiles,
            const std::vector<uintptr_t>& dst_ptrs_uintptr, const std::vector<size_t>& dst_strides) {
            std::vector<void*> dst_ptrs;
            dst_ptrs.reserve(dst_ptrs_uintptr.size());
            for (uintptr_t ptr : dst_ptrs_uintptr) {
               dst_ptrs.push_back(reinterpret_cast<void*>(ptr));
            }
            sdma_ep::put_tiles(srcDevice, dstDevice, channelIdx, tiles, dst_ptrs, dst_strides);
         },
         "src_device"_a, "dst_device"_a, "channel_idx"_a, "tiles"_a, "dst_ptrs"_a, "dst_strides"_a,
         "Host-initiated batched 2D tile transfers");

   m.def("put_tile_signal",
         [](int srcDevice, int dstDevice, int channelIdx, const sdma_ep::Tile& tile, uintptr_t dst_ptr,
            size_t dst_stride, uintptr_t flag_ptr, uint64_t flag_value, int flag_bits) {
            sdma_ep::put_tile_signal(srcDevice, dstDevice, channelIdx, tile,
                                    reinterpret_cast<void*>(dst_ptr), dst_stride,
                                    reinterpret_cast<void*>(flag_ptr),
                                    flag_value, flag_bits);
         },
         "src_device"_a, "dst_device"_a, "channel_idx"_a, "tile"_a, "dst_ptr"_a, "dst_stride"_a, "flag_ptr"_a,
         "flag_value"_a, "flag_bits"_a = 32,
         "Host-initiated 2D tile transfer with atomic signal in one submission");

   m.def("put_tiles_signal",
         [](int srcDevice, int dstDevice, int channelIdx, const std::vector<sdma_ep::Tile>& tiles,
            const std::vector<uintptr_t>& dst_ptrs_uintptr, const std::vector<size_t>& dst_strides,
            uintptr_t flag_ptr, uint64_t flag_value, int flag_bits) {
            std::vector<void*> dst_ptrs;
            dst_ptrs.reserve(dst_ptrs_uintptr.size());
            for (uintptr_t ptr : dst_ptrs_uintptr) {
               dst_ptrs.push_back(reinterpret_cast<void*>(ptr));
            }
            sdma_ep::put_tiles_signal(srcDevice, dstDevice, channelIdx, tiles, dst_ptrs, dst_strides,
                                     reinterpret_cast<void*>(flag_ptr), flag_value, flag_bits);
         },
         "src_device"_a, "dst_device"_a, "channel_idx"_a, "tiles"_a, "dst_ptrs"_a, "dst_strides"_a,
         "flag_ptr"_a, "flag_value"_a, "flag_bits"_a = 32,
         "Host-initiated batched 2D tile transfers with atomic signal in one submission");

   m.def("wait_flag_then_put",
         [](int srcDevice, int dstDevice, int channelIdx, uintptr_t flag_ptr, uint32_t expected_value,
            uintptr_t src, uintptr_t dst, size_t size, int flag_bits) {
            sdma_ep::wait_flag_then_put(srcDevice, dstDevice, channelIdx,
                                       reinterpret_cast<void*>(flag_ptr), expected_value,
                                       reinterpret_cast<void*>(src),
                                       reinterpret_cast<void*>(dst), size, flag_bits);
         },
         "src_device"_a, "dst_device"_a, "channel_idx"_a, "flag_ptr"_a, "expected_value"_a, "src"_a, "dst"_a,
         "size"_a, "flag_bits"_a = 32,
         "Host-initiated wait-on-flag then linear memory copy (POLL + COPY in one submission)");

   m.def("wait_flag_then_put_tile",
         [](int srcDevice, int dstDevice, int channelIdx, uintptr_t flag_ptr, uint32_t expected_value,
            const sdma_ep::Tile& tile, uintptr_t dst_ptr, size_t dst_stride, int flag_bits) {
            sdma_ep::wait_flag_then_put_tile(srcDevice, dstDevice, channelIdx,
                                            reinterpret_cast<void*>(flag_ptr), expected_value,
                                            tile, reinterpret_cast<void*>(dst_ptr),
                                            dst_stride, flag_bits);
         },
         "src_device"_a, "dst_device"_a, "channel_idx"_a, "flag_ptr"_a, "expected_value"_a, "tile"_a, "dst_ptr"_a,
         "dst_stride"_a, "flag_bits"_a = 32,
         "Host-initiated wait-on-flag then 2D tile transfer (POLL + SUB_WINDOW_COPY in one submission)");

   m.def("wait_flag_then_put_tiles",
         [](int srcDevice, int dstDevice, int channelIdx, uintptr_t flag_ptr, uint32_t expected_value,
            const std::vector<sdma_ep::Tile>& tiles, const std::vector<uintptr_t>& dst_ptrs_uintptr,
            const std::vector<size_t>& dst_strides, int flag_bits) {
            std::vector<void*> dst_ptrs;
            dst_ptrs.reserve(dst_ptrs_uintptr.size());
            for (uintptr_t ptr : dst_ptrs_uintptr) {
               dst_ptrs.push_back(reinterpret_cast<void*>(ptr));
            }
            sdma_ep::wait_flag_then_put_tiles(srcDevice, dstDevice, channelIdx,
                                             reinterpret_cast<void*>(flag_ptr), expected_value,
                                             tiles, dst_ptrs, dst_strides, flag_bits);
         },
         "src_device"_a, "dst_device"_a, "channel_idx"_a, "flag_ptr"_a, "expected_value"_a, "tiles"_a,
         "dst_ptrs"_a, "dst_strides"_a, "flag_bits"_a = 32,
         "Host-initiated wait-on-flag then batched 2D tile transfers");

   m.def("signal",
         [](int srcDevice, int dstDevice, int channelIdx, uintptr_t flag_ptr, uint64_t value,
            int flag_bits) {
            sdma_ep::signal(srcDevice, dstDevice, channelIdx,
                          reinterpret_cast<void*>(flag_ptr), value, flag_bits);
         },
         "src_device"_a, "dst_device"_a, "channel_idx"_a, "flag_ptr"_a, "value"_a = 1, "flag_bits"_a = 32,
         "Atomic increment of a flag (32- or 64-bit)");

   m.def("timestamp",
         [](int srcDevice, int dstDevice, int channelIdx, uintptr_t timestamp_ptr) {
            sdma_ep::timestamp(srcDevice, dstDevice, channelIdx,
                             reinterpret_cast<void*>(timestamp_ptr));
         },
         "src_device"_a, "dst_device"_a, "channel_idx"_a, "timestamp_ptr"_a,
         "Host-initiated timestamp write to 64-bit memory location");

   m.def("quiet",
         [](int srcDevice, int dstDevice, int channelIdx) {
            sdma_ep::quiet(srcDevice, dstDevice, channelIdx);
         },
         "src_device"_a, "dst_device"_a, "channel_idx"_a,
         "Wait for all SDMA operations to complete");

   // SdmaQueuePythonDeviceCtx struct
   nb::class_<sdma_ep::SdmaQueuePythonDeviceCtx>(m, "SdmaQueuePythonDeviceCtx")
       .def(nb::init<>())
       .def_rw("queue_buf", &sdma_ep::SdmaQueuePythonDeviceCtx::queueBuf, "Queue buffer pointer")
       .def_rw("rptr", &sdma_ep::SdmaQueuePythonDeviceCtx::rptr, "Read pointer")
       .def_rw("wptr", &sdma_ep::SdmaQueuePythonDeviceCtx::wptr, "Write pointer")
       .def_rw("doorbell", &sdma_ep::SdmaQueuePythonDeviceCtx::doorbell, "Doorbell pointer")
       .def_rw("cached_wptr", &sdma_ep::SdmaQueuePythonDeviceCtx::cachedWptr, "Cached write pointer")
       .def_rw("committed_wptr", &sdma_ep::SdmaQueuePythonDeviceCtx::committedWptr, "Committed write pointer");

   // Tile class
   nb::class_<sdma_ep::Tile>(m, "Tile")
       .def(nb::init<>())
       .def_rw("pid_m", &sdma_ep::Tile::pid_m, "Tile coordinate in M dimension")
       .def_rw("pid_n", &sdma_ep::Tile::pid_n, "Tile coordinate in N dimension")
       .def_rw("block_m", &sdma_ep::Tile::block_m, "Block size in M dimension")
       .def_rw("block_n", &sdma_ep::Tile::block_n, "Block size in N dimension")
       .def_rw("data", &sdma_ep::Tile::data, "Pointer to tile data (uintptr_t)")
       .def_rw("elem_size", &sdma_ep::Tile::elem_size, "Element size in bytes")
       .def_rw("src_stride", &sdma_ep::Tile::src_stride, "Source row stride in bytes (0 = contiguous)")
       .def("width_bytes", &sdma_ep::Tile::width_bytes, "Get tile width in bytes")
       .def("height", &sdma_ep::Tile::height, "Get tile height")
       .def("offset_m", &sdma_ep::Tile::offset_m, "Get M offset")
       .def("offset_n", &sdma_ep::Tile::offset_n, "Get N offset")
       .def("src_pitch", &sdma_ep::Tile::src_pitch, "Get source pitch");

   // Constants
   m.attr("QUEUE_DEVICE_CTX_SIZE") = kQueueDeviceCtxSize;
   m.attr("COPY_LINEAR_COMMAND_BYTES") = kCopyLinearCommandBytes;
   m.attr("COPY_LINEAR_SUB_WINDOW_COMMAND_BYTES") = kCopyLinearSubWindowCommandBytes;
   m.attr("ATOMIC_COMMAND_BYTES") = kAtomicCommandBytes;
   m.attr("SDMA_QUEUE_SIZE") = sdma_ep::SDMA_QUEUE_SIZE;
}

NB_MODULE(sdma_ep_py, m) {
   register_sdma_ep(m);
}
