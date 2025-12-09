/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <chrono>
#include <ctime>
#include <thread>
#include <vector>

#include "axiio.h"
#include "test-ep-config.h"
#include "test-ep.h"

// Get CPU wall clock time in nanoseconds (host-only)
static inline uint64_t getCpuTime() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

// Use types from test-ep.h
typedef struct test_sqe sqeType;
typedef struct test_cqe cqeType;

// Verify that the queue entry sizes match test-ep expectations
static_assert(sizeof(sqeType) == TEST_EP_SQE_SIZE, "test-ep SQE size mismatch");
static_assert(sizeof(cqeType) == TEST_EP_CQE_SIZE, "test-ep CQE size mismatch");

// Helper function to compare sqeType structs
__host__ __device__ bool sqeEqual(const sqeType* a, const sqeType* b) {
  return (a->magic == b->magic && a->iteration == b->iteration &&
          a->gpuTime == b->gpuTime);
}

// Helper function to compare cqeType structs
__host__ __device__ bool cqeEqual(const cqeType* a, const cqeType* b) {
  return (a->magic == b->magic && a->cpuTime == b->cpuTime);
}

__host__ __device__ sqeType sqeRead(volatile sqeType* sqeAddress) {
  sqeType result;
  result.magic = sqeAddress->magic;
  result.iteration = sqeAddress->iteration;
  result.gpuTime = sqeAddress->gpuTime;
  for (int i = 0; i < 5; ++i) {
    result.data[i] = sqeAddress->data[i];
  }
  return result;
}

__host__ __device__ cqeType cqeRead(volatile cqeType* cqeAddress) {
  cqeType result;
  result.magic = cqeAddress->magic;
  result.cpuTime = cqeAddress->cpuTime;
  return result;
}

__host__ __device__ void sqeWrite(sqeType sqeData, sqeType* sqeAddress) {
  *sqeAddress = sqeData;
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif // __HIP_DEVICE_COMPILE__
}

__host__ __device__ void cqeWrite(cqeType cqeData, cqeType* cqeAddress) {
  *cqeAddress = cqeData;
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif // __HIP_DEVICE_COMPILE__
}

__host__ __device__ sqeType sqePoll(sqeType sqeLast,
                                    volatile sqeType* sqeAddress) {
  sqeType sqeNew;
  while (true) {
    sqeNew = sqeRead(sqeAddress);
    if (sqeNew.magic == TEST_EP_MAGIC_ID && !sqeEqual(&sqeNew, &sqeLast))
      return sqeNew;
  }
}

__host__ __device__ cqeType cqePoll(cqeType cqeLast,
                                    volatile cqeType* cqeAddress) {
  cqeType cqeNew;
  while (true) {
    cqeNew = cqeRead(cqeAddress);
    if (cqeNew.magic == TEST_EP_CQE_MAGIC_ID && !cqeEqual(&cqeNew, &cqeLast))
      return cqeNew;
  }
}

// Host-only function to generate CQE from SQE
__host__ cqeType cqeGenFromSqe(const sqeType* sqeData) {
  (void)sqeData; // Not used, but kept for API compatibility
  cqeType result;
  result.magic = TEST_EP_CQE_MAGIC_ID;
  result.cpuTime = getCpuTime(); // Use CPU time for CQE
  return result;
}

// CPU thread function that polls for GPU SQEs and generates CQEs
// Each CPU thread handles one GPU thread's buffer
// Matches simple-test.hip cpuThread behavior exactly
static void cpuThread(volatile sqeType* hostSqeAddr,
                      volatile cqeType* hostCqeAddr, unsigned iterations,
                      unsigned threadIdx, long long delayNs) {
  volatile sqeType* volatileSqe = hostSqeAddr;
  volatile cqeType* volatileCqe = hostCqeAddr;
  sqeType lastMsg = {};
  lastMsg.iteration = 0xFFFFFFFFFFFFFFFFULL; // Initialize to invalid value
  uint64_t lastGpuTimeSeen = 0;

  for (unsigned i = 0; i < iterations; ++i) {
    // Poll for new GPU message
    sqeType currentMsg;

    while (true) {
      // Read message atomically (matches simple-test exactly)
      currentMsg.magic = volatileSqe->magic;
      currentMsg.iteration = volatileSqe->iteration;
      currentMsg.gpuTime = volatileSqe->gpuTime;
      for (int j = 0; j < 5; ++j) {
        currentMsg.data[j] = volatileSqe->data[j];
      }

      // Extract thread index and iteration from encoded iteration field
      unsigned msgThreadIdx = (currentMsg.iteration >> 32) & 0xFFFFFFFF;
      unsigned iter = currentMsg.iteration & 0xFFFFFFFF;

      // Check if this is a new message for this thread and iteration
      // Match simple-test logic exactly: check magic, thread index, iteration
      // number, and that gpuTime has changed (new message)
      if (currentMsg.magic == TEST_EP_MAGIC_ID && msgThreadIdx == threadIdx &&
          iter == i && currentMsg.gpuTime != lastGpuTimeSeen) {
        break;
      }
      // Yield to avoid busy-waiting too aggressively
      std::this_thread::yield();
    }

    // Get CPU wall clock time when message is received
    uint64_t cpuTime = getCpuTime();

    // Read delay value from data[0] (set by GPU)
    uint64_t delayNs = currentMsg.data[0];

    // Implement delay before responding (matches simple-test)
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

    // Generate response message (matches simple-test)
    cqeType response = {};
    response.magic = TEST_EP_CQE_MAGIC_ID;
    response.cpuTime = cpuTime;

    // Write response to memory (matches simple-test)
    // Note: GPU kernel will record GPU time when it receives this response
    volatileCqe->magic = response.magic;
    volatileCqe->cpuTime = response.cpuTime;

    lastMsg = currentMsg;
    lastGpuTimeSeen = currentMsg.gpuTime;
  }
}

