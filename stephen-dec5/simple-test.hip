/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <iostream>
#include <iomanip>
#include <thread>
#include <chrono>
#include <cstring>
#include <cstdint>
#include <ctime>
#include <cstdlib>
#include <vector>
#include <algorithm>
#include <cmath>
#include <unistd.h>
#include <getopt.h>
#include <hsa/hsa.h>
#include <random>
#include "simple-test.h"

#define HIP_CHECK(call)                                                       \
  do {                                                                        \
    hipError_t err = call;                                                    \
    if (err != hipSuccess) {                                                  \
      std::cerr << "HIP error at " << __FILE__ << ":" << __LINE__            \
                << ": " << hipGetErrorString(err) << std::endl;               \
      exit(EXIT_FAILURE);                                                     \
    }                                                                         \
  } while (0)

// Get CPU wall clock time in nanoseconds
static inline uint64_t getCpuTime() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

// Format time value with appropriate unit (ns, us, ms)
static inline void formatTime(double timeNs, double& value, 
                               const char*& unit) {
  if (timeNs >= 1000000.0) {
    // Use milliseconds
    value = timeNs / 1000000.0;
    unit = " ms";
  } else if (timeNs >= 1000.0) {
    // Use microseconds
    value = timeNs / 1000.0;
    unit = " us";
  } else {
    // Use nanoseconds
    value = timeNs;
    unit = " ns";
  }
}

// Allocate device memory using HSA runtime directly
// This may give us more control over memory properties
static hsa_status_t allocateHsaDeviceMemory(size_t size, void** ptr,
                                            const char* direction) {
  hsa_status_t status;
  
  // Initialize HSA runtime (safe to call multiple times)
  status = hsa_init();
  if (status != HSA_STATUS_SUCCESS) {
    // If already initialized, that's fine, continue
    if (status != 0x1001) { // HSA_STATUS_ERROR_ALREADY_INITIALIZED value
      std::cerr << "Error: hsa_init failed: " << status << std::endl;
      return status;
    }
  }
  
  // Iterate through agents to find GPU
  hsa_region_t device_region = {0};
  
  hsa_iterate_agents([](hsa_agent_t agent, void* data) -> hsa_status_t {
    hsa_device_type_t device_type;
    hsa_status_t status = hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, 
                                              &device_type);
    if (status != HSA_STATUS_SUCCESS) {
      return status;
    }
    
    if (device_type == HSA_DEVICE_TYPE_GPU) {
      // Found GPU agent, iterate its regions
      // Look for fine-grained global region first (better for CPU-GPU coherence)
      // Then fall back to coarse-grained if fine-grained not available
      struct RegionData {
        hsa_region_t fine;
        hsa_region_t coarse;
      };
      RegionData regions = {{0}, {0}};
      
      hsa_agent_iterate_regions(agent, [](hsa_region_t region, void* data) -> hsa_status_t {
        hsa_region_segment_t segment;
        hsa_status_t status = hsa_region_get_info(region, 
                                                   HSA_REGION_INFO_SEGMENT,
                                                   &segment);
        if (status != HSA_STATUS_SUCCESS) {
          return status;
        }
        
        // Look for global (device) memory region
        if (segment == HSA_REGION_SEGMENT_GLOBAL) {
          uint32_t alloc_allowed;
          status = hsa_region_get_info(region, HSA_REGION_INFO_RUNTIME_ALLOC_ALLOWED,
                                       &alloc_allowed);
          if (status == HSA_STATUS_SUCCESS && alloc_allowed) {
            // Check if fine-grained or coarse-grained
            uint32_t global_flags;
            status = hsa_region_get_info(region, HSA_REGION_INFO_GLOBAL_FLAGS,
                                         &global_flags);
            if (status == HSA_STATUS_SUCCESS) {
              RegionData* regions_ptr = (RegionData*)data;
              
              if (global_flags & HSA_REGION_GLOBAL_FLAG_FINE_GRAINED) {
                regions_ptr->fine = region;
              } else if (global_flags & HSA_REGION_GLOBAL_FLAG_COARSE_GRAINED) {
                regions_ptr->coarse = region;
              }
            }
          }
        }
        return HSA_STATUS_SUCCESS;
      }, &regions);
      
      // Prefer fine-grained, fall back to coarse-grained
      hsa_region_t* best_region = (hsa_region_t*)data;
      if (regions.fine.handle != 0) {
        *best_region = regions.fine;
      } else if (regions.coarse.handle != 0) {
        *best_region = regions.coarse;
      }
      
      return HSA_STATUS_INFO_BREAK; // Stop agent iteration
    }
    return HSA_STATUS_SUCCESS;
  }, &device_region);
  
  if (device_region.handle == 0) {
    std::cerr << "Error: Could not find allocatable device memory region" 
              << std::endl;
    return HSA_STATUS_ERROR_INVALID_REGION;
  }
  
  // Check what type of region we found
  uint32_t global_flags = 0;
  hsa_region_get_info(device_region, HSA_REGION_INFO_GLOBAL_FLAGS, &global_flags);
  if (global_flags & HSA_REGION_GLOBAL_FLAG_FINE_GRAINED) {
    std::cerr << "  Info: (" << direction << "):  Using HSA fine-grained "
              << "global memory region" << std::endl;
  } else if (global_flags & HSA_REGION_GLOBAL_FLAG_COARSE_GRAINED) {
    std::cerr << "  Info: (" << direction << "):  Using HSA coarse-grained "
              << "global memory region" << std::endl;
  }
  
  // Allocate memory from device region
  status = hsa_memory_allocate(device_region, size, ptr);
  return status;
}


