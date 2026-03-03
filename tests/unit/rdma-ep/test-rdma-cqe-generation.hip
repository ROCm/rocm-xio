/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cassert>

#include <hip/hip_runtime.h>

#include "bnxt/bnxt-rdma.h"
#include "ionic/ionic-rdma.h"
#include "mlx/mlx5-rdma.h"
#include "pvrdma/pvrdma-rdma.h"
#include "rdma-ep.h"
#include "rdma-ep.hip" // Include implementation for __device__ functions
#include "xio.h"       // For HIP_CHECK macro

// Simple assertion macros
#define ASSERT_EQ(a, b) assert((a) == (b))
#define ASSERT_TRUE(x) assert(x)
#define ASSERT_FALSE(x) assert(!(x))

// GPU kernel to test CQE generation from WQE for all vendors
__global__ void test_cqe_generation_kernel(bool* results) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid != 0)
    return; // Only thread 0 performs the test

  bool test_passed = true;

  // Test MLX5 CQE generation
  struct rdma_wqe mlx5_wqe = {};
  rdma_wqe_setup_send(&mlx5_wqe, 123, RDMAVendor::MLX5, 0x1000, 4096, 0xABCD);
  uint32_t qp_num = 1001;
  mlx5_wqe_set_vendor_specific(&mlx5_wqe, qp_num, true, false);
  uint64_t timestamp = 0x123456789ABCDEF0ULL;
  rdma_ep::cqeType mlx5_cqe = rdma_ep::cqeGenFromSqe(&mlx5_wqe, timestamp);
  test_passed &= (mlx5_cqe.wqe_id == 123);
  test_passed &= (mlx5_cqe.vendor == static_cast<uint8_t>(RDMAVendor::MLX5));
  test_passed &= (mlx5_cqe.status == RDMA_WC_SUCCESS);
  test_passed &= (mlx5_cqe.byte_len == 4096);
  test_passed &= (mlx5_cqe.timestamp == timestamp);
  test_passed &= (mlx5_cqe.mlx5.src_qp == qp_num);

  // Test BNXT_RE CQE generation
  struct rdma_wqe bnxt_wqe = {};
  rdma_wqe_setup_write(&bnxt_wqe, 456, RDMAVendor::BNXT_RE, 0x2000, 0x3000,
                       8192, 0x1234, 0x5678);
  bnxt_wqe_set_vendor_specific(&bnxt_wqe, 200, 128);
  rdma_ep::cqeType bnxt_cqe = rdma_ep::cqeGenFromSqe(&bnxt_wqe,
                                                     0xABCDEF0123456789ULL);
  test_passed &= (bnxt_cqe.wqe_id == 456);
  test_passed &= (bnxt_cqe.byte_len == 8192);
  test_passed &= (bnxt_cqe.bnxt.sq_cons_idx == 456);

  // Test IONIC CQE generation
  struct rdma_wqe ionic_wqe = {};
  rdma_wqe_setup_read(&ionic_wqe, 789, RDMAVendor::IONIC, 0x4000, 0x5000, 16384,
                      0x9ABC, 0xDEF0);
  uint32_t ionic_qp = 2002;
  ionic_wqe_set_vendor_specific(&ionic_wqe, ionic_qp, true, true);
  rdma_ep::cqeType ionic_cqe = rdma_ep::cqeGenFromSqe(&ionic_wqe,
                                                      0xFEDCBA9876543210ULL);
  test_passed &= (ionic_cqe.wqe_id == 789);
  test_passed &= (ionic_cqe.byte_len == 16384);
  test_passed &= (ionic_cqe.ionic.qpn == ionic_qp);

  // Test PVRDMA CQE generation
  struct rdma_wqe pvrdma_wqe = {};
  rdma_wqe_setup_send(&pvrdma_wqe, 321, RDMAVendor::PVRDMA, 0x6000, 32768,
                      0x1111);
  uint32_t pvrdma_qp = 3003;
  pvrdma_wqe_set_vendor_specific(&pvrdma_wqe, pvrdma_qp, false, true);
  rdma_ep::cqeType pvrdma_cqe = rdma_ep::cqeGenFromSqe(&pvrdma_wqe,
                                                       0x1122334455667788ULL);
  test_passed &= (pvrdma_cqe.wqe_id == 321);
  test_passed &= (pvrdma_cqe.byte_len == 32768);
  test_passed &= (pvrdma_cqe.pvrdma.qpn == pvrdma_qp);

  // Test error handling for invalid opcode
  struct rdma_wqe invalid_wqe = {};
  invalid_wqe.opcode = static_cast<uint8_t>(0xFF + 1); // Invalid opcode
  invalid_wqe.vendor = static_cast<uint8_t>(RDMAVendor::MLX5);
  invalid_wqe.wqe_id = 999;
  invalid_wqe.length = 4096;
  rdma_ep::cqeType error_cqe = rdma_ep::cqeGenFromSqe(&invalid_wqe,
                                                      0x9999999999999999ULL);
  test_passed &= (error_cqe.status == RDMA_WC_LOC_QP_OP_ERR);
  test_passed &= (error_cqe.wqe_id == 999);

  results[0] = test_passed;
}

