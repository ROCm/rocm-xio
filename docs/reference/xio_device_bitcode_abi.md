# XIO SDMA Device Bitcode ABI

When `XIO_BUILD_DEVICE_BITCODE=ON`, ROCm-XIO builds one LLVM bitcode file per
entry in `CMAKE_HIP_ARCHITECTURES` (or `OFFLOAD_ARCH`). The build artifacts are
written to `build/device-bitcode/` and installed under
`lib/xio/device/xio_device_<arch>.bc`. Architecture feature separators are
encoded as underscores in filenames, so `gfx942:xnack+` becomes
`xio_device_gfx942_xnack+`. When Python bindings are enabled, the same files
are also installed at `xio/sdma_ep/lib/` in the Python package.

Consumers may override their lookup directory with `XIO_DEVICE_BITCODE_DIR`.
The override should point directly to the directory containing the `.bc` files.

All functions below are device functions with C linkage and return `void`.
`queue_handle` is a device pointer to an initialized
`xio::sdma_ep::SdmaQueueHandle`. Pointer arguments are device addresses.
`src` is logically read-only; it is represented as a raw pointer for the C ABI.

| Symbol | Arguments after the return type |
| --- | --- |
| `xio_sdma_put` | `void* queue_handle, void* dst, const void* src, size_t size` |
| `xio_sdma_put_tile` | `void* queue_handle, void* dst, const void* src, uint32_t tile_width, uint32_t tile_height, uint32_t src_pitch, uint32_t dst_pitch, uint32_t src_x, uint32_t src_y, uint32_t dst_x, uint32_t dst_y` |
| `xio_sdma_put_signal` | `void* queue_handle, void* dst, const void* src, size_t size, uint64_t* signal` |
| `xio_sdma_put_signal_counter` | `void* queue_handle, void* dst, const void* src, size_t size, uint64_t* signal, uint64_t* counter` |
| `xio_sdma_put_counter` | `void* queue_handle, void* dst, const void* src, size_t size, uint64_t* counter` |
| `xio_sdma_signal` | `void* queue_handle, uint64_t* signal` |
| `xio_sdma_signal_counter` | `void* queue_handle, uint64_t* signal, uint64_t* counter` |
| `xio_sdma_poll_until_ge` | `uint64_t* address, uint64_t expected` |
| `xio_sdma_quiet` | `void* queue_handle` |

Every exported wrapper is marked `__attribute__((used))`; this prevents LLVM's
link-only-needed processing from removing an entry that is referenced only by a
consumer-side extern declaration. The bitcode is compiled with relocatable
device code enabled, so the wrappers retain external (currently hidden)
linkage rather than being emitted as `internal` definitions.
