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
       .def("connect", &AnvilLib::connect, "src_device"_a, "dst_device"_a, "allocate_on_host"_a = false,
            "Connect two devices with a single SDMA queue channel (idempotent)")
       .def("get_queue_device_ctx", &AnvilLib::get_queue_device_ctx, "src_device"_a, "dst_device"_a,
            "Get device context handles for the queue (queue 0)")
       .def(
           "host_put",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, uintptr_t src, uintptr_t dst,
              size_t size) {
              self.host_put(srcDevice, dstDevice, channelIdx, reinterpret_cast<void*>(src),
                            reinterpret_cast<void*>(dst), size);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "src"_a, "dst"_a, "size"_a, "Host-initiated 1D memory copy")
       .def(
           "host_atomic_add",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, uintptr_t ptr, uint64_t value) {
              self.host_atomic_add_u64(srcDevice, dstDevice, channelIdx, reinterpret_cast<void*>(ptr), value);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "ptr"_a, "value"_a,
           "Host-initiated 64-bit atomic add operation")
       .def(
           "host_atomic_add_32",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, uintptr_t ptr, uint32_t value) {
              self.host_atomic_add_u32(srcDevice, dstDevice, channelIdx, reinterpret_cast<void*>(ptr), value);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "ptr"_a, "value"_a,
           "Host-initiated 32-bit atomic add operation")
       .def(
           "host_timestamp",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, uintptr_t timestamp_ptr) {
              self.host_timestamp(srcDevice, dstDevice, channelIdx, reinterpret_cast<void*>(timestamp_ptr));
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "timestamp_ptr"_a,
           "Host-initiated timestamp write to 64-bit memory location")
       .def(
           "host_put_tile",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, const Tile& tile, uintptr_t dst_ptr,
              size_t dst_stride) {
              self.host_put_tile(srcDevice, dstDevice, channelIdx, tile, reinterpret_cast<void*>(dst_ptr), dst_stride);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "tile"_a, "dst_ptr"_a, "dst_stride"_a,
           "Host-initiated 2D tile transfer using sub-window copy")
       .def(
           "host_put_signal",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, uintptr_t src, uintptr_t dst, size_t size,
              uintptr_t flag_ptr, uint32_t flag_value) {
              self.host_put_signal_u32(srcDevice, dstDevice, channelIdx, reinterpret_cast<void*>(src),
                                       reinterpret_cast<void*>(dst), size, reinterpret_cast<void*>(flag_ptr),
                                       flag_value);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "src"_a, "dst"_a, "size"_a, "flag_ptr"_a, "flag_value"_a,
           "Host-initiated linear memory copy with atomic signal in one submission")
       .def(
           "host_put_tile_signal",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, const Tile& tile, uintptr_t dst_ptr,
              size_t dst_stride, uintptr_t flag_ptr, uint32_t flag_value) {
              self.host_put_tile_signal_u32(srcDevice, dstDevice, channelIdx, tile, reinterpret_cast<void*>(dst_ptr),
                                            dst_stride, reinterpret_cast<void*>(flag_ptr), flag_value);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "tile"_a, "dst_ptr"_a, "dst_stride"_a, "flag_ptr"_a,
           "flag_value"_a, "Host-initiated 2D tile transfer with atomic signal in one submission")
       .def(
           "host_wait_flag_then_put",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, uintptr_t flag_ptr, uint32_t expected_value,
              uintptr_t src, uintptr_t dst, size_t size) {
              self.host_wait_flag_then_put_u32(srcDevice, dstDevice, channelIdx, reinterpret_cast<void*>(flag_ptr),
                                               expected_value, reinterpret_cast<void*>(src),
                                               reinterpret_cast<void*>(dst), size);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "flag_ptr"_a, "expected_value"_a, "src"_a, "dst"_a,
           "size"_a, "Host-initiated wait-on-flag then linear memory copy (POLL + COPY in one submission)")
       .def(
           "host_wait_flag_then_put_tile",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, uintptr_t flag_ptr, uint32_t expected_value,
              const Tile& tile, uintptr_t dst_ptr, size_t dst_stride) {
              self.host_wait_flag_then_put_tile_u32(srcDevice, dstDevice, channelIdx, reinterpret_cast<void*>(flag_ptr),
                                                    expected_value, tile, reinterpret_cast<void*>(dst_ptr), dst_stride);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "flag_ptr"_a, "expected_value"_a, "tile"_a, "dst_ptr"_a,
           "dst_stride"_a,
           "Host-initiated wait-on-flag then 2D tile transfer (POLL + SUB_WINDOW_COPY in one submission)")
       .def(
           "host_wait_flag_then_put_tiles",
           [](AnvilLib& self, int srcDevice, int dstDevice, int channelIdx, uintptr_t flag_ptr, uint32_t expected_value,
              const std::vector<Tile>& tiles, const std::vector<uintptr_t>& dst_ptrs,
              const std::vector<size_t>& dst_strides) {
              if (tiles.size() != dst_ptrs.size() || tiles.size() != dst_strides.size())
              {
                 throw std::invalid_argument("tiles, dst_ptrs, and dst_strides must have the same length");
              }
              std::vector<void*> dst_ptr_vec;
              dst_ptr_vec.reserve(dst_ptrs.size());
              for (uintptr_t dst_ptr : dst_ptrs)
              {
                 dst_ptr_vec.push_back(reinterpret_cast<void*>(dst_ptr));
              }
              self.host_wait_flag_then_put_tiles_u32(srcDevice, dstDevice, channelIdx,
                                                     reinterpret_cast<void*>(flag_ptr), expected_value, tiles,
                                                     dst_ptr_vec, dst_strides);
           },
           "src_device"_a, "dst_device"_a, "channel_idx"_a, "flag_ptr"_a, "expected_value"_a, "tiles"_a, "dst_ptrs"_a,
           "dst_strides"_a,
           "Host-initiated wait-on-flag then many 2D tile transfers (one POLL + many SUB_WINDOW_COPY packets)")
       .def("host_quiet", &AnvilLib::host_quiet, "src_device"_a, "dst_device"_a, "channel_idx"_a,
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
}

NB_MODULE(sdma_ep_py, m)
{
   register_sdma_ep(m);
}