// Test CQE generation from MLX5 WQE
int test_cqe_generation_mlx5() {
  struct rdma_wqe wqe = {};
  rdma_wqe_setup_send(&wqe, 123, RDMAVendor::MLX5, 0x1000, 4096, 0xABCD);
  uint32_t qp_num = 1001;
  mlx5_wqe_set_vendor_specific(&wqe, qp_num, true, false);

  uint64_t timestamp = 0x123456789ABCDEF0ULL;
  rdma_ep::cqeType cqe = rdma_ep::cqeGenFromSqe(&wqe, timestamp);

  // Verify basic fields
  ASSERT_EQ(cqe.wqe_id, 123);
  ASSERT_EQ(cqe.vendor, static_cast<uint8_t>(RDMAVendor::MLX5));
  ASSERT_EQ(cqe.status, RDMA_WC_SUCCESS);
  ASSERT_EQ(cqe.byte_len, 4096);
  ASSERT_EQ(cqe.timestamp, timestamp);

  // Verify MLX5-specific fields
  ASSERT_EQ(cqe.mlx5.src_qp, qp_num);
  ASSERT_TRUE(cqe.mlx5.flags & MLX5_WQE_CTRL_SOLICITED);
  ASSERT_FALSE(cqe.mlx5.flags & MLX5_WQE_CTRL_FENCE);

  return 0;
}

// Test CQE generation from BNXT_RE WQE
int test_cqe_generation_bnxt() {
  struct rdma_wqe wqe = {};
  rdma_wqe_setup_write(&wqe, 456, RDMAVendor::BNXT_RE, 0x2000, 0x3000, 8192,
                       0x1234, 0x5678);
  bnxt_wqe_set_vendor_specific(&wqe, 200, 128);

  uint64_t timestamp = 0xABCDEF0123456789ULL;
  rdma_ep::cqeType cqe = rdma_ep::cqeGenFromSqe(&wqe, timestamp);

  // Verify basic fields
  ASSERT_EQ(cqe.wqe_id, 456);
  ASSERT_EQ(cqe.vendor, static_cast<uint8_t>(RDMAVendor::BNXT_RE));
  ASSERT_EQ(cqe.status, RDMA_WC_SUCCESS);
  ASSERT_EQ(cqe.byte_len, 8192);
  ASSERT_EQ(cqe.timestamp, timestamp);

  // Verify BNXT-specific fields (uses wqe_id for indices)
  ASSERT_EQ(cqe.bnxt.sq_cons_idx, 456);
  ASSERT_EQ(cqe.bnxt.cq_cons_idx, 456);

  return 0;
}

// Test CQE generation from IONIC WQE
int test_cqe_generation_ionic() {
  struct rdma_wqe wqe = {};
  rdma_wqe_setup_read(&wqe, 789, RDMAVendor::IONIC, 0x4000, 0x5000, 16384,
                      0x9ABC, 0xDEF0);
  uint32_t qp_num = 2002;
  ionic_wqe_set_vendor_specific(&wqe, qp_num, true, true);

  uint64_t timestamp = 0xFEDCBA9876543210ULL;
  rdma_ep::cqeType cqe = rdma_ep::cqeGenFromSqe(&wqe, timestamp);

  // Verify basic fields
  ASSERT_EQ(cqe.wqe_id, 789);
  ASSERT_EQ(cqe.vendor, static_cast<uint8_t>(RDMAVendor::IONIC));
  ASSERT_EQ(cqe.status, RDMA_WC_SUCCESS);
  ASSERT_EQ(cqe.byte_len, 16384);
  ASSERT_EQ(cqe.timestamp, timestamp);

  // Verify IONIC-specific fields
  ASSERT_EQ(cqe.ionic.qpn, qp_num);
  ASSERT_EQ(cqe.ionic.reserved, 0);

  return 0;
}

