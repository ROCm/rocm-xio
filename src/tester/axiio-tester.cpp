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
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <CLI/CLI.hpp>

#include "axiio.h"
#include "test-ep-config.h"

int main(int argc, char** argv) {
  CLI::App app{"axiio-tester: A test harness for rocm-axiio."};
  app.fallthrough(true);

  // Global flags (not endpoint-specific)
  bool printInfo = false;
  app.add_flag("-i,--info", printInfo, "Print GPU information");

  bool listEndpoints = false;
  app.add_flag("-l,--list-endpoints", listEndpoints,
               "List all available endpoints");

  // Common options (will be inherited by subcommands via fallthrough)
  // We'll use a single config that gets copied to the selected endpoint
  AxiioEndpointConfig commonConfig;
  app
    .add_option("-n,--iterations", commonConfig.iterations,
                "Number of I/O operations")
    ->default_val(128)
    ->group("Common Options");

  app
    .add_option("-t,--threads", commonConfig.numThreads,
                "Number of GPU threads (default: 1, max: 32)")
    ->default_val(1)
    ->check(CLI::Range(1, 32))
    ->group("Common Options");

  app
    .add_option("--delay", commonConfig.delayNs,
                "Delay in nanoseconds for CPU response (default: 0). "
                "Negative: fixed delay of |delay| ns. "
                "Positive: random delay 0 to delay ns.")
    ->default_val(0)
    ->group("Common Options");

  app
    .add_option("-m,--memory-mode", commonConfig.memoryMode,
                "Memory mode (0-7)")
    ->default_val(0)
    ->check(CLI::Range(0, 7))
    ->group("Common Options");

  commonConfig.verbose = false;
  app.add_flag("-v,--verbose", commonConfig.verbose, "Enable detailed output")
    ->group("Common Options");

  bool printHistogram = false;
  app.add_flag("--histogram", printHistogram, "Generate performance histogram")
    ->group("Common Options");

  // Get all available endpoints
  const auto& registry = getEndpointRegistry();

  // Create subcommands for each endpoint
  std::map<std::string, CLI::App*> endpointSubcommands;
  std::map<std::string, std::unique_ptr<AxiioEndpoint>> endpoints;

  for (const auto& endpointInfo : registry) {
    // Create endpoint object
    auto endpoint = createEndpoint(endpointInfo.name);
    if (!endpoint) {
      continue;
    }

    // Create subcommand for this endpoint
    std::string description = endpointInfo.description;
    CLI::App* subcmd = app.add_subcommand(endpointInfo.name, description);

    // Enable fallthrough for the subcommand itself
    // This allows options defined on the main app to be parsed
    subcmd->fallthrough(true);

    // Store endpoint and subcommand
    endpoints[endpointInfo.name] = std::move(endpoint);
    endpointSubcommands[endpointInfo.name] = subcmd;

    // Let endpoint configure its own CLI options
    endpoints[endpointInfo.name]->configureCliOptions(*subcmd);
  }

  // Parse command line
  CLI11_PARSE(app, argc, argv);

  // Handle global flags
  if (listEndpoints) {
    listAvailableEndpoints();
    return EXIT_SUCCESS;
  }

  if (printInfo) {
    axiioPrintDeviceInfo();
    return EXIT_SUCCESS;
  }

  // Find which subcommand was called
  std::string selectedEndpoint;
  for (const auto& [name, subcmd] : endpointSubcommands) {
    if (subcmd->parsed()) {
      selectedEndpoint = name;
      break;
    }
  }

  // If no subcommand was called, show help
  if (selectedEndpoint.empty()) {
    std::cout << app.help() << std::endl;
    return EXIT_SUCCESS;
  }

  // Get the selected endpoint and copy common config
  auto& endpoint = endpoints[selectedEndpoint];
  AxiioEndpointConfig baseConfig = commonConfig;

  // Initialize endpoint-specific configuration
  baseConfig.endpointConfig = endpoint->initializeEndpointConfig();

  // Get GPU device information
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

  // Print device and endpoint info
  std::cout << "GPU Model: " << deviceProp.name << std::endl;
  std::cout << "GPU Device ID: " << deviceId << std::endl;
  std::cout << "GPU Wall Clock Rate: " << gpuWallClockRateKHz << " KHz"
            << std::endl;
  std::cout << "GPU Clock Period: " << std::fixed << std::setprecision(3)
            << gpuClockPeriodNs << " ns" << std::endl;
  std::cout << "CPU Clock: CLOCK_MONOTONIC" << std::endl;
  std::cout << "CPU Clock Resolution: " << std::fixed << std::setprecision(3)
            << cpuClockResolutionNs << " ns" << std::endl;
  std::cout << "Using endpoint: " << endpoint->getName() << std::endl;
  std::cout << "Description: " << endpoint->getDescription() << std::endl;
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

  // Extract memory mode bits and explain them
  bool gpuWriteToDevice = (baseConfig.memoryMode & 0x1) != 0; // LSB
  bool cpuWriteToDevice = (baseConfig.memoryMode & 0x2) != 0; // Bit 1
  bool doorbellOnDevice = (baseConfig.memoryMode & 0x4) != 0; // Bit 2
  std::cout << "Memory Mode: " << baseConfig.memoryMode
            << " (GPU write: " << (gpuWriteToDevice ? "device" : "host")
            << ", CPU write: " << (cpuWriteToDevice ? "device" : "host")
            << ", Doorbell: " << (doorbellOnDevice ? "device" : "host") << ")"
            << std::endl;

  // Get queue entry sizes and lengths from endpoint
  size_t sqeSize = endpoint->getSubmissionQueueEntrySize();
  size_t cqeSize = endpoint->getCompletionQueueEntrySize();
  size_t sqeLength = endpoint->getSubmissionQueueLength(&baseConfig);
  size_t cqeLength = endpoint->getCompletionQueueLength(&baseConfig);

  // Validate doorbell mode: numThreads must not exceed doorbell queue length
  test_ep::TestEpConfig* testEpConfig = static_cast<test_ep::TestEpConfig*>(
    baseConfig.endpointConfig);
  unsigned doorbell = (testEpConfig != nullptr) ? testEpConfig->doorbell : 0;
  if (doorbell > 0 && baseConfig.numThreads > doorbell) {
    std::cerr << "Error: Number of threads (" << baseConfig.numThreads
              << ") exceeds doorbell queue length (" << doorbell << ")"
              << std::endl;
    return EXIT_FAILURE;
  }

  std::cout << "SQE size: " << sqeSize << " bytes" << std::endl;
  std::cout << "CQE size: " << cqeSize << " bytes" << std::endl;
  std::cout << "SQE length: " << sqeLength << " entries" << std::endl;
  std::cout << "CQE length: " << cqeLength << " entries" << std::endl;

  // Allocate queue memory
  void* hostSqeAddr = nullptr;
  void* hostCqeAddr = nullptr;
  unsigned long long int* hostStartTime = nullptr;
  unsigned long long int* hostEndTime = nullptr;

  size_t totalSqeSize = sqeSize * sqeLength;
  size_t totalCqeSize = cqeSize * cqeLength;
  size_t totalTimingSize = baseConfig.iterations * baseConfig.numThreads *
                           sizeof(unsigned long long int);

  // Allocate queues based on memory mode
  hipError_t sqeErr = axiioAllocateSubmissionQueue(totalSqeSize,
                                                   baseConfig.memoryMode,
                                                   &hostSqeAddr);
  if (sqeErr != hipSuccess) {
    std::cerr << "Failed to allocate submission queue" << std::endl;
    return EXIT_FAILURE;
  }

  hipError_t cqeErr = axiioAllocateCompletionQueue(totalCqeSize,
                                                   baseConfig.memoryMode,
                                                   &hostCqeAddr);
  if (cqeErr != hipSuccess) {
    std::cerr << "Failed to allocate completion queue" << std::endl;
    axiioFreeSubmissionQueue(hostSqeAddr, baseConfig.memoryMode);
    return EXIT_FAILURE;
  }

  // Timing buffers are always host-accessible
  HIP_CHECK(hipHostMalloc((void**)&hostStartTime, totalTimingSize));
  HIP_CHECK(hipHostMalloc((void**)&hostEndTime, totalTimingSize));

  // Initialize timing buffers to zero
  memset(hostStartTime, 0, totalTimingSize);
  memset(hostEndTime, 0, totalTimingSize);

  // Assign buffers to our config structure
  baseConfig.startTimes = hostStartTime;
  baseConfig.endTimes = hostEndTime;
  baseConfig.submissionQueue = hostSqeAddr;
  baseConfig.completionQueue = hostCqeAddr;

  // Run endpoint test
  hipError_t err = endpoint->run(&baseConfig);
  if (err != hipSuccess) {
    std::cerr << "Endpoint run failed: " << hipGetErrorString(err)
              << " (error code: " << err << ")" << std::endl;
    axiioFreeSubmissionQueue(hostSqeAddr, baseConfig.memoryMode);
    axiioFreeCompletionQueue(hostCqeAddr, baseConfig.memoryMode);
    HIP_CHECK(hipHostFree(hostStartTime));
    HIP_CHECK(hipHostFree(hostEndTime));
    return EXIT_FAILURE;
  }

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
          double durationNs = (hostEndTime[i] - hostStartTime[i]) *
                              gpuClockPeriodNs;
          std::cout << std::fixed << std::setprecision(3) << durationNs << " ns"
                    << std::endl;
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
            double durationNs = (hostEndTime[idx] - hostStartTime[idx]) *
                                gpuClockPeriodNs;
            std::cout << std::fixed << std::setprecision(3) << durationNs
                      << " ns" << std::endl;
          } else {
            std::cout << "INVALID" << std::endl;
          }
        }
      }
      std::cout << std::endl;
    }
  }

  // Calculate durations (skip first iteration per thread, as it
  // tends to be larger)
  std::vector<double> durations;
  for (unsigned t = 0; t < baseConfig.numThreads; ++t) {
    unsigned baseIdx = t * baseConfig.iterations;
    for (unsigned i = 1; i < baseConfig.iterations; ++i) {
      unsigned idx = baseIdx + i;
      if (hostEndTime[idx] > hostStartTime[idx]) {
        double durationNs = (hostEndTime[idx] - hostStartTime[idx]) *
                            gpuClockPeriodNs;
        durations.push_back(durationNs);
      }
    }
  }

  // Print statistics (printHistogram is already set from common options)

  if (durations.size() > 0) {
    if (printHistogram) {
      axiioPrintHistogram(durations, baseConfig.iterations,
                          baseConfig.numThreads);
    } else {
      axiioPrintStatistics(durations, baseConfig.iterations,
                           baseConfig.numThreads);
    }
  } else {
    std::cout << "Warning: No valid timing data collected" << std::endl;
  }

  // Print completion message (like simple-test)
  std::cout << "\nTest completed successfully!" << std::endl;

  // Free memory
  axiioFreeSubmissionQueue(hostSqeAddr, baseConfig.memoryMode);
  axiioFreeCompletionQueue(hostCqeAddr, baseConfig.memoryMode);
  HIP_CHECK(hipHostFree(hostStartTime));
  HIP_CHECK(hipHostFree(hostEndTime));

  return EXIT_SUCCESS;
}
