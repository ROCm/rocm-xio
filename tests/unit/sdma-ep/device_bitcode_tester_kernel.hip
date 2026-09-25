/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstddef>
#include <cstdint>

#include <hip/hip_runtime.h>

extern "C" {
__device__ void xio_sdma_put(void*, void*, const void*, size_t);
__device__ void xio_sdma_poll_until_ge(uint64_t*, uint64_t);
}

extern "C" __global__ void test_xio_sdma_put(
  void* queue_handle, void* dst, const void* src, size_t size) {
  if (threadIdx.x == 0)
    xio_sdma_put(queue_handle, dst, src, size);
}

extern "C" __global__ void test_xio_sdma_poll_until_ge(
  uint64_t* address, uint64_t expected) {
  if (threadIdx.x == 0)
    xio_sdma_poll_until_ge(address, expected);
}

int main() { return 0; }
