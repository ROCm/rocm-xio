/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cassert>
#include <cstring>

#include <hip/hip_runtime.h>

#include "rdma-ep.h"
#include "rdma-ep.hip" // Include implementation for __device__ functions
#include "xio.h"       // For HIP_CHECK macro

using namespace xio;

// Simple assertion macros
#define ASSERT_EQ(a, b) assert((a) == (b))
#define ASSERT_TRUE(x) assert(x)
#define ASSERT_FALSE(x) assert(!(x))
#define ASSERT_STREQ(a, b) assert(strcmp((a), (b)) == 0)

// GPU kernel to test WQE/CQE setup functions on device
__global__ void test_wqe_cqe_setup_kernel(bool* results) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid != 0)
    return; // Only thread 0 performs the test

  bool test_passed = true;

  // Test WQE setup functions
  struct rdma_wqe wqe_send = {};
  rdma_wqe_setup_send(&wqe_send, 123, RDMAVendor::MLX5, 0x1000, 4096, 0xABCD);
  test_passed &= (wqe_send.opcode == RDMA_OP_SEND);
  test_passed &= (wqe_send.vendor == static_cast<uint8_t>(RDMAVendor::MLX5));
  test_passed &= (wqe_send.wqe_id == 123);
  test_passed &= (wqe_send.length == 4096);
  test_passed &= (wqe_send.local_addr == 0x1000);

  struct rdma_wqe wqe_write = {};
  rdma_wqe_setup_write(&wqe_write, 456, RDMAVendor::BNXT_RE, 0x2000, 0x3000,
                       8192, 0x1234, 0x5678);
  test_passed &= (wqe_write.opcode == RDMA_OP_RDMA_WRITE);
  test_passed &= (wqe_write.remote_addr == 0x3000);
  test_passed &= (wqe_write.rkey == 0x5678);

  struct rdma_wqe wqe_read = {};
  rdma_wqe_setup_read(&wqe_read, 789, RDMAVendor::IONIC, 0x4000, 0x5000, 16384,
                      0x9ABC, 0xDEF0);
  test_passed &= (wqe_read.opcode == RDMA_OP_RDMA_READ);
  test_passed &= (wqe_read.wqe_id == 789);

  // Test CQE setup functions
  struct rdma_cqe cqe_success = {};
  rdma_cqe_setup_success(&cqe_success, 123, RDMAVendor::ROCM_ERNIC, 4096,
                         0x12345678);
  test_passed &= (cqe_success.status == RDMA_WC_SUCCESS);
  test_passed &= (cqe_success.byte_len == 4096);
  test_passed &= (rdma_cqe_ok(&cqe_success));

  struct rdma_cqe cqe_error = {};
  rdma_cqe_setup_error(&cqe_error, 456, RDMAVendor::MLX5, RDMA_WC_LOC_LEN_ERR,
                       0x87654321);
  test_passed &= (cqe_error.status == RDMA_WC_LOC_LEN_ERR);
  test_passed &= (!rdma_cqe_ok(&cqe_error));
  test_passed &= (rdma_cqe_status(&cqe_error) == RDMA_WC_LOC_LEN_ERR);

  // Test structure sizes
  test_passed &= (sizeof(struct rdma_wqe) == RDMA_EP_SQE_SIZE);
  test_passed &= (sizeof(struct rdma_cqe) == RDMA_EP_CQE_SIZE);

  results[0] = test_passed;
}

// Test WQE setup functions
int test_wqe_setup_send() {
  struct rdma_wqe wqe = {};
  rdma_wqe_setup_send(&wqe, 123, RDMAVendor::MLX5, 0x1000, 4096, 0xABCD);

  ASSERT_EQ(wqe.opcode, RDMA_OP_SEND);
  ASSERT_EQ(wqe.vendor, static_cast<uint8_t>(RDMAVendor::MLX5));
  ASSERT_EQ(wqe.wqe_id, 123);
  ASSERT_EQ(wqe.length, 4096);
  ASSERT_EQ(wqe.local_addr, 0x1000);
  ASSERT_EQ(wqe.remote_addr, 0);
  ASSERT_EQ(wqe.lkey, 0xABCD);
  ASSERT_EQ(wqe.rkey, 0);
  ASSERT_EQ(wqe.imm_data, 0);
  ASSERT_EQ(wqe.vendor_specific, 0);

  return 0;
}

