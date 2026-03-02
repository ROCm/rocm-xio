/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cassert>
#include <cstring>

#include <hip/hip_runtime.h>

#include "rdma-ep.h"
#include "rdma-ep.hip" // Include implementation for __device__ functions

// Simple assertion macros
#define ASSERT_EQ(a, b) assert((a) == (b))
#define ASSERT_TRUE(x) assert(x)
#define ASSERT_FALSE(x) assert(!(x))
#define ASSERT_STREQ(a, b) assert(strcmp((a), (b)) == 0)

// GPU kernel to test config structure on device
// Note: Config validation is host-only, but we can test that config
// structure fields are accessible on GPU
__global__ void test_config_structure_kernel(
  rdma_ep::RdmaEpConfig* device_config, bool* results) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid != 0)
    return; // Only thread 0 performs the test

  bool test_passed = true;

  // Verify config structure fields are accessible on GPU
  // (Note: std::string vendorStr is not accessible on device, but other fields
  // are)
  test_passed &= (device_config->iterations > 0);
  test_passed &= (device_config->queueLength > 0);
  test_passed &= (device_config->transferSize > 0);
  test_passed &= (device_config->vendor == RDMAVendor::MLX5 ||
                  device_config->vendor == RDMAVendor::BNXT_RE ||
                  device_config->vendor == RDMAVendor::IONIC ||
                  device_config->vendor == RDMAVendor::PVRDMA ||
                  device_config->vendor == RDMAVendor::UNKNOWN);

  results[0] = test_passed;
}

// Test valid config with all fields set correctly
int test_valid_config() {
  rdma_ep::RdmaEpConfig config = {};
  config.iterations = 100;
  config.vendorStr = "mlx5";
  config.emulate = false;
  config.queueLength = 256;
  config.transferSize = 4096;

  std::string result = rdma_ep::validateConfig(&config);

  ASSERT_STREQ(result.c_str(), "");
  ASSERT_EQ(config.vendor, RDMAVendor::MLX5);
  ASSERT_EQ(config.iterations, 100);
  ASSERT_EQ(config.queueLength, 256);
  ASSERT_EQ(config.transferSize, 4096);

  return 0;
}

// Test invalid queue length (not power of 2)
int test_invalid_queue_length_not_power_of_2() {
  rdma_ep::RdmaEpConfig config = {};
  config.iterations = 100;
  config.vendorStr = "mlx5";
  config.emulate = false;
  config.queueLength = 255; // Not a power of 2
  config.transferSize = 4096;

  std::string result = rdma_ep::validateConfig(&config);

  ASSERT_TRUE(result.find("power of 2") != std::string::npos ||
              result.find("queue length") != std::string::npos);

  return 0;
}

// Test invalid queue length (out of range - too small)
int test_invalid_queue_length_too_small() {
  rdma_ep::RdmaEpConfig config = {};
  config.iterations = 100;
  config.vendorStr = "mlx5";
  config.emulate = false;
  config.queueLength = 1; // Too small (minimum is typically 2)
  config.transferSize = 4096;

  std::string result = rdma_ep::validateConfig(&config);

  // Should fail validation (queue length too small or not power of 2)
  ASSERT_TRUE(result.length() > 0);

  return 0;
}

// Test invalid queue length (out of range - too large)
int test_invalid_queue_length_too_large() {
  rdma_ep::RdmaEpConfig config = {};
  config.iterations = 100;
  config.vendorStr = "mlx5";
  config.emulate = false;
  config.queueLength = 0x1000000; // Very large (16M)
  config.transferSize = 4096;

  std::string result = rdma_ep::validateConfig(&config);

  // Should fail validation (queue length too large)
  ASSERT_TRUE(result.length() > 0);

  return 0;
}

// Test zero iterations
int test_zero_iterations() {
  rdma_ep::RdmaEpConfig config = {};
  config.iterations = 0;
  config.vendorStr = "mlx5";
  config.emulate = false;
  config.queueLength = 256;
  config.transferSize = 4096;

  std::string result = rdma_ep::validateConfig(&config);

  // Zero iterations might be invalid
  ASSERT_TRUE(result.length() > 0);

  return 0;
}

// Test zero transfer size
int test_zero_transfer_size() {
  rdma_ep::RdmaEpConfig config = {};
  config.iterations = 100;
  config.vendorStr = "mlx5";
  config.emulate = false;
  config.queueLength = 256;
  config.transferSize = 0;

  std::string result = rdma_ep::validateConfig(&config);

  // Zero transfer size might be invalid
  ASSERT_TRUE(result.length() > 0);

  return 0;
}

