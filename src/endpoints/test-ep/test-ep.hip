/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <ctime>
#include <iostream>
#include <thread>
#include <vector>

#include <unistd.h>

#include "test-ep.h"
#include "xio-data-pattern.hpp"
#include "xio-timing.h"
#include "xio.h"

namespace xio::test_ep {

static inline uint64_t getCpuTime() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

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
    if (sqeNew.magic == magicId && !sqeEqual(&sqeNew, &sqeLast))
      return sqeNew;
  }
}

__host__ __device__ cqeType cqePoll(cqeType cqeLast,
                                    volatile cqeType* cqeAddress) {
  cqeType cqeNew;
  while (true) {
    cqeNew = cqeRead(cqeAddress);
    if (cqeNew.magic == cqeMagicId && !cqeEqual(&cqeNew, &cqeLast))
      return cqeNew;
  }
}

// Host-only function to generate CQE from SQE
__host__ cqeType cqeGenFromSqe(const sqeType* sqeData) {
  (void)sqeData; // Not used, but kept for API compatibility
  cqeType result;
  result.magic = cqeMagicId;
  result.cpuTime = getCpuTime(); // Use CPU time for CQE
  return result;
}

// CPU thread function for doorbell mode
// Polls doorbell address and processes SQEs from the submission queue
static void cpuThreadDoorbell(volatile sqeType* sqeQueue,
                              volatile cqeType* cqeQueue,
                              volatile uint32_t* doorbell, unsigned queueSize,
                              unsigned numThreads, unsigned iterations,
                              long long delayNs) {
  uint32_t head = 0;
  while (head < iterations * numThreads) {
    // Poll doorbell for new tail value (use atomic load for consistency)
    uint32_t tail = __atomic_load_n(doorbell, __ATOMIC_ACQUIRE);

    // Process all new SQEs between head and tail
    while (head < tail && head < iterations * numThreads) {
      unsigned sqeIndex = head % queueSize;
      volatile sqeType* sqe = &sqeQueue[sqeIndex];

      // Read SQE (read magic first to check if SQE is ready)
      // GPU thread writes SQE and then updates doorbell, so if doorbell says
      // it's here, it should be written, but we still validate
      sqeType currentMsg;
      currentMsg.magic = sqe->magic;

      // If magic is not set, SQE hasn't been written yet - wait for it
      if (currentMsg.magic != magicId) {
        std::this_thread::yield();
        continue;
      }

      // Read rest of SQE after confirming magic is set
      currentMsg.iteration = sqe->iteration;
      currentMsg.gpuTime = sqe->gpuTime;
      for (int j = 0; j < 5; ++j) {
        currentMsg.data[j] = sqe->data[j];
      }

      // Use same sequence number (head) as SQE for circular buffer indexing
      unsigned cqeIndex = head % queueSize;
      // Store sequence number for validation (head is the sequence number)
      uint32_t sqeSeq = head;

      // Read delay value from data[0]
      uint64_t actualDelayNs = currentMsg.data[0];

      // Implement delay before responding
      // Optimize delay loop to reduce getCpuTime() calls
      if (actualDelayNs > 0) {
        if (actualDelayNs < 1000000) {
          // For short delays, spin with reduced time checks
          uint64_t startTime = getCpuTime();
          uint64_t elapsed = 0;
          uint32_t spinCount = 0;
          while (elapsed < actualDelayNs) {
            // Check time less frequently to reduce system call overhead
            if (spinCount % 1000 == 0) {
              elapsed = getCpuTime() - startTime;
            }
            spinCount++;
            std::atomic_signal_fence(std::memory_order_acq_rel);
          }
        } else {
          std::this_thread::sleep_for(std::chrono::nanoseconds(actualDelayNs));
        }
      }

      // Get CPU wall clock time AFTER delay is applied
      uint64_t cpuTime = getCpuTime();

      // Write CQE response
      // Store sequence number in upper 32 bits, CPU time in lower 32 bits
      // This allows GPU to verify CQE corresponds to its SQE
      volatile cqeType* cqe = &cqeQueue[cqeIndex];
      cqe->magic = cqeMagicId;
      cqe->cpuTime = ((uint64_t)sqeSeq << 32) | (cpuTime & 0xFFFFFFFFULL);

      head++;
    }

    if (head >= tail) {
      std::this_thread::yield();
    }
  }
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
      if (currentMsg.magic == magicId && msgThreadIdx == threadIdx &&
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
    // Optimize delay loop to reduce getCpuTime() calls
    if (delayNs > 0) {
      if (delayNs < 1000000) {
        // For short delays, spin with reduced time checks
        uint64_t startTime = getCpuTime();
        uint64_t elapsed = 0;
        uint32_t spinCount = 0;
        while (elapsed < delayNs) {
          // Check time less frequently to reduce system call overhead
          if (spinCount % 1000 == 0) {
            elapsed = getCpuTime() - startTime;
          }
          spinCount++;
          std::atomic_signal_fence(std::memory_order_acq_rel);
        }
      } else {
        // For larger delays, use sleep
        std::this_thread::sleep_for(std::chrono::nanoseconds(delayNs));
      }
    }

    // Generate response message (matches simple-test)
    cqeType response = {};
    response.magic = cqeMagicId;
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
  sqeType sqeNew = {magicId, 0, 0, {0}};
  sqeType sqeOld = {magicId, 0, 0, {0}};
  sqeType sqeStop = {magicId, 0xFFFFFFFFFFFFFFFFULL, 0, {0}};
  cqeType cqeLocal = {cqeMagicId, 0};

  while (!sqeEqual(&sqeNew, &sqeStop)) {
    sqeNew = sqePoll(sqeOld, (volatile sqeType*)sqeAddr);
#ifdef __HIP_DEVICE_COMPILE__
    // Device code - can't call getCpuTime, just use a dummy value
    cqeLocal.magic = cqeMagicId;
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
                                          long long delayNs, unsigned doorbell,
                                          void* doorbellAddr,
                                          unsigned queueSize) {
  std::vector<std::thread> cpuThreadHandles;

  // Cast void* to endpoint-specific types
  volatile sqeType* sqePtr = static_cast<volatile sqeType*>(hostSqeAddr);
  volatile cqeType* cqePtr = static_cast<volatile cqeType*>(hostCqeAddr);

  if (doorbell > 0) {
    // Doorbell mode: single CPU thread polls doorbell
    volatile uint32_t* doorbellPtr = static_cast<volatile uint32_t*>(
      doorbellAddr);
    cpuThreadHandles.emplace_back(cpuThreadDoorbell, sqePtr, cqePtr,
                                  doorbellPtr, queueSize, numThreads,
                                  iterations, delayNs);
  } else if (numThreads == 1) {
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
                                XioTimingStats* timingStats,
                                unsigned iterations, unsigned numThreads,
                                long long delayNs, unsigned doorbell,
                                uint32_t* doorbellAddr, unsigned queueSize,
                                volatile bool* stopRequested,
                                bool doVerify, uint32_t baseSeed,
                                uint32_t* verifyPass,
                                uint32_t* verifyFail) {
  // Get thread ID for multi-threading
  unsigned tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid >= numThreads) {
    return;
  }

  // Use per-thread buffers if multi-threaded (non-doorbell mode)
  bool doorbellMode = (doorbell > 0);
  sqeType* mySqe = (numThreads > 1 && !doorbellMode) ? &sqePtr[tid] : sqePtr;
  cqeType* myCqe = (numThreads > 1 && !doorbellMode) ? &cqePtr[tid] : cqePtr;
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

  if (doorbellMode) {
    // Doorbell mode: write SQEs to circular queue and ring doorbell after all
    // threads in an iteration have submitted their SQE
    // Use a shared atomic counter for sequence numbers across all threads
    __shared__ uint32_t globalSeq;
    if (threadIdx.x == 0) {
      globalSeq = 0;
    }
    __syncthreads();

    for (unsigned i = 0; i < iterations; ++i) {
      if (stopRequested && i % 100 == 0 &&
          *stopRequested)
        break;

      // Record start time for this iteration (when SQE is posted)
      unsigned long long pollStartTime = wall_clock64();
      unsigned long long startTime = 0;
      if (myStartTimes != nullptr) {
        myStartTimes[i] = pollStartTime;
      } else if (timingStats != nullptr) {
        startTime = pollStartTime;
      }

      // Prepare message to CPU
      sqeType msg = {};
      msg.magic = magicId;
      msg.iteration = ((uint64_t)tid << 32) | i;
      uint64_t sqeGpuTime = wall_clock64();
      msg.gpuTime = sqeGpuTime;

      // Calculate delay
      uint64_t actualDelayNs = 0;
      if (delayNs < 0) {
        actualDelayNs = static_cast<uint64_t>(-delayNs);
      } else if (delayNs > 0) {
        uint64_t seed = tid * 0x9e3779b9ULL + i * 0x6c6229e6ULL +
                        wall_clock64();
        seed = (seed * 1103515245ULL + 12345ULL) & 0x7FFFFFFFULL;
        actualDelayNs = seed % (static_cast<uint64_t>(delayNs) + 1);
      }
      msg.data[0] = actualDelayNs;

      // Fill remaining data payload
      for (int j = 1; j < 5; ++j) {
        msg.data[j] = 0x123456789ABCDEF0ULL + tid + i + j;
      }

      // Get next sequence number atomically (shared across all threads)
      uint32_t seq = atomicAdd(&globalSeq, 1U);
      unsigned sqeIndex = seq % queueSize;

      // Write SQE
      sqePtr[sqeIndex] = msg;
      __threadfence_system(); // Ensure SQE write is visible

      // Synchronize all threads before ringing doorbell
      __syncthreads();

      // Ring doorbell after all threads in this iteration have submitted their
      // SQE (tail = (i + 1) * numThreads)
      // Only thread 0 updates doorbell to avoid race conditions
      if (doorbellAddr != nullptr && threadIdx.x == 0) {
        uint32_t tail = (i + 1) * numThreads;
        uint32_t* doorbellPtr = (uint32_t*)doorbellAddr;
        __hip_atomic_store(doorbellPtr, tail, __ATOMIC_RELEASE,
                           __HIP_MEMORY_SCOPE_SYSTEM);
        __threadfence_system(); // Ensure doorbell update is visible
      }
      __syncthreads(); // Ensure doorbell update is visible to all threads

      // Poll for CPU response in CQE queue (use same sequence number as SQE)
      unsigned cqeIndex = seq % queueSize;
      volatile cqeType* myCqe = &cqePtr[cqeIndex];
      // Store expected sequence number for validation
      uint32_t expectedSeq = seq;

      while (true) {
        uint64_t magic = myCqe->magic;
        uint64_t cqeValue = myCqe->cpuTime;
        currentResponse.magic = magic;
        currentResponse.cpuTime = cqeValue;
        if (currentResponse.magic == cqeMagicId) {
          if (cqeValue != 0) {
            // Verify CQE corresponds to our SQE by checking sequence number
            // matches
            uint32_t cqeSeq = (cqeValue >> 32) & 0xFFFFFFFFULL;
            uint64_t cqeCpuTime = cqeValue & 0xFFFFFFFFULL;
            if (cqeSeq == expectedSeq &&
                (cqeCpuTime != (lastCpuTime & 0xFFFFFFFFULL) ||
                 lastCpuTime == 0)) {
              // Record GPU time immediately when valid CQE is detected
              unsigned long long endTime = wall_clock64();
              if (myEndTimes != nullptr) {
                myEndTimes[i] = endTime;
              } else if (timingStats != nullptr && startTime > 0 &&
                         endTime > startTime) {
                unsigned long long int duration = endTime - startTime;
                updateTimingStats(timingStats, duration);
              }
              break;
            }
          }
        }
      }
      lastResponse = currentResponse;
      lastCpuTime = currentResponse.cpuTime;
    }
  } else {
    // Normal polling mode
    for (unsigned i = 0; i < iterations; ++i) {
      if (stopRequested && i % 100 == 0 &&
          *stopRequested)
        break;

      // Record start time for this iteration
      unsigned long long pollStartTime = wall_clock64();
      unsigned long long startTime = 0;
      if (myStartTimes != nullptr) {
        myStartTimes[i] = pollStartTime;
      } else if (timingStats != nullptr) {
        startTime = pollStartTime;
      }

      sqeType msg = {};
      msg.magic = magicId;
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
        uint64_t seed = tid * 0x9e3779b9ULL + i * 0x6c6229e6ULL +
                        wall_clock64();
        // Simple LCG-based random number generator
        seed = (seed * 1103515245ULL + 12345ULL) & 0x7FFFFFFFULL;
        actualDelayNs = seed % (static_cast<uint64_t>(delayNs) + 1);
      }
      msg.data[0] = actualDelayNs;

      if (doVerify) {
        uint32_t iterSeed = baseSeed + i;
        xio::DataPatternParams fp{
          reinterpret_cast<uint8_t*>(&msg.data[1]),
          4 * sizeof(uint64_t), 0,
          static_cast<uint32_t>(
            4 * sizeof(uint64_t)),
          iterSeed, nullptr};
        xio::dataPattern(false, fp);
      } else {
        for (int j = 1; j < 5; ++j)
          msg.data[j] =
            0x123456789ABCDEF0ULL + tid + i + j;
      }

      *mySqe = msg;
      __threadfence_system();

      while (true) {
        uint64_t magic = volatileCqe->magic;
        uint64_t cpuTime = volatileCqe->cpuTime;
        currentResponse.magic = magic;
        currentResponse.cpuTime = cpuTime;
        if (currentResponse.magic == cqeMagicId) {
          if (currentResponse.cpuTime != 0) {
            if (currentResponse.cpuTime !=
                    lastCpuTime ||
                lastCpuTime == 0) {
              break;
            }
          }
        }
      }
      lastResponse = currentResponse;
      lastCpuTime = currentResponse.cpuTime;

      unsigned long long endTime = wall_clock64();
      if (myEndTimes != nullptr) {
        myEndTimes[i] = endTime;
      } else if (timingStats != nullptr &&
                 startTime > 0 &&
                 endTime > startTime) {
        unsigned long long int duration =
          endTime - startTime;
        updateTimingStats(timingStats, duration);
      }

      if (doVerify) {
        uint32_t iterSeed = baseSeed + i;
        xio::DataPatternParams vp{
          reinterpret_cast<uint8_t*>(
            &mySqe->data[1]),
          4 * sizeof(uint64_t), 0,
          static_cast<uint32_t>(
            4 * sizeof(uint64_t)),
          iterSeed, nullptr};
        if (xio::dataPattern(true, vp)) {
          if (verifyPass)
            atomicAdd(verifyPass, 1u);
        } else {
          if (verifyFail)
            atomicAdd(verifyFail, 1u);
        }
      }
    }
  }

  // Synchronize threads before returning
  if (numThreads > 1) {
    __syncthreads();
  }
}

// CPU emulation of endpoint kernel - runs kernel logic on CPU threads
static void endpoint_kernel_cpu_emulate(
  sqeType* sqePtr, cqeType* cqePtr, unsigned long long int* startTimes,
  unsigned long long int* endTimes, XioTimingStats* timingStats,
  unsigned iterations, unsigned numThreads, long long delayNs,
  unsigned doorbell, uint32_t* doorbellAddr, unsigned queueSize,
  unsigned threadId) {
  // Use per-thread buffers if multi-threaded (non-doorbell mode)
  bool doorbellMode = (doorbell > 0);
  sqeType* mySqe = (numThreads > 1 && !doorbellMode) ? &sqePtr[threadId]
                                                     : sqePtr;
  cqeType* myCqe = (numThreads > 1 && !doorbellMode) ? &cqePtr[threadId]
                                                     : cqePtr;
  volatile cqeType* volatileCqe = myCqe;

  // Get per-thread timing arrays if provided
  unsigned long long int* myStartTimes = nullptr;
  unsigned long long int* myEndTimes = nullptr;
  if (startTimes != nullptr) {
    myStartTimes = &startTimes[threadId * iterations];
  }
  if (endTimes != nullptr) {
    myEndTimes = &endTimes[threadId * iterations];
  }

  cqeType lastResponse = {};
  lastResponse.magic = 0; // Initialize to invalid value
  cqeType currentResponse = {};
  uint64_t lastCpuTime = 0;

  if (doorbellMode) {
    // Doorbell mode: write SQEs to circular queue and ring doorbell
    // Use atomic counter for sequence numbers across all threads
    // Note: This is per-thread-call, so we need to synchronize initialization
    static std::atomic<uint32_t> globalSeq{0};
    // Use a barrier to synchronize threads before doorbell updates
    static std::atomic<uint32_t> barrierCounter{0};
    static std::atomic<uint32_t> barrierGeneration{0};
    // Reset sequence counter at start of first iteration for first thread
    if (threadId == 0 && iterations > 0) {
      globalSeq.store(0, std::memory_order_relaxed);
      barrierCounter.store(0, std::memory_order_relaxed);
      barrierGeneration.store(0, std::memory_order_relaxed);
    }

    for (unsigned i = 0; i < iterations; ++i) {
      // Record start time for this iteration (when SQE is posted)
      // Use CPU time instead of GPU wall clock in emulation mode
      uint64_t pollStartTime = getCpuTime();
      uint64_t startTime = 0;
      if (myStartTimes != nullptr) {
        myStartTimes[i] = pollStartTime;
      } else if (timingStats != nullptr) {
        startTime = pollStartTime;
      }

      // Prepare message to CPU
      sqeType msg = {};
      msg.magic = magicId;
      msg.iteration = ((uint64_t)threadId << 32) | i;
      uint64_t sqeGpuTime = getCpuTime(); // Use CPU time in emulation
      msg.gpuTime = sqeGpuTime;

      // Calculate delay
      uint64_t actualDelayNs = 0;
      if (delayNs < 0) {
        actualDelayNs = static_cast<uint64_t>(-delayNs);
      } else if (delayNs > 0) {
        uint64_t seed = threadId * 0x9e3779b9ULL + i * 0x6c6229e6ULL +
                        getCpuTime();
        seed = (seed * 1103515245ULL + 12345ULL) & 0x7FFFFFFFULL;
        actualDelayNs = seed % (static_cast<uint64_t>(delayNs) + 1);
      }
      msg.data[0] = actualDelayNs;

      // Fill remaining data payload
      for (int j = 1; j < 5; ++j) {
        msg.data[j] = 0x123456789ABCDEF0ULL + threadId + i + j;
      }

      // Get next sequence number atomically
      uint32_t seq = globalSeq.fetch_add(1);
      unsigned sqeIndex = seq % queueSize;

      // Write SQE
      sqePtr[sqeIndex] = msg;
      std::atomic_thread_fence(std::memory_order_release);

      // Barrier: wait for all threads to write their SQEs before ringing
      // doorbell Use a simple counter-based barrier optimized for low latency
      uint32_t gen = barrierGeneration.load(std::memory_order_acquire);
      uint32_t count = barrierCounter.fetch_add(1, std::memory_order_acq_rel) +
                       1;
      if (count == numThreads) {
        // Last thread to arrive - reset counter and advance generation
        barrierCounter.store(0, std::memory_order_release);
        barrierGeneration.store(gen + 1, std::memory_order_release);
      } else {
        // Wait for all threads to arrive - spin briefly then yield
        // Most threads should arrive quickly, so we spin first for low latency
        for (uint32_t spin = 0; spin < 50; ++spin) {
          if (barrierGeneration.load(std::memory_order_acquire) != gen) {
            goto barrier_done;
          }
          std::atomic_signal_fence(std::memory_order_acq_rel);
        }
        // If still waiting after spinning, yield to avoid wasting CPU
        while (barrierGeneration.load(std::memory_order_acquire) == gen) {
          std::this_thread::yield();
        }
      barrier_done:;
      }

      // Ring doorbell after all threads in this iteration have submitted their
      // SQE (tail = (i + 1) * numThreads)
      // Only thread 0 updates doorbell
      if (doorbellAddr != nullptr && threadId == 0) {
        uint32_t tail = (i + 1) * numThreads;
        std::atomic<uint32_t>* doorbellPtr =
          reinterpret_cast<std::atomic<uint32_t>*>(doorbellAddr);
        doorbellPtr->store(tail, std::memory_order_release);
        std::atomic_thread_fence(std::memory_order_seq_cst);
      }

      // Poll for CPU response in CQE queue (use same sequence number as SQE)
      unsigned cqeIndex = seq % queueSize;
      volatile cqeType* myCqePtr = &cqePtr[cqeIndex];
      uint32_t expectedSeq = seq;

      // Poll with minimal backoff to reduce CPU spinning while maintaining low
      // latency
      uint32_t spinCount = 0;
      while (true) {
        uint64_t magic = myCqePtr->magic;
        uint64_t cqeValue = myCqePtr->cpuTime;
        currentResponse.magic = magic;
        currentResponse.cpuTime = cqeValue;
        if (currentResponse.magic == cqeMagicId) {
          if (cqeValue != 0) {
            // Verify CQE corresponds to our SQE by checking sequence number
            // matches
            uint32_t cqeSeq = (cqeValue >> 32) & 0xFFFFFFFFULL;
            uint64_t cqeCpuTime = cqeValue & 0xFFFFFFFFULL;
            if (cqeSeq == expectedSeq &&
                (cqeCpuTime != (lastCpuTime & 0xFFFFFFFFULL) ||
                 lastCpuTime == 0)) {
              // Record time immediately when valid CQE is detected
              uint64_t endTime = getCpuTime();
              if (myEndTimes != nullptr) {
                myEndTimes[i] = endTime;
              } else if (timingStats != nullptr && startTime > 0 &&
                         endTime > startTime) {
                unsigned long long int duration = endTime - startTime;
                updateTimingStats(timingStats, duration);
              }
              break;
            }
          }
        }
        // Minimal spinning then yield to reduce CPU usage
        if (spinCount < 100) {
          spinCount++;
          std::atomic_signal_fence(std::memory_order_acq_rel);
        } else {
          std::this_thread::yield();
        }
      }
      lastResponse = currentResponse;
      lastCpuTime = currentResponse.cpuTime;
    }
  } else {
    // Normal polling mode
    for (unsigned i = 0; i < iterations; ++i) {
      // Record start time for this iteration
      uint64_t pollStartTime = getCpuTime();
      uint64_t startTime = 0;
      if (myStartTimes != nullptr) {
        myStartTimes[i] = pollStartTime;
      } else if (timingStats != nullptr) {
        startTime = pollStartTime;
      }

      // Prepare message to CPU
      sqeType msg = {};
      msg.magic = magicId;
      msg.iteration = ((uint64_t)threadId << 32) | i;
      msg.gpuTime = getCpuTime(); // Use CPU time in emulation

      // Calculate delay
      uint64_t actualDelayNs = 0;
      if (delayNs < 0) {
        actualDelayNs = static_cast<uint64_t>(-delayNs);
      } else if (delayNs > 0) {
        uint64_t seed = threadId * 0x9e3779b9ULL + i * 0x6c6229e6ULL +
                        getCpuTime();
        seed = (seed * 1103515245ULL + 12345ULL) & 0x7FFFFFFFULL;
        actualDelayNs = seed % (static_cast<uint64_t>(delayNs) + 1);
      }
      msg.data[0] = actualDelayNs;

      // Fill remaining data payload
      for (int j = 1; j < 5; ++j) {
        msg.data[j] = 0x123456789ABCDEF0ULL + threadId + i + j;
      }

      // Write message to memory
      *mySqe = msg;
      std::atomic_thread_fence(std::memory_order_release);

      // Poll for CPU response
      while (true) {
        uint64_t magic = volatileCqe->magic;
        uint64_t cpuTime = volatileCqe->cpuTime;
        currentResponse.magic = magic;
        currentResponse.cpuTime = cpuTime;
        if (currentResponse.magic == cqeMagicId) {
          if (currentResponse.cpuTime != 0) {
            if (currentResponse.cpuTime != lastCpuTime || lastCpuTime == 0) {
              break;
            }
          }
        }
      }
      lastResponse = currentResponse;
      lastCpuTime = currentResponse.cpuTime;

      // Record time when CPU response is received
      uint64_t endTime = getCpuTime();
      if (myEndTimes != nullptr) {
        myEndTimes[i] = endTime;
      } else if (timingStats != nullptr && startTime > 0 &&
                 endTime > startTime) {
        unsigned long long int duration = endTime - startTime;
        updateTimingStats(timingStats, duration);
      }
    }
  }
}

hipError_t run(XioEndpointConfig* config) {
  std::vector<std::thread> cpuThreadHandles;

  // Get test-ep specific config
  TestEpConfig* testEpConfig = static_cast<TestEpConfig*>(
    config->endpointConfig);
  unsigned doorbell = (testEpConfig != nullptr) ? testEpConfig->doorbell : 0;
  bool emulate = (testEpConfig != nullptr) ? testEpConfig->emulate : false;

  // Cast void* to endpoint-specific types
  sqeType* sqePtr = static_cast<sqeType*>(config->submissionQueue);
  cqeType* cqePtr = static_cast<cqeType*>(config->completionQueue);

  // Doorbell mode setup
  void* doorbellAddr = nullptr;
  unsigned queueSize = doorbell; // Use doorbell value as queue size
  if (doorbell > 0) {
    // Allocate doorbell (bit 2 of memoryMode: 0=host, 1=device)
    bool doorbellOnDevice = (config->memoryMode & 0x4) != 0;
    if (doorbellOnDevice) {
      // Allocate device memory for doorbell
      const size_t host_page_size = sysconf(_SC_PAGESIZE);
      size_t alignedSize = ((sizeof(uint32_t) + host_page_size - 1) /
                            host_page_size) *
                           host_page_size;
      hsa_status_t hsa_status = allocDeviceMemory(alignedSize, &doorbellAddr,
                                                  "Doorbell");
      if (hsa_status != HSA_STATUS_SUCCESS) {
        std::cerr << "Error: Failed to allocate doorbell in device memory"
                  << std::endl;
        return hipErrorMemoryAllocation;
      }
      memset(doorbellAddr, 0, sizeof(uint32_t));
    } else {
      hipError_t hipErr = xio::allocHostMemory(sizeof(uint32_t),
                                               (void**)&doorbellAddr,
                                               "doorbell", XIO_HOST_MEM_MAPPED);
      if (hipErr != hipSuccess) {
        std::cerr << "Error: Failed to allocate doorbell memory" << std::endl;
        return hipErrorMemoryAllocation;
      }
    }
  }

  // Get doorbell pointer for use in both modes
  uint32_t* doorbellPtr = static_cast<uint32_t*>(doorbellAddr);

  // Reset doorbell before launching threads (needed for both modes)
  if (doorbell > 0 && doorbellPtr != nullptr) {
    *doorbellPtr = 0;
    std::atomic_thread_fence(std::memory_order_seq_cst);
  }

  if (config->numThreads > 0) {
    // Check hardware concurrency for CPU threads
    unsigned hardwareThreads = std::thread::hardware_concurrency();
    if (config->numThreads > hardwareThreads && doorbell == 0) {
      // Warning: requested more CPU threads than available (not applicable in
      // doorbell mode)
    }

    // Launch CPU threads via launcher
    cpuThreadHandles = launchCpuThreads(config->submissionQueue,
                                        config->completionQueue,
                                        config->numThreads, config->iterations,
                                        config->delayNs, doorbell, doorbellAddr,
                                        queueSize);

    // Small delay to ensure CPU threads are ready
    std::this_thread::sleep_for(std::chrono::microseconds(100));
  }

  hipError_t err = hipSuccess;

  if (emulate) {
    // Emulation mode: run kernel logic on CPU threads instead of GPU
    std::vector<std::thread> gpuEmulationThreads;

    // Launch CPU threads to emulate GPU kernel
    for (unsigned t = 0; t < config->numThreads; ++t) {
      gpuEmulationThreads.emplace_back(endpoint_kernel_cpu_emulate, sqePtr,
                                       cqePtr, config->startTimes,
                                       config->endTimes, config->timingStats,
                                       config->iterations, config->numThreads,
                                       config->delayNs, doorbell, doorbellPtr,
                                       queueSize, t);
    }

    // Wait for all emulation threads to complete
    for (auto& thread : gpuEmulationThreads) {
      thread.join();
    }
  } else {
    uint32_t* doorbellPtr =
      static_cast<uint32_t*>(doorbellAddr);
    uint32_t* d_vPass = nullptr;
    uint32_t* d_vFail = nullptr;
    if (testEpConfig->verify) {
      (void)hipHostMalloc(&d_vPass,
                          sizeof(uint32_t),
                          hipHostMallocMapped);
      (void)hipHostMalloc(&d_vFail,
                          sizeof(uint32_t),
                          hipHostMallocMapped);
      if (d_vPass) *d_vPass = 0;
      if (d_vFail) *d_vFail = 0;
    }

    hipLaunchKernelGGL(endpoint_kernel, dim3(1),
                       dim3(config->numThreads), 0, 0,
                       sqePtr, cqePtr,
                       config->startTimes,
                       config->endTimes,
                       config->timingStats,
                       config->iterations,
                       config->numThreads,
                       config->delayNs, doorbell,
                       doorbellPtr, queueSize,
                       config->stopRequested,
                       testEpConfig->verify,
                       testEpConfig->seed,
                       d_vPass, d_vFail);

    err = hipGetLastError();
    if (err != hipSuccess) {
      for (auto& thread : cpuThreadHandles)
        thread.join();
      if (d_vPass) (void)hipHostFree(d_vPass);
      if (d_vFail) (void)hipHostFree(d_vFail);
      return err;
    }

    err = hipDeviceSynchronize();
    if (err != hipSuccess) {
      for (auto& thread : cpuThreadHandles)
        thread.join();
      if (d_vPass) (void)hipHostFree(d_vPass);
      if (d_vFail) (void)hipHostFree(d_vFail);
      return err;
    }

    if (testEpConfig->verify && d_vPass && d_vFail) {
      config->verifyPass = *d_vPass;
      config->verifyFail = *d_vFail;
    }
    if (d_vPass) (void)hipHostFree(d_vPass);
    if (d_vFail) (void)hipHostFree(d_vFail);
  }

  // Join CPU threads if they were launched
  for (auto& thread : cpuThreadHandles) {
    thread.join();
  }

  // Free doorbell if allocated
  if (doorbellAddr != nullptr) {
    bool doorbellOnDevice = (config->memoryMode & 0x4) != 0;
    if (doorbellOnDevice) {
      hsa_memory_free(doorbellAddr);
    } else {
      xio::freeHostMemory(doorbellAddr, XIO_HOST_MEM_MAPPED);
    }
  }

  return hipSuccess;
}

} // namespace xio::test_ep
