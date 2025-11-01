/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <time.h>

#include <chrono>
#include <cstring>
#include <iomanip>
#include <string>
#include <thread>
#include <vector>

#include <hip/hip_runtime.h>

#include <CLI/CLI.hpp>

#include "axiio.h"

// Type aliases for queue entries
typedef axiioEndPoint::sqeType sqeType;
typedef axiioEndPoint::cqeType cqeType;

typedef struct {
  unsigned nIterations;
  bool printDeviceInfo;
  bool genHistogram;
  bool beVerbose;
  std::string endpoint;
  std::string memoryType;
  unsigned submitQueueLen;
  unsigned completeQueueLen;
} cmdLineArgs;

typedef struct {
  unsigned long long int* startTime;
  unsigned long long int* endTime;
} testStats;

typedef struct {
  cmdLineArgs args;
  testStats stats;
} testConfig;

// Kernel wrappers that use static dispatch (no object dereferencing needed)
__global__ void driveEndpointKernel(EndpointType endpointType,
                                    unsigned sqeIterations, sqeType* sqeAddr,
                                    cqeType* cqeAddr,
                                    unsigned long long int* sqDoorBell,
                                    unsigned long long int* startTime,
                                    unsigned long long int* endTime) {
  // Write heartbeat immediately to signal kernel started
  if (sqDoorBell) {
    *sqDoorBell = 0xDEADBEEF; // Heartbeat value
    __threadfence_system();
  }

  axiioEndPoint::driveEndpointDispatch(endpointType, sqeIterations, sqeAddr,
                                       cqeAddr, startTime, endTime);
  // Write to doorbell to signal completion
  if (sqDoorBell) {
    *sqDoorBell = sqeIterations;
    __threadfence_system();
  }
}

static void driveFunction(EndpointType endpointType, hipStream_t stream,
                          unsigned sqeIterations, sqeType* sqeAddr,
                          cqeType* cqeAddr, unsigned long long int* sqDoorBell,
                          unsigned long long int* startTime,
                          unsigned long long int* endTime) {
  driveEndpointKernel<<<1, 1, 0, stream>>>(endpointType, sqeIterations, sqeAddr,
                                           cqeAddr, sqDoorBell, startTime,
                                           endTime);
}

static void emulateFunction(EndpointType endpointType, hipStream_t stream,
                            unsigned sqeIterations, sqeType* sqeAddr,
                            cqeType* cqeAddr,
                            volatile unsigned long long int* sqDoorBell) {
  // Call static dispatch directly from CPU thread
  axiioEndPoint::emulateEndpointDispatch(endpointType, sqeIterations, sqeAddr,
                                         cqeAddr);
  // Poll doorbell to wait for drive completion
  if (sqDoorBell) {
    while (*sqDoorBell != sqeIterations) {
      // Busy wait for doorbell signal
    }
  }
}