// Export test-ep functions
__host__ __device__ void test_ep_emulateEndpoint(unsigned sqeIterations,
                                                 void* sqeAddr, void* cqeAddr) {
  sqeType sqeNew = {TEST_EP_MAGIC_ID, 0, 0, {0}};
  sqeType sqeOld = {TEST_EP_MAGIC_ID, 0, 0, {0}};
  sqeType sqeStop = {TEST_EP_MAGIC_ID, 0xFFFFFFFFFFFFFFFFULL, 0, {0}};
  cqeType cqeLocal = {TEST_EP_CQE_MAGIC_ID, 0};

  while (!sqeEqual(&sqeNew, &sqeStop)) {
    sqeNew = sqePoll(sqeOld, (volatile sqeType*)sqeAddr);
#ifdef __HIP_DEVICE_COMPILE__
    // Device code - can't call getCpuTime, just use a dummy value
    cqeLocal.magic = TEST_EP_CQE_MAGIC_ID;
    cqeLocal.cpuTime = 0;
#else
    // Host code - can call getCpuTime
    cqeLocal = cqeGenFromSqe(&sqeNew);
#endif
    cqeWrite(cqeLocal, (cqeType*)cqeAddr);
    sqeOld = sqeNew;
  }
}

// Host function to launch CPU threads for test-ep
// Matches simple-test.hip CPU thread launching behavior
std::vector<std::thread> launchCpuThreads(void* hostSqeAddr, void* hostCqeAddr,
                                          unsigned numThreads,
                                          unsigned iterations,
                                          long long delayNs) {
  std::vector<std::thread> cpuThreadHandles;

  // Cast void* to endpoint-specific types
  volatile sqeType* sqePtr = static_cast<volatile sqeType*>(hostSqeAddr);
  volatile cqeType* cqePtr = static_cast<volatile cqeType*>(hostCqeAddr);

  if (numThreads == 1) {
    // Single-threaded mode
    cpuThreadHandles.emplace_back(cpuThread, sqePtr, cqePtr, iterations, 0,
                                  delayNs);
  } else {
    // Multi-threaded mode: one CPU thread per GPU thread
    for (unsigned t = 0; t < numThreads; ++t) {
      cpuThreadHandles.emplace_back(cpuThread, &sqePtr[t], &cqePtr[t],
                                    iterations, t, delayNs);
    }
  }

  return cpuThreadHandles;
}

