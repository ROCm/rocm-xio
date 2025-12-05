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

    // Process the message (simple function: invert the first data word)
    // The response includes CPU time which is recorded after processing
    (void)currentMsg.data[0]; // Processed but not used in response

    // Get CPU wall clock time
    uint64_t cpuTime = getCpuTime();

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
  if (argc > 1) {
    iterations = static_cast<unsigned>(atoi(argv[1]));
  }

  // Get GPU device information
  int deviceId = 0;
  HIP_CHECK(hipGetDevice(&deviceId));
  hipDeviceProp_t deviceProp;
  HIP_CHECK(hipGetDeviceProperties(&deviceProp, deviceId));

  std::cout << "Simple GPU-CPU Communication Test" << std::endl;
  std::cout << "  GPU Model: " << deviceProp.name << std::endl;
  std::cout << "  GPU Device ID: " << deviceId << std::endl;
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

  // Print results
  std::cout << "\n|-----------|-----------------|-----------------|" << std::endl;
  std::cout << std::setw(9) << "| Iteration" << " | " << std::setw(15)
            << "GPU Time" << " | " << std::setw(17)
            << "CPU Time  |" << std::endl;
  std::cout << "|-----------|-----------------|-----------------|" << std::endl;
  for (unsigned i = 0; i < iterations; ++i) {
    std::cout << "|" << std::setw(10) << (i + 1) << " | " << std::setw(15)
              << startTimes[i] << " | " << std::setw(15)
              << cpuTimes[i] << " |" << std::endl;
  }
  std::cout << "|-----------|-----------------|-----------------|" << std::endl;

  // Cleanup
  HIP_CHECK(hipHostFree(gpuToCpu));
  HIP_CHECK(hipHostFree(cpuToGpu));
  HIP_CHECK(hipHostFree(startTimes));
  HIP_CHECK(hipHostFree(cpuTimes));

  std::cout << "\nTest completed successfully!" << std::endl;
  return EXIT_SUCCESS;
}