// CPU thread function that polls for GPU messages and responds
// Each CPU thread handles one GPU thread's buffer
void cpuThread(GpuToCpuMsg* gpuToCpuHost, CpuToGpuMsg* cpuToGpuHost,
               unsigned iterations, unsigned threadIdx) {
  volatile GpuToCpuMsg* volatileGpuToCpu = gpuToCpuHost;
  volatile CpuToGpuMsg* volatileCpuToGpu = cpuToGpuHost;
  GpuToCpuMsg lastMsg = {};
  lastMsg.iteration = 0xFFFFFFFF; // Initialize to invalid value
  uint64_t lastGpuTimeSeen = 0;

  for (unsigned i = 0; i < iterations; ++i) {
    // Poll for new GPU message
    GpuToCpuMsg currentMsg;
    
    while (true) {
      currentMsg.magic = volatileGpuToCpu->magic;
      currentMsg.iteration = volatileGpuToCpu->iteration;
      currentMsg.gpuTime = volatileGpuToCpu->gpuTime;
      for (int j = 0; j < 5; ++j) {
        currentMsg.data[j] = volatileGpuToCpu->data[j];
      }
      
      // Extract thread index and iteration from encoded iteration field
      unsigned msgThreadIdx = (currentMsg.iteration >> 32) & 0xFFFFFFFF;
      unsigned iter = currentMsg.iteration & 0xFFFFFFFF;
      
      // Check if this is a new message for this thread and iteration
      if (currentMsg.magic == GPU_TO_CPU_MAGIC &&
          msgThreadIdx == threadIdx &&
          iter == i &&
          currentMsg.gpuTime != lastGpuTimeSeen) {
        break;
      }
      // Yield to avoid busy-waiting too aggressively
      std::this_thread::yield();
    }

    // Get CPU wall clock time when message is received
    uint64_t cpuTime = getCpuTime();
    
    // Read delay value from data[0] (set by GPU)
    uint64_t delayNs = currentMsg.data[0];
    
    // Implement delay before responding
    if (delayNs > 0) {
      if (delayNs < 1000000) {
        // For delays < 1ms, use busy-wait for accuracy
        uint64_t startTime = getCpuTime();
        while (getCpuTime() - startTime < delayNs) {
          // Busy-wait loop
        }
      } else {
        // For larger delays, use sleep
        std::this_thread::sleep_for(std::chrono::nanoseconds(delayNs));
      }
    }
    
    // Write response to memory
    volatileCpuToGpu->magic = CPU_TO_GPU_MAGIC;
    volatileCpuToGpu->cpuTime = cpuTime;

    lastMsg = currentMsg;
    lastGpuTimeSeen = currentMsg.gpuTime;
  }
}

// GPU kernel that supports multiple threads
// Each thread uses its own buffer and encodes thread index in iteration field
__global__ void gpuKernel(GpuToCpuMsg* gpuToCpu, CpuToGpuMsg* cpuToGpu,
                          unsigned iterations,
                          unsigned long long int* startTimes,
                          unsigned long long int* cpuTimes,
                          unsigned long long gpuClockRateKHz,
                          unsigned numThreads,
                          long long delayNs) {
  // Get thread index (0 to numThreads-1)
  unsigned tid = blockIdx.x * blockDim.x + threadIdx.x;
  
  // Only process threads in range [0, numThreads)
  if (tid >= numThreads) {
    return;
  }
  
  // Each thread uses its own buffer
  GpuToCpuMsg* myGpuToCpu = &gpuToCpu[tid];
  CpuToGpuMsg* myCpuToGpu = &cpuToGpu[tid];
  unsigned long long int* myStartTimes = 
    &startTimes[tid * iterations];
  unsigned long long int* myCpuTimes = 
    &cpuTimes[tid * iterations];
  
  volatile CpuToGpuMsg* volatileCpuToGpu = myCpuToGpu;
  GpuToCpuMsg msg = {};
  CpuToGpuMsg lastResponse = {};
  lastResponse.magic = 0; // Initialize to invalid value
  CpuToGpuMsg currentResponse = {};
  uint64_t lastCpuTime = 0;
  
  // Calculate timeout: 100ms in GPU clock ticks
  unsigned long long timeoutTicks = 100ULL * gpuClockRateKHz;

  for (unsigned i = 0; i < iterations; ++i) {
    // Record start time for this iteration
    unsigned long long pollStartTime = wall_clock64();
    myStartTimes[i] = pollStartTime;

    // Prepare message to CPU
    // Encode thread index in upper 32 bits, iteration in lower 32 bits
    msg.magic = GPU_TO_CPU_MAGIC;
    msg.iteration = ((uint64_t)tid << 32) | i;
    msg.gpuTime = wall_clock64();
    
    // Calculate delay based on delayNs parameter
    // Negative: fixed delay of |delayNs|
    // Positive: random delay between 0 and delayNs
    uint64_t actualDelayNs = 0;
    if (delayNs < 0) {
      // Fixed delay: use absolute value
      actualDelayNs = static_cast<uint64_t>(-delayNs);
    } else if (delayNs > 0) {
      // Random delay: generate value between 0 and delayNs
      // Use thread ID, iteration, and GPU time as seed for pseudo-randomness
      uint64_t seed = tid * 0x9e3779b9ULL + i * 0x6c6229e6ULL + 
                      wall_clock64();
      // Simple LCG-based random number generator
      seed = (seed * 1103515245ULL + 12345ULL) & 0x7FFFFFFFULL;
      actualDelayNs = seed % (static_cast<uint64_t>(delayNs) + 1);
    }
    msg.data[0] = actualDelayNs;
    
    // Fill remaining data payload
    for (int j = 1; j < 5; ++j) {
      msg.data[j] = 0x123456789ABCDEF0ULL + tid + i + j;
    }

    // Write message to memory
    *myGpuToCpu = msg;
    __threadfence_system(); // Ensure write is visible

    // Poll for CPU response with timeout
    bool timeoutReached = false;
    while (true) {
      // Check for timeout: 100ms elapsed
      unsigned long long currentTime = wall_clock64();
      if (currentTime - pollStartTime >= timeoutTicks) {
        timeoutReached = true;
        break;
      }
 
      uint64_t magic = volatileCpuToGpu->magic;
      uint64_t cpuTime = volatileCpuToGpu->cpuTime;
      currentResponse.magic = magic;
      currentResponse.cpuTime = cpuTime;
      // Check if this is a new response
      if (currentResponse.magic == CPU_TO_GPU_MAGIC) {
        if (currentResponse.cpuTime != 0) {
          // Accept if this is a new response (cpuTime changed)
          // Or if this is the first valid response (lastCpuTime was 0)
          if (currentResponse.cpuTime != lastCpuTime || lastCpuTime == 0) {
            break;
          }
        }
      }
    }
    // If timeout reached, record 0 as CPU time to indicate timeout
    if (timeoutReached) {
      myCpuTimes[i] = 0;
      lastCpuTime = 0; // Reset to allow next iteration to accept any response
    } else {
      lastResponse = currentResponse;
      lastCpuTime = currentResponse.cpuTime;
      // Record CPU time from response
      myCpuTimes[i] = currentResponse.cpuTime;
    }
  }
}

