/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cassert>
#include <cstring>

#include <hip/hip_runtime.h>

#include "bnxt/bnxt-rdma.h"
#include "ionic/ionic-rdma.h"
#include "mlx/mlx5-rdma.h"
#include "rdma-ep.h"
#include "rdma-ep.hip" // Include implementation for __device__ functions
#include "rocm-ernic/rocm-ernic-rdma.h"
#include "xio.h" // For HIP_CHECK macro

// Simple assertion macros
#define ASSERT_EQ(a, b) assert((a) == (b))
#define ASSERT_TRUE(x) assert(x)
#define ASSERT_FALSE(x) assert(!(x))

// GPU kernel to test vendor-specific functions on device
__global__ void test_vendor_specific_kernel(bool* results) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid != 0)
    return; // Only thread 0 performs the test

  bool test_passed = true;

  // Test MLX5
  struct rdma_wqe mlx5_wqe = {};
  uint32_t qp_num = 1000;
  mlx5_wqe_set_vendor_specific(&mlx5_wqe, qp_num, true, false);
  uint32_t extracted_qp = static_cast<uint32_t>(mlx5_wqe.vendor_specific >> 32);
  uint32_t extracted_flags = static_cast<uint32_t>(mlx5_wqe.vendor_specific &
                                                   0xFFFFFFFF);
  test_passed &= (extracted_qp == qp_num);
  test_passed &= (extracted_flags & MLX5_WQE_CTRL_SOLICITED);

  rdma_ep::cqeType mlx5_cqe = rdma_ep::cqeGenFromSqe(&mlx5_wqe, 0);
  test_passed &= (mlx5_cqe.mlx5.src_qp == qp_num);

  // Test BNXT_RE
  struct rdma_wqe bnxt_wqe = {};
  bnxt_wqe_set_vendor_specific(&bnxt_wqe, 200, 128);
  uint32_t extracted_sq_prod = static_cast<uint32_t>(bnxt_wqe.vendor_specific >>
                                                     32);
  test_passed &= (extracted_sq_prod == 200);

  bnxt_wqe.wqe_id = 123;
  rdma_ep::cqeType bnxt_cqe = rdma_ep::cqeGenFromSqe(&bnxt_wqe, 0);
  test_passed &= (bnxt_cqe.bnxt.sq_cons_idx == 123);

  // Test IONIC
  struct rdma_wqe ionic_wqe = {};
  uint32_t ionic_qp = 2000;
  ionic_wqe_set_vendor_specific(&ionic_wqe, ionic_qp, true, true);
  uint32_t ionic_extracted_qp = static_cast<uint32_t>(
    ionic_wqe.vendor_specific >> 32);
  test_passed &= (ionic_extracted_qp == ionic_qp);

  rdma_ep::cqeType ionic_cqe = rdma_ep::cqeGenFromSqe(&ionic_wqe, 0);
  test_passed &= (ionic_cqe.ionic.qpn == ionic_qp);

  // Test rocm-ernic
  struct rdma_wqe rocm_ernic_wqe = {};
  uint32_t rocm_ernic_qp = 3000;
  rocm_ernic_wqe_set_vendor_specific(&rocm_ernic_wqe, rocm_ernic_qp, false,
                                     true);
  uint32_t rocm_ernic_extracted_qp = static_cast<uint32_t>(
    rocm_ernic_wqe.vendor_specific >> 32);
  test_passed &= (rocm_ernic_extracted_qp == rocm_ernic_qp);

  rdma_ep::cqeType rocm_ernic_cqe = rdma_ep::cqeGenFromSqe(&rocm_ernic_wqe, 0);
  test_passed &= (rocm_ernic_cqe.rocm_ernic.qpn == rocm_ernic_qp);

  results[0] = test_passed;
}

