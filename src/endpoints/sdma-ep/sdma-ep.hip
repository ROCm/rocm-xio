/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstdint>
#include <cstring>
#include <iostream>
#include <map>
#include <vector>

#include <hip/hip_ext.h>
#include <hip/hip_runtime.h>

#include "anvil.hpp"
#include "anvil_device.hpp"
#include "sdma-ep.h"
#include "xio.h"

using namespace xio;

// Discard HIP return values in cleanup paths to satisfy nodiscard
static void ignoreHip(hipError_t e) {
  (void)e;
}

// LFSR for deterministic fill/verify: 32-bit maximal-length (polynomial
// x^32+x^22+x^2+x+1). Seed advances per iteration so each transfer chunk is
// verifiable.
static constexpr uint32_t kLfsrSeed = 0x12345678u;

static inline uint32_t lfsr_next(uint32_t s) {
  const uint32_t tap = 0x80200003u;
  return (s >> 1) ^ ((s & 1u) ? tap : 0u);
}

static inline uint32_t lfsr_advance(uint32_t s, unsigned n) {
  for (unsigned i = 0; i < n; i++)
    s = lfsr_next(s);
  return s;
}

// Fill size bytes (must be multiple of 4) with LFSR output starting at state.
static void lfsr_fill_chunk(void* buf, size_t size, uint32_t state) {
  uint32_t* p = static_cast<uint32_t*>(buf);
  size_t n = size / sizeof(uint32_t);
  for (size_t i = 0; i < n; i++) {
    p[i] = state;
    state = lfsr_next(state);
  }
}

// SDMA endpoint implementation using anvil library for hardware access
namespace sdma_ep {

// Initialize the anvil library singleton
static bool anvil_initialized = false;

void ensureAnvilInit() {
  if (!anvil_initialized) {
    anvil::AnvilLib::getInstance().init();
    anvil_initialized = true;
  }
}

} // namespace sdma_ep

// Single-thread kernel: one thread does all transfers to avoid queue
// contention (multi-thread submit can stall on anvil's committedWptr ordering).
__global__ void sdma_p2p_kernel(anvil::SdmaQueueDeviceHandle* handle,
                                void* dstBuf, void* srcBuf, size_t transferSize,
                                unsigned iterations, uint64_t* signal,
                                unsigned long long* startTimes,
                                unsigned long long* endTimes) {
  for (unsigned i = 0; i < iterations; i++) {
    size_t offset = i * transferSize;
    void* src = static_cast<char*>(srcBuf) + offset;
    void* dst = static_cast<char*>(dstBuf) + offset;

    if (startTimes != nullptr) {
      startTimes[i] = wall_clock64();
    }

    if (i == iterations - 1) {
      anvil::put_signal(*handle, dst, src, transferSize, signal);
    } else {
      anvil::put(*handle, dst, src, transferSize);
    }

    if (endTimes != nullptr) {
      endTimes[i] = wall_clock64();
    }
  }
  // Kernel waits for SDMA completion so host can rely on hipDeviceSynchronize
  if (iterations > 0) {
    anvil::waitSignal(signal, 1);
  }
}

