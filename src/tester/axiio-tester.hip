/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <ctime>
#include <iomanip>
#include <iostream>
#include <thread>
#include <vector>

#include <CLI/CLI.hpp>

#include "axiio-endpoint-config.h"
#include "axiio-endpoint-registry.h"
#include "axiio-endpoint.h"
#include "axiio-helpers.h"
#include "axiio-tester.h"
#include "axiio.h"

// Get CPU wall clock time in nanoseconds
// Reserved for future CPU thread support
__attribute__((unused)) static inline uint64_t getCpuTime() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

// Note: CPU thread support should be implemented by endpoints themselves
// if they need it. The tester is generic and doesn't know about endpoint
// specifics.

// GPU kernel that calls the endpoint drive function with config
__global__ void test_endpoint_kernel(AxiioEndpoint endpoint,
                                     AxiioEndpointConfig config,
                                     void* submissionQueue,
                                     void* completionQueue) {
  endpoint.drive(config, submissionQueue, completionQueue);
}

int main(int argc, char** argv) {
  CLI::App app{"axiio-tester: A test harness for rocm-axiio."};

  // Base configuration
  AxiioEndpointConfig baseConfig;

  // CLI options - common testing parameters
  app
    .add_option("-n,--iterations", baseConfig.iterations,
                "Number of I/O operations")
    ->default_val(128);

  app
    .add_option("-t,--threads", baseConfig.numThreads,
                "Number of GPU threads (default: 1, max: 32)")
    ->default_val(1)
    ->check(CLI::Range(1, 32));

  app
    .add_option("--delay", baseConfig.delayNs,
                "Delay in nanoseconds for CPU response (default: 0). "
                "Negative: fixed delay of |delay| ns. "
                "Positive: random delay 0 to delay ns.")
    ->default_val(0);

  app
    .add_option("-m,--memory-mode", baseConfig.memoryMode, "Memory mode (0-3)")
    ->default_val(0)
    ->check(CLI::Range(0, 3));

  baseConfig.verbose = false;
  app.add_flag("-v,--verbose", baseConfig.verbose, "Enable detailed output");

  bool printInfo = false;
  app.add_flag("-i,--info", printInfo, "Print GPU information");

  bool printHistogram = false;
  app.add_flag("--histogram", printHistogram, "Generate performance histogram");

  std::string endpointName = "test-ep";
  app
    .add_option("-e,--endpoint", endpointName,
                "Endpoint to use (test-ep, nvme-ep, rdma-ep, sdma-ep)")
    ->default_val("test-ep");

  bool listEndpoints = false;
  app.add_flag("-l,--list-endpoints", listEndpoints,
               "List all available endpoints");

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
    std::cerr << "Error: Unknown endpoint '" << endpointName << "'"
              << std::endl;
    std::cerr << "Use --list-endpoints to see available endpoints" << std::endl;
    return EXIT_FAILURE;
  }

  // Create endpoint object
  AxiioEndpoint endpoint(endpointName);

  // Set up endpoint-specific configuration
  // Note: Endpoints can register their config setup via the registry
  // For now, we'll leave endpointConfig as nullptr and let endpoints handle it
  // TODO: Add endpoint config registration mechanism
  (void)baseConfig.endpointConfig; // Reserved for future endpoint config
                                   // support

  if (baseConfig.verbose) {
    std::cout << "Using endpoint: " << endpoint.getName() << std::endl;
    std::cout << "Description: " << endpoint.getDescription() << std::endl;
    std::cout << "Iterations: " << baseConfig.iterations << std::endl;
    std::cout << "Threads: " << baseConfig.numThreads << std::endl;
    if (baseConfig.delayNs != 0) {
      if (baseConfig.delayNs < 0) {
        std::cout << "Delay: Fixed " << -baseConfig.delayNs << " ns"
                  << std::endl;
      } else {
        std::cout << "Delay: Random 0 to " << baseConfig.delayNs << " ns"
                  << std::endl;
      }
    }
    std::cout << "Memory Mode: " << baseConfig.memoryMode << std::endl;
  }

  // Get queue entry sizes from endpoint
  size_t sqeSize = endpoint.getSubmissionQueueEntrySize();
  size_t cqeSize = endpoint.getCompletionQueueEntrySize();

  if (baseConfig.verbose) {
    std::cout << "SQE size: " << sqeSize << " bytes" << std::endl;
    std::cout << "CQE size: " << cqeSize << " bytes" << std::endl;
  }

  // Allocate memory based on number of threads
  void* hostSqeAddr = nullptr;
  void* hostCqeAddr = nullptr;
  unsigned long long int* hostStartTime = nullptr;
  unsigned long long int* hostEndTime = nullptr;

  size_t totalSqeSize = (baseConfig.numThreads > 1)
                          ? sqeSize * baseConfig.numThreads
                          : sqeSize;
  size_t totalCqeSize = (baseConfig.numThreads > 1)
                          ? cqeSize * baseConfig.numThreads
                          : cqeSize;
  size_t totalTimingSize = baseConfig.iterations * baseConfig.numThreads *
                           sizeof(unsigned long long int);

  HIP_CHECK(hipHostMalloc(&hostSqeAddr, totalSqeSize));
  HIP_CHECK(hipHostMalloc(&hostCqeAddr, totalCqeSize));
  HIP_CHECK(hipHostMalloc((void**)&hostStartTime, totalTimingSize));
  HIP_CHECK(hipHostMalloc((void**)&hostEndTime, totalTimingSize));

  // Initialize buffers to zero
  memset(hostSqeAddr, 0, totalSqeSize);
  memset(hostCqeAddr, 0, totalCqeSize);
  memset(hostStartTime, 0, totalTimingSize);
  memset(hostEndTime, 0, totalTimingSize);

  // Allocate device memory for SQE/CQE and timing
  void* deviceSqeAddr = nullptr;
  void* deviceCqeAddr = nullptr;
  unsigned long long int* deviceStartTime = nullptr;
  unsigned long long int* deviceEndTime = nullptr;

  HIP_CHECK(hipMalloc(&deviceSqeAddr, totalSqeSize));
  HIP_CHECK(hipMalloc(&deviceCqeAddr, totalCqeSize));
  HIP_CHECK(hipMalloc((void**)&deviceStartTime, totalTimingSize));
  HIP_CHECK(hipMalloc((void**)&deviceEndTime, totalTimingSize));

  // Set timing arrays in config
  baseConfig.startTimes = deviceStartTime;
  baseConfig.endTimes = deviceEndTime;

  // Copy initial buffers to device
  HIP_CHECK(
    hipMemcpy(deviceSqeAddr, hostSqeAddr, totalSqeSize, hipMemcpyHostToDevice));
  HIP_CHECK(
    hipMemcpy(deviceCqeAddr, hostCqeAddr, totalCqeSize, hipMemcpyHostToDevice));

  // Copy endpoint object and config to device (needed for kernel)
  AxiioEndpoint* deviceEndpoint = nullptr;
  HIP_CHECK(hipMalloc((void**)&deviceEndpoint, sizeof(AxiioEndpoint)));
  HIP_CHECK(hipMemcpy(deviceEndpoint, &endpoint, sizeof(AxiioEndpoint),
                      hipMemcpyHostToDevice));

  AxiioEndpointConfig* deviceConfig = nullptr;
  HIP_CHECK(hipMalloc((void**)&deviceConfig, sizeof(AxiioEndpointConfig)));
  // Create device config copy (pointers will be device pointers)
  AxiioEndpointConfig deviceConfigCopy = baseConfig;
  deviceConfigCopy.startTimes = deviceStartTime;
  deviceConfigCopy.endTimes = deviceEndTime;
  deviceConfigCopy.endpointConfig = nullptr; // Endpoint config not needed on
                                             // device
  HIP_CHECK(hipMemcpy(deviceConfig, &deviceConfigCopy,
                      sizeof(AxiioEndpointConfig), hipMemcpyHostToDevice));

  // Check hardware concurrency for CPU threads
  unsigned hardwareThreads = std::thread::hardware_concurrency();
  if (baseConfig.numThreads > hardwareThreads) {
    std::cerr << "Warning: Requested " << baseConfig.numThreads
              << " CPU threads but only " << hardwareThreads
              << " hardware threads available. Performance may degrade."
              << std::endl;
  }

  if (baseConfig.verbose) {
    std::cout << "Launching GPU kernel..." << std::endl;
  }

  // Launch GPU kernel with config
  // Note: If endpoints need CPU threads, they should handle that internally
  // or via a callback mechanism. The tester is generic.
  hipLaunchKernelGGL(test_endpoint_kernel, dim3(1), dim3(baseConfig.numThreads),
                     0, 0, *deviceEndpoint, *deviceConfig, deviceSqeAddr,
                     deviceCqeAddr);

  // Check for kernel launch errors
  hipError_t err = hipGetLastError();
  if (err != hipSuccess) {
    std::cerr << "Kernel launch failed: " << hipGetErrorString(err)
              << std::endl;
    HIP_CHECK(hipFree(deviceEndpoint));
    HIP_CHECK(hipFree(deviceConfig));
    return EXIT_FAILURE;
  }

  // Wait for GPU kernel to complete
  HIP_CHECK(hipDeviceSynchronize());

  // Copy results back to host
  HIP_CHECK(hipMemcpy(hostStartTime, deviceStartTime, totalTimingSize,
                      hipMemcpyDeviceToHost));
  HIP_CHECK(hipMemcpy(hostEndTime, deviceEndTime, totalTimingSize,
                      hipMemcpyDeviceToHost));

  // Print raw timing data if verbose
  if (baseConfig.verbose) {
    if (baseConfig.numThreads == 1) {
      std::cout << "\nRaw timing data:" << std::endl;
      std::cout << "Index | Start Time      | End Time        | Duration"
                << std::endl;
      std::cout << "------|-----------------|-----------------|----------"
                << std::endl;
      for (unsigned i = 0; i < baseConfig.iterations; ++i) {
        std::cout << std::setw(5) << i << " | " << std::setw(15)
                  << hostStartTime[i] << " | " << std::setw(15)
                  << hostEndTime[i] << " | ";
        if (hostEndTime[i] > hostStartTime[i]) {
          std::cout << (hostEndTime[i] - hostStartTime[i]) << std::endl;
        } else {
          std::cout << "INVALID" << std::endl;
        }
      }
      std::cout << std::endl;
    } else {
      std::cout << "\nRaw timing data (multi-threaded):" << std::endl;
      std::cout << "Thread | Index | Start Time      | End Time        | "
                << "Duration" << std::endl;
      std::cout << "-------|-------|-----------------|-----------------|"
                << "----------" << std::endl;
      for (unsigned t = 0; t < baseConfig.numThreads; ++t) {
        for (unsigned i = 0; i < baseConfig.iterations; ++i) {
          unsigned idx = t * baseConfig.iterations + i;
          std::cout << std::setw(6) << t << " | " << std::setw(5) << i << " | "
                    << std::setw(15) << hostStartTime[idx] << " | "
                    << std::setw(15) << hostEndTime[idx] << " | ";
          if (hostEndTime[idx] > hostStartTime[idx]) {
            std::cout << (hostEndTime[idx] - hostStartTime[idx]) << std::endl;
          } else {
            std::cout << "INVALID" << std::endl;
          }
        }
      }
      std::cout << std::endl;
    }
  }

  // Calculate durations (skip first 3 iterations per thread)
  std::vector<double> durations;
  for (unsigned t = 0; t < baseConfig.numThreads; ++t) {
    unsigned baseIdx = t * baseConfig.iterations;
    for (unsigned i = 3; i < baseConfig.iterations; ++i) {
      unsigned idx = baseIdx + i;
      if (hostEndTime[idx] > hostStartTime[idx]) {
        durations.push_back((double)(hostEndTime[idx] - hostStartTime[idx]));
      }
    }
  }

  // Print statistics
  if (durations.size() > 0) {
    if (printHistogram) {
      axxioPrintHistogram(durations, baseConfig.iterations);
    } else {
      axxioPrintStatistics(durations, baseConfig.iterations);
    }
  } else {
    std::cout << "Warning: No valid timing data collected" << std::endl;
  }

  // Free memory
  HIP_CHECK(hipFree(deviceEndpoint));
  HIP_CHECK(hipFree(deviceConfig));
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
