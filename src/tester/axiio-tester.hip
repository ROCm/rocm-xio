/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <CLI/CLI.hpp>
#include <iostream>
#include <cstring>
#include <vector>

#include "axiio.h"
#include "axiio-tester.h"
#include "axiio-helpers.h"
#include "axiio-endpoint.h"
#include "axiio-endpoint-registry.h"

// GPU kernel that calls the endpoint drive function
__global__ void test_endpoint_kernel(
  AxiioEndpoint endpoint,
  unsigned iterations,
  void* submissionQueue,
  void* completionQueue,
  unsigned long long int* startTimes,
  unsigned long long int* endTimes) {
  endpoint.drive(iterations, submissionQueue, completionQueue, startTimes, endTimes);
}

int main(int argc, char** argv) {
  CLI::App app{"axiio-tester: A test harness for rocm-axiio."};

  // CLI options
  unsigned iterations = 128;
  app.add_option("-n,--iterations", iterations, "Number of I/O operations")
    ->default_val(128);

  bool verbose = false;
  app.add_flag("-v,--verbose", verbose, "Enable detailed output");

  bool printInfo = false;
  app.add_flag("-i,--info", printInfo, "Print GPU information");

  bool printHistogram = false;
  app.add_flag("--histogram", printHistogram, "Generate performance histogram");

  std::string endpointName = "test-ep";
  app.add_option("-e,--endpoint", endpointName,
                 "Endpoint to use (test-ep, nvme-ep, rdma-ep, sdma-ep)")
    ->default_val("test-ep");

  bool listEndpoints = false;
  app.add_flag("-l,--list-endpoints", listEndpoints, "List all available endpoints");

  CLI11_PARSE(app, argc, argv);

  // List endpoints if requested
  if (listEndpoints) {
    listAvailableEndpoints();
    return EXIT_SUCCESS;
  }

  // Print GPU info if requested
  if (printInfo) {
    axxioPrintDeviceInfo();
  }

  // Validate endpoint
  if (!isValidEndpoint(endpointName)) {
    std::cerr << "Error: Unknown endpoint '" << endpointName << "'" << std::endl;
    std::cerr << "Use --list-endpoints to see available endpoints" << std::endl;
    return EXIT_FAILURE;
  }

  // Create endpoint object
  AxiioEndpoint endpoint(endpointName);
  
  if (verbose) {
    std::cout << "Using endpoint: " << endpoint.getName() << std::endl;
    std::cout << "Description: " << endpoint.getDescription() << std::endl;
    std::cout << "Iterations: " << iterations << std::endl;
  }

  // Get queue entry sizes
  // Since all endpoints are built together, we use the maximum sizes
  // to ensure compatibility with all endpoints:
  // - TEST_EP: 32/32 bytes
  // - NVME_EP: 64/16 bytes  
  // - RDMA_EP: 64/64 bytes
  // - SDMA_EP: 32/16 bytes
  // Maximum: 64/64 bytes
  constexpr size_t sqeSize = 64;
  constexpr size_t cqeSize = 64;

  if (verbose) {
    std::cout << "SQE size: " << sqeSize << " bytes" << std::endl;
    std::cout << "CQE size: " << cqeSize << " bytes" << std::endl;
  }

  // Allocate host memory for SQE/CQE and timing
  void* hostSqeAddr = nullptr;
  void* hostCqeAddr = nullptr;
  unsigned long long int* hostStartTime = nullptr;
  unsigned long long int* hostEndTime = nullptr;

  HIP_CHECK(hipHostMalloc(&hostSqeAddr, sqeSize));
  HIP_CHECK(hipHostMalloc(&hostCqeAddr, cqeSize));
  HIP_CHECK(hipHostMalloc((void**)&hostStartTime, iterations * sizeof(unsigned long long int)));
  HIP_CHECK(hipHostMalloc((void**)&hostEndTime, iterations * sizeof(unsigned long long int)));

  // Initialize buffers to zero
  memset(hostSqeAddr, 0, sqeSize);
  memset(hostCqeAddr, 0, cqeSize);
  memset(hostStartTime, 0, iterations * sizeof(unsigned long long int));
  memset(hostEndTime, 0, iterations * sizeof(unsigned long long int));

  // Allocate device memory for SQE/CQE and timing
  void* deviceSqeAddr = nullptr;
  void* deviceCqeAddr = nullptr;
  unsigned long long int* deviceStartTime = nullptr;
  unsigned long long int* deviceEndTime = nullptr;

  HIP_CHECK(hipMalloc(&deviceSqeAddr, sqeSize));
  HIP_CHECK(hipMalloc(&deviceCqeAddr, cqeSize));
  HIP_CHECK(hipMalloc((void**)&deviceStartTime, iterations * sizeof(unsigned long long int)));
  HIP_CHECK(hipMalloc((void**)&deviceEndTime, iterations * sizeof(unsigned long long int)));

  // Copy initial buffers to device
  HIP_CHECK(hipMemcpy(deviceSqeAddr, hostSqeAddr, sqeSize, hipMemcpyHostToDevice));
  HIP_CHECK(hipMemcpy(deviceCqeAddr, hostCqeAddr, cqeSize, hipMemcpyHostToDevice));

  // Copy endpoint object to device (needed for kernel)
  AxiioEndpoint* deviceEndpoint = nullptr;
  HIP_CHECK(hipMalloc((void**)&deviceEndpoint, sizeof(AxiioEndpoint)));
  HIP_CHECK(hipMemcpy(deviceEndpoint, &endpoint, sizeof(AxiioEndpoint), hipMemcpyHostToDevice));

  if (verbose) {
    std::cout << "Launching GPU kernel..." << std::endl;
  }

  // Launch GPU kernel
  hipLaunchKernelGGL(test_endpoint_kernel, dim3(1), dim3(1), 0, 0,
                     *deviceEndpoint, iterations, deviceSqeAddr, deviceCqeAddr,
                     deviceStartTime, deviceEndTime);
  HIP_CHECK(hipDeviceSynchronize());

  // Copy results back to host
  HIP_CHECK(hipMemcpy(hostStartTime, deviceStartTime,
                      iterations * sizeof(unsigned long long int),
                      hipMemcpyDeviceToHost));
  HIP_CHECK(hipMemcpy(hostEndTime, deviceEndTime,
                      iterations * sizeof(unsigned long long int),
                      hipMemcpyDeviceToHost));

  // Calculate durations
  std::vector<double> durations;
  for (unsigned i = 0; i < iterations; ++i) {
    if (hostEndTime[i] > hostStartTime[i]) {
      durations.push_back((double)(hostEndTime[i] - hostStartTime[i]));
    }
  }

  // Print statistics
  if (durations.size() > 0) {
    if (printHistogram) {
      axxioPrintHistogram(durations, iterations);
    } else {
      axxioPrintStatistics(durations, iterations);
    }
  } else {
    std::cout << "Warning: No valid timing data collected" << std::endl;
  }

  // Free memory
  HIP_CHECK(hipFree(deviceEndpoint));
  HIP_CHECK(hipFree(deviceSqeAddr));
  HIP_CHECK(hipFree(deviceCqeAddr));
  HIP_CHECK(hipFree(deviceStartTime));
  HIP_CHECK(hipFree(deviceEndTime));
  HIP_CHECK(hipHostFree(hostSqeAddr));
  HIP_CHECK(hipHostFree(hostCqeAddr));
  HIP_CHECK(hipHostFree(hostStartTime));
  HIP_CHECK(hipHostFree(hostEndTime));

  return EXIT_SUCCESS;
}
