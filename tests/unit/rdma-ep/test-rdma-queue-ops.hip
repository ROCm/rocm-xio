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

// Simple assertion macros
#define ASSERT_EQ(a, b) assert((a) == (b))
#define ASSERT_TRUE(x) assert(x)
#define ASSERT_FALSE(x) assert(!(x))
#define ASSERT_MEMEQ(a, b, size) assert(memcmp((a), (b), (size)) == 0)

// GPU kernel to test SQE read/write operations on device
__global__ void test_sqe_read_write_kernel(rdma_ep::sqeType* device_buffer,
                                           bool* success) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid != 0)
    return; // Only thread 0 performs the test

  // Create a WQE on device
  struct rdma_wqe original_wqe = {};
  rdma_wqe_setup_send(&original_wqe, 123, RDMAVendor::MLX5, 0x1000, 4096,
                      0xABCD);
  original_wqe.vendor_specific = 0x123456789ABCDEF0ULL;

  // Write to device memory buffer
  rdma_ep::sqeWrite(original_wqe, device_buffer);

  // Read back from device memory buffer
  rdma_ep::sqeType read_wqe = rdma_ep::sqeRead(
    reinterpret_cast<volatile rdma_ep::sqeType*>(device_buffer));

  // Verify all fields match
  bool test_passed = true;
  test_passed &= (read_wqe.opcode == original_wqe.opcode);
  test_passed &= (read_wqe.vendor == original_wqe.vendor);
  test_passed &= (read_wqe.wqe_id == original_wqe.wqe_id);
  test_passed &= (read_wqe.length == original_wqe.length);
  test_passed &= (read_wqe.local_addr == original_wqe.local_addr);
  test_passed &= (read_wqe.remote_addr == original_wqe.remote_addr);
  test_passed &= (read_wqe.lkey == original_wqe.lkey);
  test_passed &= (read_wqe.rkey == original_wqe.rkey);
  test_passed &= (read_wqe.imm_data == original_wqe.imm_data);
  test_passed &= (read_wqe.vendor_specific == original_wqe.vendor_specific);

  *success = test_passed;
}

// GPU kernel to test CQE read/write operations on device
__global__ void test_cqe_read_write_kernel(rdma_ep::cqeType* device_buffer,
                                           bool* success) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid != 0)
    return; // Only thread 0 performs the test

  // Create a CQE on device
  struct rdma_cqe original_cqe = {};
  rdma_cqe_setup_success(&original_cqe, 456, RDMAVendor::BNXT_RE, 8192,
                         0xDEADBEEF);
  original_cqe.bnxt.sq_cons_idx = 100;
  original_cqe.bnxt.cq_cons_idx = 200;

  // Write to device memory buffer
  rdma_ep::cqeWrite(original_cqe, device_buffer);

  // Read back from device memory buffer
  rdma_ep::cqeType read_cqe = rdma_ep::cqeRead(
    reinterpret_cast<volatile rdma_ep::cqeType*>(device_buffer));

  // Verify all fields match
  bool test_passed = true;
  test_passed &= (read_cqe.wqe_id == original_cqe.wqe_id);
  test_passed &= (read_cqe.vendor == original_cqe.vendor);
  test_passed &= (read_cqe.status == original_cqe.status);
  test_passed &= (read_cqe.byte_len == original_cqe.byte_len);
  test_passed &= (read_cqe.imm_data == original_cqe.imm_data);
  test_passed &= (read_cqe.timestamp == original_cqe.timestamp);
  test_passed &= (read_cqe.bnxt.sq_cons_idx == original_cqe.bnxt.sq_cons_idx);
  test_passed &= (read_cqe.bnxt.cq_cons_idx == original_cqe.bnxt.cq_cons_idx);

  *success = test_passed;
}