// Test CQE generation from PVRDMA WQE
int test_cqe_generation_pvrdma() {
  struct rdma_wqe wqe = {};
  rdma_wqe_setup_send(&wqe, 321, RDMAVendor::PVRDMA, 0x6000, 32768, 0x1111);
  uint32_t qp_num = 3003;
  pvrdma_wqe_set_vendor_specific(&wqe, qp_num, false, true);

  uint64_t timestamp = 0x1122334455667788ULL;
  rdma_ep::cqeType cqe = rdma_ep::cqeGenFromSqe(&wqe, timestamp);

  // Verify basic fields
  ASSERT_EQ(cqe.wqe_id, 321);
  ASSERT_EQ(cqe.vendor, static_cast<uint8_t>(RDMAVendor::PVRDMA));
  ASSERT_EQ(cqe.status, RDMA_WC_SUCCESS);
  ASSERT_EQ(cqe.byte_len, 32768);
  ASSERT_EQ(cqe.timestamp, timestamp);

  // Verify PVRDMA-specific fields
  ASSERT_EQ(cqe.pvrdma.qpn, qp_num);
  ASSERT_EQ(cqe.pvrdma.reserved, 0);

  return 0;
}

// Test error handling for invalid opcode
int test_cqe_generation_invalid_opcode() {
  struct rdma_wqe wqe = {};
  wqe.opcode = static_cast<uint8_t>(0xFF + 1); // Invalid opcode (greater than
                                               // max)
  wqe.vendor = static_cast<uint8_t>(RDMAVendor::MLX5);
  wqe.wqe_id = 999;
  wqe.length = 4096;

  uint64_t timestamp = 0x9999999999999999ULL;
  rdma_ep::cqeType cqe = rdma_ep::cqeGenFromSqe(&wqe, timestamp);

  // Verify error status is set
  ASSERT_EQ(cqe.status, RDMA_WC_LOC_QP_OP_ERR);
  ASSERT_EQ(cqe.wqe_id, 999);
  ASSERT_EQ(cqe.byte_len, 4096);

  return 0;
}

// Test that stop command (opcode 0xFF) is handled correctly
int test_cqe_generation_stop_command() {
  struct rdma_wqe wqe = {};
  wqe.opcode = 0xFF; // Stop command
  wqe.vendor = static_cast<uint8_t>(RDMAVendor::MLX5);
  wqe.wqe_id = 0xFFFF;
  wqe.length = 0;

  uint64_t timestamp = 0xAAAAAAAAAAAAAAAAULL;
  rdma_ep::cqeType cqe = rdma_ep::cqeGenFromSqe(&wqe, timestamp);

  // Stop command should still generate a CQE (though it's a special case)
  ASSERT_EQ(cqe.wqe_id, 0xFFFF);
  ASSERT_EQ(cqe.status, RDMA_WC_SUCCESS); // Stop command is valid

  return 0;
}

// Test wqe_id matching between WQE and CQE
int test_wqe_id_matching() {
  uint16_t test_ids[] = {1, 100, 1000, 0xFFFF};

  for (size_t i = 0; i < sizeof(test_ids) / sizeof(test_ids[0]); i++) {
    struct rdma_wqe wqe = {};
    rdma_wqe_setup_send(&wqe, test_ids[i], RDMAVendor::MLX5, 0x1000, 4096,
                        0xABCD);

    rdma_ep::cqeType cqe = rdma_ep::cqeGenFromSqe(&wqe, 0);

    ASSERT_EQ(cqe.wqe_id, test_ids[i]);
  }

  return 0;
}

// Test byte_len matches WQE length
int test_byte_len_matching() {
  uint32_t test_lengths[] = {1, 64, 4096, 65536, 0xFFFFFFFF};

  for (size_t i = 0; i < sizeof(test_lengths) / sizeof(test_lengths[0]); i++) {
    struct rdma_wqe wqe = {};
    rdma_wqe_setup_write(&wqe, 1, RDMAVendor::BNXT_RE, 0x1000, 0x2000,
                         test_lengths[i], 0x1234, 0x5678);

    rdma_ep::cqeType cqe = rdma_ep::cqeGenFromSqe(&wqe, 0);

    ASSERT_EQ(cqe.byte_len, test_lengths[i]);
  }

  return 0;
}

// GPU-based test that launches kernel
int test_cqe_generation_gpu() {
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
  hipLaunchKernelGGL(test_cqe_generation_kernel, dim3(1), dim3(1), 0, 0,
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
  failures += test_cqe_generation_gpu();

  // Run host-based tests (for detailed verification)
  failures += test_cqe_generation_mlx5();
  failures += test_cqe_generation_bnxt();
  failures += test_cqe_generation_ionic();
  failures += test_cqe_generation_pvrdma();
  failures += test_cqe_generation_invalid_opcode();
  failures += test_cqe_generation_stop_command();
  failures += test_wqe_id_matching();
  failures += test_byte_len_matching();

  if (failures == 0) {
    return 0;
  } else {
    return 1;
  }
}