// Test MLX5 vendor-specific functions
int test_mlx5_vendor_specific() {
  struct rdma_wqe wqe = {};
  uint32_t qp_num = 1000;
  bool solicited = true;
  bool fence = false;

  mlx5_wqe_set_vendor_specific(&wqe, qp_num, solicited, fence);

  // Verify encoding: QP number in upper 32 bits, flags in lower 32 bits
  uint32_t extracted_qp = static_cast<uint32_t>(wqe.vendor_specific >> 32);
  uint32_t extracted_flags = static_cast<uint32_t>(wqe.vendor_specific &
                                                   0xFFFFFFFF);

  ASSERT_EQ(extracted_qp, qp_num);
  ASSERT_TRUE(extracted_flags & MLX5_WQE_CTRL_SOLICITED);
  ASSERT_FALSE(extracted_flags & MLX5_WQE_CTRL_FENCE);

  // Test with fence flag
  mlx5_wqe_set_vendor_specific(&wqe, qp_num, false, true);
  extracted_flags = static_cast<uint32_t>(wqe.vendor_specific & 0xFFFFFFFF);
  ASSERT_FALSE(extracted_flags & MLX5_WQE_CTRL_SOLICITED);
  ASSERT_TRUE(extracted_flags & MLX5_WQE_CTRL_FENCE);

  // Generate CQE and verify extraction
  rdma_ep::cqeType cqe = rdma_ep::cqeGenFromSqe(&wqe, 0);
  struct rdma_cqe* cqe_ptr = &cqe;

  ASSERT_EQ(mlx5_cqe_get_src_qp(cqe_ptr), qp_num);
  ASSERT_EQ(mlx5_cqe_get_flags(cqe_ptr), extracted_flags);

  return 0;
}

// Test BNXT_RE vendor-specific functions
int test_bnxt_vendor_specific() {
  struct rdma_wqe wqe = {};
  uint32_t sq_prod_idx = 42;
  uint32_t inline_len = 64;

  bnxt_wqe_set_vendor_specific(&wqe, sq_prod_idx, inline_len);

  // Verify encoding: SQ producer index in upper 32 bits, inline_len in lower
  uint32_t extracted_sq_prod = static_cast<uint32_t>(wqe.vendor_specific >> 32);
  uint32_t extracted_inline = static_cast<uint32_t>(wqe.vendor_specific &
                                                    0xFFFFFFFF);

  ASSERT_EQ(extracted_sq_prod, sq_prod_idx);
  ASSERT_EQ(extracted_inline, inline_len);

  // Generate CQE and verify BNXT fields
  wqe.wqe_id = 123;
  rdma_ep::cqeType cqe = rdma_ep::cqeGenFromSqe(&wqe, 0);
  struct rdma_cqe* cqe_ptr = &cqe;

  ASSERT_EQ(bnxt_cqe_get_sq_cons_idx(cqe_ptr), 123);
  ASSERT_EQ(bnxt_cqe_get_cq_cons_idx(cqe_ptr), 123);

  return 0;
}

// Test IONIC vendor-specific functions
int test_ionic_vendor_specific() {
  struct rdma_wqe wqe = {};
  uint32_t qp_num = 2000;
  bool signaled = true;
  bool fence = true;

  ionic_wqe_set_vendor_specific(&wqe, qp_num, signaled, fence);

  // Verify encoding: QP number in upper 32 bits, flags in lower 32 bits
  uint32_t extracted_qp = static_cast<uint32_t>(wqe.vendor_specific >> 32);
  uint32_t extracted_flags = static_cast<uint32_t>(wqe.vendor_specific &
                                                   0xFFFFFFFF);

  ASSERT_EQ(extracted_qp, qp_num);
  ASSERT_TRUE(extracted_flags & IONIC_SEND_SIGNALED);
  ASSERT_TRUE(extracted_flags & IONIC_SEND_FENCE);

  // Test without flags
  ionic_wqe_set_vendor_specific(&wqe, qp_num, false, false);
  extracted_flags = static_cast<uint32_t>(wqe.vendor_specific & 0xFFFFFFFF);
  ASSERT_FALSE(extracted_flags & IONIC_SEND_SIGNALED);
  ASSERT_FALSE(extracted_flags & IONIC_SEND_FENCE);

  // Generate CQE and verify extraction
  rdma_ep::cqeType cqe = rdma_ep::cqeGenFromSqe(&wqe, 0);
  struct rdma_cqe* cqe_ptr = &cqe;

  ASSERT_EQ(ionic_cqe_get_qpn(cqe_ptr), qp_num);

  return 0;
}