// Test SQE read/write operations on GPU
int test_sqe_read_write() {
  hipError_t err;

  // Initialize HIP
  err = hipInit(0);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to initialize HIP: %s\n", hipGetErrorString(err));
    return 1;
  }

  // Allocate device memory
  rdma_ep::sqeType* device_buffer = nullptr;
  bool* device_success = nullptr;

  err = hipMalloc(&device_buffer, RDMA_EP_SQE_SIZE);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to allocate device memory for SQE: %s\n",
            hipGetErrorString(err));
    return 1;
  }

  err = hipMalloc(&device_success, sizeof(bool));
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to allocate device memory for success flag: %s\n",
            hipGetErrorString(err));
    HIP_CHECK(hipFree(device_buffer));
    return 1;
  }

  // Initialize device memory
  err = hipMemset(device_buffer, 0, RDMA_EP_SQE_SIZE);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to memset device buffer: %s\n",
            hipGetErrorString(err));
    HIP_CHECK(hipFree(device_buffer));
    HIP_CHECK(hipFree(device_success));
    return 1;
  }

  bool host_success = false;
  err = hipMemcpy(device_success, &host_success, sizeof(bool),
                  hipMemcpyHostToDevice);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to copy success flag to device: %s\n",
            hipGetErrorString(err));
    HIP_CHECK(hipFree(device_buffer));
    HIP_CHECK(hipFree(device_success));
    return 1;
  }

  // Launch GPU kernel
  hipLaunchKernelGGL(test_sqe_read_write_kernel, dim3(1), dim3(1), 0, 0,
                     device_buffer, device_success);

  err = hipGetLastError();
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to launch kernel: %s\n", hipGetErrorString(err));
    HIP_CHECK(hipFree(device_buffer));
    HIP_CHECK(hipFree(device_success));
    return 1;
  }

  // Wait for kernel completion
  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to synchronize device: %s\n",
            hipGetErrorString(err));
    HIP_CHECK(hipFree(device_buffer));
    HIP_CHECK(hipFree(device_success));
    return 1;
  }

  // Copy result back
  err = hipMemcpy(&host_success, device_success, sizeof(bool),
                  hipMemcpyDeviceToHost);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to copy result from device: %s\n",
            hipGetErrorString(err));
    HIP_CHECK(hipFree(device_buffer));
    HIP_CHECK(hipFree(device_success));
    return 1;
  }

  // Cleanup
  HIP_CHECK(hipFree(device_buffer));
  HIP_CHECK(hipFree(device_success));

  if (!host_success) {
    fprintf(stderr,
            "GPU kernel test failed: SQE read/write verification failed\n");
    return 1;
  }

  return 0;
}

// Test CQE read/write operations on GPU
int test_cqe_read_write() {
  hipError_t err;

  // Allocate device memory
  rdma_ep::cqeType* device_buffer = nullptr;
  bool* device_success = nullptr;

  err = hipMalloc(&device_buffer, RDMA_EP_CQE_SIZE);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to allocate device memory for CQE: %s\n",
            hipGetErrorString(err));
    return 1;
  }

  err = hipMalloc(&device_success, sizeof(bool));
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to allocate device memory for success flag: %s\n",
            hipGetErrorString(err));
    HIP_CHECK(hipFree(device_buffer));
    return 1;
  }

  // Initialize device memory
  err = hipMemset(device_buffer, 0, RDMA_EP_CQE_SIZE);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to memset device buffer: %s\n",
            hipGetErrorString(err));
    HIP_CHECK(hipFree(device_buffer));
    HIP_CHECK(hipFree(device_success));
    return 1;
  }

  bool host_success = false;
  err = hipMemcpy(device_success, &host_success, sizeof(bool),
                  hipMemcpyHostToDevice);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to copy success flag to device: %s\n",
            hipGetErrorString(err));
    HIP_CHECK(hipFree(device_buffer));
    HIP_CHECK(hipFree(device_success));
    return 1;
  }

  // Launch GPU kernel
  hipLaunchKernelGGL(test_cqe_read_write_kernel, dim3(1), dim3(1), 0, 0,
                     device_buffer, device_success);

  err = hipGetLastError();
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to launch kernel: %s\n", hipGetErrorString(err));
    HIP_CHECK(hipFree(device_buffer));
    HIP_CHECK(hipFree(device_success));
    return 1;
  }

  // Wait for kernel completion
  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to synchronize device: %s\n",
            hipGetErrorString(err));
    HIP_CHECK(hipFree(device_buffer));
    HIP_CHECK(hipFree(device_success));
    return 1;
  }

  // Copy result back
  err = hipMemcpy(&host_success, device_success, sizeof(bool),
                  hipMemcpyDeviceToHost);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to copy result from device: %s\n",
            hipGetErrorString(err));
    HIP_CHECK(hipFree(device_buffer));
    HIP_CHECK(hipFree(device_success));
    return 1;
  }

  // Cleanup
  HIP_CHECK(hipFree(device_buffer));
  HIP_CHECK(hipFree(device_success));

  if (!host_success) {
    fprintf(stderr,
            "GPU kernel test failed: CQE read/write verification failed\n");
    return 1;
  }

  return 0;
}

