/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cmath>
#include <csignal>
#include <cstring>
#include <ctime>
#include <iomanip>
#include <iostream>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <CLI/CLI.hpp>

#include "xio-cli-options.h"
#include "xio.h"

using namespace xio;

// Static pointer to config for signal handler access
static XioEndpointConfig* g_configForSignalHandler = nullptr;
// Static pointer to endpoint name for signal handler access
static std::string* g_endpointNameForSignalHandler = nullptr;

// Forward declaration for NVMe queue cleanup
extern "C" {
int nvme_ep_cleanup_queues(void* endpointConfig);
}

// SIGINT handler - sets stop flag and attempts to cleanup NVMe queues
static void sigintHandler(int sig) {
  (void)sig; // Suppress unused parameter warning
  if (g_configForSignalHandler != nullptr &&
      g_configForSignalHandler->stopRequested != nullptr) {
    *g_configForSignalHandler->stopRequested = true;
  }

  // Attempt to delete NVMe queues if this is the NVMe endpoint
  if (g_configForSignalHandler != nullptr &&
      g_configForSignalHandler->endpointConfig != nullptr &&
      g_endpointNameForSignalHandler != nullptr &&
      *g_endpointNameForSignalHandler == "nvme-ep") {
    nvme_ep_cleanup_queues(g_configForSignalHandler->endpointConfig);
  }
}

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
  // Note: iterations are endpoint-specific (test-ep
  // has --iterations, nvme-ep derives count from
  // --read-io + --write-io and controls doorbell
  // batching via --batch-size)

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

  bool showHistogram = false;
  app.add_flag("--histogram", showHistogram, "Generate performance histogram")
    ->group("Common Options");

  bool lessTiming = false;
  app
    .add_flag("--less-timing", lessTiming,
              "Use lightweight timing mode (track min/max/mean only, "
              "useful for large iterations)")
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
  std::map<std::string, void*> endpointConfigs;

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

    void* epCfg = endpoints[endpointInfo.name]->initializeEndpointConfig();
    endpointConfigs[endpointInfo.name] = epCfg;
    switch (endpoints[endpointInfo.name]->getType()) {
      case EndpointType::TEST_EP:
        registerTestEpCliOptions(*subcmd,
                                 static_cast<test_ep::TestEpConfig*>(epCfg));
        break;
      case EndpointType::NVME_EP:
        registerNvmeEpCliOptions(*subcmd,
                                 static_cast<nvme_ep::nvmeEpConfig*>(epCfg));
        break;
      case EndpointType::RDMA_EP:
        registerRdmaEpCliOptions(*subcmd,
                                 static_cast<rdma_ep::RdmaEpConfig*>(epCfg));
        break;
      case EndpointType::SDMA_EP:
        registerSdmaEpCliOptions(*subcmd,
                                 static_cast<sdma_ep::SdmaEpConfig*>(epCfg));
        break;
      default:
        break;
    }
  }

  // Parse command line
  CLI11_PARSE(app, argc, argv);

  // Handle global flags
  if (listEndpoints) {
    listAvailableEndpoints();
    return EXIT_SUCCESS;
  }

  if (printInfo) {
    printDeviceInfo();
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

  // Reuse the config pointer obtained before CLI parsing
  baseConfig.endpointConfig = endpointConfigs[selectedEndpoint];

  // For SDMA, detect which subcommand was selected
  if (endpoint->getType() == EndpointType::SDMA_EP) {
    detectSdmaTestType(*endpointSubcommands[selectedEndpoint],
                       static_cast<sdma_ep::SdmaEpConfig*>(
                         baseConfig.endpointConfig));
  }

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

  // Explicitly initialize the HIP runtime so that init overhead
  // is isolated from benchmark timing and errors are reported
  // clearly before any device queries.
  if (!emulateMode) {
    hipError_t herr = hipInit(0);
    if (herr != hipSuccess) {
      std::cerr << "hipInit failed: " << hipGetErrorString(herr) << std::endl;
      return EXIT_FAILURE;
    }
  }

  // Get GPU device information (skip in emulate mode)
  int deviceId = 0;
  double gpuClockPeriodNs = 10.0;
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
  size_t totalTimingSize = lessTiming
                             ? 0
                             : (baseConfig.iterations * baseConfig.numThreads *
                                sizeof(unsigned long long int));

  // Allocate queues based on memory mode
  // Bit 0: GPU write location (SQE) - 0=host, 1=device
  // Bit 1: CPU write location (CQE) - 0=host, 1=device
  bool sqIsDevice = (baseConfig.memoryMode & 0x1) != 0;
  bool cqIsDevice = (baseConfig.memoryMode & 0x2) != 0;

  hipError_t sqeErr = allocateQueue(totalSqeSize, sqIsDevice,
                                    "submission queue", &hostSqeAddr);
  if (sqeErr != hipSuccess) {
    std::cerr << "Failed to allocate submission queue" << std::endl;
    return EXIT_FAILURE;
  }

  hipError_t cqeErr = allocateQueue(totalCqeSize, cqIsDevice,
                                    "completion queue", &hostCqeAddr);
  if (cqeErr != hipSuccess) {
    std::cerr << "Failed to allocate completion queue" << std::endl;
    freeQueue(hostSqeAddr, sqIsDevice, "submission queue");
    return EXIT_FAILURE;
  }

  // Timing buffers are always host-accessible
  // Allocate full timing arrays if timing is enabled (default mode)
  // Allocate lightweight stats structure if less-timing mode is enabled
  XioTimingStats* timingStats = nullptr;
  if (!lessTiming && totalTimingSize > 0) {
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
  } else if (lessTiming) {
    // Allocate lightweight timing stats structure for less-timing mode
    hipError_t hipErr = hipHostMalloc((void**)&timingStats,
                                      sizeof(XioTimingStats));
    if (hipErr != hipSuccess) {
      // HIP not available (e.g., emulate mode), use regular malloc
      void* ptr = malloc(sizeof(XioTimingStats));
      if (ptr == nullptr) {
        std::cerr << "Error: Failed to allocate timing stats buffer"
                  << std::endl;
        return EXIT_FAILURE;
      }
      timingStats = static_cast<XioTimingStats*>(ptr);
    }
    // Initialize timing stats
    timingStats->minDuration = ULLONG_MAX;
    timingStats->maxDuration = 0;
    timingStats->sumDuration = 0;
    timingStats->count = 0;
  }

  // Allocate stop flag for SIGINT handling (GPU-accessible)
  volatile bool* stopRequestedFlag = nullptr;
  hipError_t stopFlagErr = hipHostMalloc((void**)&stopRequestedFlag,
                                         sizeof(bool), hipHostMallocMapped);
  if (stopFlagErr != hipSuccess) {
    // Fallback to regular malloc if HIP not available (emulate mode)
    stopRequestedFlag = static_cast<volatile bool*>(malloc(sizeof(bool)));
    if (stopRequestedFlag == nullptr) {
      std::cerr << "Error: Failed to allocate stop flag" << std::endl;
      // Cleanup and exit
      if (!lessTiming && hostStartTime != nullptr) {
        hipError_t hipErrFree1 = hipHostFree(hostStartTime);
        if (hipErrFree1 != hipSuccess) {
          free(hostStartTime);
        }
      }
      if (!lessTiming && hostEndTime != nullptr) {
        hipError_t hipErrFree2 = hipHostFree(hostEndTime);
        if (hipErrFree2 != hipSuccess) {
          free(hostEndTime);
        }
      }
      if (lessTiming && timingStats != nullptr) {
        hipError_t hipErrFree3 = hipHostFree(timingStats);
        if (hipErrFree3 != hipSuccess) {
          free(timingStats);
        }
      }
      freeQueue(hostSqeAddr, sqIsDevice, "submission queue");
      freeQueue(hostCqeAddr, cqIsDevice, "completion queue");
      return EXIT_FAILURE;
    }
  }
  *stopRequestedFlag = false;

  // Assign buffers to our config structure
  baseConfig.startTimes = hostStartTime;
  baseConfig.endTimes = hostEndTime;
  baseConfig.timingStats = timingStats;
  baseConfig.submissionQueue = hostSqeAddr;
  baseConfig.completionQueue = hostCqeAddr;
  baseConfig.stopRequested = stopRequestedFlag;

  // Install SIGINT handler for graceful shutdown
  struct sigaction sa;
  sa.sa_handler = sigintHandler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = 0;
  if (sigaction(SIGINT, &sa, nullptr) != 0) {
    std::cerr << "Warning: Failed to install SIGINT handler: "
              << strerror(errno) << std::endl;
  }

  // Store config pointer and endpoint name for signal handler
  g_configForSignalHandler = &baseConfig;
  g_endpointNameForSignalHandler = &selectedEndpoint;

  // Run endpoint test
  hipError_t err = endpoint->run(&baseConfig);
  if (err != hipSuccess) {
    std::cerr << "Endpoint run failed: " << hipGetErrorString(err)
              << " (error code: " << err << ")" << std::endl;
    freeQueue(hostSqeAddr, sqIsDevice, "submission queue");
    freeQueue(hostCqeAddr, cqIsDevice, "completion queue");
    // Free host memory using HIP or regular free (only if allocated)
    if (!lessTiming && hostStartTime != nullptr) {
      hipError_t hipErrFree1 = hipHostFree(hostStartTime);
      if (hipErrFree1 != hipSuccess) {
        free(hostStartTime);
      }
    }
    if (!lessTiming && hostEndTime != nullptr) {
      hipError_t hipErrFree2 = hipHostFree(hostEndTime);
      if (hipErrFree2 != hipSuccess) {
        free(hostEndTime);
      }
    }
    if (lessTiming && timingStats != nullptr) {
      hipError_t hipErrFree3 = hipHostFree(timingStats);
      if (hipErrFree3 != hipSuccess) {
        free(timingStats);
      }
    }
    // Free stop flag on error
    if (stopRequestedFlag != nullptr) {
      hipError_t hipErrFree = hipHostFree(const_cast<bool*>(stopRequestedFlag));
      if (hipErrFree != hipSuccess) {
        free(const_cast<bool*>(stopRequestedFlag));
      }
    }
    // Clear signal handler pointers
    g_configForSignalHandler = nullptr;
    g_endpointNameForSignalHandler = nullptr;
    return EXIT_FAILURE;
  }

  // Check if test was interrupted by SIGINT
  bool wasInterrupted = false;
  if (stopRequestedFlag != nullptr && *stopRequestedFlag) {
    wasInterrupted = true;
    std::cout << "\nTest interrupted by user (SIGINT)" << std::endl;
  }

  // Print raw timing data if verbose and full timing is enabled
  if (baseConfig.verbose && !lessTiming) {
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

  // Handle timing statistics based on mode
  if (lessTiming && timingStats != nullptr) {
    // Less-timing mode: use same printStatistics function as normal mode
    if (timingStats->count > 0) {
      // Convert timing stats to durations vector for printStatistics
      double minDurationNs = static_cast<double>(timingStats->minDuration) *
                             gpuClockPeriodNs;
      double maxDurationNs = static_cast<double>(timingStats->maxDuration) *
                             gpuClockPeriodNs;
      double meanDurationNs = (static_cast<double>(timingStats->sumDuration) /
                               static_cast<double>(timingStats->count)) *
                              gpuClockPeriodNs;

      // Create a synthetic durations vector with min, max, and mean values
      // distributed to approximate the distribution (for stddev calculation)
      std::vector<double> durations;
      if (timingStats->count == 1) {
        durations.push_back(meanDurationNs);
      } else if (timingStats->count == 2) {
        durations.push_back(minDurationNs);
        durations.push_back(maxDurationNs);
      } else {
        // Distribute: 1 min, 1 max, rest mean (gives reasonable stddev)
        durations.push_back(minDurationNs);
        durations.push_back(maxDurationNs);
        for (unsigned long long int i = 2; i < timingStats->count; ++i) {
          durations.push_back(meanDurationNs);
        }
      }

      // Print statistics using same function as normal mode
      // Use actual count from timingStats instead of configured iterations
      // Note: readIterations/writeIterations not available without
      // endpoint-specific headers, so pass 0 to show "Iterations" instead of
      // "Reads/Writes" Note: verifiedReadsCount not available in less-timing
      // mode, use UINT_MAX
      unsigned actualIterations = static_cast<unsigned>(timingStats->count);
      if (showHistogram) {
        printHistogram(durations, actualIterations, baseConfig.numThreads, 0, 0,
                       UINT_MAX);
      } else {
        printStatistics(durations, actualIterations, baseConfig.numThreads, 0,
                        0, UINT_MAX);
      }
    } else {
      std::cout << "Warning: No timing data collected in less-timing mode"
                << std::endl;
    }
  } else if (!lessTiming) {
    // Full timing mode: calculate durations from individual timestamps
    // (skip first iteration per thread, as it tends to be larger)
    std::vector<double> durations;
    unsigned actualIterations = 0;
    for (unsigned t = 0; t < baseConfig.numThreads; ++t) {
      unsigned baseIdx = t * baseConfig.iterations;
      for (unsigned i = 0; i < baseConfig.iterations; ++i) {
        unsigned idx = baseIdx + i;
        if (hostEndTime[idx] > hostStartTime[idx]) {
          actualIterations++; // Count all completed iterations
          if (i > 0) {
            // Skip first iteration per thread for statistics
            double durationNs = (hostEndTime[idx] - hostStartTime[idx]) *
                                gpuClockPeriodNs;
            durations.push_back(durationNs);
          }
        }
      }
    }

    // Print statistics (showHistogram flag is already set from common options)
    // Use actual count of completed iterations instead of configured iterations
    // Note: readIterations/writeIterations not available without
    // endpoint-specific headers, so pass 0 to show "Iterations" instead of
    // "Reads/Writes" Note: verifiedReadsCount not tracked in normal mode, use
    // UINT_MAX
    if (durations.size() > 0) {
      if (showHistogram) {
        printHistogram(durations, actualIterations, baseConfig.numThreads, 0, 0,
                       UINT_MAX);
      } else {
        printStatistics(durations, actualIterations, baseConfig.numThreads, 0,
                        0, UINT_MAX);
      }
    } else {
      std::cout << "Warning: No valid timing data collected" << std::endl;
    }
  }

  // Print completion message
  if (!wasInterrupted) {
    std::cout << "\nTest completed successfully!" << std::endl;
  }

  // Free memory
  freeQueue(hostSqeAddr, sqIsDevice, "submission queue");
  freeQueue(hostCqeAddr, cqIsDevice, "completion queue");
  // Free host memory using HIP or regular free (only if allocated)
  if (!lessTiming && hostStartTime != nullptr) {
    hipError_t hipErrFree1 = hipHostFree(hostStartTime);
    if (hipErrFree1 != hipSuccess) {
      free(hostStartTime);
    }
  }
  if (!lessTiming && hostEndTime != nullptr) {
    hipError_t hipErrFree2 = hipHostFree(hostEndTime);
    if (hipErrFree2 != hipSuccess) {
      free(hostEndTime);
    }
  }
  if (lessTiming && timingStats != nullptr) {
    hipError_t hipErrFree3 = hipHostFree(timingStats);
    if (hipErrFree3 != hipSuccess) {
      free(timingStats);
    }
  }
  // Free stop flag
  if (stopRequestedFlag != nullptr) {
    hipError_t hipErrFree = hipHostFree(const_cast<bool*>(stopRequestedFlag));
    if (hipErrFree != hipSuccess) {
      free(const_cast<bool*>(stopRequestedFlag));
    }
  }

  // Clear signal handler pointers
  g_configForSignalHandler = nullptr;
  g_endpointNameForSignalHandler = nullptr;

  return EXIT_SUCCESS;
}
