/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <algorithm>
#include <cmath>
#include <cstring>
#include <ctime>
#include <iomanip>
#include <iostream>
#include <vector>

#include <CLI/CLI.hpp>

#include "axiio.h"

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
  app.add_option("-e,--endpoint", endpointName, "Endpoint to use")
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

  // Get GPU device information (like simple-test)
  int deviceId = 0;
  HIP_CHECK(hipGetDevice(&deviceId));
  hipDeviceProp_t deviceProp;
  HIP_CHECK(hipGetDeviceProperties(&deviceProp, deviceId));

  // Get GPU wall clock frequency (in KHz)
  int gpuWallClockRateKHz = 0;
  HIP_CHECK(hipDeviceGetAttribute(&gpuWallClockRateKHz,
                                  hipDeviceAttributeWallClockRate, deviceId));

  // Calculate GPU clock period in nanoseconds
  // Frequency is in KHz, so period = 1e6 / frequency_khz nanoseconds
  double gpuClockPeriodNs = 1000000.0 /
                            static_cast<double>(gpuWallClockRateKHz);

  // Get CPU clock resolution
  struct timespec cpuRes;
  clock_getres(CLOCK_MONOTONIC, &cpuRes);
  double cpuClockResolutionNs = cpuRes.tv_sec * 1000000000.0 + cpuRes.tv_nsec;

  // Always print device and endpoint info (even when not verbose)
  std::cout << "GPU Model: " << deviceProp.name << std::endl;
  std::cout << "GPU Device ID: " << deviceId << std::endl;
  std::cout << "GPU Wall Clock Rate: " << gpuWallClockRateKHz << " KHz"
            << std::endl;
  std::cout << "GPU Clock Period: " << std::fixed << std::setprecision(3)
            << gpuClockPeriodNs << " ns" << std::endl;
  std::cout << "CPU Clock: CLOCK_MONOTONIC" << std::endl;
  std::cout << "CPU Clock Resolution: " << std::fixed << std::setprecision(3)
            << cpuClockResolutionNs << " ns" << std::endl;
  std::cout << "Using endpoint: " << endpoint.getName() << std::endl;
  std::cout << "Description: " << endpoint.getDescription() << std::endl;
  std::cout << "Iterations: " << baseConfig.iterations << std::endl;
  std::cout << "Threads: " << baseConfig.numThreads << std::endl;
  if (baseConfig.delayNs != 0) {
    if (baseConfig.delayNs < 0) {
      std::cout << "Delay: Fixed " << -baseConfig.delayNs << " ns" << std::endl;
    } else {
      std::cout << "Delay: Random 0 to " << baseConfig.delayNs << " ns"
                << std::endl;
    }
  }

  // Extract memory mode bits and explain them (like simple-test)
  bool gpuWriteToDevice = (baseConfig.memoryMode & 0x1) != 0; // LSB
  bool cpuWriteToDevice = (baseConfig.memoryMode & 0x2) != 0; // MSB
  std::cout << "Memory Mode: " << baseConfig.memoryMode
            << " (GPU write: " << (gpuWriteToDevice ? "device" : "host")
            << ", CPU write: " << (cpuWriteToDevice ? "device" : "host") << ")"
            << std::endl;

  // Get queue entry sizes from endpoint
  size_t sqeSize = endpoint.getSubmissionQueueEntrySize();
  size_t cqeSize = endpoint.getCompletionQueueEntrySize();

  std::cout << "SQE size: " << sqeSize << " bytes" << std::endl;
  std::cout << "CQE size: " << cqeSize << " bytes" << std::endl;

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

  // This allows both CPU and GPU to access the same memory
  // Timing arrays are host-accessible so CPU threads can write to endTimes
  baseConfig.startTimes = hostStartTime;
  baseConfig.endTimes = hostEndTime;
  baseConfig.submissionQueue = hostSqeAddr;
  baseConfig.completionQueue = hostCqeAddr;

  // Run endpoint test - launches GPU kernel and waits for completion
  // CPU threads are handled internally by the endpoint if needed
  hipError_t err = endpoint.run(&baseConfig);
  if (err != hipSuccess) {
    std::cerr << "Endpoint run failed: " << hipGetErrorString(err)
              << " (error code: " << err << ")" << std::endl;
    HIP_CHECK(hipHostFree(hostSqeAddr));
    HIP_CHECK(hipHostFree(hostCqeAddr));
    HIP_CHECK(hipHostFree(hostStartTime));
    HIP_CHECK(hipHostFree(hostEndTime));
    return EXIT_FAILURE;
  }

  // Timing arrays are already host-accessible, no copy needed

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

  // Calculate durations (skip first iteration per thread, as it tends to be
  // larger)
  std::vector<double> durations;
  for (unsigned t = 0; t < baseConfig.numThreads; ++t) {
    unsigned baseIdx = t * baseConfig.iterations;
    for (unsigned i = 1; i < baseConfig.iterations; ++i) {
      unsigned idx = baseIdx + i;
      if (hostEndTime[idx] > hostStartTime[idx]) {
        durations.push_back((double)(hostEndTime[idx] - hostStartTime[idx]));
      }
    }
  }

  // Print statistics (always printed, even when not verbose)
  if (durations.size() > 0) {
    if (printHistogram) {
      axxioPrintHistogram(durations, baseConfig.iterations);
    } else {
      axxioPrintStatistics(durations, baseConfig.iterations);
    }
  } else {
    std::cout << "Warning: No valid timing data collected" << std::endl;
  }

  // Print completion message (like simple-test)
  std::cout << "\nTest completed successfully!" << std::endl;

  // Free memory
  HIP_CHECK(hipHostFree(hostSqeAddr));
  HIP_CHECK(hipHostFree(hostCqeAddr));
  HIP_CHECK(hipHostFree(hostStartTime));
  HIP_CHECK(hipHostFree(hostEndTime));

  return EXIT_SUCCESS;
}