// Ping-pong kernel to test latency of put, signal, quiet
// quiet can be substituted by local counter or flush
__global__ void sdma_ping_pong_kernel(anvil::SdmaQueueDeviceHandle* handle,
                                      void* dstBuf, void* srcBuf, size_t nElem,
                                      unsigned iterations, uint64_t** signals,
                                      int rank, uint64_t* counter,
                                      bool use_counter, bool use_flush,
                                      unsigned long long* startTimes,
                                      unsigned long long* endTimes) {
  if (rank > 1)
    return;

  // Maintain local copy of SDMA handle
  // This is required if the handle is shared across multiple waves or
  // threadblocks
  anvil::SdmaQueueDeviceHandle sdma_handle = *handle;

  int rank1_offset = 1000000;

  int* src = static_cast<int*>(srcBuf);
  int* dst = static_cast<int*>(dstBuf);

  uint64_t* local_signal = signals[rank];
  uint64_t* remote_signal = signals[1 - rank];
  // Use value to track index of put operation
  // This is an advanced optimization
  uint64_t put_index = 0;

  for (unsigned i = 0; i < iterations; i++) {
    // Initiator
    if (rank == 0) {
      if (threadIdx.x == 0) {
        if (startTimes != nullptr) {
          startTimes[i] = wall_clock64();
        }
      }
      // Populate src buffer
      for (size_t j = threadIdx.x; j < nElem; j += blockDim.x) {
        src[j] = i + j + 42;
      }
      __syncthreads();
      __threadfence_system();
      // Have thread 0 trigger the SDMA
      if (threadIdx.x == 0) {
        if (use_counter) {
          anvil::put_signal_counter(sdma_handle, dst, src, nElem * sizeof(int),
                                    remote_signal, counter);
        } else if (use_flush) {
          anvil::put_signal_counter_impl<true, true, false>(
            sdma_handle, dst, src, nElem * sizeof(int), remote_signal,
            /* counter*/ nullptr, &put_index);
        } else {
          anvil::put_signal(sdma_handle, dst, src, nElem * sizeof(int),
                            remote_signal);
        }
      }

      // Flush for benchmarking purpose
      if (threadIdx.x == 0) {
        if (use_counter) {
          anvil::waitCounter(counter, i + 1);
        } else if (use_flush) {
          anvil::flush(sdma_handle, put_index);
        } else {
          anvil::quiet(sdma_handle);
        }
      }

      // Wait for signal
      if (threadIdx.x == 0) {
        anvil::waitSignal(local_signal, (i + 1));
      }
      __syncthreads();

      if (endTimes != nullptr) {
        endTimes[i] = wall_clock64();
      }

      // Check if received values are correct
      for (size_t j = threadIdx.x; j < nElem; j += blockDim.x) {
        int expected_value = static_cast<int>(rank1_offset + i + j + 42);
        if (src[j] != expected_value) {
          printf("[SDMA-EP] rank 1 Error: buffer[%zu] = %d, expected %d\n", j,
                 src[j], expected_value);
        }
      }
    }

    // Responder
    if (rank == 1) {
      // Have thread 0 wait for signal
      if (threadIdx.x == 0) {
        anvil::waitSignal(local_signal, (i + 1));
      }
      __syncthreads();

      // Check if received values are correct
      for (size_t j = threadIdx.x; j < nElem; j += blockDim.x) {
        int expected_value = static_cast<int>(i + j + 42);
        if (src[j] != expected_value) {
          printf("[SDMA-EP] rank 1 Error: buffer[%zu] = %d, expected %d\n", j,
                 src[j], expected_value);
        }
        // Update values to send them back
        src[j] += rank1_offset;
      }
      __syncthreads();
      __threadfence_system();

      // Signal that rank1 is ready for next iteration
      if (threadIdx.x == 0) {
        if (use_counter) {
          anvil::put_signal_counter(sdma_handle, dst, src, nElem * sizeof(int),
                                    remote_signal, counter);
        } else if (use_flush) {
          anvil::put_signal_counter_impl<true, true, false>(
            sdma_handle, dst, src, nElem * sizeof(int), remote_signal,
            /* counter */ nullptr, &put_index);

        } else {
          anvil::put_signal(sdma_handle, dst, src, nElem * sizeof(int),
                            remote_signal);
        }
      }

      // Flush for benchmarking purpose
      if (threadIdx.x == 0) {
        if (use_counter) {
          anvil::waitCounter(counter, i + 1);
        } else if (use_flush) {
          anvil::flush(sdma_handle, put_index);
        } else {
          anvil::quiet(sdma_handle);
        }
      }
    }

  } // iteration
}