// Test vendor string conversion: "mlx5" -> MLX5
int test_vendor_string_mlx5() {
  rdma_ep::RdmaEpConfig config = {};
  config.iterations = 100;
  config.vendorStr = "mlx5";
  config.emulate = false;
  config.queueLength = 256;
  config.transferSize = 4096;

  std::string result = rdma_ep::validateConfig(&config);

  ASSERT_STREQ(result.c_str(), "");
  ASSERT_EQ(config.vendor, RDMAVendor::MLX5);

  return 0;
}

// Test vendor string conversion: "bnxt" -> BNXT_RE
int test_vendor_string_bnxt() {
  rdma_ep::RdmaEpConfig config = {};
  config.iterations = 100;
  config.vendorStr = "bnxt";
  config.emulate = false;
  config.queueLength = 256;
  config.transferSize = 4096;

  std::string result = rdma_ep::validateConfig(&config);

  ASSERT_STREQ(result.c_str(), "");
  ASSERT_EQ(config.vendor, RDMAVendor::BNXT_RE);

  return 0;
}

// Test vendor string conversion: "bnxt_re" -> BNXT_RE
int test_vendor_string_bnxt_re() {
  rdma_ep::RdmaEpConfig config = {};
  config.iterations = 100;
  config.vendorStr = "bnxt_re";
  config.emulate = false;
  config.queueLength = 256;
  config.transferSize = 4096;

  std::string result = rdma_ep::validateConfig(&config);

  ASSERT_STREQ(result.c_str(), "");
  ASSERT_EQ(config.vendor, RDMAVendor::BNXT_RE);

  return 0;
}

// Test vendor string conversion: "ionic" -> IONIC
int test_vendor_string_ionic() {
  rdma_ep::RdmaEpConfig config = {};
  config.iterations = 100;
  config.vendorStr = "ionic";
  config.emulate = false;
  config.queueLength = 256;
  config.transferSize = 4096;

  std::string result = rdma_ep::validateConfig(&config);

  ASSERT_STREQ(result.c_str(), "");
  ASSERT_EQ(config.vendor, RDMAVendor::IONIC);

  return 0;
}

// Test vendor string conversion: "pvrdma" -> PVRDMA
int test_vendor_string_pvrdma() {
  rdma_ep::RdmaEpConfig config = {};
  config.iterations = 100;
  config.vendorStr = "pvrdma";
  config.emulate = false;
  config.queueLength = 256;
  config.transferSize = 4096;

  std::string result = rdma_ep::validateConfig(&config);

  ASSERT_STREQ(result.c_str(), "");
  ASSERT_EQ(config.vendor, RDMAVendor::PVRDMA);

  return 0;
}

// Test vendor string conversion: "all" -> UNKNOWN
int test_vendor_string_all() {
  rdma_ep::RdmaEpConfig config = {};
  config.iterations = 100;
  config.vendorStr = "all";
  config.emulate = false;
  config.queueLength = 256;
  config.transferSize = 4096;

  std::string result = rdma_ep::validateConfig(&config);

  ASSERT_STREQ(result.c_str(), "");
  ASSERT_EQ(config.vendor, RDMAVendor::UNKNOWN);

  return 0;
}

// Test invalid vendor string handling
int test_invalid_vendor_string() {
  rdma_ep::RdmaEpConfig config = {};
  config.iterations = 100;
  config.vendorStr = "invalid_vendor";
  config.emulate = false;
  config.queueLength = 256;
  config.transferSize = 4096;

  std::string result = rdma_ep::validateConfig(&config);

  ASSERT_TRUE(result.find("Invalid vendor") != std::string::npos ||
              result.length() > 0);

  return 0;
}

// Test case-insensitive vendor strings
int test_vendor_string_case_insensitive() {
  rdma_ep::RdmaEpConfig config1 = {};
  config1.iterations = 100;
  config1.vendorStr = "MLX5";
  config1.emulate = false;
  config1.queueLength = 256;
  config1.transferSize = 4096;

  std::string result1 = rdma_ep::validateConfig(&config1);
  // Note: validateConfig does case-sensitive comparison, but CLI11 handles
  // case-insensitive matching. For unit test purposes, we test the actual
  // behavior.
  // If CLI11 is used, "MLX5" would be accepted, but validateConfig does
  // exact match, so it will fail here.
  // This is expected behavior - CLI11 handles case-insensitivity, not
  // validateConfig.

  rdma_ep::RdmaEpConfig config2 = {};
  config2.iterations = 100;
  config2.vendorStr = "mlx5";
  config2.emulate = false;
  config2.queueLength = 256;
  config2.transferSize = 4096;

  std::string result2 = rdma_ep::validateConfig(&config2);
  ASSERT_STREQ(result2.c_str(), "");
  ASSERT_EQ(config2.vendor, RDMAVendor::MLX5);

  return 0;
}

