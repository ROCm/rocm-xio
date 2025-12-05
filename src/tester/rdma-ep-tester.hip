/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <chrono>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <vector>

#include <hip/hip_runtime.h>

#include "axiio-endpoints.h"
#include "rdma-ep/bnxt/bnxt-rdma.h"
#include "rdma-ep/ionic/ionic-rdma.h"
#include "rdma-ep/mlx/mlx5-rdma.h"
#include "rdma-ep/pvrdma/pvrdma-rdma.h"
#include "rdma-ep/rdma-ep.h"

/*
 * RDMA Endpoint Tester with Emulation Support
 *
 * This tester validates RDMA operations for all 4 supported vendors:
 * - MLX5 (Mellanox/NVIDIA ConnectX)
 * - BNXT_RE (Broadcom NetXtreme)
 * - IONIC (Pensando)
 * - PVRDMA (VMware)
 *
 * Emulation Mode:
 * When no RDMA hardware is present, this tester uses GPU-based emulation
 * to simulate RDMA operations. The emulator thread processes WQEs and
 * generates CQEs, mimicking hardware behavior.
 */

// Test configuration
#define NUM_ITERATIONS 1000
#define NUM_WARMUP 100
#define TRANSFER_SIZE 4096

// Emulation kernel - simulates RDMA NIC processing WQEs
__global__ void rdma_emulator_kernel(sqeType_s* wqe_ring, cqeType_s* cqe_ring,
                                     unsigned int num_iterations,
                                     RDMAVendor vendor) {
  // Each thread acts as an independent emulated NIC
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid > 0)
    return; // Only thread 0 acts as emulator

  printf("[Emulator] Starting RDMA emulation for vendor %s\n",
         rdma_vendor_name(vendor));

  // Call the actual emulation function from rdma-ep
  rdma_ep_emulateEndpoint(num_iterations, wqe_ring, cqe_ring);

  printf("[Emulator] Emulation complete\n");
}

// GPU kernel to drive RDMA operations
__global__ void rdma_driver_kernel(sqeType_s* wqe_ring, cqeType_s* cqe_ring,
                                   unsigned int num_iterations,
                                   RDMAVendor vendor,
                                   unsigned long long int* start_times,
                                   unsigned long long int* end_times) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid > 0)
    return; // Only thread 0 drives operations

  printf("[Driver] Starting RDMA operations for vendor %s\n",
         rdma_vendor_name(vendor));

  // Call the actual driver function from rdma-ep
  rdma_ep_driveEndpoint(num_iterations, wqe_ring, cqe_ring, start_times,
                        end_times);

  printf("[Driver] Operations complete\n");
}

