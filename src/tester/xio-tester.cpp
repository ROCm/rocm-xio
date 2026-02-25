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

#include "xio.h"

int main(int argc, char** argv) {
  CLI::App app{"xio-tester: A test harness for rocm-xio."};
  app.fallthrough(true);

  // Global flags (not endpoint-specific)
  bool printInfo = false;
  app.add_flag("-i,--info", printInfo, "Print GPU information");

  bool listEndpoints = false;
  app.add_flag("-l,--list-endpoints", listEndpoints,
               "List all available endpoints");

  // Common options (will be inherited by subcommands via fallthrough)
  // We'll use a single config that gets copied to the selected endpoint
  XioEndpointConfig commonConfig;
  // Note: iterations is now endpoint-specific (test-ep has --iterations,
  // nvme-ep uses --read-io + --write-io)

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
                "Memory mode (0-15)")
    ->default_val(0)
    ->check(CLI::Range(0, 15))
    ->group("Common Options");

  commonConfig.verbose = false;
  app.add_flag("-v,--verbose", commonConfig.verbose, "Enable detailed output")
    ->group("Common Options");

  bool printHistogram = false;
  app.add_flag("--histogram", printHistogram, "Generate performance histogram")
    ->group("Common Options");

  app
    .add_flag("--pci-mmio-bridge", commonConfig.pciMmioBridge,
              "Use PCI MMIO bridge to route endpoint doorbell rings")
    ->group("Common Options");

  // Get all available endpoints
  const auto& registry = getEndpointRegistry();

  // Create subcommands for each endpoint
  std::map<std::string, CLI::App*> endpointSubcommands;
  std::map<std::string, std::unique_ptr<XioEndpoint>> endpoints;

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
    xioPrintDeviceInfo();
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
  XioEndpointConfig baseConfig = commonConfig;

  // Initialize endpoint-specific configuration
  baseConfig.endpointConfig = endpoint->initializeEndpointConfig();

  // Apply common configuration to endpoint-specific config
  if (baseConfig.endpointConfig) {
    endpoint->applyCommonConfig(baseConfig.endpointConfig, &baseConfig);
  }

  // Validate endpoint-specific configuration
  std::string validation_error = endpoint->validateConfig(
    baseConfig.endpointConfig);
  if (!validation_error.empty()) {
    std::cerr << "Error: " << validation_error << std::endl;
    return EXIT_FAILURE;
  }

  // Get iterations from endpoint (endpoints can override getIterations)
  baseConfig.iterations = endpoint->getIterations(baseConfig.endpointConfig);

  // Check if endpoint is in emulate mode
  bool emulateMode = endpoint->isEmulateMode();

  // In emulate mode, memory mode must be 0 (host memory only)
  if (emulateMode && baseConfig.memoryMode != 0) {
    std::cerr << "Error: Memory mode must be 0 in emulate mode (device memory "
                 "not supported)"
              << std::endl;
    return EXIT_FAILURE;
  }

  // Get GPU device information (skip in emulate mode)
  int deviceId = 0;
  double gpuClockPeriodNs = 10.0; // Default: 10ns (100MHz) for emulate mode
  if (!emulateMode) {
    HIP_CHECK(hipGetDevice(&deviceId));
    hipDeviceProp_t deviceProp;
    HIP_CHECK(hipGetDeviceProperties(&deviceProp, deviceId));

    // Get GPU wall clock frequency (in KHz)
    int gpuWallClockRateKHz = 0;
    HIP_CHECK(hipDeviceGetAttribute(&gpuWallClockRateKHz,
                                    hipDeviceAttributeWallClockRate, deviceId));

    // Calculate GPU clock period in nanoseconds
    // Frequency is in KHz, so period = 1e6 / frequency_khz nanoseconds
    gpuClockPeriodNs = 1000000.0 / static_cast<double>(gpuWallClockRateKHz);

    // Print device and endpoint info
    std::cout << "Model: " << deviceProp.name << std::endl;
    std::cout << "GPU Device ID: " << deviceId << std::endl;
    std::cout << "GPU Wall Clock Rate: " << gpuWallClockRateKHz << " KHz"
              << std::endl;
  } else {
    // Emulate mode: use CPU time instead of GPU time
    std::cout << "Model: [Emulation Mode - CPU]" << std::endl;
    std::cout << "GPU Device ID: N/A (emulation)" << std::endl;
    std::cout << "GPU Wall Clock Rate: 100000 KHz (emulated)" << std::endl;
  }

  std::cout << "GPU Clock Period: " << std::fixed << std::setprecision(3)
            << gpuClockPeriodNs << " ns" << std::endl;

  // Get CPU clock resolution
  struct timespec cpuRes;
  clock_getres(CLOCK_MONOTONIC, &cpuRes);
  double cpuClockResolutionNs = cpuRes.tv_sec * 1000000000.0 + cpuRes.tv_nsec;
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
  unsigned doorbell = endpoint->getDoorbellQueueLength();
  if (doorbell > 0 && baseConfig.numThreads > doorbell) {
    std::cerr << "Error: Number of threads (" << baseConfig.numThreads
              << ") exceeds doorbell queue length (" << doorbell << ")"
              << std::endl;
    return EXIT_FAILURE;
  }

  if (sqeSize > 0 || cqeSize > 0) {
    std::cout << "SQE size: " << sqeSize << " bytes" << std::endl;
    std::cout << "CQE size: " << cqeSize << " bytes" << std::endl;
    std::cout << "SQE length: " << sqeLength << " entries" << std::endl;
    std::cout << "CQE length: " << cqeLength << " entries" << std::endl;
  }

  // Allocate queue memory (use at least 1 byte to avoid allocator edge cases)
  void* hostSqeAddr = nullptr;
  void* hostCqeAddr = nullptr;
  unsigned long long int* hostStartTime = nullptr;
  unsigned long long int* hostEndTime = nullptr;

  size_t totalSqeSize = sqeSize * sqeLength;
  size_t totalCqeSize = cqeSize * cqeLength;
  if (totalSqeSize == 0)
    totalSqeSize = 1;
  if (totalCqeSize == 0)
    totalCqeSize = 1;
  size_t totalTimingSize = baseConfig.iterations * baseConfig.numThreads *
                           sizeof(unsigned long long int);

  // Allocate queues based on memory mode
  hipError_t sqeErr = xioAllocateSubmissionQueue(totalSqeSize,
                                                 baseConfig.memoryMode,
                                                 &hostSqeAddr);
  if (sqeErr != hipSuccess) {
    std::cerr << "Failed to allocate submission queue" << std::endl;
    return EXIT_FAILURE;
  }

  hipError_t cqeErr = xioAllocateCompletionQueue(totalCqeSize,
                                                 baseConfig.memoryMode,
                                                 &hostCqeAddr);
  if (cqeErr != hipSuccess) {
    std::cerr << "Failed to allocate completion queue" << std::endl;
    xioFreeSubmissionQueue(hostSqeAddr, baseConfig.memoryMode);
    return EXIT_FAILURE;
  }

  // Timing buffers are always host-accessible
  // Try HIP first, but fall back to malloc if HIP is not available (emulate
  // mode)
  hipError_t hipErr1 = hipHostMalloc((void**)&hostStartTime, totalTimingSize);
  if (hipErr1 != hipSuccess) {
    // HIP not available (e.g., emulate mode), use regular malloc
    void* ptr = malloc(totalTimingSize);
    if (ptr == nullptr) {
      std::cerr << "Error: Failed to allocate start time buffer" << std::endl;
      return EXIT_FAILURE;
    }
    hostStartTime = static_cast<unsigned long long int*>(ptr);
  }
  hipError_t hipErr2 = hipHostMalloc((void**)&hostEndTime, totalTimingSize);
  if (hipErr2 != hipSuccess) {
    // HIP not available (e.g., emulate mode), use regular malloc
    void* ptr = malloc(totalTimingSize);
    if (ptr == nullptr) {
      std::cerr << "Error: Failed to allocate end time buffer" << std::endl;
      return EXIT_FAILURE;
    }
    hostEndTime = static_cast<unsigned long long int*>(ptr);
  }

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
    xioFreeSubmissionQueue(hostSqeAddr, baseConfig.memoryMode);
    xioFreeCompletionQueue(hostCqeAddr, baseConfig.memoryMode);
    // Free host memory using HIP or regular free
    hipError_t hipErrFree1 = hipHostFree(hostStartTime);
    if (hipErrFree1 != hipSuccess) {
      free(hostStartTime);
    }
    hipError_t hipErrFree2 = hipHostFree(hostEndTime);
    if (hipErrFree2 != hipSuccess) {
      free(hostEndTime);
    }
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
      xioPrintHistogram(durations, baseConfig.iterations,
                        baseConfig.numThreads);
    } else {
      xioPrintStatistics(durations, baseConfig.iterations,
                         baseConfig.numThreads);
    }
  } else {
    std::cout << "Warning: No valid timing data collected" << std::endl;
  }

  // Print completion message (like simple-test)
  std::cout << "\nTest completed successfully!" << std::endl;

  // Free memory
  xioFreeSubmissionQueue(hostSqeAddr, baseConfig.memoryMode);
  xioFreeCompletionQueue(hostCqeAddr, baseConfig.memoryMode);
  // Free host memory using HIP or regular free
  hipError_t hipErrFree1 = hipHostFree(hostStartTime);
  if (hipErrFree1 != hipSuccess) {
    free(hostStartTime);
  }
  hipError_t hipErrFree2 = hipHostFree(hostEndTime);
  if (hipErrFree2 != hipSuccess) {
    free(hostEndTime);
  }

  return EXIT_SUCCESS;
}