int test_wqe_setup_write() {
  struct rdma_wqe wqe = {};
  rdma_wqe_setup_write(&wqe, 456, RDMAVendor::BNXT_RE, 0x2000, 0x3000, 8192,
                       0x1234, 0x5678);

  ASSERT_EQ(wqe.opcode, RDMA_OP_RDMA_WRITE);
  ASSERT_EQ(wqe.vendor, static_cast<uint8_t>(RDMAVendor::BNXT_RE));
  ASSERT_EQ(wqe.wqe_id, 456);
  ASSERT_EQ(wqe.length, 8192);
  ASSERT_EQ(wqe.local_addr, 0x2000);
  ASSERT_EQ(wqe.remote_addr, 0x3000);
  ASSERT_EQ(wqe.lkey, 0x1234);
  ASSERT_EQ(wqe.rkey, 0x5678);
  ASSERT_EQ(wqe.imm_data, 0);
  ASSERT_EQ(wqe.vendor_specific, 0);

  return 0;
}

int test_wqe_setup_read() {
  struct rdma_wqe wqe = {};
  rdma_wqe_setup_read(&wqe, 789, RDMAVendor::IONIC, 0x4000, 0x5000, 16384,
                      0x9ABC, 0xDEF0);

  ASSERT_EQ(wqe.opcode, RDMA_OP_RDMA_READ);
  ASSERT_EQ(wqe.vendor, static_cast<uint8_t>(RDMAVendor::IONIC));
  ASSERT_EQ(wqe.wqe_id, 789);
  ASSERT_EQ(wqe.length, 16384);
  ASSERT_EQ(wqe.local_addr, 0x4000);
  ASSERT_EQ(wqe.remote_addr, 0x5000);
  ASSERT_EQ(wqe.lkey, 0x9ABC);
  ASSERT_EQ(wqe.rkey, 0xDEF0);
  ASSERT_EQ(wqe.imm_data, 0);
  ASSERT_EQ(wqe.vendor_specific, 0);

  return 0;
}

// Test CQE setup functions
int test_cqe_setup_success() {
  struct rdma_cqe cqe = {};
  rdma_cqe_setup_success(&cqe, 123, RDMAVendor::ROCM_ERNIC, 4096, 0x12345678);

  ASSERT_EQ(cqe.wqe_id, 123);
  ASSERT_EQ(cqe.vendor, static_cast<uint8_t>(RDMAVendor::ROCM_ERNIC));
  ASSERT_EQ(cqe.status, RDMA_WC_SUCCESS);
  ASSERT_EQ(cqe.byte_len, 4096);
  ASSERT_EQ(cqe.imm_data, 0);
  ASSERT_EQ(cqe.timestamp, 0x12345678);
  ASSERT_EQ(cqe.vendor_data, 0);
  ASSERT_EQ(cqe.reserved, 0);

  return 0;
}

int test_cqe_setup_error() {
  struct rdma_cqe cqe = {};
  rdma_cqe_setup_error(&cqe, 456, RDMAVendor::MLX5, RDMA_WC_LOC_LEN_ERR,
                       0x87654321);

  ASSERT_EQ(cqe.wqe_id, 456);
  ASSERT_EQ(cqe.vendor, static_cast<uint8_t>(RDMAVendor::MLX5));
  ASSERT_EQ(cqe.status, RDMA_WC_LOC_LEN_ERR);
  ASSERT_EQ(cqe.byte_len, 0);
  ASSERT_EQ(cqe.imm_data, 0);
  ASSERT_EQ(cqe.timestamp, 0x87654321);
  ASSERT_EQ(cqe.vendor_data, 0);
  ASSERT_EQ(cqe.reserved, 0);

  return 0;
}