static int run(testConfig* config, EndpointType endpointType) {
  sqeType* sqQueue;
  cqeType* cqQueue;
  unsigned long long int* sqDoorBell;
  unsigned long long int* d_startTime;
  unsigned long long int* d_endTime;
  // Use mapped + coherent memory for CPU-GPU visibility in polling loops
  unsigned int flags = hipHostMallocMapped | hipHostMallocCoherent;

  // Convert memory type to lowercase for comparison
  std::string memType = config->args.memoryType;
  std::transform(memType.begin(), memType.end(), memType.begin(),
                 [](unsigned char c) {
                   return std::tolower(c);
                 });

  bool useDeviceMemory = (memType == "device");

  // NOTE: We pass endpointType by value, not the object pointer
  // This avoids GPU trying to dereference CPU stack memory
  hipStream_t stream1, stream2;
  HIP_CHECK(hipStreamCreate(&stream1));
  HIP_CHECK(hipStreamCreate(&stream2));

  // Allocate queue memory based on user preference
  size_t sqSize = config->args.submitQueueLen * sizeof(sqeType);
  size_t cqSize = config->args.completeQueueLen * sizeof(cqeType);

  if (useDeviceMemory) {
    HIP_CHECK(hipMalloc(&sqQueue, sqSize));
    HIP_CHECK(hipMalloc(&cqQueue, cqSize));
    HIP_CHECK(hipMalloc(&sqDoorBell, sizeof(unsigned long long int)));
  } else {
    HIP_CHECK(hipHostMalloc(&sqQueue, sqSize, flags));
    HIP_CHECK(hipHostMalloc(&cqQueue, cqSize, flags));
    HIP_CHECK(
      hipHostMalloc(&sqDoorBell, sizeof(unsigned long long int), flags));
  }

  // Initialize doorbell to 0
  if (useDeviceMemory) {
    HIP_CHECK(hipMemset(sqDoorBell, 0, sizeof(unsigned long long int)));
  } else {
    *sqDoorBell = 0;
  }

  // Initialize queues to safe initial values to avoid polling uninitialized
  // memory Use values that won't match the initial poll states in emulate/drive
  // functions
  sqeType sqeInit = {};
  sqeInit.magicID = 0x00; // Invalid magic ID (not TEST_EP_MAGIC_ID)
  sqeInit.entryId = 0;
  sqeInit.timeStamp = 0;
  sqeInit.dataPayload = 0;

  cqeType cqeInit = {};
  cqeInit.magicID = 0x00; // Invalid magic ID (not TEST_EP_MAGIC_ID)
  cqeInit.entryId = 0;
  cqeInit.dataPayload = 0;

  if (useDeviceMemory) {
    HIP_CHECK(
      hipMemcpy(sqQueue, &sqeInit, sizeof(sqeType), hipMemcpyHostToDevice));
    HIP_CHECK(
      hipMemcpy(cqQueue, &cqeInit, sizeof(cqeType), hipMemcpyHostToDevice));
  } else {
    memcpy(sqQueue, &sqeInit, sizeof(sqeType));
    memcpy(cqQueue, &cqeInit, sizeof(cqeType));
  }

  // allocate device timers
  HIP_CHECK(hipMalloc(&d_startTime, config->args.nIterations *
                                      sizeof(unsigned long long int)));
  HIP_CHECK(hipMalloc(&d_endTime, config->args.nIterations *
                                    sizeof(unsigned long long int)));

  if (config->args.beVerbose) {
    std::cout << "Starting drive and emulate threads..." << std::endl;
  }

  std::thread driveThread(driveFunction, endpointType, stream1,
                          config->args.nIterations, sqQueue, cqQueue,
                          sqDoorBell, d_startTime, d_endTime);
  std::thread emulateThread(emulateFunction, endpointType, stream2,
                            config->args.nIterations, sqQueue, cqQueue,
                            sqDoorBell);

  if (config->args.beVerbose) {
    std::cout << "Threads started, waiting for completion..." << std::endl;
  }

  // Wait a moment and check if kernel started
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  if (config->args.beVerbose) {
    std::cout << "Doorbell value after 100ms: 0x" << std::hex << *sqDoorBell
              << std::dec << std::endl;
  }

  driveThread.join();

  if (config->args.beVerbose) {
    std::cout << "Drive thread completed" << std::endl;
  }

  emulateThread.join();

  if (config->args.beVerbose) {
    std::cout << "Emulate thread completed" << std::endl;
  }

  HIP_CHECK(hipDeviceSynchronize());

  HIP_CHECK(hipMemcpy(config->stats.startTime, d_startTime,
                      config->args.nIterations * sizeof(unsigned long long int),
                      hipMemcpyDeviceToHost));
  HIP_CHECK(hipMemcpy(config->stats.endTime, d_endTime,
                      config->args.nIterations * sizeof(unsigned long long int),
                      hipMemcpyDeviceToHost));

  HIP_CHECK(hipFree(d_startTime));
  HIP_CHECK(hipFree(d_endTime));

  // Free queue memory based on allocation type
  if (useDeviceMemory) {
    HIP_CHECK(hipFree(sqQueue));
    HIP_CHECK(hipFree(cqQueue));
    HIP_CHECK(hipFree(sqDoorBell));
  } else {
    HIP_CHECK(hipHostFree(sqQueue));
    HIP_CHECK(hipHostFree(cqQueue));
    HIP_CHECK(hipHostFree(sqDoorBell));
  }

  return 0;
}

