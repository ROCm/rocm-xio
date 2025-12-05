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

// CPU thread function that polls for GPU messages and responds
void cpuThread(GpuToCpuMsg* gpuToCpu, CpuToGpuMsg* cpuToGpu,
               unsigned iterations) {
  volatile GpuToCpuMsg* volatileGpuToCpu = gpuToCpu;
  volatile CpuToGpuMsg* volatileCpuToGpu = cpuToGpu;
  GpuToCpuMsg lastMsg = {};
  lastMsg.iteration = 0xFFFFFFFF; // Initialize to invalid value

  for (unsigned i = 0; i < iterations; ++i) {
    // Poll for new GPU message
    GpuToCpuMsg currentMsg;
    while (true) {
      // Read the message atomically from volatile pointer
      currentMsg.magic = volatileGpuToCpu->magic;
      currentMsg.iteration = volatileGpuToCpu->iteration;
      currentMsg.gpuTime = volatileGpuToCpu->gpuTime;
      for (int j = 0; j < 5; ++j) {
        currentMsg.data[j] = volatileGpuToCpu->data[j];
      }
      
      // Check if this is a new message for this iteration
      if (currentMsg.magic == GPU_TO_CPU_MAGIC &&
          currentMsg.iteration == i) {
        // Verify it's different from last message we processed
        if (lastMsg.iteration != i || 
            lastMsg.gpuTime != currentMsg.gpuTime) {
          break;
        }
      }
      // Yield to avoid busy-waiting too aggressively
      std::this_thread::yield();
    }

    // Get CPU wall clock time when message is received (before processing)
    uint64_t cpuTime = getCpuTime();

    // Process the message (simple function: invert the first data word)
    // The response includes CPU time which is recorded when message received
    (void)currentMsg.data[0]; // Processed but not used in response

    // Write response to GPU memory atomically
    volatileCpuToGpu->magic = CPU_TO_GPU_MAGIC;
    __sync_synchronize(); // Ensure magic is written before cpuTime
    volatileCpuToGpu->cpuTime = cpuTime;
    __sync_synchronize(); // Ensure write is visible to GPU

    lastMsg = currentMsg;
  }
}

// GPU kernel that runs one thread
__global__ void gpuKernel(GpuToCpuMsg* gpuToCpu, CpuToGpuMsg* cpuToGpu,
                          unsigned iterations,
                          unsigned long long int* startTimes,
                          unsigned long long int* cpuTimes) {
  // Only thread 0 runs
  if (threadIdx.x != 0 || blockIdx.x != 0) {
    return;
  }

  volatile CpuToGpuMsg* volatileCpuToGpu = cpuToGpu;
  GpuToCpuMsg msg = {};
  CpuToGpuMsg lastResponse = {};
  lastResponse.magic = 0; // Initialize to invalid value
  CpuToGpuMsg currentResponse = {};
  uint64_t lastCpuTime = 0;

  for (unsigned i = 0; i < iterations; ++i) {
    // Record start time for this iteration
    startTimes[i] = wall_clock64();

    // Prepare message to CPU
    msg.magic = GPU_TO_CPU_MAGIC;
    msg.iteration = i;
    msg.gpuTime = wall_clock64();
    
    // Fill data payload
    for (int j = 0; j < 5; ++j) {
      msg.data[j] = 0x123456789ABCDEF0ULL + i + j;
    }

    // Write message to host memory atomically
    *gpuToCpu = msg;
    __threadfence_system(); // Ensure write is visible to CPU

    // Poll for CPU response
    while (true) {
      // Read response atomically from volatile pointer
      currentResponse.magic = volatileCpuToGpu->magic;
      currentResponse.cpuTime = volatileCpuToGpu->cpuTime;
      __threadfence_system();
      
      // Check if this is a new response
      if (currentResponse.magic == CPU_TO_GPU_MAGIC &&
          currentResponse.cpuTime != lastCpuTime) {
        break;
      }
    }

    lastResponse = currentResponse;
    lastCpuTime = currentResponse.cpuTime;
    
    // Record CPU time from response
    cpuTimes[i] = currentResponse.cpuTime;
  }
}