// Kernel that sends data from rank0 to rank1
// rank0 is re-using the same buffer for `transfers_per_iteration` iterations
// This kernel tests the different variations to determine that the source
// buffer can be re-used
__global__ void sdma_buffer_reuse_kernel(
  anvil::SdmaQueueDeviceHandle* handle, void* dstBuf, void* srcBuf,
  size_t nElem, unsigned iterations, uint64_t** signals, int rank,
  uint64_t* counter, bool use_counter, bool use_flush,
  unsigned long long* startTimes, unsigned long long* endTimes) {
  if (rank > 1)
    return;

  // Maintain local copy of SDMA handle
  // This is required if the handle is shared across multiple waves or
  // threadblocks
  anvil::SdmaQueueDeviceHandle sdma_handle = *handle;

  unsigned transfers_per_iteration = 10;

  int* src = static_cast<int*>(srcBuf);
  int* dst = static_cast<int*>(dstBuf);

  uint64_t* local_signal = signals[rank];
  uint64_t* remote_signal = signals[1 - rank];

  // Use value to track index of put operation
  // This is an advanced optimization
  uint64_t put_index = 0;

  for (unsigned i = 0; i < iterations; i++) {
    // if (startTimes != nullptr) {
    //   startTimes[i] = wall_clock64();
    // }

    int offset = 0;

    // Initiator
    if (rank == 0) {
      for (unsigned t = 0; t < transfers_per_iteration; t++) {
        // Populate src buffer
        for (size_t j = threadIdx.x; j < nElem; j += blockDim.x) {
          src[j] = i + (t * nElem) + j + 42;
        }
        __syncthreads();
        __threadfence_system();
        // Have thread 0 trigger the SDMA
        if (threadIdx.x == 0) {
          if (t == (transfers_per_iteration - 1)) {
            if (use_counter) {
              anvil::put_signal_counter(sdma_handle, dst + offset, src,
                                        nElem * sizeof(int), remote_signal,
                                        counter);

            } else if (use_flush) {
              anvil::put_signal_counter_impl<true, true, false>(
                sdma_handle, dst + offset, src, nElem * sizeof(int),
                remote_signal, /*counter*/ nullptr, &put_index);
            } else {
              anvil::put_signal(sdma_handle, dst + offset, src,
                                nElem * sizeof(int), remote_signal);
            }
          } else {
            if (use_counter) {
              anvil::put_counter(sdma_handle, dst + offset, src,
                                 nElem * sizeof(int), counter);
            } else if (use_flush) {
              anvil::put_signal_counter_impl<true, false, false>(
                sdma_handle, dst + offset, src, nElem * sizeof(int),
                /* signal*/ nullptr, /*counter*/ nullptr, &put_index);
            } else {
              anvil::put(sdma_handle, dst + offset, src, nElem * sizeof(int));
            }
          }
        }
        // Wait for buffer re-use
        if (threadIdx.x == 0) {
          if (use_counter) {
            anvil::waitCounter(counter, (i * transfers_per_iteration) + t + 1);
          } else if (use_flush) {
            anvil::flush(sdma_handle, put_index);
          } else {
            anvil::quiet(sdma_handle);
          }
        }
        __syncthreads();
        offset += nElem;
      }

      // Wait for signal
      if (threadIdx.x == 0) {
        anvil::waitSignal(local_signal, (i + 1));
      }
    }

    // Responder
    if (rank == 1) {
      // Have thread 0 wait for padding
      if (threadIdx.x == 0) {
        anvil::waitSignal(local_signal, (i + 1));
      }
      __syncthreads();

      // Check if received values are correct
      for (unsigned t = 0; t < transfers_per_iteration; t++) {
        for (size_t j = threadIdx.x; j < nElem; j += blockDim.x) {
          int expected_value = static_cast<int>(i + (t * nElem) + j + 42);
          if (src[j + offset] != expected_value) {
            printf("[SDMA-EP] rank 1 Error: buffer[%zu] = %d, expected %d\n",
                   j + offset, src[j + offset], expected_value);
          }
        }
        offset += nElem;
      }

      // Signal that rank1 is ready for next iteration
      __syncthreads();
      if (threadIdx.x == 0) {
        anvil::signal(sdma_handle, remote_signal);
      }
    }
    // if (endTimes != nullptr) {
    //   endTimes[i] = wall_clock64();
    // }
  }
}