int main(int argc, char** argv) {
  CLI::App app{"axiio-tester: A test harness for rocm-axiio."};
  argv = app.ensure_utf8(argv);

  testConfig config = {};
  config.args.printDeviceInfo = false;
  config.args.genHistogram = false;
  config.args.beVerbose = false;

  app
    .add_option("-n, --iterations", config.args.nIterations,
                "Number of iterations to run the test.")
    ->default_val(128)
    ->check(CLI::PositiveNumber);

  app
    .add_flag("-i, --info", config.args.printDeviceInfo,
              "Print information about GPUs in the system.")
    ->default_val(false);

  app
    .add_flag("--histogram", config.args.genHistogram,
              "Generate histogram of iteration runtimes.")
    ->default_val(false);

  app
    .add_flag("-v, --verbose", config.args.beVerbose,
              "Print detailed per-iteration timing results.")
    ->default_val(false);

  auto endpoint_opt =
    app
      .add_option("-e, --endpoint", config.args.endpoint,
                  "Select endpoint (test-ep, nvme-ep) or use -e alone to list.")
      ->expected(0, 1);

  app
    .add_option("-m, --memory", config.args.memoryType,
                "Memory allocation type: 'host' or 'device'.")
    ->default_val("host")
    ->check([](const std::string& val) {
      std::string lower = val;
      std::transform(lower.begin(), lower.end(), lower.begin(),
                     [](unsigned char c) {
                       return std::tolower(c);
                     });
      return (lower == "host" || lower == "device")
               ? std::string()
               : std::string("Memory type must be 'host' or 'device'");
    });

  app
    .add_option("--submit-queue-len", config.args.submitQueueLen,
                "Length of the submission queue (number of entries).")
    ->default_val(1024)
    ->check(CLI::PositiveNumber);

  app
    .add_option("--complete-queue-len", config.args.completeQueueLen,
                "Length of the completion queue (number of entries).")
    ->default_val(512)
    ->check(CLI::PositiveNumber);

  CLI11_PARSE(app, argc, argv);

  // If -e was specified without argument, list endpoints
  if (endpoint_opt->count() > 0 && config.args.endpoint.empty()) {
    listAvailableEndpoints();
    return EXIT_SUCCESS;
  }

  // If no endpoint specified at all, use default
  if (config.args.endpoint.empty()) {
    config.args.endpoint = "test-ep";
  }

  // List available endpoints if "list" is specified
  if (config.args.endpoint == "list") {
    listAvailableEndpoints();
    return EXIT_SUCCESS;
  }

  // Validate and select endpoint
  if (!isValidEndpoint(config.args.endpoint)) {
    std::cerr << "Error: Invalid endpoint '" << config.args.endpoint << "'"
              << std::endl;
    std::cerr << "Valid endpoints: test-ep, nvme-ep" << std::endl;
    std::cerr << "Use '-e' or '--endpoint list' to see all." << std::endl;
    return EXIT_FAILURE;
  }

  // Display test configuration
  std::cout << "Using endpoint: " << config.args.endpoint << std::endl;

  // Display memory allocation type
  std::string memTypeDisplay = config.args.memoryType;
  std::transform(memTypeDisplay.begin(), memTypeDisplay.end(),
                 memTypeDisplay.begin(), [](unsigned char c) {
                   return std::tolower(c);
                 });
  std::cout << "Memory allocation: " << memTypeDisplay << std::endl;
  std::cout << "Submit queue length: " << config.args.submitQueueLen
            << std::endl;
  std::cout << "Complete queue length: " << config.args.completeQueueLen
            << std::endl;

  /*
   * Get information on all the GPUs in the system and the specific GPU(s)
   * chosen to run tests on.
   */

  if (config.args.printDeviceInfo) {
    axxioPrintDeviceInfo();
  }

  // Allocate host memory for timing arrays
  config.stats.startTime = (unsigned long long int*)malloc(
    config.args.nIterations * sizeof(unsigned long long int));
  config.stats.endTime = (unsigned long long int*)malloc(
    config.args.nIterations * sizeof(unsigned long long int));

  // Get endpoint type from string
  EndpointType endpointType = getEndpointType(config.args.endpoint);

  run(&config, endpointType);

  // Get wall clock frequency for nanosecond calculation
  int wallClkRate;
  HIP_CHECK(
    hipDeviceGetAttribute(&wallClkRate, hipDeviceAttributeWallClockRate, 0));

  // Collect duration values for histogram and statistics
  std::vector<double> durations;
  durations.reserve(config.args.nIterations);

  // Calculate width needed for iteration number
  int iterWidth = std::to_string(config.args.nIterations - 1).length();

  // Print detailed results if verbose
  if (config.args.beVerbose) {
    std::cout << "Results:" << std::endl;
  }

  for (unsigned i = 0; i < config.args.nIterations; i++) {
    unsigned long long int duration = config.stats.endTime[i] -
                                      config.stats.startTime[i];
    double duration_ns = (double)duration * 1000000.0 / (double)wallClkRate;
    durations.push_back(duration_ns);

    if (config.args.beVerbose) {
      std::cout << std::dec << "  Iter: " << std::setw(iterWidth) << i
                << ": Start Tick: " << std::setw(13)
                << config.stats.startTime[i] << ", End Tick: " << std::setw(13)
                << config.stats.endTime[i] << ", Duration: " << std::setw(4)
                << duration << ", Runtime: " << std::setw(6) << std::fixed
                << std::setprecision(0) << duration_ns << " ns" << std::endl;
    }
  }

  // Generate histogram and statistics if requested
  if (config.args.genHistogram && config.args.nIterations > 0) {
    axxioPrintHistogram(durations, config.args.nIterations);
  } else if (config.args.nIterations > 0) {
    // Always print statistics even without histogram
    axxioPrintStatistics(durations);
  }

  free(config.stats.startTime);
  free(config.stats.endTime);

  return EXIT_SUCCESS;
}