// Test SQE comparison function
int test_sqe_equal() {
  struct rdma_wqe wqe1 = {};
  struct rdma_wqe wqe2 = {};
  struct rdma_wqe wqe3 = {};

  rdma_wqe_setup_send(&wqe1, 100, RDMAVendor::MLX5, 0x1000, 4096, 0xABCD);
  rdma_wqe_setup_send(&wqe2, 100, RDMAVendor::MLX5, 0x2000, 8192, 0xEF00);
  rdma_wqe_setup_send(&wqe3, 200, RDMAVendor::MLX5, 0x1000, 4096, 0xABCD);

  // wqe1 and wqe2 have same wqe_id and opcode (should be equal)
  ASSERT_TRUE(rdma_ep::sqeEqual(&wqe1, &wqe2));

  // wqe1 and wqe3 have different wqe_id (should not be equal)
  ASSERT_FALSE(rdma_ep::sqeEqual(&wqe1, &wqe3));

  // Test with different opcode
  struct rdma_wqe wqe4 = {};
  rdma_wqe_setup_write(&wqe4, 100, RDMAVendor::MLX5, 0x1000, 0x2000, 4096,
                       0xABCD, 0xEF00);
  ASSERT_FALSE(rdma_ep::sqeEqual(&wqe1, &wqe4));

  return 0;
}

// Test CQE comparison function
int test_cqe_equal() {
  struct rdma_cqe cqe1 = {};
  struct rdma_cqe cqe2 = {};
  struct rdma_cqe cqe3 = {};

  rdma_cqe_setup_success(&cqe1, 100, RDMAVendor::IONIC, 4096, 0x1111);
  rdma_cqe_setup_success(&cqe2, 100, RDMAVendor::PVRDMA, 8192, 0x2222);
  rdma_cqe_setup_error(&cqe3, 200, RDMAVendor::IONIC, RDMA_WC_LOC_LEN_ERR,
                       0x3333);

  // cqe1 and cqe2 have same wqe_id (should be equal)
  ASSERT_TRUE(rdma_ep::cqeEqual(&cqe1, &cqe2));

  // cqe1 and cqe3 have different wqe_id (should not be equal)
  ASSERT_FALSE(rdma_ep::cqeEqual(&cqe1, &cqe3));

  return 0;
}

// Test byte-by-byte read/write preserves all fields
int test_byte_by_byte_preservation() {
  // Create WQE with all fields set
  struct rdma_wqe original_wqe = {};
  rdma_wqe_setup_write(&original_wqe, 999, RDMAVendor::IONIC, 0xAAAA, 0xBBBB,
                       0xCCCC, 0xDDDD, 0xEEEE);
  original_wqe.imm_data = 0x12345678;
  original_wqe.vendor_specific = 0xFEDCBA9876543210ULL;

  // Write and read back
  alignas(64) uint8_t buffer[RDMA_EP_SQE_SIZE] = {};
  rdma_ep::sqeWrite(original_wqe, reinterpret_cast<rdma_ep::sqeType*>(buffer));
  rdma_ep::sqeType read_wqe = rdma_ep::sqeRead(
    reinterpret_cast<volatile rdma_ep::sqeType*>(buffer));

  // Verify byte-by-byte match
  ASSERT_MEMEQ(&original_wqe, &read_wqe, sizeof(struct rdma_wqe));

  // Create CQE with all fields set
  struct rdma_cqe original_cqe = {};
  rdma_cqe_setup_success(&original_cqe, 888, RDMAVendor::PVRDMA, 0xFFFF,
                         0xAAAAAAAA);
  original_cqe.imm_data = 0x87654321;
  original_cqe.pvrdma.qpn = 5000;
  original_cqe.pvrdma.reserved = 0x1234;

  // Write and read back
  alignas(64) uint8_t cqe_buffer[RDMA_EP_CQE_SIZE] = {};
  rdma_ep::cqeWrite(original_cqe,
                    reinterpret_cast<rdma_ep::cqeType*>(cqe_buffer));
  rdma_ep::cqeType read_cqe = rdma_ep::cqeRead(
    reinterpret_cast<volatile rdma_ep::cqeType*>(cqe_buffer));

  // Verify byte-by-byte match
  ASSERT_MEMEQ(&original_cqe, &read_cqe, sizeof(struct rdma_cqe));

  return 0;
}

int main() {
  int failures = 0;

  failures += test_sqe_read_write();
  failures += test_cqe_read_write();
  failures += test_sqe_equal();
  failures += test_cqe_equal();
  failures += test_byte_by_byte_preservation();

  if (failures == 0) {
    return 0;
  } else {
    return 1;
  }
}