// SDMA-ep run function - sets up real hardware SDMA queues
hipError_t sdma_ep_run(XioEndpointConfig* config) {
  hipError_t err;

  // Initialize anvil library for hardware SDMA access
  try {
    sdma_ep::ensureAnvilInit();
  } catch (const std::exception& e) {
    std::cerr << "Failed to initialize anvil library: " << e.what()
              << std::endl;
    return hipErrorInitializationError;
  }

  bool useHostDst = false;
  bool verifyData = false;
  int cfgSrc = -1;
  int cfgDst = -1;
  size_t transferSize = 4096;
  std::string testType = "";
  bool useCounter = false;
  bool useFlush = false;
  if (config->endpointConfig) {
    const auto* epConfig = static_cast<const sdma_ep::SdmaEpConfig*>(
      config->endpointConfig);
    testType = epConfig->testType;
    useHostDst = epConfig->useHostDst;
    verifyData = epConfig->verifyData;
    cfgSrc = epConfig->srcDeviceId;
    cfgDst = epConfig->dstDeviceId;
    transferSize = epConfig->transferSize;
    useCounter = epConfig->useCounter;
    useFlush = epConfig->useFlush;
  }

  int numGpus = 0;
  err = hipGetDeviceCount(&numGpus);
  if (err != hipSuccess || numGpus < 1) {
    std::cerr << "SDMA endpoint requires at least 1 GPU, found: " << numGpus
              << std::endl;
    return hipErrorInvalidDevice;
  }
  if (!useHostDst && numGpus < 2) {
    std::cerr << "SDMA P2P mode requires at least 2 GPUs (use --to-host for "
                 "single GPU)"
              << std::endl;
    return hipErrorInvalidDevice;
  }

  // Use configured device IDs; -1 means default (src=0, dst=1 for P2P; 0 for
  // --to-host).
  int srcGpu = (cfgSrc >= 0) ? cfgSrc : 0;
  int dstGpu = useHostDst ? 0 : ((cfgDst >= 0) ? cfgDst : 1);
  if (srcGpu < 0 || srcGpu >= numGpus) {
    std::cerr << "SDMA source GPU " << srcGpu << " out of range [0, " << numGpus
              << ")" << std::endl;
    return hipErrorInvalidDevice;
  }
  if (dstGpu < 0 || dstGpu >= numGpus) {
    std::cerr << "SDMA destination GPU " << dstGpu << " out of range [0, "
              << numGpus << ")" << std::endl;
    return hipErrorInvalidDevice;
  }
  if (!useHostDst && srcGpu == dstGpu) {
    std::cerr << "SDMA P2P requires different source and destination GPUs"
              << std::endl;
    return hipErrorInvalidDevice;
  }

  // Print GPU arch, UUID, and PCIe address for the GPU(s) used
  std::cout << "SDMA source GPU:" << std::endl;
  printGpuDeviceDetails(srcGpu);
  if (!useHostDst) {
    std::cout << "SDMA destination GPU:" << std::endl;
    printGpuDeviceDetails(dstGpu);
  }
  std::cout << "Transfer size: " << transferSize << " bytes x "
            << config->iterations << " iterations" << std::endl;
  if (useHostDst) {
    std::cout << "SDMA transfer: GPU " << srcGpu << " -> pinned host memory"
              << std::endl;
  } else {
    std::cout << "SDMA P2P transfer: GPU " << srcGpu << " -> GPU " << dstGpu
              << std::endl;
    int canAccess = 0;
    err = hipDeviceCanAccessPeer(&canAccess, srcGpu, dstGpu);
    if (err != hipSuccess) {
      std::cerr << "hipDeviceCanAccessPeer failed: " << hipGetErrorString(err)
                << std::endl;
      return err;
    }
    if (canAccess == 0) {
      std::cerr << "P2P not available: GPU " << srcGpu << " cannot access GPU "
                << dstGpu << " (hipDeviceCanAccessPeer returned 0)"
                << std::endl;
      return hipErrorInvalidDevice;
    }
    anvil::EnablePeerAccess(srcGpu, dstGpu);

    // For buffer-reuse and ping-pong, enable bidirectional peer access
    if (testType == "buffer-reuse" || testType == "ping-pong") {
      int canAccessReverse = 0;
      err = hipDeviceCanAccessPeer(&canAccessReverse, dstGpu, srcGpu);
      if (err != hipSuccess) {
        std::cerr << "hipDeviceCanAccessPeer (reverse) failed: "
                  << hipGetErrorString(err) << std::endl;
        return err;
      }
      if (canAccessReverse == 0) {
        std::cerr << "P2P not available: GPU " << dstGpu
                  << " cannot access GPU " << srcGpu
                  << " (hipDeviceCanAccessPeer returned 0)" << std::endl;
        return hipErrorInvalidDevice;
      }
      anvil::EnablePeerAccess(dstGpu, srcGpu);
    }
  }

  // Create bidirectional SDMA connections and queues
  try {
    bool success = anvil::AnvilLib::getInstance().connect(srcGpu, dstGpu, 1);
    if (!success) {
      std::cerr << "Failed to connect SDMA (src=" << srcGpu
                << ", dst=" << dstGpu << ")" << std::endl;
      return hipErrorInvalidDevice;
    }

    success = anvil::AnvilLib::getInstance().connect(dstGpu, srcGpu, 1);
    if (!success) {
      std::cerr << "Failed to connect SDMA (src=" << dstGpu
                << ", dst=" << srcGpu << ")" << std::endl;
      return hipErrorInvalidDevice;
    }
  } catch (const std::exception& e) {
    std::cerr << "SDMA connect error: " << e.what() << std::endl;
    return hipErrorInvalidDevice;
  }

  // Store SDMA queue handles in a map indexed by rank
  std::map<int, anvil::SdmaQueueDeviceHandle*> sdmaHandles;

  try {
    anvil::SdmaQueue* queue0 =
      anvil::AnvilLib::getInstance().getSdmaQueue(srcGpu, dstGpu, 0);
    if (queue0 == nullptr) {
      std::cerr << "Failed to get SDMA queue (rank 0: " << srcGpu << " -> "
                << dstGpu << ")" << std::endl;
      return hipErrorInvalidValue;
    }
    sdmaHandles[0] = queue0->deviceHandle();

    anvil::SdmaQueue* queue1 =
      anvil::AnvilLib::getInstance().getSdmaQueue(dstGpu, srcGpu, 0);
    if (queue1 == nullptr) {
      std::cerr << "Failed to get SDMA queue (rank 1: " << dstGpu << " -> "
                << srcGpu << ")" << std::endl;
      return hipErrorInvalidValue;
    }
    sdmaHandles[1] = queue1->deviceHandle();
  } catch (const std::exception& e) {
    std::cerr << "SDMA queue error: " << e.what() << std::endl;
    return hipErrorInvalidValue;
  }

  // Set device for memory allocations
  err = hipSetDevice(srcGpu);
  if (err != hipSuccess)
    return err;

  // Calculate buffer sizes (transferSize from config, validated by endpoint)
  size_t totalSize = transferSize * config->iterations * 10;
  // if (testType == "buffer-reuse") {
  //   totalSize = transferSize * 10;
  // }

  // Allocate source buffer on source GPU (uncached for P2P to match RAD)
  void* srcBuf = nullptr;
  if (useHostDst) {
    err = hipMalloc(&srcBuf, totalSize);
  } else {
    err = hipExtMallocWithFlags(&srcBuf, totalSize, hipDeviceMallocUncached);
  }
  if (err != hipSuccess) {
    std::cerr << "Failed to allocate source buffer" << std::endl;
    return err;
  }

  // Initialize source buffer with LFSR pattern (seed advances per iteration)
  const size_t dwordsPerChunk = transferSize / sizeof(uint32_t);
  std::vector<uint32_t> hostChunk(dwordsPerChunk);
  for (unsigned i = 0; i < config->iterations; i++) {
    uint32_t state = lfsr_advance(kLfsrSeed, i * dwordsPerChunk);
    lfsr_fill_chunk(hostChunk.data(), transferSize, state);
    err = hipMemcpy(static_cast<char*>(srcBuf) + i * transferSize,
                    hostChunk.data(), transferSize, hipMemcpyHostToDevice);
    if (err != hipSuccess) {
      ignoreHip(hipFree(srcBuf));
      return err;
    }
  }

  void* dstBuf = nullptr;
  if (useHostDst) {
    err = hipHostMalloc(&dstBuf, totalSize, hipHostMallocDefault);
    if (err != hipSuccess) {
      std::cerr << "Failed to allocate pinned host destination buffer"
                << std::endl;
      ignoreHip(hipFree(srcBuf));
      return err;
    }
    std::memset(dstBuf, 0, totalSize);
  } else {
    err = hipSetDevice(dstGpu);
    if (err != hipSuccess) {
      ignoreHip(hipFree(srcBuf));
      return err;
    }
    err = hipExtMallocWithFlags(&dstBuf, totalSize, hipDeviceMallocUncached);
    if (err != hipSuccess) {
      std::cerr << "Failed to allocate destination buffer" << std::endl;
      ignoreHip(hipFree(srcBuf));
      return err;
    }
    err = hipMemset(dstBuf, 0, totalSize);
    if (err != hipSuccess) {
      ignoreHip(hipFree(dstBuf));
      ignoreHip(hipFree(srcBuf));
      return err;
    }
  }

  // Helper lambda for cleanup (defined early so it can be used in error paths)
  auto cleanupBuffers = [&]() {
    if (useHostDst) {
      ignoreHip(hipHostFree(dstBuf));
    } else {
      ignoreHip(hipSetDevice(dstGpu));
      ignoreHip(hipFree(dstBuf));
    }
    ignoreHip(hipSetDevice(srcGpu));
    ignoreHip(hipFree(srcBuf));
  };

  // Allocate completion signals - use uncached memory for P2P access
  // For buffer-reuse, signals map stores pointers to device arrays of signal
  // pointers For p2p, signals map stores individual signal pointers
  std::map<int, uint64_t**> signals;

  // Allocate individual signal memory on each GPU
  uint64_t* signal0 = nullptr;
  uint64_t* signal1 = nullptr;

  auto cleanupSignals = [&]() {
    // Free device signal arrays
    if (signals.count(0)) {
      ignoreHip(hipSetDevice(srcGpu));
      ignoreHip(hipFree(signals[0]));
    }
    if (signals.count(1)) {
      ignoreHip(hipSetDevice(dstGpu));
      ignoreHip(hipFree(signals[1]));
    }
    // Free individual signal memory
    if (signal1 != nullptr) {
      ignoreHip(hipSetDevice(dstGpu));
      ignoreHip(hipFree(signal1));
    }
    if (signal0 != nullptr) {
      ignoreHip(hipSetDevice(srcGpu));
      ignoreHip(hipFree(signal0));
    }
  };

  // Allocate signal on source GPU (rank 0)
  err = hipSetDevice(srcGpu);
  if (err != hipSuccess) {
    if (useHostDst) {
      ignoreHip(hipFree(dstBuf));
    } else {
      ignoreHip(hipSetDevice(dstGpu));
      ignoreHip(hipFree(dstBuf));
    }
    ignoreHip(hipFree(srcBuf));
    return err;
  }

  err = hipExtMallocWithFlags((void**)&signal0, sizeof(uint64_t),
                              hipDeviceMallocUncached);
  if (err != hipSuccess) {
    if (useHostDst) {
      ignoreHip(hipFree(dstBuf));
    } else {
      ignoreHip(hipSetDevice(dstGpu));
      ignoreHip(hipFree(dstBuf));
    }
    ignoreHip(hipFree(srcBuf));
    return err;
  }

  err = hipMemset(signal0, 0, sizeof(uint64_t));
  if (err != hipSuccess) {
    ignoreHip(hipFree(signal0));
    cleanupBuffers();
    return err;
  }

  // Allocate signal on destination GPU (rank 1)
  if (!useHostDst) {
    err = hipSetDevice(dstGpu);
    if (err != hipSuccess) {
      ignoreHip(hipSetDevice(srcGpu));
      ignoreHip(hipFree(signal0));
      cleanupBuffers();

      return err;
    }

    err = hipExtMallocWithFlags((void**)&signal1, sizeof(uint64_t),
                                hipDeviceMallocUncached);
    if (err != hipSuccess) {
      ignoreHip(hipSetDevice(srcGpu));
      ignoreHip(hipFree(signal0));
      cleanupBuffers();
      return err;
    }

    err = hipMemset(signal1, 0, sizeof(uint64_t));
    if (err != hipSuccess) {
      ignoreHip(hipFree(signal1));
      ignoreHip(hipSetDevice(srcGpu));
      ignoreHip(hipFree(signal0));
      cleanupBuffers();
      return err;
    }
  }

  // Create host array with signal pointers
  uint64_t* signalsHost[2] = {signal0, signal1};

  // Allocate device array on srcGpu and copy signal pointers
  err = hipSetDevice(srcGpu);
  if (err != hipSuccess) {
    ignoreHip(hipSetDevice(dstGpu));
    ignoreHip(hipFree(signal1));
    ignoreHip(hipSetDevice(srcGpu));
    ignoreHip(hipFree(signal0));
    cleanupBuffers();
    return err;
  }

  err = hipMalloc(&signals[0], 2 * sizeof(uint64_t*));
  if (err != hipSuccess) {
    ignoreHip(hipSetDevice(dstGpu));
    ignoreHip(hipFree(signal1));
    ignoreHip(hipSetDevice(srcGpu));
    ignoreHip(hipFree(signal0));
    cleanupBuffers();
    return err;
  }

  err = hipMemcpy(signals[0], signalsHost, 2 * sizeof(uint64_t*),
                  hipMemcpyHostToDevice);
  if (err != hipSuccess) {
    cleanupSignals();
    cleanupBuffers();
    return err;
  }

  // Allocate device array on dstGpu and copy signal pointers
  if (!useHostDst) {
    err = hipSetDevice(dstGpu);
    if (err != hipSuccess) {
      cleanupSignals();
      cleanupBuffers();
      return err;
    }

    err = hipMalloc(&signals[1], 2 * sizeof(uint64_t*));
    if (err != hipSuccess) {
      cleanupSignals();
      cleanupBuffers();
      return err;
    }

    err = hipMemcpy(signals[1], signalsHost, 2 * sizeof(uint64_t*),
                    hipMemcpyHostToDevice);
    if (err != hipSuccess) {
      ignoreHip(hipFree(signals[1]));
      cleanupSignals();
      cleanupBuffers();
      return err;
    }
  }

  // Allocate counters for buffer-reuse test (one per GPU)
  uint64_t* counter0 = nullptr;
  uint64_t* counter1 = nullptr;

  if (useCounter) {
    // Allocate counter on source GPU (rank 0)
    err = hipSetDevice(srcGpu);
    if (err != hipSuccess) {
      cleanupSignals();
      cleanupBuffers();
      return err;
    }

    err = hipExtMallocWithFlags((void**)&counter0, sizeof(uint64_t),
                                hipDeviceMallocUncached);
    if (err != hipSuccess) {
      cleanupSignals();
      cleanupBuffers();
      return err;
    }

    err = hipMemset(counter0, 0, sizeof(uint64_t));
    if (err != hipSuccess) {
      ignoreHip(hipFree(counter0));
      cleanupSignals();
      cleanupBuffers();
      return err;
    }

    // Allocate counter on destination GPU (rank 1)
    err = hipSetDevice(dstGpu);
    if (err != hipSuccess) {
      ignoreHip(hipSetDevice(srcGpu));
      ignoreHip(hipFree(counter0));
      cleanupSignals();
      cleanupBuffers();
      return err;
    }

    err = hipExtMallocWithFlags((void**)&counter1, sizeof(uint64_t),
                                hipDeviceMallocUncached);
    if (err != hipSuccess) {
      ignoreHip(hipSetDevice(srcGpu));
      ignoreHip(hipFree(counter0));
      cleanupSignals();
      cleanupBuffers();
      return err;
    }

    err = hipMemset(counter1, 0, sizeof(uint64_t));
    if (err != hipSuccess) {
      ignoreHip(hipFree(counter1));
      ignoreHip(hipSetDevice(srcGpu));
      ignoreHip(hipFree(counter0));
      cleanupSignals();
      cleanupBuffers();
      return err;
    }
  }

  // Helper lambdas for cleanup
  auto cleanupCounters = [&]() {
    if (useCounter) {
      ignoreHip(hipSetDevice(srcGpu));
      ignoreHip(hipFree(counter0));
      ignoreHip(hipSetDevice(dstGpu));
      ignoreHip(hipFree(counter1));
    }
  };
  auto cleanupAll = [&]() {
    cleanupCounters();
    cleanupSignals();
    cleanupBuffers();
  };

  // Launch kernel based on test type
  const unsigned numBlocks = 1;
  const unsigned threadsPerBlock = (testType == "p2p") ? 1 : 256;

  std::cout << "Launching " << config->iterations << " SDMA (test: " << testType
            << ", grid: " << numBlocks << " blocks x " << threadsPerBlock
            << " threads)" << std::endl;

  if (testType == "p2p") {
    err = hipSetDevice(srcGpu);
    if (err != hipSuccess) {
      cleanupAll();
      return err;
    }
    hipLaunchKernelGGL(sdma_p2p_kernel, dim3(numBlocks), dim3(threadsPerBlock),
                       0, 0, sdmaHandles[0], dstBuf, srcBuf, transferSize,
                       config->iterations, signals[0][0], config->startTimes,
                       config->endTimes);
  } else if (testType == "buffer-reuse") {
    // For buffer-reuse kernel, launch on both GPUs with different ranks
    // signals[0] and signals[1] are device arrays containing signal pointers
    size_t nElem = transferSize / sizeof(int);

    // Launch rank 0 (initiator) on source GPU with srcGpu->dstGpu handle
    err = hipSetDevice(srcGpu);
    if (err != hipSuccess) {
      cleanupAll();
      return err;
    }
    hipLaunchKernelGGL(sdma_buffer_reuse_kernel, dim3(numBlocks),
                       dim3(threadsPerBlock), 0, 0, sdmaHandles[0], dstBuf,
                       srcBuf, nElem, config->iterations, signals[0],
                       /*rank*/ 0, counter0, useCounter, useFlush,
                       config->startTimes, config->endTimes);

    // Launch rank 1 (responder) on destination GPU with dstGpu->srcGpu handle
    // Swap buffer arguments: rank 1's src should point to where rank 0 wrote
    // (dstBuf)
    err = hipSetDevice(dstGpu);
    if (err != hipSuccess) {
      cleanupAll();
      return err;
    }
    hipLaunchKernelGGL(sdma_buffer_reuse_kernel, dim3(numBlocks),
                       dim3(threadsPerBlock), 0, 0, sdmaHandles[1], srcBuf,
                       dstBuf, nElem, config->iterations, signals[1],
                       /*rank*/ 1, counter1, useCounter, useFlush,
                       config->startTimes, config->endTimes);
  } else if (testType == "ping-pong") {
    // For ping-pong kernel, launch on both GPUs with different ranks
    // signals[0] and signals[1] are device arrays containing signal pointers
    size_t nElem = transferSize / sizeof(int);

    // Launch rank 0 (initiator) on source GPU with srcGpu->dstGpu handle
    err = hipSetDevice(srcGpu);
    if (err != hipSuccess) {
      cleanupAll();
      return err;
    }
    hipLaunchKernelGGL(sdma_ping_pong_kernel, dim3(numBlocks),
                       dim3(threadsPerBlock), 0, 0, sdmaHandles[0], dstBuf,
                       srcBuf, nElem, config->iterations, signals[0],
                       /*rank*/ 0, counter0, useCounter, useFlush,
                       config->startTimes, config->endTimes);

    // Launch rank 1 (responder) on destination GPU with dstGpu->srcGpu handle
    // Swap buffer arguments: rank 1's src should point to where rank 0 wrote
    // (dstBuf)
    err = hipSetDevice(dstGpu);
    if (err != hipSuccess) {
      cleanupAll();
      return err;
    }
    hipLaunchKernelGGL(sdma_ping_pong_kernel, dim3(numBlocks),
                       dim3(threadsPerBlock), 0, 0, sdmaHandles[1], srcBuf,
                       dstBuf, nElem, config->iterations, signals[1],
                       /*rank*/ 1, counter1, useCounter, useFlush,
                       config->startTimes, config->endTimes);
  } else {
    std::cerr << "Unknown test type: " << testType << std::endl;
    cleanupAll();
    return hipErrorInvalidValue;
  }

  err = hipGetLastError();
  if (err != hipSuccess) {
    std::cerr << "Kernel launch failed: " << hipGetErrorString(err)
              << std::endl;
    cleanupAll();
    return err;
  }

  // Wait for kernel to complete
  err = hipSetDevice(srcGpu);
  if (err != hipSuccess) {
    std::cerr << "Failed to set device to srcGpu for sync: "
              << hipGetErrorString(err) << std::endl;
    cleanupAll();
    return err;
  }
  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    std::cerr << "Device sync on srcGpu failed: " << hipGetErrorString(err)
              << std::endl;
    cleanupAll();
    return err;
  }

  // For buffer-reuse and ping-pong, synchronize both GPUs
  if (testType == "buffer-reuse" || testType == "ping-pong") {
    err = hipSetDevice(dstGpu);
    if (err != hipSuccess) {
      std::cerr << "Failed to set device to dstGpu for sync: "
                << hipGetErrorString(err) << std::endl;
      cleanupAll();
      return err;
    }
    err = hipDeviceSynchronize();
    if (err != hipSuccess) {
      std::cerr << "Device sync on dstGpu failed: " << hipGetErrorString(err)
                << std::endl;
      cleanupAll();
      return err;
    }
  }

  std::cout << "SDMA transfers completed successfully" << std::endl;

  // Optional: Verify destination contains LFSR pattern per iteration when
  // --verify (each iteration uses a distinct LFSR segment).
  if (verifyData) {
    const size_t dwordsPerChunk = transferSize / sizeof(uint32_t);
    std::vector<uint32_t> expectedChunk(dwordsPerChunk);
    bool verified = true;
    unsigned failIter = 0;
    size_t failOffset = 0;
    if (useHostDst) {
      const uint32_t* dst = static_cast<const uint32_t*>(dstBuf);
      for (unsigned i = 0; i < config->iterations && verified; i++) {
        uint32_t state = lfsr_advance(kLfsrSeed, i * dwordsPerChunk);
        lfsr_fill_chunk(expectedChunk.data(), transferSize, state);
        const uint32_t* actual = dst + i * dwordsPerChunk;
        for (size_t j = 0; j < dwordsPerChunk; j++) {
          if (actual[j] != expectedChunk[j]) {
            verified = false;
            failIter = i;
            failOffset = j * sizeof(uint32_t);
            break;
          }
        }
      }
    } else {
      std::vector<uint32_t> hostChunk(dwordsPerChunk);
      err = hipSetDevice(dstGpu);
      if (err != hipSuccess) {
        verified = false;
      } else {
        for (unsigned i = 0; i < config->iterations && verified; i++) {
          err = hipMemcpy(hostChunk.data(),
                          static_cast<const char*>(dstBuf) + i * transferSize,
                          transferSize, hipMemcpyDeviceToHost);
          if (err != hipSuccess) {
            verified = false;
            break;
          }
          uint32_t state = lfsr_advance(kLfsrSeed, i * dwordsPerChunk);
          lfsr_fill_chunk(expectedChunk.data(), transferSize, state);
          for (size_t j = 0; j < dwordsPerChunk; j++) {
            if (hostChunk[j] != expectedChunk[j]) {
              verified = false;
              failIter = i;
              failOffset = j * sizeof(uint32_t);
              break;
            }
          }
        }
      }
    }
    if (verified) {
      std::cout << "Data verification: PASSED (LFSR pattern, "
                << config->iterations << " iterations)" << std::endl;
    } else {
      std::cerr << "Data verification: FAILED at iteration " << failIter
                << " offset " << failOffset << std::endl;
      cleanupAll();
      return hipErrorUnknown;
    }
  }

  // Cleanup all resources
  cleanupAll();

  return hipSuccess;
}

// Legacy driveEndpoint function - not used with anvil integration
__device__ void sdma_ep_driveEndpoint(const XioEndpointConfig& config,
                                      void* sqeAddr, void* cqeAddr) {
  // This function is not used when running with anvil library
  // The anvil-based implementation uses sdma_transfer_kernel instead
}

// Emulation mode not supported - hardware only
__host__ __device__ void sdma_ep_emulateEndpoint(unsigned sqeIterations,
                                                 void* sqeAddr, void* cqeAddr) {
  // SDMA endpoint requires real hardware via anvil library
  // Emulation mode has been removed to focus on hardware implementation
#ifdef __HIP_DEVICE_COMPILE__
  // Device code path (should not be called)
  __builtin_trap();
#else
  // Host code path
  throw std::runtime_error(
    "sdma-ep emulation not supported - requires real SDMA hardware");
#endif
}