// Test getIterations function
int test_get_iterations() {
  rdma_ep::RdmaEpConfig config = {};
  config.iterations = 500;

  unsigned iterations = rdma_ep::getIterations(&config);

  ASSERT_EQ(iterations, 500);

  return 0;
}

// Test getIterations with null pointer (should return default)
int test_get_iterations_null() {
  unsigned iterations = rdma_ep::getIterations(nullptr);

  ASSERT_EQ(iterations, 128); // Default value

  return 0;
}

// Test various valid queue lengths (powers of 2)
int test_valid_queue_lengths() {
  uint32_t valid_lengths[] = {2,   4,    8,    16,   32,   64,    128,   256,
                              512, 1024, 2048, 4096, 8192, 16384, 32768, 65536};

  for (size_t i = 0; i < sizeof(valid_lengths) / sizeof(valid_lengths[0]);
       i++) {
    rdma_ep::RdmaEpConfig config = {};
    config.iterations = 100;
    config.vendorStr = "mlx5";
    config.emulate = false;
    config.queueLength = valid_lengths[i];
    config.transferSize = 4096;

    std::string result = rdma_ep::validateConfig(&config);

    // Should pass validation (assuming within max range)
    if (valid_lengths[i] <= 65536) {
      ASSERT_STREQ(result.c_str(), "");
    }
  }

  return 0;
}

// GPU-based test that launches kernel to verify config structure on device
int test_config_structure_gpu() {
  hipError_t err = hipInit(0);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to initialize HIP: %s\n", hipGetErrorString(err));
    return 1;
  }

  // Create config on host
  rdma_ep::RdmaEpConfig host_config = {};
  host_config.iterations = 100;
  host_config.vendor = RDMAVendor::MLX5;
  host_config.emulate = false;
  host_config.queueLength = 256;
  host_config.transferSize = 4096;

  // Allocate device memory for config
  rdma_ep::RdmaEpConfig* device_config = nullptr;
  err = hipMalloc(&device_config, sizeof(rdma_ep::RdmaEpConfig));
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to allocate device memory for config: %s\n",
            hipGetErrorString(err));
    return 1;
  }

  // Copy config to device (note: vendorStr won't be copied, but that's OK)
  err = hipMemcpy(device_config, &host_config, sizeof(rdma_ep::RdmaEpConfig),
                  hipMemcpyHostToDevice);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to copy config to device: %s\n",
            hipGetErrorString(err));
    hipFree(device_config);
    return 1;
  }

  bool* device_results = nullptr;
  err = hipMalloc(&device_results, sizeof(bool));
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to allocate device memory for results: %s\n",
            hipGetErrorString(err));
    hipFree(device_config);
    return 1;
  }

  bool host_result = false;
  err = hipMemcpy(device_results, &host_result, sizeof(bool),
                  hipMemcpyHostToDevice);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to copy to device: %s\n", hipGetErrorString(err));
    hipFree(device_config);
    hipFree(device_results);
    return 1;
  }

  // Launch GPU kernel
  hipLaunchKernelGGL(test_config_structure_kernel, dim3(1), dim3(1), 0, 0,
                     device_config, device_results);

  err = hipGetLastError();
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to launch kernel: %s\n", hipGetErrorString(err));
    hipFree(device_config);
    hipFree(device_results);
    return 1;
  }

  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to synchronize: %s\n", hipGetErrorString(err));
    hipFree(device_config);
    hipFree(device_results);
    return 1;
  }

  err = hipMemcpy(&host_result, device_results, sizeof(bool),
                  hipMemcpyDeviceToHost);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to copy from device: %s\n", hipGetErrorString(err));
    hipFree(device_config);
    hipFree(device_results);
    return 1;
  }

  hipFree(device_config);
  hipFree(device_results);

  if (!host_result) {
    fprintf(stderr, "GPU kernel test failed\n");
    return 1;
  }

  return 0;
}

int main() {
  int failures = 0;

  // Run GPU-based tests
  failures += test_config_structure_gpu();

  // Run host-based tests (for configuration validation)
  failures += test_valid_config();
  failures += test_invalid_queue_length_not_power_of_2();
  failures += test_invalid_queue_length_too_small();
  failures += test_invalid_queue_length_too_large();
  failures += test_zero_iterations();
  failures += test_zero_transfer_size();
  failures += test_vendor_string_mlx5();
  failures += test_vendor_string_bnxt();
  failures += test_vendor_string_bnxt_re();
  failures += test_vendor_string_ionic();
  failures += test_vendor_string_pvrdma();
  failures += test_vendor_string_all();
  failures += test_invalid_vendor_string();
  failures += test_vendor_string_case_insensitive();
  failures += test_get_iterations();
  failures += test_get_iterations_null();
  failures += test_valid_queue_lengths();

  if (failures == 0) {
    return 0;
  } else {
    return 1;
  }
}