int test_cqe_ok() {
  struct rdma_cqe success_cqe = {};
  rdma_cqe_setup_success(&success_cqe, 1, RDMAVendor::MLX5, 100, 0);

  struct rdma_cqe error_cqe = {};
  rdma_cqe_setup_error(&error_cqe, 2, RDMAVendor::MLX5, RDMA_WC_LOC_LEN_ERR, 0);

  ASSERT_TRUE(rdma_cqe_ok(&success_cqe));
  ASSERT_FALSE(rdma_cqe_ok(&error_cqe));

  return 0;
}

int test_cqe_status() {
  struct rdma_cqe cqe = {};
  rdma_cqe_setup_error(&cqe, 1, RDMAVendor::MLX5, RDMA_WC_REM_ACCESS_ERR, 0);

  ASSERT_EQ(rdma_cqe_status(&cqe), RDMA_WC_REM_ACCESS_ERR);

  return 0;
}

int test_structure_sizes() {
  // Verify structure sizes match expected values
  ASSERT_EQ(sizeof(struct rdma_wqe), RDMA_EP_SQE_SIZE);
  ASSERT_EQ(sizeof(struct rdma_cqe), RDMA_EP_CQE_SIZE);
  ASSERT_EQ(RDMA_EP_SQE_SIZE, 64);
  ASSERT_EQ(RDMA_EP_CQE_SIZE, 64);

  return 0;
}

int test_vendor_name() {
  ASSERT_STREQ(rdma_vendor_name(RDMAVendor::MLX5), "MLX5");
  ASSERT_STREQ(rdma_vendor_name(RDMAVendor::BNXT_RE), "BNXT_RE");
  ASSERT_STREQ(rdma_vendor_name(RDMAVendor::IONIC), "IONIC");
  ASSERT_STREQ(rdma_vendor_name(RDMAVendor::ROCM_ERNIC), "rocm-ernic");
  ASSERT_STREQ(rdma_vendor_name(RDMAVendor::UNKNOWN), "UNKNOWN");

  return 0;
}

// GPU-based test that launches kernel
int test_wqe_cqe_setup_gpu() {
  hipError_t err = hipInit(0);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to initialize HIP: %s\n", hipGetErrorString(err));
    return 1;
  }

  bool* device_results = nullptr;
  err = hipMalloc(&device_results, sizeof(bool));
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to allocate device memory: %s\n",
            hipGetErrorString(err));
    return 1;
  }

  bool host_result = false;
  err = hipMemcpy(device_results, &host_result, sizeof(bool),
                  hipMemcpyHostToDevice);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to copy to device: %s\n", hipGetErrorString(err));
    HIP_CHECK(hipFree(device_results));
    return 1;
  }

  // Launch GPU kernel
  hipLaunchKernelGGL(test_wqe_cqe_setup_kernel, dim3(1), dim3(1), 0, 0,
                     device_results);

  err = hipGetLastError();
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to launch kernel: %s\n", hipGetErrorString(err));
    HIP_CHECK(hipFree(device_results));
    return 1;
  }

  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to synchronize: %s\n", hipGetErrorString(err));
    HIP_CHECK(hipFree(device_results));
    return 1;
  }

  err = hipMemcpy(&host_result, device_results, sizeof(bool),
                  hipMemcpyDeviceToHost);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to copy from device: %s\n", hipGetErrorString(err));
    HIP_CHECK(hipFree(device_results));
    return 1;
  }

  HIP_CHECK(hipFree(device_results));

  if (!host_result) {
    fprintf(stderr, "GPU kernel test failed\n");
    return 1;
  }

  return 0;
}

int main() {
  int failures = 0;

  // Run GPU-based tests
  failures += test_wqe_cqe_setup_gpu();

  // Run host-based tests (for functions that don't need GPU)
  failures += test_wqe_setup_send();
  failures += test_wqe_setup_write();
  failures += test_wqe_setup_read();
  failures += test_cqe_setup_success();
  failures += test_cqe_setup_error();
  failures += test_cqe_ok();
  failures += test_cqe_status();
  failures += test_structure_sizes();
  failures += test_vendor_name();

  if (failures == 0) {
    return 0;
  } else {
    return 1;
  }
}