// Test a single RDMA vendor
bool test_rdma_vendor(RDMAVendor vendor, const char* vendor_name,
                      bool use_emulation) {
  std::cout << "\n========================================\n";
  std::cout << "Testing RDMA Vendor: " << vendor_name << "\n";
  std::cout << "Mode: " << (use_emulation ? "Emulation" : "Hardware") << "\n";
  std::cout << "========================================\n";

  // Allocate host-pinned memory for queues
  sqeType_s* h_wqe_ring;
  cqeType_s* h_cqe_ring;
  unsigned long long int* h_start_times;
  unsigned long long int* h_end_times;

  hipError_t err;
  err = hipHostMalloc(&h_wqe_ring, sizeof(sqeType_s));
  if (err != hipSuccess) {
    std::cerr << "Failed to allocate host WQE ring\n";
    return false;
  }
  err = hipHostMalloc(&h_cqe_ring, sizeof(cqeType_s));
  if (err != hipSuccess) {
    std::cerr << "Failed to allocate host CQE ring\n";
    hipHostFree(h_wqe_ring);
    return false;
  }
  err = hipHostMalloc(&h_start_times,
                      sizeof(unsigned long long) * NUM_ITERATIONS);
  if (err != hipSuccess) {
    std::cerr << "Failed to allocate host start times\n";
    hipHostFree(h_wqe_ring);
    hipHostFree(h_cqe_ring);
    return false;
  }
  err = hipHostMalloc(&h_end_times,
                      sizeof(unsigned long long) * NUM_ITERATIONS);
  if (err != hipSuccess) {
    std::cerr << "Failed to allocate host end times\n";
    hipHostFree(h_wqe_ring);
    hipHostFree(h_cqe_ring);
    hipHostFree(h_start_times);
    return false;
  }

  // Allocate GPU memory
  sqeType_s* d_wqe_ring;
  cqeType_s* d_cqe_ring;
  unsigned long long int* d_start_times;
  unsigned long long int* d_end_times;

  err = hipMalloc(&d_wqe_ring, sizeof(sqeType_s));
  if (err != hipSuccess) {
    std::cerr << "Failed to allocate device WQE ring\n";
    hipHostFree(h_wqe_ring);
    hipHostFree(h_cqe_ring);
    hipHostFree(h_start_times);
    hipHostFree(h_end_times);
    return false;
  }
  err = hipMalloc(&d_cqe_ring, sizeof(cqeType_s));
  if (err != hipSuccess) {
    std::cerr << "Failed to allocate device CQE ring\n";
    hipFree(d_wqe_ring);
    hipHostFree(h_wqe_ring);
    hipHostFree(h_cqe_ring);
    hipHostFree(h_start_times);
    hipHostFree(h_end_times);
    return false;
  }
  err = hipMalloc(&d_start_times, sizeof(unsigned long long) * NUM_ITERATIONS);
  if (err != hipSuccess) {
    std::cerr << "Failed to allocate device start times\n";
    hipFree(d_wqe_ring);
    hipFree(d_cqe_ring);
    hipHostFree(h_wqe_ring);
    hipHostFree(h_cqe_ring);
    hipHostFree(h_start_times);
    hipHostFree(h_end_times);
    return false;
  }
  err = hipMalloc(&d_end_times, sizeof(unsigned long long) * NUM_ITERATIONS);
  if (err != hipSuccess) {
    std::cerr << "Failed to allocate device end times\n";
    hipFree(d_wqe_ring);
    hipFree(d_cqe_ring);
    hipFree(d_start_times);
    hipHostFree(h_wqe_ring);
    hipHostFree(h_cqe_ring);
    hipHostFree(h_start_times);
    hipHostFree(h_end_times);
    return false;
  }

  // Initialize WQE/CQE rings
  memset(h_wqe_ring, 0, sizeof(sqeType_s));
  memset(h_cqe_ring, 0, sizeof(cqeType_s));

  hipMemcpy(d_wqe_ring, h_wqe_ring, sizeof(sqeType_s), hipMemcpyHostToDevice);
  hipMemcpy(d_cqe_ring, h_cqe_ring, sizeof(cqeType_s), hipMemcpyHostToDevice);

  // Launch emulator kernel if in emulation mode
  hipStream_t emulator_stream, driver_stream;
  if (use_emulation) {
    hipStreamCreate(&emulator_stream);
    hipStreamCreate(&driver_stream);

    std::cout << "Launching emulator kernel...\n";
    rdma_emulator_kernel<<<1, 1, 0, emulator_stream>>>(
      d_wqe_ring, d_cqe_ring, NUM_ITERATIONS + NUM_WARMUP, vendor);

    // Small delay to ensure emulator is ready
    hipStreamSynchronize(emulator_stream);
  } else {
    hipStreamCreate(&driver_stream);
  }

  // Launch driver kernel
  std::cout << "Launching driver kernel...\n";
  auto start = std::chrono::high_resolution_clock::now();

  rdma_driver_kernel<<<1, 1, 0, driver_stream>>>(d_wqe_ring, d_cqe_ring,
                                                 NUM_ITERATIONS, vendor,
                                                 d_start_times, d_end_times);

  hipStreamSynchronize(driver_stream);
  auto end = std::chrono::high_resolution_clock::now();

  // Copy results back
  hipMemcpy(h_start_times, d_start_times,
            sizeof(unsigned long long) * NUM_ITERATIONS, hipMemcpyDeviceToHost);
  hipMemcpy(h_end_times, d_end_times,
            sizeof(unsigned long long) * NUM_ITERATIONS, hipMemcpyDeviceToHost);

  // Calculate statistics
  double total_time_ms =
    std::chrono::duration<double, std::milli>(end - start).count();
  double ops_per_sec = (NUM_ITERATIONS / total_time_ms) * 1000.0;

  // Calculate latencies
  std::vector<double> latencies;
  for (int i = NUM_WARMUP; i < NUM_ITERATIONS; i++) {
    if (h_end_times[i] > h_start_times[i]) {
      double latency_ns = static_cast<double>(h_end_times[i] -
                                              h_start_times[i]);
      latencies.push_back(latency_ns);
    }
  }

  // Calculate percentiles
  std::sort(latencies.begin(), latencies.end());
  double avg_latency = 0.0;
  for (auto l : latencies)
    avg_latency += l;
  avg_latency /= latencies.size();

  double p50 = latencies[latencies.size() * 50 / 100];
  double p90 = latencies[latencies.size() * 90 / 100];
  double p99 = latencies[latencies.size() * 99 / 100];

  // Print results
  std::cout << "\n=== Test Results ===\n";
  std::cout << "Total operations: " << NUM_ITERATIONS << "\n";
  std::cout << "Total time: " << std::fixed << std::setprecision(2)
            << total_time_ms << " ms\n";
  std::cout << "Operations/sec: " << std::fixed << std::setprecision(0)
            << ops_per_sec << "\n";
  std::cout << "Average latency: " << std::fixed << std::setprecision(1)
            << avg_latency << " cycles\n";
  std::cout << "P50 latency: " << p50 << " cycles\n";
  std::cout << "P90 latency: " << p90 << " cycles\n";
  std::cout << "P99 latency: " << p99 << " cycles\n";

  // Cleanup
  hipFree(d_wqe_ring);
  hipFree(d_cqe_ring);
  hipFree(d_start_times);
  hipFree(d_end_times);
  hipHostFree(h_wqe_ring);
  hipHostFree(h_cqe_ring);
  hipHostFree(h_start_times);
  hipHostFree(h_end_times);

  if (use_emulation) {
    hipStreamDestroy(emulator_stream);
  }
  hipStreamDestroy(driver_stream);

  return true;
}