// Test rocm-ernic vendor-specific functions
int test_rocm_ernic_vendor_specific() {
  struct rdma_wqe wqe = {};
  uint32_t qp_num = 3000;
  bool signaled = false;
  bool fence = true;

  rocm_ernic_wqe_set_vendor_specific(&wqe, qp_num, signaled, fence);

  // Verify encoding: QP number in upper 32 bits, flags in lower 32 bits
  uint32_t extracted_qp = static_cast<uint32_t>(wqe.vendor_specific >> 32);
  uint32_t extracted_flags = static_cast<uint32_t>(wqe.vendor_specific &
                                                   0xFFFFFFFF);

  ASSERT_EQ(extracted_qp, qp_num);
  ASSERT_FALSE(extracted_flags & ROCM_ERNIC_SEND_SIGNALED);
  ASSERT_TRUE(extracted_flags & ROCM_ERNIC_SEND_FENCE);

  // Test with signaled flag
  rocm_ernic_wqe_set_vendor_specific(&wqe, qp_num, true, false);
  extracted_flags = static_cast<uint32_t>(wqe.vendor_specific & 0xFFFFFFFF);
  ASSERT_TRUE(extracted_flags & ROCM_ERNIC_SEND_SIGNALED);
  ASSERT_FALSE(extracted_flags & ROCM_ERNIC_SEND_FENCE);

  // Generate CQE and verify extraction
  rdma_ep::cqeType cqe = rdma_ep::cqeGenFromSqe(&wqe, 0);
  struct rdma_cqe* cqe_ptr = &cqe;

  ASSERT_EQ(rocm_ernic_cqe_get_qpn(cqe_ptr), qp_num);

  return 0;
}

// Test vendor-specific CQE field extraction for all vendors
int test_vendor_cqe_extraction() {
  // MLX5
  struct rdma_wqe mlx5_wqe = {};
  mlx5_wqe.vendor = static_cast<uint8_t>(RDMAVendor::MLX5);
  mlx5_wqe.wqe_id = 1;
  mlx5_wqe.length = 4096;
  mlx5_wqe_set_vendor_specific(&mlx5_wqe, 1001, true, false);
  rdma_ep::cqeType mlx5_cqe = rdma_ep::cqeGenFromSqe(&mlx5_wqe, 0x1111);
  ASSERT_EQ(mlx5_cqe.mlx5.src_qp, 1001);
  ASSERT_TRUE(mlx5_cqe.mlx5.flags & MLX5_WQE_CTRL_SOLICITED);

  // BNXT_RE
  struct rdma_wqe bnxt_wqe = {};
  bnxt_wqe.vendor = static_cast<uint8_t>(RDMAVendor::BNXT_RE);
  bnxt_wqe.wqe_id = 2;
  bnxt_wqe.length = 8192;
  bnxt_wqe_set_vendor_specific(&bnxt_wqe, 200, 128);
  rdma_ep::cqeType bnxt_cqe = rdma_ep::cqeGenFromSqe(&bnxt_wqe, 0x2222);
  ASSERT_EQ(bnxt_cqe.bnxt.sq_cons_idx, 2);
  ASSERT_EQ(bnxt_cqe.bnxt.cq_cons_idx, 2);

  // IONIC
  struct rdma_wqe ionic_wqe = {};
  ionic_wqe.vendor = static_cast<uint8_t>(RDMAVendor::IONIC);
  ionic_wqe.wqe_id = 3;
  ionic_wqe.length = 16384;
  ionic_wqe_set_vendor_specific(&ionic_wqe, 2002, true, true);
  rdma_ep::cqeType ionic_cqe = rdma_ep::cqeGenFromSqe(&ionic_wqe, 0x3333);
  ASSERT_EQ(ionic_cqe.ionic.qpn, 2002);
  ASSERT_EQ(ionic_cqe.ionic.reserved, 0);

  // rocm-ernic
  struct rdma_wqe rocm_ernic_wqe = {};
  rocm_ernic_wqe.vendor = static_cast<uint8_t>(RDMAVendor::ROCM_ERNIC);
  rocm_ernic_wqe.wqe_id = 4;
  rocm_ernic_wqe.length = 32768;
  rocm_ernic_wqe_set_vendor_specific(&rocm_ernic_wqe, 3003, false, true);
  rdma_ep::cqeType rocm_ernic_cqe = rdma_ep::cqeGenFromSqe(&rocm_ernic_wqe,
                                                           0x4444);
  ASSERT_EQ(rocm_ernic_cqe.rocm_ernic.qpn, 3003);
  ASSERT_EQ(rocm_ernic_cqe.rocm_ernic.reserved, 0);

  return 0;
}

// GPU-based test that launches kernel
int test_vendor_specific_gpu() {
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
  hipLaunchKernelGGL(test_vendor_specific_kernel, dim3(1), dim3(1), 0, 0,
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
  failures += test_vendor_specific_gpu();

  // Run host-based tests (for detailed verification)
  failures += test_mlx5_vendor_specific();
  failures += test_bnxt_vendor_specific();
  failures += test_ionic_vendor_specific();
  failures += test_rocm_ernic_vendor_specific();
  failures += test_vendor_cqe_extraction();

  if (failures == 0) {
    return 0;
  } else {
    return 1;
  }
}