// Endpoint kernel - receives pointers directly like simple-test
__global__ void endpoint_kernel(sqeType* sqePtr, cqeType* cqePtr,
                                unsigned long long int* startTimes,
                                unsigned long long int* endTimes,
                                unsigned iterations, unsigned numThreads,
                                long long delayNs) {
  // Get thread ID for multi-threading
  unsigned tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid >= numThreads) {
    return;
  }

  // Use per-thread buffers if multi-threaded
  sqeType* mySqe = (numThreads > 1) ? &sqePtr[tid] : sqePtr;
  cqeType* myCqe = (numThreads > 1) ? &cqePtr[tid] : cqePtr;
  volatile cqeType* volatileCqe = myCqe;

  // Get per-thread timing arrays if provided
  unsigned long long int* myStartTimes = nullptr;
  unsigned long long int* myEndTimes = nullptr;
  if (startTimes != nullptr) {
    myStartTimes = &startTimes[tid * iterations];
  }
  if (endTimes != nullptr) {
    myEndTimes = &endTimes[tid * iterations];
  }

  cqeType lastResponse = {};
  lastResponse.magic = 0; // Initialize to invalid value
  cqeType currentResponse = {};
  uint64_t lastCpuTime = 0;

  // Encode thread index in iteration field (upper 32 bits) and iteration (lower
  // 32 bits)
  for (unsigned i = 0; i < iterations; ++i) {
    // Record start time for this iteration
    unsigned long long pollStartTime = wall_clock64();
    if (myStartTimes != nullptr) {
      myStartTimes[i] = pollStartTime;
    }

    // Prepare message to CPU (matches simple-test)
    // Encode thread index in upper 32 bits, iteration in lower 32 bits
    sqeType msg = {};
    msg.magic = TEST_EP_MAGIC_ID;
    msg.iteration = ((uint64_t)tid << 32) | i;
    msg.gpuTime = wall_clock64();

    // Calculate delay based on delayNs parameter (per iteration, like
    // simple-test) Negative: fixed delay of |delayNs| Positive: random delay
    // between 0 and delayNs
    uint64_t actualDelayNs = 0;
    if (delayNs < 0) {
      // Fixed delay: use absolute value
      actualDelayNs = static_cast<uint64_t>(-delayNs);
    } else if (delayNs > 0) {
      // Random delay: generate value between 0 and delayNs
      // Use thread ID, iteration, and GPU time as seed for pseudo-randomness
      uint64_t seed = tid * 0x9e3779b9ULL + i * 0x6c6229e6ULL + wall_clock64();
      // Simple LCG-based random number generator
      seed = (seed * 1103515245ULL + 12345ULL) & 0x7FFFFFFFULL;
      actualDelayNs = seed % (static_cast<uint64_t>(delayNs) + 1);
    }
    msg.data[0] = actualDelayNs;

    // Fill remaining data payload
    for (int j = 1; j < 5; ++j) {
      msg.data[j] = 0x123456789ABCDEF0ULL + tid + i + j;
    }

    // Write message to memory (matches simple-test)
    *mySqe = msg;
    __threadfence_system(); // Ensure write is visible

    // Poll for CPU response (matches simple-test exactly)
    while (true) {
      uint64_t magic = volatileCqe->magic;
      uint64_t cpuTime = volatileCqe->cpuTime;
      currentResponse.magic = magic;
      currentResponse.cpuTime = cpuTime;
      // Check if this is a new response
      if (currentResponse.magic == TEST_EP_CQE_MAGIC_ID) {
        if (currentResponse.cpuTime != 0) {
          // Accept if this is a new response (cpuTime changed)
          // Or if this is the first valid response (lastCpuTime was 0)
          if (currentResponse.cpuTime != lastCpuTime || lastCpuTime == 0) {
            break;
          }
        }
      }
    }
    lastResponse = currentResponse;
    lastCpuTime = currentResponse.cpuTime;

    // Record GPU time when CPU response is received (use GPU time for both
    // start and end)
    if (myEndTimes != nullptr) {
      myEndTimes[i] = wall_clock64();
    }
  }

  // Synchronize threads before returning
  if (numThreads > 1) {
    __syncthreads();
  }
}

#include <iostream>

// Run method implementation for test-ep - launches GPU kernel and waits for
// completion
hipError_t test_ep_run(AxiioEndpointConfig* config) {
  std::vector<std::thread> cpuThreadHandles;

  // Cast void* to endpoint-specific types
  sqeType* sqePtr = static_cast<sqeType*>(config->submissionQueue);
  cqeType* cqePtr = static_cast<cqeType*>(config->completionQueue);

  if (config->numThreads > 0) {
    // Check hardware concurrency for CPU threads
    unsigned hardwareThreads = std::thread::hardware_concurrency();
    if (config->numThreads > hardwareThreads) {
      // Warning: requested more CPU threads than available
    }

    // Launch CPU threads via launcher
    cpuThreadHandles = launchCpuThreads(config->submissionQueue,
                                        config->completionQueue,
                                        config->numThreads, config->iterations,
                                        config->delayNs);

    // Small delay to ensure CPU threads are ready
    std::this_thread::sleep_for(std::chrono::microseconds(100));
  }

  // Launch GPU kernel - pass pointers directly like simple-test
  hipLaunchKernelGGL(endpoint_kernel, dim3(1), dim3(config->numThreads), 0, 0,
                     sqePtr, cqePtr, config->startTimes, config->endTimes,
                     config->iterations, config->numThreads, config->delayNs);

  // Check for kernel launch errors
  hipError_t err = hipGetLastError();
  if (err != hipSuccess) {
    // Join CPU threads if launched
    for (auto& thread : cpuThreadHandles) {
      thread.join();
    }
    return err;
  }

  // Wait for GPU kernel to complete
  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    // Join CPU threads if launched
    for (auto& thread : cpuThreadHandles) {
      thread.join();
    }
    return err;
  }

  // Join CPU threads if they were launched
  for (auto& thread : cpuThreadHandles) {
    thread.join();
  }

  return hipSuccess;
}
