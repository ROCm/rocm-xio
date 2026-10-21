# Changelog for rocm-xio

## UNRELEASED - rocm-xio 0.0.1

### Added

- sdma-ep: host-initiated SDMA queues can have several independent channels
  per GPU pair. C++ gains `initHostQueue(src, dst, numChannels)` and
  `getHostChannelCount(src, dst)`; the Python binding gains
  `create_host_queue(src, dst, num_channels=1)` and
  `get_host_channel_count(src, dst)`. Existing calls keep one channel.

### Changed

- rdma-ep: the mlx5 atomic opcodes were swapped (compare-and-swap is 0x11 and
  fetch-add is 0x12); atomics previously failed with a local QP operation
  error.

### Removed

### Limitations

### Known issues
