/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for rdma_ep endian conversion helpers.
 */

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include <hip/hip_runtime.h>

#include "endian.hpp"
#include "xio-test-assert.h"
#include "xio.h"

int test_byteswap_16() {
  uint16_t val = 0x1234;
  ASSERT_EQ(xio::rdma_ep::byteswap(val), static_cast<uint16_t>(0x3412));
  return 0;
}

int test_byteswap_32() {
  uint32_t val = 0x12345678;
  ASSERT_EQ(xio::rdma_ep::byteswap(val), 0x78563412u);
  return 0;
}

int test_byteswap_64() {
  uint64_t val = 0x0102030405060708ULL;
  ASSERT_EQ(xio::rdma_ep::byteswap(val), 0x0807060504030201ULL);
  return 0;
}

int test_byteswap_identity_8() {
  uint8_t val = 0xAB;
  ASSERT_EQ(xio::rdma_ep::byteswap(val), static_cast<uint8_t>(0xAB));
  return 0;
}

int test_to_be_from_be_roundtrip() {
  uint32_t original = 0xDEADBEEF;
  uint32_t be = xio::rdma_ep::endian::to_be(original);
  ASSERT_EQ(xio::rdma_ep::endian::from_be(be), original);
  return 0;
}

int test_to_le_from_le_roundtrip() {
  uint64_t original = 0x123456789ABCDEF0ULL;
  uint64_t le = xio::rdma_ep::endian::to_le(original);
  ASSERT_EQ(xio::rdma_ep::endian::from_le(le), original);
  return 0;
}

int test_native_is_identity() {
  uint32_t val = 0x42424242;
  ASSERT_EQ((xio::rdma_ep::endian::to_native<xio::rdma_ep::endian::Order::Native>(val)),
            val);
  return 0;
}

__global__ void test_endian_gpu(bool* results) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid != 0)
    return;

  bool pass = true;

  uint32_t val = 0x12345678;
  uint32_t be = xio::rdma_ep::endian::to_be(val);
  uint32_t back = xio::rdma_ep::endian::from_be(be);
  pass &= (back == val);

  uint64_t val64 = 0x0102030405060708ULL;
  uint64_t swapped = xio::rdma_ep::byteswap(val64);
  uint64_t back64 = xio::rdma_ep::byteswap(swapped);
  pass &= (back64 == val64);

  results[0] = pass;
}

int test_endian_on_gpu() {
  hipError_t err = hipInit(0);
  if (err != hipSuccess) {
    printf("  skipping GPU endian test (no GPU)\n");
    return 0;
  }

  int count = 0;
  err = hipGetDeviceCount(&count);
  if (err != hipSuccess || count == 0) {
    printf("  skipping GPU endian test (no GPU)\n");
    return 0;
  }

  bool* device_results = nullptr;
  hsa_status_t hsa_ret = xio::allocDeviceMemory(sizeof(bool),
                                                (void**)&device_results,
                                                "endian results",
                                                XIO_DEVICE_MEM_HIP);
  if (hsa_ret != HSA_STATUS_SUCCESS)
    return 1;

  bool host_result = false;
  (void)hipMemcpy(device_results, &host_result, sizeof(bool),
                  hipMemcpyHostToDevice);

  hipLaunchKernelGGL(test_endian_gpu, dim3(1), dim3(1), 0, 0, device_results);

  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    xio::freeDeviceMemory(device_results, XIO_DEVICE_MEM_HIP);
    return 1;
  }

  (void)hipMemcpy(&host_result, device_results, sizeof(bool),
                  hipMemcpyDeviceToHost);
  xio::freeDeviceMemory(device_results, XIO_DEVICE_MEM_HIP);

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