int main(int argc, char** argv) {
  unsigned iterations = 10;
  bool verbose = false;
  int opt;

  // Parse command line options
  while ((opt = getopt(argc, argv, "n:v")) != -1) {
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
      default:
        std::cerr << "Usage: " << argv[0] 
                  << " [-n iterations] [-v]" << std::endl;
        std::cerr << "  -n iterations  Number of iterations (default: 10)" 
                  << std::endl;
        std::cerr << "  -v             Verbose: show timing table" 
                  << std::endl;
        return EXIT_FAILURE;
    }
  }

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

  // Allocate host-accessible memory for communication
  GpuToCpuMsg* gpuToCpu = nullptr;
  CpuToGpuMsg* cpuToGpu = nullptr;
  unsigned long long int* startTimes = nullptr;
  unsigned long long int* cpuTimes = nullptr;

  HIP_CHECK(hipHostMalloc((void**)&gpuToCpu, sizeof(GpuToCpuMsg),
                          hipHostMallocDefault));
  HIP_CHECK(hipHostMalloc((void**)&cpuToGpu, sizeof(CpuToGpuMsg),
                          hipHostMallocDefault));
  HIP_CHECK(hipHostMalloc((void**)&startTimes,
                          iterations * sizeof(unsigned long long int),
                          hipHostMallocDefault));
  HIP_CHECK(hipHostMalloc((void**)&cpuTimes,
                          iterations * sizeof(unsigned long long int),
                          hipHostMallocDefault));

  // Initialize buffers
  memset(gpuToCpu, 0, sizeof(GpuToCpuMsg));
  memset(cpuToGpu, 0, sizeof(CpuToGpuMsg));
  memset(startTimes, 0, iterations * sizeof(unsigned long long int));
  memset(cpuTimes, 0, iterations * sizeof(unsigned long long int));

  // Ensure initialization is visible
  __sync_synchronize();

  // Launch CPU thread first
  std::thread cpuThreadHandle(cpuThread, gpuToCpu, cpuToGpu, iterations);

  // Small delay to ensure CPU thread is ready
  std::this_thread::sleep_for(std::chrono::microseconds(100));

  // Launch GPU kernel (1 block, 1 thread)
  hipLaunchKernelGGL(gpuKernel, dim3(1), dim3(1), 0, 0, gpuToCpu, cpuToGpu,
                      iterations, startTimes, cpuTimes);

  // Check for kernel launch errors
  hipError_t err = hipGetLastError();
  if (err != hipSuccess) {
    std::cerr << "Kernel launch failed: " << hipGetErrorString(err)
              << std::endl;
    cpuThreadHandle.join();
    return EXIT_FAILURE;
  }

  HIP_CHECK(hipDeviceSynchronize());

  // Wait for CPU thread to finish
  cpuThreadHandle.join();

  // Calculate deltas
  std::vector<long long> gpuDeltas(iterations);
  std::vector<long long> cpuDeltas(iterations);
  
  gpuDeltas[0] = 0; // First iteration has no previous value
  cpuDeltas[0] = 0;
  
  for (unsigned i = 1; i < iterations; ++i) {
    gpuDeltas[i] = static_cast<long long>(startTimes[i]) - 
                   static_cast<long long>(startTimes[i-1]);
    cpuDeltas[i] = static_cast<long long>(cpuTimes[i]) - 
                   static_cast<long long>(cpuTimes[i-1]);
  }

  // Print results table if verbose
  if (verbose) {
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
      std::cout << "|" << std::setw(10) << (i + 1) << " | " << std::setw(15)
                << startTimes[i] << " | " << std::setw(15)
                << cpuTimes[i] << " | " << std::setw(15)
                << gpuDeltas[i] << " | " << std::setw(15)
                << cpuDeltas[i] << " |" << std::endl;
    }
    std::cout << "|-----------|-----------------|-----------------|"
              << "-----------------|-----------------|" << std::endl;
  }

  // Calculate statistics for deltas (skip first two elements: 
  // index 0 is always 0, index 1 has cold start overhead)
  // All statistics (min, max, avg, std dev) exclude the cold start iteration
  if (iterations > 2) {
    // GPU Delta statistics (skip first iteration with cold start)
    auto gpuDeltaBegin = gpuDeltas.begin() + 2;
    auto gpuDeltaEnd = gpuDeltas.end();
    auto gpuMin = std::min_element(gpuDeltaBegin, gpuDeltaEnd);
    auto gpuMax = std::max_element(gpuDeltaBegin, gpuDeltaEnd);
    
    double gpuSum = 0.0;
    for (auto it = gpuDeltaBegin; it != gpuDeltaEnd; ++it) {
      gpuSum += static_cast<double>(*it);
    }
    double gpuAvg = gpuSum / (iterations - 2);
    
    double gpuVariance = 0.0;
    for (auto it = gpuDeltaBegin; it != gpuDeltaEnd; ++it) {
      double diff = static_cast<double>(*it) - gpuAvg;
      gpuVariance += diff * diff;
    }
    gpuVariance /= (iterations - 2);
    double gpuStdDev = std::sqrt(gpuVariance);

    // CPU Delta statistics (skip first iteration with cold start)
    auto cpuDeltaBegin = cpuDeltas.begin() + 2;
    auto cpuDeltaEnd = cpuDeltas.end();
    auto cpuMin = std::min_element(cpuDeltaBegin, cpuDeltaEnd);
    auto cpuMax = std::max_element(cpuDeltaBegin, cpuDeltaEnd);
    
    double cpuSum = 0.0;
    for (auto it = cpuDeltaBegin; it != cpuDeltaEnd; ++it) {
      cpuSum += static_cast<double>(*it);
    }
    double cpuAvg = cpuSum / (iterations - 2);
    
    double cpuVariance = 0.0;
    for (auto it = cpuDeltaBegin; it != cpuDeltaEnd; ++it) {
      double diff = static_cast<double>(*it) - cpuAvg;
      cpuVariance += diff * diff;
    }
    cpuVariance /= (iterations - 2);
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
    double gpuTotalNs = static_cast<double>(startTimes[iterations-1] - 
                                            startTimes[0]) * gpuClockPeriodNs;
    double cpuTotalNs = static_cast<double>(cpuTimes[iterations-1] - 
                                            cpuTimes[0]);

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

  // Cleanup
  HIP_CHECK(hipHostFree(gpuToCpu));
  HIP_CHECK(hipHostFree(cpuToGpu));
  HIP_CHECK(hipHostFree(startTimes));
  HIP_CHECK(hipHostFree(cpuTimes));

  std::cout << "\nTest completed successfully!" << std::endl;
  return EXIT_SUCCESS;
}