int main(int argc, char** argv) {
  unsigned iterations = 10;
  bool verbose = false;
  unsigned memoryMode = 0;
  long long delayNs = 0; // Delay: negative = fixed delay, positive = max random delay
  int opt;

  unsigned numThreads = 1; // Default: single thread
  
  // Long option definitions for getopt_long
  static struct option long_options[] = {
    {"delay", required_argument, 0, 'd'},
    {0, 0, 0, 0}
  };
  
  // Parse command line options
  int option_index = 0;
  while ((opt = getopt_long(argc, argv, "n:vm:t:d:", long_options, 
                            &option_index)) != -1) {
    switch (opt) {
      case 'n':
        iterations = static_cast<unsigned>(atoi(optarg));
        if (iterations == 0) {
          std::cerr << "Error: iterations must be > 0" << std::endl;
          return EXIT_FAILURE;
        }
        break;
      case 'v':
        verbose = true;
        break;
      case 'm':
        memoryMode = static_cast<unsigned>(atoi(optarg));
        if (memoryMode > 3) {
          std::cerr << "Error: memory mode must be 0-3" << std::endl;
          return EXIT_FAILURE;
        }
        break;
      case 't':
        numThreads = static_cast<unsigned>(atoi(optarg));
        if (numThreads == 0 || numThreads > 32) {
          std::cerr << "Error: threads must be 1-32" << std::endl;
          return EXIT_FAILURE;
        }
        break;
      case 'd':
        delayNs = strtoll(optarg, nullptr, 10);
        if (delayNs == 0 && optarg[0] != '0' && optarg[0] != '-') {
          std::cerr << "Error: invalid delay value: " << optarg 
                    << std::endl;
          return EXIT_FAILURE;
        }
        break;
      default:
        std::cerr << "Usage: " << argv[0] 
                  << " [-n iterations] [-v] [-m mode] [-t threads] "
                  << "[--delay ns]" << std::endl;
        std::cerr << "  -n iterations  Number of iterations (default: 10)" 
                  << std::endl;
        std::cerr << "  -v             Verbose: show timing table" 
                  << std::endl;
        std::cerr << "  -m mode        Memory mode (default: 0)" 
                  << std::endl;
        std::cerr << "                  Bit 0 (LSB): GPU write location "
                  << "(0=host, 1=device)" << std::endl;
        std::cerr << "                  Bit 1 (MSB): CPU write location "
                  << "(0=host, 1=device)" << std::endl;
        std::cerr << "  -t threads     Number of GPU threads (default: 1, "
                  << "max: 32)" << std::endl;
        std::cerr << "  --delay ns     Delay in nanoseconds for CPU response "
                  << "(default: 0)" << std::endl;
        std::cerr << "                  Negative: fixed delay of |delay| ns" 
                  << std::endl;
        std::cerr << "                  Positive: random delay 0 to delay ns" 
                  << std::endl;
        return EXIT_FAILURE;
    }
  }

  // Extract memory mode bits
  bool gpuWriteToDevice = (memoryMode & 0x1) != 0;  // LSB
  bool cpuWriteToDevice = (memoryMode & 0x2) != 0; // MSB

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
  double gpuClockPeriodNs = 1000000.0 / static_cast<double>(gpuWallClockRateKHz);

  // Get CPU clock resolution
  struct timespec cpuRes;
  clock_getres(CLOCK_MONOTONIC, &cpuRes);
  double cpuClockResolutionNs = cpuRes.tv_sec * 1000000000.0 + 
                                 cpuRes.tv_nsec;

  std::cout << "Simple GPU-CPU Communication Test" << std::endl;
  std::cout << "  GPU Model: " << deviceProp.name << std::endl;
  std::cout << "  GPU Device ID: " << deviceId << std::endl;
  std::cout << "  GPU Wall Clock Rate: " << gpuWallClockRateKHz << " KHz" 
            << std::endl;
  std::cout << "  GPU Clock Period: " << std::fixed << std::setprecision(3)
            << gpuClockPeriodNs << " ns" << std::endl;
  std::cout << "  CPU Clock: CLOCK_MONOTONIC" << std::endl;
  std::cout << "  CPU Clock Resolution: " << std::fixed 
            << std::setprecision(3) << cpuClockResolutionNs << " ns" 
            << std::endl;
  std::cout << "  Iterations: " << iterations << std::endl;
  std::cout << "  Threads: " << numThreads << std::endl;
  std::cout << "  Memory Mode: " << memoryMode << " (GPU write: " 
            << (gpuWriteToDevice ? "device" : "host") 
            << ", CPU write: " << (cpuWriteToDevice ? "device" : "host") 
            << ")" << std::endl;
  if (delayNs != 0) {
    if (delayNs < 0) {
      std::cout << "  Delay: Fixed " << -delayNs << " ns" << std::endl;
    } else {
      std::cout << "  Delay: Random 0 to " << delayNs << " ns" 
                << std::endl;
    }
  }

  // Allocate memory for communication based on mode
  // All device memory uses HSA fine-grained memory (directly CPU accessible)
  // For multi-threaded mode, allocate arrays of buffers (one per thread)
  GpuToCpuMsg* gpuToCpuHost = nullptr; // Host pointer (CPU uses this)
  GpuToCpuMsg* gpuToCpuDevice = nullptr; // Device pointer (GPU uses this)
  CpuToGpuMsg* cpuToGpuHost = nullptr; // Host pointer (CPU uses this)
  CpuToGpuMsg* cpuToGpuDevice = nullptr; // Device pointer (GPU uses this)
  unsigned long long int* startTimes = nullptr;
  unsigned long long int* cpuTimes = nullptr;
  
  // Multi-threaded mode: arrays of buffers
  GpuToCpuMsg* gpuToCpuHostArray = nullptr;
  GpuToCpuMsg* gpuToCpuDeviceArray = nullptr;
  CpuToGpuMsg* cpuToGpuHostArray = nullptr;
  CpuToGpuMsg* cpuToGpuDeviceArray = nullptr;
  unsigned long long int* startTimesArray = nullptr;
  unsigned long long int* cpuTimesArray = nullptr;

  // Get page size for alignment
  const size_t host_page_size = sysconf(_SC_PAGESIZE);
  
  if (numThreads == 1) {
    // Single-threaded mode: allocate single buffers
    // Allocate GPU->CPU message buffer
    if (gpuWriteToDevice) {
      size_t gpuToCpuSize = ((sizeof(GpuToCpuMsg) + host_page_size - 1) / 
                             host_page_size) * host_page_size;
      
      hsa_status_t hsa_status = allocateHsaDeviceMemory(gpuToCpuSize, 
                                                        (void**)&gpuToCpuDevice,
                                                        "GPU->CPU");
      if (hsa_status != HSA_STATUS_SUCCESS) {
        std::cerr << "Error: HSA memory allocation failed for GPU->CPU "
                  << "buffer: " << hsa_status << std::endl;
        return EXIT_FAILURE;
      }
      gpuToCpuHost = (GpuToCpuMsg*)gpuToCpuDevice;
      memset(gpuToCpuHost, 0, sizeof(GpuToCpuMsg));
    } else {
      HIP_CHECK(hipHostMalloc((void**)&gpuToCpuHost, sizeof(GpuToCpuMsg),
                              hipHostMallocDefault));
      memset(gpuToCpuHost, 0, sizeof(GpuToCpuMsg));
      gpuToCpuDevice = gpuToCpuHost;
    }
    
    // Allocate CPU->GPU response buffer
    if (cpuWriteToDevice) {
      size_t cpuToGpuSize = ((sizeof(CpuToGpuMsg) + host_page_size - 1) / 
                             host_page_size) * host_page_size;
      
      hsa_status_t hsa_status = allocateHsaDeviceMemory(cpuToGpuSize, 
                                                        (void**)&cpuToGpuDevice,
                                                        "CPU->GPU");
      if (hsa_status != HSA_STATUS_SUCCESS) {
        std::cerr << "Error: HSA memory allocation failed for CPU->GPU "
                  << "buffer: " << hsa_status << std::endl;
        if (gpuWriteToDevice) {
          hsa_memory_free(gpuToCpuDevice);
        } else {
          HIP_CHECK(hipHostFree(gpuToCpuHost));
        }
        return EXIT_FAILURE;
      }
      cpuToGpuHost = (CpuToGpuMsg*)cpuToGpuDevice;
      memset(cpuToGpuHost, 0, sizeof(CpuToGpuMsg));
    } else {
      HIP_CHECK(hipHostMalloc((void**)&cpuToGpuHost, sizeof(CpuToGpuMsg),
                              hipHostMallocDefault));
      memset(cpuToGpuHost, 0, sizeof(CpuToGpuMsg));
      cpuToGpuDevice = cpuToGpuHost;
    }
    
    // Timing buffers
    HIP_CHECK(hipHostMalloc((void**)&startTimes,
                            iterations * sizeof(unsigned long long int),
                            hipHostMallocDefault));
    HIP_CHECK(hipHostMalloc((void**)&cpuTimes,
                            iterations * sizeof(unsigned long long int),
                            hipHostMallocDefault));
    memset(startTimes, 0, iterations * sizeof(unsigned long long int));
    memset(cpuTimes, 0, iterations * sizeof(unsigned long long int));
  } else {
    // Multi-threaded mode: allocate arrays of buffers (one per thread)
    // Allocate GPU->CPU message buffers
    if (gpuWriteToDevice) {
      size_t gpuToCpuSize = ((sizeof(GpuToCpuMsg) * numThreads + 
                             host_page_size - 1) / host_page_size) * 
                            host_page_size;
      
      hsa_status_t hsa_status = allocateHsaDeviceMemory(gpuToCpuSize, 
                                                        (void**)&gpuToCpuDeviceArray,
                                                        "GPU->CPU");
      if (hsa_status != HSA_STATUS_SUCCESS) {
        std::cerr << "Error: HSA memory allocation failed for GPU->CPU "
                  << "buffers: " << hsa_status << std::endl;
        return EXIT_FAILURE;
      }
      gpuToCpuHostArray = (GpuToCpuMsg*)gpuToCpuDeviceArray;
      memset(gpuToCpuHostArray, 0, 
             sizeof(GpuToCpuMsg) * numThreads);
    } else {
      HIP_CHECK(hipHostMalloc((void**)&gpuToCpuHostArray, 
                              sizeof(GpuToCpuMsg) * numThreads,
                              hipHostMallocDefault));
      memset(gpuToCpuHostArray, 0, 
             sizeof(GpuToCpuMsg) * numThreads);
      gpuToCpuDeviceArray = gpuToCpuHostArray;
    }
    
    // Allocate CPU->GPU response buffers
    if (cpuWriteToDevice) {
      size_t cpuToGpuSize = ((sizeof(CpuToGpuMsg) * numThreads + 
                             host_page_size - 1) / host_page_size) * 
                            host_page_size;
      
      hsa_status_t hsa_status = allocateHsaDeviceMemory(cpuToGpuSize, 
                                                        (void**)&cpuToGpuDeviceArray,
                                                        "CPU->GPU");
      if (hsa_status != HSA_STATUS_SUCCESS) {
        std::cerr << "Error: HSA memory allocation failed for CPU->GPU "
                  << "buffers: " << hsa_status << std::endl;
        if (gpuWriteToDevice) {
          hsa_memory_free(gpuToCpuDeviceArray);
        } else {
          HIP_CHECK(hipHostFree(gpuToCpuHostArray));
        }
        return EXIT_FAILURE;
      }
      cpuToGpuHostArray = (CpuToGpuMsg*)cpuToGpuDeviceArray;
      memset(cpuToGpuHostArray, 0, 
             sizeof(CpuToGpuMsg) * numThreads);
    } else {
      HIP_CHECK(hipHostMalloc((void**)&cpuToGpuHostArray, 
                              sizeof(CpuToGpuMsg) * numThreads,
                              hipHostMallocDefault));
      memset(cpuToGpuHostArray, 0, 
             sizeof(CpuToGpuMsg) * numThreads);
      cpuToGpuDeviceArray = cpuToGpuHostArray;
    }
    
    // Timing buffers (per thread)
    HIP_CHECK(hipHostMalloc((void**)&startTimesArray,
                            iterations * numThreads * 
                            sizeof(unsigned long long int),
                            hipHostMallocDefault));
    HIP_CHECK(hipHostMalloc((void**)&cpuTimesArray,
                            iterations * numThreads * 
                            sizeof(unsigned long long int),
                            hipHostMallocDefault));
    memset(startTimesArray, 0, 
           iterations * numThreads * sizeof(unsigned long long int));
    memset(cpuTimesArray, 0, 
           iterations * numThreads * sizeof(unsigned long long int));
  }

  // Check hardware concurrency and warn if exceeded
  unsigned hardwareThreads = std::thread::hardware_concurrency();
  if (numThreads > hardwareThreads) {
    std::cerr << "Warning: Requested " << numThreads 
              << " CPU threads but only " << hardwareThreads 
              << " hardware threads available. Performance may degrade."
              << std::endl;
  }

  // Ensure initialization is visible
  __sync_synchronize();

  // Launch CPU threads (one per GPU thread)
  std::vector<std::thread> cpuThreadHandles;
  if (numThreads == 1) {
    // Single-threaded mode
    cpuThreadHandles.emplace_back(cpuThread, gpuToCpuHost, cpuToGpuHost,
                                  iterations, 0);
  } else {
    // Multi-threaded mode: one CPU thread per GPU thread
    for (unsigned t = 0; t < numThreads; ++t) {
      cpuThreadHandles.emplace_back(cpuThread, 
                                    &gpuToCpuHostArray[t],
                                    &cpuToGpuHostArray[t],
                                    iterations, t);
    }
  }

  // Small delay to ensure CPU threads are ready
  std::this_thread::sleep_for(std::chrono::microseconds(100));

  // Launch GPU kernel
  if (numThreads == 1) {
    // Single-threaded: use single buffers
    GpuToCpuMsg* gpuToCpu = gpuWriteToDevice ? gpuToCpuDevice : gpuToCpuHost;
    CpuToGpuMsg* cpuToGpu = cpuWriteToDevice ? cpuToGpuDevice : cpuToGpuHost;
    hipLaunchKernelGGL(gpuKernel, dim3(1), dim3(1), 0, 0, gpuToCpu, cpuToGpu,
                        iterations, startTimes, cpuTimes, gpuWallClockRateKHz,
                        1, delayNs);
  } else {
    // Multi-threaded: use arrays, launch numThreads threads
    hipLaunchKernelGGL(gpuKernel, dim3(1), dim3(numThreads), 0, 0,
                        gpuToCpuDeviceArray, cpuToGpuDeviceArray,
                        iterations, startTimesArray, cpuTimesArray,
                        gpuWallClockRateKHz, numThreads, delayNs);
  }

  // Check for kernel launch errors
  hipError_t err = hipGetLastError();
  if (err != hipSuccess) {
    std::cerr << "Kernel launch failed: " << hipGetErrorString(err)
              << std::endl;
    // Join all CPU threads before exiting
    for (auto& handle : cpuThreadHandles) {
      handle.join();
    }
    return EXIT_FAILURE;
  }

  HIP_CHECK(hipDeviceSynchronize());

  // Wait for all CPU threads to finish
  for (auto& handle : cpuThreadHandles) {
    handle.join();
  }

  // Calculate deltas
  std::vector<long long> gpuDeltas;
  std::vector<long long> cpuDeltas;
  
  if (numThreads == 1) {
    // Single-threaded mode
    gpuDeltas.resize(iterations);
    cpuDeltas.resize(iterations);
    gpuDeltas[0] = 0;
    cpuDeltas[0] = 0;
    
    for (unsigned i = 1; i < iterations; ++i) {
      gpuDeltas[i] = static_cast<long long>(startTimes[i]) - 
                     static_cast<long long>(startTimes[i-1]);
      cpuDeltas[i] = static_cast<long long>(cpuTimes[i]) - 
                     static_cast<long long>(cpuTimes[i-1]);
    }
  } else {
    // Multi-threaded mode: aggregate across all threads
    gpuDeltas.resize(iterations * numThreads);
    cpuDeltas.resize(iterations * numThreads);
    
    for (unsigned t = 0; t < numThreads; ++t) {
      unsigned baseIdx = t * iterations;
      gpuDeltas[baseIdx] = 0;
      cpuDeltas[baseIdx] = 0;
      
      for (unsigned i = 1; i < iterations; ++i) {
        unsigned idx = baseIdx + i;
        unsigned prevIdx = baseIdx + i - 1;
        gpuDeltas[idx] = static_cast<long long>(startTimesArray[idx]) - 
                         static_cast<long long>(startTimesArray[prevIdx]);
        cpuDeltas[idx] = static_cast<long long>(cpuTimesArray[idx]) - 
                         static_cast<long long>(cpuTimesArray[prevIdx]);
      }
    }
  }

  // Print results table if verbose
  if (verbose) {
    if (numThreads == 1) {
      std::cout << "\n|-----------|-----------------|-----------------|"
                << "-----------------|-----------------|" << std::endl;
      std::cout << std::setw(9) << "| Iteration" << " | " << std::setw(15)
                << "GPU Time" << " | " << std::setw(15)
                << "CPU Time" << " | " << std::setw(15)
                << "GPU Delta" << " | " << std::setw(17)
                << "CPU Delta   |" << std::endl;
      std::cout << "|-----------|-----------------|-----------------|"
                << "-----------------|-----------------|" << std::endl;
      for (unsigned i = 0; i < iterations; ++i) {
        std::cout << "|" << std::setw(10) << (i + 1) << " | " 
                  << std::setw(15)
                  << startTimes[i] << " | " << std::setw(15)
                  << cpuTimes[i] << " | " << std::setw(15)
                  << gpuDeltas[i] << " | " << std::setw(15)
                  << cpuDeltas[i] << " |" << std::endl;
      }
      std::cout << "|-----------|-----------------|-----------------|"
                << "-----------------|-----------------|" << std::endl;
    } else {
      std::cout << "\n|--------|------------|-----------------|"
                << "-----------------|-----------------|"
                << "-----------------|" << std::endl;
      std::cout << std::setw(7) << "| Thread" << " | " 
                << std::setw(10) << "Iteration" << " | " 
                << std::setw(15) << "GPU Time" << " | " 
                << std::setw(15) << "CPU Time" << " | " 
                << std::setw(15) << "GPU Delta" << " | " 
                << std::setw(15) << "CPU Delta" << " |" << std::endl;
      std::cout << "|--------|------------|-----------------|"
                << "-----------------|-----------------|"
                << "-----------------|" << std::endl;
      for (unsigned t = 0; t < numThreads; ++t) {
        for (unsigned i = 0; i < iterations; ++i) {
          unsigned idx = t * iterations + i;
          std::cout << "|" << std::setw(7) << t << " | " 
                    << std::setw(10) << (i + 1) << " | " 
                    << std::setw(15) << startTimesArray[idx] << " | " 
                    << std::setw(15) << cpuTimesArray[idx] << " | " 
                    << std::setw(15) << gpuDeltas[idx] << " | " 
                    << std::setw(15) << cpuDeltas[idx] << " |" 
                    << std::endl;
        }
      }
      std::cout << "|--------|------------|-----------------|"
                << "-----------------|-----------------|"
                << "-----------------|" << std::endl;
    }
  }

  // Calculate statistics for deltas (skip first three elements: 
  // index 0 is always 0, index 1 has cold start overhead,
  // index 2 often has the max value from first iteration)
  // All statistics (min, max, avg, std dev) exclude these iterations
  if (iterations > 3) {
    // Collect deltas excluding first 3 iterations for each thread
    std::vector<long long> gpuDeltaFiltered;
    std::vector<long long> cpuDeltaFiltered;
    
    if (numThreads == 1) {
      // Single-threaded: skip first 3 elements
      for (size_t i = 3; i < gpuDeltas.size(); ++i) {
        gpuDeltaFiltered.push_back(gpuDeltas[i]);
        cpuDeltaFiltered.push_back(cpuDeltas[i]);
      }
    } else {
      // Multi-threaded: skip first 3 elements for each thread
      for (unsigned t = 0; t < numThreads; ++t) {
        unsigned baseIdx = t * iterations;
        for (unsigned i = 3; i < iterations; ++i) {
          unsigned idx = baseIdx + i;
          gpuDeltaFiltered.push_back(gpuDeltas[idx]);
          cpuDeltaFiltered.push_back(cpuDeltas[idx]);
        }
      }
    }
    
    if (!gpuDeltaFiltered.empty()) {
      auto gpuMin = std::min_element(gpuDeltaFiltered.begin(), 
                                     gpuDeltaFiltered.end());
      auto gpuMax = std::max_element(gpuDeltaFiltered.begin(), 
                                     gpuDeltaFiltered.end());
    
      double gpuSum = 0.0;
      for (auto val : gpuDeltaFiltered) {
        gpuSum += static_cast<double>(val);
      }
      double gpuAvg = gpuSum / gpuDeltaFiltered.size();
      
      double gpuVariance = 0.0;
      for (auto val : gpuDeltaFiltered) {
        double diff = static_cast<double>(val) - gpuAvg;
        gpuVariance += diff * diff;
      }
      gpuVariance /= gpuDeltaFiltered.size();
      double gpuStdDev = std::sqrt(gpuVariance);

      // CPU Delta statistics
      auto cpuMin = std::min_element(cpuDeltaFiltered.begin(), 
                                     cpuDeltaFiltered.end());
      auto cpuMax = std::max_element(cpuDeltaFiltered.begin(), 
                                     cpuDeltaFiltered.end());
      
      double cpuSum = 0.0;
      for (auto val : cpuDeltaFiltered) {
        cpuSum += static_cast<double>(val);
      }
      double cpuAvg = cpuSum / cpuDeltaFiltered.size();
      
      double cpuVariance = 0.0;
      for (auto val : cpuDeltaFiltered) {
        double diff = static_cast<double>(val) - cpuAvg;
        cpuVariance += diff * diff;
      }
      cpuVariance /= cpuDeltaFiltered.size();
      double cpuStdDev = std::sqrt(cpuVariance);

      // Convert GPU deltas from cycles to nanoseconds
      double gpuMinNs = static_cast<double>(*gpuMin) * gpuClockPeriodNs;
      double gpuMaxNs = static_cast<double>(*gpuMax) * gpuClockPeriodNs;
      double gpuAvgNs = gpuAvg * gpuClockPeriodNs;
      double gpuStdDevNs = gpuStdDev * gpuClockPeriodNs;

      // CPU deltas are already in nanoseconds
      double cpuMinNs = static_cast<double>(*cpuMin);
      double cpuMaxNs = static_cast<double>(*cpuMax);
      double cpuAvgNs = cpuAvg;
      double cpuStdDevNs = cpuStdDev;

      // Format GPU statistics
      double gpuMinVal, gpuMaxVal, gpuAvgVal, gpuStdDevVal;
      const char* gpuMinUnit, *gpuMaxUnit, *gpuAvgUnit, *gpuStdDevUnit;
      formatTime(gpuMinNs, gpuMinVal, gpuMinUnit);
      formatTime(gpuMaxNs, gpuMaxVal, gpuMaxUnit);
      formatTime(gpuAvgNs, gpuAvgVal, gpuAvgUnit);
      formatTime(gpuStdDevNs, gpuStdDevVal, gpuStdDevUnit);

      // Format CPU statistics
      double cpuMinVal, cpuMaxVal, cpuAvgVal, cpuStdDevVal;
      const char* cpuMinUnit, *cpuMaxUnit, *cpuAvgUnit, *cpuStdDevUnit;
      formatTime(cpuMinNs, cpuMinVal, cpuMinUnit);
      formatTime(cpuMaxNs, cpuMaxVal, cpuMaxUnit);
      formatTime(cpuAvgNs, cpuAvgVal, cpuAvgUnit);
      formatTime(cpuStdDevNs, cpuStdDevVal, cpuStdDevUnit);

      // Print statistics
      std::cout << "\nDelta Statistics (Real Time):" << std::endl;
    std::cout << "  GPU Delta:" << std::endl;
    std::cout << "    Min:     " << std::fixed << std::setprecision(2)
              << gpuMinVal << gpuMinUnit << " (" << *gpuMin 
              << " cycles, " << std::setprecision(2) << gpuMinNs << " ns)" 
              << std::endl;
    std::cout << "    Max:     " << std::fixed << std::setprecision(2)
              << gpuMaxVal << gpuMaxUnit << " (" << *gpuMax 
              << " cycles, " << std::setprecision(2) << gpuMaxNs << " ns)" 
              << std::endl;
    std::cout << "    Average: " << std::fixed << std::setprecision(2)
              << gpuAvgVal << gpuAvgUnit << " (" << std::setprecision(0)
              << gpuAvg << " cycles, " << std::setprecision(2) << gpuAvgNs 
              << " ns)" << std::endl;
    std::cout << "    Std Dev: " << std::fixed << std::setprecision(2)
              << gpuStdDevVal << gpuStdDevUnit << " (" 
              << std::setprecision(0) << gpuStdDev << " cycles, "
              << std::setprecision(2) << gpuStdDevNs << " ns)" 
              << std::endl;
    std::cout << "  CPU Delta:" << std::endl;
    std::cout << "    Min:     " << std::fixed << std::setprecision(2)
              << cpuMinVal << cpuMinUnit << " (" << cpuMinNs << " ns)" 
              << std::endl;
    std::cout << "    Max:     " << std::fixed << std::setprecision(2)
              << cpuMaxVal << cpuMaxUnit << " (" << cpuMaxNs << " ns)" 
              << std::endl;
    std::cout << "    Average: " << std::fixed << std::setprecision(2)
              << cpuAvgVal << cpuAvgUnit << " (" << cpuAvgNs << " ns)" 
              << std::endl;
    std::cout << "    Std Dev: " << std::fixed << std::setprecision(2)
              << cpuStdDevVal << cpuStdDevUnit << " (" << cpuStdDevNs 
              << " ns)" << std::endl;
      // Calculate total elapsed time (first to last iteration)
      double gpuTotalNs, cpuTotalNs;
      if (numThreads == 1) {
        gpuTotalNs = static_cast<double>(startTimes[iterations-1] - 
                                         startTimes[0]) * gpuClockPeriodNs;
        cpuTotalNs = static_cast<double>(cpuTimes[iterations-1] - 
                                         cpuTimes[0]);
      } else {
        // For multi-threaded, use average across threads
        double gpuTotalSum = 0.0;
        double cpuTotalSum = 0.0;
        for (unsigned t = 0; t < numThreads; ++t) {
          unsigned firstIdx = t * iterations;
          unsigned lastIdx = firstIdx + iterations - 1;
          gpuTotalSum += static_cast<double>(startTimesArray[lastIdx] - 
                                             startTimesArray[firstIdx]) * 
                         gpuClockPeriodNs;
          cpuTotalSum += static_cast<double>(cpuTimesArray[lastIdx] - 
                                              cpuTimesArray[firstIdx]);
        }
        gpuTotalNs = gpuTotalSum / numThreads;
        cpuTotalNs = cpuTotalSum / numThreads;
      }

      double gpuTotalVal, cpuTotalVal;
      const char* gpuTotalUnit, *cpuTotalUnit;
      formatTime(gpuTotalNs, gpuTotalVal, gpuTotalUnit);
      formatTime(cpuTotalNs, cpuTotalVal, cpuTotalUnit);

      std::cout << "\n  Total Elapsed Time (first to last iteration):" 
                << std::endl;
      std::cout << "    GPU Total: " << std::fixed << std::setprecision(2)
                << gpuTotalVal << gpuTotalUnit << " (" << gpuTotalNs 
                << " ns)" << std::endl;
      std::cout << "    CPU Total: " << std::fixed << std::setprecision(2)
                << cpuTotalVal << cpuTotalUnit << " (" << cpuTotalNs 
                << " ns)" << std::endl;
      std::cout << "    Difference: " << std::fixed << std::setprecision(2)
                << std::abs(gpuTotalNs - cpuTotalNs) << " ns" << std::endl;
      std::cout << "    Ratio:      " << std::fixed << std::setprecision(4)
                << (cpuTotalNs / gpuTotalNs) << std::endl;

      std::cout << "\n  Delta Comparison:" << std::endl;
      std::cout << "    GPU Avg: " << std::fixed << std::setprecision(2)
                << gpuAvgNs << " ns" << std::endl;
      std::cout << "    CPU Avg: " << std::fixed << std::setprecision(2)
                << cpuAvgNs << " ns" << std::endl;
      std::cout << "    Ratio:   " << std::fixed << std::setprecision(4)
                << (cpuAvgNs / gpuAvgNs) << std::endl;
    }
  }

  // Cleanup
  if (numThreads == 1) {
    // Single-threaded cleanup
    if (gpuWriteToDevice) {
      hsa_memory_free(gpuToCpuDevice);
    } else {
      HIP_CHECK(hipHostFree(gpuToCpuHost));
    }
    
    if (cpuWriteToDevice) {
      hsa_memory_free(cpuToGpuDevice);
    } else {
      HIP_CHECK(hipHostFree(cpuToGpuHost));
    }
    
    HIP_CHECK(hipHostFree(startTimes));
    HIP_CHECK(hipHostFree(cpuTimes));
  } else {
    // Multi-threaded cleanup
    if (gpuWriteToDevice) {
      hsa_memory_free(gpuToCpuDeviceArray);
    } else {
      HIP_CHECK(hipHostFree(gpuToCpuHostArray));
    }
    
    if (cpuWriteToDevice) {
      hsa_memory_free(cpuToGpuDeviceArray);
    } else {
      HIP_CHECK(hipHostFree(cpuToGpuHostArray));
    }
    
    HIP_CHECK(hipHostFree(startTimesArray));
    HIP_CHECK(hipHostFree(cpuTimesArray));
  }

  std::cout << "\nTest completed successfully!" << std::endl;
  return EXIT_SUCCESS;
}

