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

// For physical memory mapping
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "axiio.h"

// For NVMe-specific buffer testing
#include "nvme-ep.h"

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
  // Real NVMe hardware support
  bool useRealHardware;
  uint64_t nvmeDoorbellAddr;
  uint64_t nvmeSqBaseAddr;
  uint64_t nvmeCqBaseAddr;
  size_t nvmeSqSize;
  size_t nvmeCqSize;
  // Data buffer support for NVMe I/O testing
  bool useDataBuffers;
  size_t dataBufferSize;
  unsigned nvmeBlockSize;
  std::string testPattern;
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

// Specialized kernel for NVMe endpoint with data buffers
// Calls nvme_ep_driveEndpointWithBuffers directly
__global__ void driveNVMeEndpointWithBuffersKernel(
  unsigned sqeIterations, sqeType* sqeAddr, cqeType* cqeAddr,
  unsigned long long int* sqDoorBell, unsigned long long int* startTime,
  unsigned long long int* endTime, uint8_t* readBuffer, uint8_t* writeBuffer,
  size_t bufferSize, uint32_t blockSize, enum nvme_test_pattern pattern) {
  // Write heartbeat immediately to signal kernel started
  if (sqDoorBell) {
    *sqDoorBell = 0xDEADBEEF; // Heartbeat value
    __threadfence_system();
  }

  // Call NVMe-specific function with buffers
  nvme_ep_driveEndpointWithBuffers(sqeIterations, sqeAddr, cqeAddr, startTime,
                                   endTime, readBuffer, writeBuffer, bufferSize,
                                   blockSize, pattern);

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

static void driveNVMeWithBuffersFunction(
  hipStream_t stream, unsigned sqeIterations, sqeType* sqeAddr,
  cqeType* cqeAddr, unsigned long long int* sqDoorBell,
  unsigned long long int* startTime, unsigned long long int* endTime,
  uint8_t* readBuffer, uint8_t* writeBuffer, size_t bufferSize,
  uint32_t blockSize, enum nvme_test_pattern pattern) {
  driveNVMeEndpointWithBuffersKernel<<<1, 1, 0, stream>>>(
    sqeIterations, sqeAddr, cqeAddr, sqDoorBell, startTime, endTime, readBuffer,
    writeBuffer, bufferSize, blockSize, pattern);
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

// Helper function to map physical memory to virtual address space
static void* mapPhysicalMemory(uint64_t physAddr, size_t size, int& fd) {
  // Open /dev/mem for physical memory access (requires root/CAP_SYS_RAWIO)
  fd = open("/dev/mem", O_RDWR | O_SYNC);
  if (fd == -1) {
    std::cerr << "Error: Failed to open /dev/mem. "
              << "Root privileges or CAP_SYS_RAWIO capability required."
              << std::endl;
    std::cerr << "Try: sudo ./bin/axiio-tester ..." << std::endl;
    return nullptr;
  }

  // Calculate page-aligned base address and offset within page
  size_t pageSize = sysconf(_SC_PAGE_SIZE);
  uint64_t pageBase = physAddr & ~(pageSize - 1);
  size_t offset = physAddr - pageBase;

  // Map extra space to cover offset
  size_t mapSize = offset + size;

  // Map physical memory to virtual address space
  void* virtBase = mmap(nullptr, mapSize, PROT_READ | PROT_WRITE, MAP_SHARED,
                        fd, pageBase);

  if (virtBase == MAP_FAILED) {
    std::cerr << "Error: Failed to mmap physical address 0x" << std::hex
              << physAddr << std::dec << std::endl;
    close(fd);
    return nullptr;
  }

  // Return pointer adjusted for offset
  return static_cast<uint8_t*>(virtBase) + offset;
}

// Helper function to unmap physical memory
static void unmapPhysicalMemory(void* virtAddr, uint64_t physAddr, size_t size,
                                int fd) {
  if (virtAddr && fd != -1) {
    // Calculate page-aligned base address and offset
    size_t pageSize = sysconf(_SC_PAGE_SIZE);
    uint64_t pageBase = physAddr & ~(pageSize - 1);
    size_t offset = physAddr - pageBase;
    size_t mapSize = offset + size;

    // Get the original mapped base address
    void* virtBase = static_cast<uint8_t*>(virtAddr) - offset;

    munmap(virtBase, mapSize);
    close(fd);
  }
}

static int run(testConfig* config, EndpointType endpointType) {
  sqeType* sqQueue;
  cqeType* cqQueue;
  unsigned long long int* sqDoorBell;
  unsigned long long int* d_startTime;
  unsigned long long int* d_endTime;

  // File descriptors for /dev/mem mapping (used in real hardware mode)
  int sqFd = -1, cqFd = -1, dbFd = -1;
  bool mappedPhysical = false;

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

  // Allocate queue memory based on mode
  size_t sqSize, cqSize;

  if (config->args.useRealHardware) {
    // Real NVMe hardware mode - map physical addresses
    std::cout << "Real NVMe hardware mode enabled" << std::endl;
    std::cout << "  Doorbell address: 0x" << std::hex
              << config->args.nvmeDoorbellAddr << std::dec << std::endl;
    std::cout << "  SQ base address: 0x" << std::hex
              << config->args.nvmeSqBaseAddr << std::dec
              << " (size: " << config->args.nvmeSqSize << " bytes)"
              << std::endl;
    std::cout << "  CQ base address: 0x" << std::hex
              << config->args.nvmeCqBaseAddr << std::dec
              << " (size: " << config->args.nvmeCqSize << " bytes)"
              << std::endl;

    sqSize = config->args.nvmeSqSize;
    cqSize = config->args.nvmeCqSize;

    // Map physical memory regions
    sqQueue = static_cast<sqeType*>(
      mapPhysicalMemory(config->args.nvmeSqBaseAddr, sqSize, sqFd));
    cqQueue = static_cast<cqeType*>(
      mapPhysicalMemory(config->args.nvmeCqBaseAddr, cqSize, cqFd));
    sqDoorBell = static_cast<unsigned long long int*>(
      mapPhysicalMemory(config->args.nvmeDoorbellAddr,
                        sizeof(unsigned long long int), dbFd));

    if (!sqQueue || !cqQueue || !sqDoorBell) {
      std::cerr << "Error: Failed to map NVMe hardware addresses" << std::endl;
      if (sqQueue)
        unmapPhysicalMemory(sqQueue, config->args.nvmeSqBaseAddr, sqSize, sqFd);
      if (cqQueue)
        unmapPhysicalMemory(cqQueue, config->args.nvmeCqBaseAddr, cqSize, cqFd);
      if (sqDoorBell)
        unmapPhysicalMemory(sqDoorBell, config->args.nvmeDoorbellAddr,
                            sizeof(unsigned long long int), dbFd);
      return EXIT_FAILURE;
    }

    mappedPhysical = true;

  } else {
    // Emulated mode - allocate memory normally
    sqSize = config->args.submitQueueLen * sizeof(sqeType);
    cqSize = config->args.completeQueueLen * sizeof(cqeType);

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
  }

  // Initialize doorbell to 0 (skip for real hardware - may already be in use)
  if (!mappedPhysical) {
    if (useDeviceMemory) {
      HIP_CHECK(hipMemset(sqDoorBell, 0, sizeof(unsigned long long int)));
    } else {
      *sqDoorBell = 0;
    }
  }

  // Initialize queues to safe initial values to avoid polling uninitialized
  // memory Use values that won't match the initial poll states in emulate/drive
  // functions Skip initialization for real hardware mode (queues may already
  // contain data)
  if (!mappedPhysical) {
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
  }

  // allocate device timers
  HIP_CHECK(hipMalloc(&d_startTime, config->args.nIterations *
                                      sizeof(unsigned long long int)));
  HIP_CHECK(hipMalloc(&d_endTime, config->args.nIterations *
                                    sizeof(unsigned long long int)));

  // Allocate data buffers if requested
  uint8_t* readBuffer = nullptr;
  uint8_t* writeBuffer = nullptr;
  bool usingDataBuffers = false;

  if (config->args.useDataBuffers && endpointType == EndpointType::NVME_EP) {
    usingDataBuffers = true;
    std::cout << "Allocating data buffers for NVMe I/O testing..." << std::endl;
    std::cout << "  Buffer size: " << config->args.dataBufferSize << " bytes"
              << std::endl;
    std::cout << "  Block size: " << config->args.nvmeBlockSize << " bytes"
              << std::endl;
    std::cout << "  Test pattern: " << config->args.testPattern << std::endl;

    // Allocate buffers using hipHostMalloc for CPU-GPU visibility
    HIP_CHECK(
      hipHostMalloc(&readBuffer, config->args.dataBufferSize, flags));
    HIP_CHECK(
      hipHostMalloc(&writeBuffer, config->args.dataBufferSize, flags));

    // Initialize write buffer with pattern on CPU
    // (Pattern will be regenerated on GPU during test)
    memset(writeBuffer, 0, config->args.dataBufferSize);
    memset(readBuffer, 0, config->args.dataBufferSize);
  }

  if (config->args.beVerbose) {
    std::cout << "Starting drive and emulate threads..." << std::endl;
  }

  // Choose appropriate drive function based on data buffer usage
  std::thread driveThread;
  std::thread emulateThread;

  if (usingDataBuffers) {
    // Parse pattern string to enum
    enum nvme_test_pattern pattern = NVME_PATTERN_SEQUENTIAL;
    if (config->args.testPattern == "zeros") {
      pattern = NVME_PATTERN_ZEROS;
    } else if (config->args.testPattern == "ones") {
      pattern = NVME_PATTERN_ONES;
    } else if (config->args.testPattern == "random") {
      pattern = NVME_PATTERN_RANDOM;
    } else if (config->args.testPattern == "block_id") {
      pattern = NVME_PATTERN_BLOCK_ID;
    }

    // Use NVMe-specific kernel with buffers
    driveThread = std::thread(
      driveNVMeWithBuffersFunction, stream1, config->args.nIterations, sqQueue,
      cqQueue, sqDoorBell, d_startTime, d_endTime, readBuffer, writeBuffer,
      config->args.dataBufferSize, config->args.nvmeBlockSize, pattern);
  } else {
    // Use generic dispatcher
    driveThread =
      std::thread(driveFunction, endpointType, stream1, config->args.nIterations,
                  sqQueue, cqQueue, sqDoorBell, d_startTime, d_endTime);
  }

  emulateThread =
    std::thread(emulateFunction, endpointType, stream2, config->args.nIterations,
                sqQueue, cqQueue, sqDoorBell);

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

  // Free data buffers if allocated
  if (usingDataBuffers) {
    if (readBuffer) {
      HIP_CHECK(hipHostFree(readBuffer));
    }
    if (writeBuffer) {
      HIP_CHECK(hipHostFree(writeBuffer));
    }
  }

  // Free queue memory based on allocation type
  if (mappedPhysical) {
    // Unmap physical memory regions
    unmapPhysicalMemory(sqQueue, config->args.nvmeSqBaseAddr, sqSize, sqFd);
    unmapPhysicalMemory(cqQueue, config->args.nvmeCqBaseAddr, cqSize, cqFd);
    unmapPhysicalMemory(sqDoorBell, config->args.nvmeDoorbellAddr,
                        sizeof(unsigned long long int), dbFd);
  } else if (useDeviceMemory) {
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

  // Real NVMe hardware support options
  app
    .add_flag("--real-hardware", config.args.useRealHardware,
              "Use real NVMe hardware instead of emulated endpoint.")
    ->default_val(false);

  app
    .add_option("--nvme-doorbell", config.args.nvmeDoorbellAddr,
                "Physical address of NVMe doorbell register (hex).")
    ->default_val(0ULL);

  app
    .add_option("--nvme-sq-base", config.args.nvmeSqBaseAddr,
                "Physical base address of NVMe submission queue (hex).")
    ->default_val(0ULL);

  app
    .add_option("--nvme-cq-base", config.args.nvmeCqBaseAddr,
                "Physical base address of NVMe completion queue (hex).")
    ->default_val(0ULL);

  app
    .add_option("--nvme-sq-size", config.args.nvmeSqSize,
                "Size of NVMe submission queue in bytes.")
    ->default_val(0ULL)
    ->check(CLI::NonNegativeNumber);

  app
    .add_option("--nvme-cq-size", config.args.nvmeCqSize,
                "Size of NVMe completion queue in bytes.")
    ->default_val(0ULL)
    ->check(CLI::NonNegativeNumber);

  // Data buffer options for NVMe I/O testing
  app
    .add_flag("--use-data-buffers", config.args.useDataBuffers,
              "Enable data buffer allocation for NVMe I/O testing.")
    ->default_val(false);

  app
    .add_option("--data-buffer-size", config.args.dataBufferSize,
                "Size of data buffers for NVMe I/O testing (bytes).")
    ->default_val(1024 * 1024)  // 1 MB default
    ->check(CLI::PositiveNumber);

  app
    .add_option("--nvme-block-size", config.args.nvmeBlockSize,
                "NVMe block size in bytes (typically 512 or 4096).")
    ->default_val(512)
    ->check(CLI::PositiveNumber);

  app
    .add_option("--test-pattern", config.args.testPattern,
                "Data test pattern: sequential, zeros, ones, random, block_id")
    ->default_val("sequential")
    ->check([](const std::string& val) {
      return (val == "sequential" || val == "zeros" || val == "ones" ||
              val == "random" || val == "block_id")
               ? std::string()
               : std::string(
                   "Pattern must be: sequential, zeros, ones, random, or block_id");
    });

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

  // Validate real hardware parameters
  if (config.args.useRealHardware) {
    if (config.args.nvmeDoorbellAddr == 0 || config.args.nvmeSqBaseAddr == 0 ||
        config.args.nvmeCqBaseAddr == 0 || config.args.nvmeSqSize == 0 ||
        config.args.nvmeCqSize == 0) {
      std::cerr
        << "Error: --real-hardware requires all of the following options:"
        << std::endl;
      std::cerr << "  --nvme-doorbell <addr>" << std::endl;
      std::cerr << "  --nvme-sq-base <addr>" << std::endl;
      std::cerr << "  --nvme-cq-base <addr>" << std::endl;
      std::cerr << "  --nvme-sq-size <size>" << std::endl;
      std::cerr << "  --nvme-cq-size <size>" << std::endl;
      return EXIT_FAILURE;
    }

    // Force nvme-ep endpoint for real hardware mode
    if (config.args.endpoint != "nvme-ep") {
      std::cout << "Note: --real-hardware mode requires nvme-ep endpoint. "
                << "Switching to nvme-ep." << std::endl;
      config.args.endpoint = "nvme-ep";
    }
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
