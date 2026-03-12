/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for rdma_ep endian conversion helpers.
 */

#include <cassert>
#include <cstdint>
#include <cstdio>

#include <hip/hip_runtime.h>

#include "endian.hpp"

#define ASSERT_EQ(a, b) assert((a) == (b))

int test_byteswap_16() {
  uint16_t val = 0x1234;
  uint16_t swapped = rdma_ep::byteswap(val);
  ASSERT_EQ(swapped, static_cast<uint16_t>(0x3412));
  return 0;
}

int test_byteswap_32() {
  uint32_t val = 0x12345678;
  uint32_t swapped = rdma_ep::byteswap(val);
  ASSERT_EQ(swapped, 0x78563412u);
  return 0;
}

int test_byteswap_64() {
  uint64_t val = 0x0102030405060708ULL;
  uint64_t swapped = rdma_ep::byteswap(val);
  ASSERT_EQ(swapped, 0x0807060504030201ULL);
  return 0;
}

int test_byteswap_identity_8() {
  uint8_t val = 0xAB;
  uint8_t swapped = rdma_ep::byteswap(val);
  ASSERT_EQ(swapped, static_cast<uint8_t>(0xAB));
  return 0;
}

int test_to_be_from_be_roundtrip() {
  uint32_t original = 0xDEADBEEF;
  uint32_t be = rdma_ep::endian::to_be(original);
  uint32_t back = rdma_ep::endian::from_be(be);
  ASSERT_EQ(back, original);
  return 0;
}

int test_to_le_from_le_roundtrip() {
  uint64_t original = 0x123456789ABCDEF0ULL;
  uint64_t le = rdma_ep::endian::to_le(original);
  uint64_t back = rdma_ep::endian::from_le(le);
  ASSERT_EQ(back, original);
  return 0;
}

int test_native_is_identity() {
  uint32_t val = 0x42424242;
  uint32_t native =
    rdma_ep::endian::to_native<rdma_ep::endian::Order::Native>(val);
  ASSERT_EQ(native, val);
  return 0;
}

__global__ void test_endian_gpu(bool *results) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid != 0)
    return;

  bool pass = true;

  uint32_t val = 0x12345678;
  uint32_t be = rdma_ep::endian::to_be(val);
  uint32_t back = rdma_ep::endian::from_be(be);
  pass &= (back == val);

  uint64_t val64 = 0x0102030405060708ULL;
  uint64_t swapped = rdma_ep::byteswap(val64);
  uint64_t back64 = rdma_ep::byteswap(swapped);
  pass &= (back64 == val64);

  results[0] = pass;
}

int test_endian_on_gpu() {
  hipError_t err = hipInit(0);
  if (err != hipSuccess)
    return 1;

  bool *device_results = nullptr;
  err = hipMalloc(&device_results, sizeof(bool));
  if (err != hipSuccess)
    return 1;

  bool host_result = false;
  (void)hipMemcpy(device_results, &host_result, sizeof(bool),
                  hipMemcpyHostToDevice);

  hipLaunchKernelGGL(test_endian_gpu, dim3(1), dim3(1), 0, 0,
                     device_results);

  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    (void)hipFree(device_results);
    return 1;
  }

  (void)hipMemcpy(&host_result, device_results, sizeof(bool),
                  hipMemcpyDeviceToHost);
  (void)hipFree(device_results);

  return host_result ? 0 : 1;
}

int main() {
  int failures = 0;
  failures += test_byteswap_16();
  failures += test_byteswap_32();
  failures += test_byteswap_64();
  failures += test_byteswap_identity_8();
  failures += test_to_be_from_be_roundtrip();
  failures += test_to_le_from_le_roundtrip();
  failures += test_native_is_identity();
  failures += test_endian_on_gpu();

  if (failures == 0) {
    printf("All endian tests passed.\n");
    return 0;
  }
  printf("%d endian test(s) failed.\n", failures);
  return 1;
}
