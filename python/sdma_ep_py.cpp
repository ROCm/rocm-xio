#include <nanobind/nanobind.h>
#include <nanobind/stl/vector.h>
#include <cstddef>

#include "anvil.hpp"
#include "anvil-host-api.hpp"
#include "anvil_device.hpp"

namespace nb = nanobind;
using namespace anvil;
using namespace nb::literals;

namespace
{
constexpr int kQueueDeviceCtxSize = sizeof(SdmaQueuePythonDeviceCtx) / sizeof(uintptr_t);
constexpr std::size_t kCopyLinearCommandBytes = sizeof(SDMA_PKT_COPY_LINEAR);
constexpr std::size_t kCopyLinearSubWindowCommandBytes = sizeof(SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY);
constexpr std::size_t kAtomicCommandBytes = sizeof(SDMA_PKT_ATOMIC);
} // namespace

void register_sdma_ep(nb::module_& m)
{
   nb::class_<AnvilLib>(m, "AnvilLib")
       .def_static("get_instance", &AnvilLib::getInstance, nb::rv_policy::reference)
       .def("init", &AnvilLib::init)
       .def("connect", &AnvilLib::connect, "src_device"_a, "dst_device"_a, "num_channels"_a = 1,
            "allocate_on_host"_a = false,
            "Connect two devices with one or more SDMA queue channels (idempotent)")
       .def("get_queue_device_ctx", &AnvilLib::get_queue_device_ctx, "src_device"_a, "dst_device"_a,
            "Get device context handles for the queue (queue 0)")
       .def(
           "put",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, uintptr_t src, uintptr_t dst, size_t size) {
              self.put(srcDevice, dstDevice, channelIdx, reinterpret_cast<void*>(src),
                           reinterpret_cast<void*>(dst), size);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "src"_a, "dst"_a, "size"_a,
           "Host-initiated 1D memory copy")
       .def(
           "put_signal",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, uintptr_t src, uintptr_t dst, size_t size,
              uintptr_t flag_ptr, uint64_t flag_value, int flag_bits) {
              self.put_signal(srcDevice, dstDevice, channelIdx, reinterpret_cast<void*>(src),
                                  reinterpret_cast<void*>(dst), size, reinterpret_cast<void*>(flag_ptr),
                                  flag_value, flag_bits);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "src"_a, "dst"_a, "size"_a, "flag_ptr"_a,
           "flag_value"_a, "flag_bits"_a = 32,
           "Host-initiated linear memory copy with atomic signal in one submission")
       .def(
           "wait_flag_then_put",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, uintptr_t flag_ptr, uint32_t expected_value,
              uintptr_t src, uintptr_t dst, size_t size, int flag_bits) {
              self.wait_flag_then_put(srcDevice, dstDevice, channelIdx, reinterpret_cast<void*>(flag_ptr),
                                      expected_value, reinterpret_cast<void*>(src),
                                      reinterpret_cast<void*>(dst), size, flag_bits);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "flag_ptr"_a, "expected_value"_a, "src"_a, "dst"_a,
           "size"_a, "flag_bits"_a = 32,
           "Host-initiated wait-on-flag then linear memory copy (POLL + COPY in one submission)")
      .def(
          "signal",
          [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, uintptr_t flag_ptr, uint64_t value,
             int flag_bits) {
             self.signal(srcDevice, dstDevice, channelIdx, reinterpret_cast<void*>(flag_ptr), value, flag_bits);
          },
          "src_device"_a, "dst_device"_a, "channel_idx"_a, "flag_ptr"_a, "value"_a = 1, "flag_bits"_a = 32,
          "Atomic increment of a flag (32- or 64-bit)")
       .def(
           "timestamp",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, uintptr_t timestamp_ptr) {
              self.timestamp(srcDevice, dstDevice, channelIdx, reinterpret_cast<void*>(timestamp_ptr));
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "timestamp_ptr"_a,
           "Host-initiated timestamp write to 64-bit memory location")
       .def(
           "put_tile",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, const Tile& tile, uintptr_t dst_ptr,
              size_t dst_stride) {
              self.put_tile(srcDevice, dstDevice, channelIdx, tile, reinterpret_cast<void*>(dst_ptr), dst_stride);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "tile"_a, "dst_ptr"_a, "dst_stride"_a,
           "Host-initiated 2D tile transfer using sub-window copy")
       .def(
           "put_tile_signal",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, const Tile& tile, uintptr_t dst_ptr,
              size_t dst_stride, uintptr_t flag_ptr, uint64_t flag_value, int flag_bits) {
              self.put_tile_signal(srcDevice, dstDevice, channelIdx, tile, reinterpret_cast<void*>(dst_ptr),
                                       dst_stride, reinterpret_cast<void*>(flag_ptr), flag_value, flag_bits);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "tile"_a, "dst_ptr"_a, "dst_stride"_a, "flag_ptr"_a,
           "flag_value"_a, "flag_bits"_a = 32,
           "Host-initiated 2D tile transfer with atomic signal in one submission")
       .def(
           "wait_flag_then_put_tile",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, uintptr_t flag_ptr, uint32_t expected_value,
              const Tile& tile, uintptr_t dst_ptr, size_t dst_stride, int flag_bits) {
              self.wait_flag_then_put_tile(srcDevice, dstDevice, channelIdx, reinterpret_cast<void*>(flag_ptr),
                                           expected_value, tile, reinterpret_cast<void*>(dst_ptr), dst_stride,
                                           flag_bits);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "flag_ptr"_a, "expected_value"_a, "tile"_a, "dst_ptr"_a,
           "dst_stride"_a, "flag_bits"_a = 32,
           "Host-initiated wait-on-flag then 2D tile transfer (POLL + SUB_WINDOW_COPY in one submission)")
      .def(
          "put_tiles",
          [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, const std::vector<Tile>& tiles,
             const std::vector<uintptr_t>& dst_ptrs_uintptr, const std::vector<size_t>& dst_strides) {
              // Convert uintptr_t to void*
              std::vector<void*> dst_ptrs;
              dst_ptrs.reserve(dst_ptrs_uintptr.size());
              for (uintptr_t ptr : dst_ptrs_uintptr) {
                 dst_ptrs.push_back(reinterpret_cast<void*>(ptr));
              }
              self.put_tiles(srcDevice, dstDevice, channelIdx, tiles, dst_ptrs, dst_strides);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "tiles"_a, "dst_ptrs"_a, "dst_strides"_a,
           "Host-initiated batched 2D tile transfers")
       .def(
           "wait_flag_then_put_tiles",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, uintptr_t flag_ptr, uint32_t expected_value,
              const std::vector<Tile>& tiles, const std::vector<uintptr_t>& dst_ptrs_uintptr,
              const std::vector<size_t>& dst_strides, int flag_bits) {
              // Convert uintptr_t to void*
              std::vector<void*> dst_ptrs;
              dst_ptrs.reserve(dst_ptrs_uintptr.size());
              for (uintptr_t ptr : dst_ptrs_uintptr) {
                 dst_ptrs.push_back(reinterpret_cast<void*>(ptr));
              }
              self.wait_flag_then_put_tiles(srcDevice, dstDevice, channelIdx,
                                            reinterpret_cast<void*>(flag_ptr), expected_value,
                                            tiles, dst_ptrs, dst_strides, flag_bits);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "flag_ptr"_a, "expected_value"_a, "tiles"_a,
           "dst_ptrs"_a, "dst_strides"_a, "flag_bits"_a = 32,
           "Host-initiated wait-on-flag then many 2D tile transfers (one POLL + many SUB_WINDOW_COPY packets)")
       .def("quiet", &AnvilLib::quiet, "src_device"_a, "dst_device"_a, "channel_idx"_a,
            "Block until all submitted SDMA operations complete");

   nb::class_<SdmaQueuePythonDeviceCtx>(m, "SdmaQueuePythonDeviceCtx")
       .def_ro("queue_buf", &SdmaQueuePythonDeviceCtx::queueBuf)
       .def_ro("rptr", &SdmaQueuePythonDeviceCtx::rptr)
       .def_ro("wptr", &SdmaQueuePythonDeviceCtx::wptr)
       .def_ro("doorbell", &SdmaQueuePythonDeviceCtx::doorbell)
       .def_ro("cached_wptr", &SdmaQueuePythonDeviceCtx::cachedWptr)
       .def_ro("committed_wptr", &SdmaQueuePythonDeviceCtx::committedWptr);

   // Tile struct for 2D transfers
   nb::class_<Tile>(m, "Tile")
       .def(nb::init<>())
       .def_rw("pid_m", &Tile::pid_m, "Tile coordinate in M dimension")
       .def_rw("pid_n", &Tile::pid_n, "Tile coordinate in N dimension")
       .def_rw("block_m", &Tile::block_m, "Block size in M dimension")
       .def_rw("block_n", &Tile::block_n, "Block size in N dimension")
       .def_prop_rw(
           "data", [](const Tile& t) { return reinterpret_cast<uintptr_t>(t.data); },
           [](Tile& t, uintptr_t ptr) { t.data = reinterpret_cast<void*>(ptr); }, "Pointer to tile data")
       .def_rw("elem_size", &Tile::elem_size, "Element size in bytes (e.g., 4 for float)")
       .def_rw("src_stride", &Tile::src_stride, "Source row stride in bytes (0 = contiguous)")
       .def("width_bytes", &Tile::width_bytes, "Get tile width in bytes")
       .def("height", &Tile::height, "Get tile height in rows")
       .def("offset_m", &Tile::offset_m, "Get M offset")
       .def("offset_n", &Tile::offset_n, "Get N offset")
       .def("src_pitch", &Tile::src_pitch, "Get source pitch in bytes");

   m.attr("QUEUE_DEVICE_CTX_SIZE") = nb::int_(kQueueDeviceCtxSize);
   m.attr("SDMA_PKT_COPY_LINEAR_BYTES") = nb::int_(kCopyLinearCommandBytes);
   m.attr("SDMA_PKT_LINEAR_SUB_WINDOW_BYTES") = nb::int_(kCopyLinearSubWindowCommandBytes);
   m.attr("SDMA_PKT_ATOMIC_BYTES") = nb::int_(kAtomicCommandBytes);
   m.attr("SDMA_QUEUE_SIZE") = nb::int_(sdma_ep::SDMA_QUEUE_SIZE);
}

NB_MODULE(sdma_ep_py, m)
{
   register_sdma_ep(m);
}