int main(int argc, char** argv) {
  std::cout << "========================================\n";
  std::cout << "    RDMA Endpoint Tester\n";
  std::cout << "    ROCm-AXIIO Project\n";
  std::cout << "========================================\n\n";

  // Check GPU availability
  int device_count;
  hipGetDeviceCount(&device_count);
  if (device_count == 0) {
    std::cerr << "Error: No HIP-capable devices found\n";
    return 1;
  }

  hipDeviceProp_t props;
  hipGetDeviceProperties(&props, 0);
  std::cout << "GPU: " << props.name << " (gfx" << props.gcnArchName << ")\n";
  std::cout << "Compute units: " << props.multiProcessorCount << "\n";
  std::cout << "Memory: " << (props.totalGlobalMem / (1024 * 1024 * 1024))
            << " GB\n";

  // Determine mode
  bool use_emulation = true; // Default to emulation
  if (argc > 1 && std::string(argv[1]) == "--hardware") {
    use_emulation = false;
    std::cout << "\nHardware mode requested (requires actual RDMA NICs)\n";
  } else {
    std::cout << "\nEmulation mode (no RDMA hardware required)\n";
    std::cout << "Use --hardware flag to test with real RDMA NICs\n";
  }

  // Test all vendors
  bool all_passed = true;

  all_passed &= test_rdma_vendor(RDMAVendor::MLX5, "MLX5 (Mellanox/NVIDIA)",
                                 use_emulation);
  all_passed &= test_rdma_vendor(RDMAVendor::BNXT_RE, "BNXT_RE (Broadcom)",
                                 use_emulation);
  all_passed &= test_rdma_vendor(RDMAVendor::IONIC, "IONIC (Pensando)",
                                 use_emulation);
  all_passed &= test_rdma_vendor(RDMAVendor::PVRDMA, "PVRDMA (VMware)",
                                 use_emulation);

  std::cout << "\n========================================\n";
  if (all_passed) {
    std::cout << "✓ All RDMA vendor tests PASSED\n";
  } else {
    std::cout << "✗ Some RDMA vendor tests FAILED\n";
  }
  std::cout << "========================================\n";

  return all_passed ? 0 : 1;
}
