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

namespace sdma_ep {

static bool s_initialized = false;

int initEndpoint() {
  if (s_initialized)
    return 0;
  try {
    anvil::AnvilLib::getInstance().init();
    s_initialized = true;
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "sdma_ep::initEndpoint: " << e.what() << std::endl;
    return -1;
  }
}

void shutdownEndpoint() {
  s_initialized = false;
}

int createConnection(int srcDeviceId, int dstDeviceId,
                     SdmaConnectionInfo* info) {
  if (!s_initialized) {
    std::cerr << "sdma_ep::createConnection: " << "call initEndpoint() first"
              << std::endl;
    return -1;
  }
  try {
    if (srcDeviceId != dstDeviceId) {
      anvil::EnablePeerAccess(srcDeviceId, dstDeviceId);
    }
    uint32_t engineId =
      anvil::AnvilLib::getInstance().getSdmaEngineId(srcDeviceId, dstDeviceId);
    if (info) {
      info->srcDeviceId = srcDeviceId;
      info->dstDeviceId = dstDeviceId;
      info->engineId = engineId;
    }
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "sdma_ep::createConnection: " << e.what() << std::endl;
    return -1;
  }
}

int createQueue(int srcDeviceId, int dstDeviceId, SdmaQueueInfo* info) {
  if (!s_initialized) {
    std::cerr << "sdma_ep::createQueue: " << "call initEndpoint() first"
              << std::endl;
    return -1;
  }
  try {
    uint32_t engineId =
      anvil::AnvilLib::getInstance().getSdmaEngineId(srcDeviceId, dstDeviceId);
    int channelIdx = 0;
    anvil::SdmaQueue* q = anvil::AnvilLib::getInstance().createSdmaQueue(
      srcDeviceId, dstDeviceId, engineId, &channelIdx);
    if (!q) {
      std::cerr << "sdma_ep::createQueue: " << "queue creation failed"
                << std::endl;
      return -1;
    }
    if (info) {
      info->deviceHandle = q->deviceHandle();
      info->srcDeviceId = srcDeviceId;
      info->dstDeviceId = dstDeviceId;
      info->channelIdx = channelIdx;
    }
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "sdma_ep::createQueue: " << e.what() << std::endl;
    return -1;
  }
}

void destroyQueue(SdmaQueueInfo* info) {
  if (info) {
    info->deviceHandle = nullptr;
  }
}

std::string validateConfig(SdmaEpConfig* config) {
  if (!config)
    return std::string();
  if (config->testType.empty()) {
    return "Missing test subcommand. Available: "
           "p2p, ping-pong, buffer-reuse";
  }
  if (config->useCounter && config->useFlush) {
    return "Cannot use both --use-counter and "
           "--use-flush at the same time";
  }
  if (config->transferSize == 0)
    return "transfer-size must be > 0";
  if (config->transferSize % 4 != 0)
    return "transfer-size must be a multiple of 4 "
           "(LFSR uses dwords)";
  return std::string();
}

unsigned getIterations(void* endpointConfig) {
  (void)endpointConfig;
  return 128;
}

} // namespace sdma_ep

// Single-thread kernel: one thread does all transfers to avoid queue
// contention (multi-thread submit can stall on anvil's committedWptr ordering).
__global__ void sdma_p2p_kernel(anvil::SdmaQueueDeviceHandle* handle,
                                void* dstBuf, void* srcBuf, size_t transferSize,
                                unsigned iterations, uint64_t* signal,
                                unsigned long long* startTimes,
                                unsigned long long* endTimes,
                                volatile bool* stopRequested) {
  unsigned last = 0;
  for (unsigned i = 0; i < iterations; i++) {
    if (stopRequested && i % 100 == 0 &&
        *stopRequested)
      break;

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
    last = i + 1;
  }
  if (last == iterations && iterations > 0) {
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
                                      unsigned long long* endTimes,
                                      volatile bool* stopRequested) {
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
    if (stopRequested && i % 100 == 0 &&
        *stopRequested)
      break;

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
// rank0 is reusing the same buffer for `transfers_per_iteration` iterations
// This kernel tests the different variations to determine that the source
// buffer can be reused
__global__ void sdma_buffer_reuse_kernel(
  anvil::SdmaQueueDeviceHandle* handle, void* dstBuf, void* srcBuf,
  size_t nElem, unsigned iterations, uint64_t** signals, int rank,
  uint64_t* counter, bool use_counter, bool use_flush,
  unsigned long long* startTimes, unsigned long long* endTimes,
  volatile bool* stopRequested) {
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
    if (stopRequested && i % 100 == 0 &&
        *stopRequested)
      break;

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
        // Wait for buffer reuse
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

  if (sdma_ep::initEndpoint() != 0) {
    std::cerr << "Failed to initialize SDMA endpoint" << std::endl;
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
                << dstGpu << std::endl;
      return hipErrorInvalidDevice;
    }

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
                  << " cannot access GPU " << srcGpu << std::endl;
        return hipErrorInvalidDevice;
      }
    }
  }

  sdma_ep::SdmaConnectionInfo connFwd, connRev;
  if (sdma_ep::createConnection(srcGpu, dstGpu, &connFwd) != 0) {
    std::cerr << "Failed to create SDMA connection " << srcGpu << " -> "
              << dstGpu << std::endl;
    return hipErrorInvalidDevice;
  }
  if (sdma_ep::createConnection(dstGpu, srcGpu, &connRev) != 0) {
    std::cerr << "Failed to create SDMA connection " << dstGpu << " -> "
              << srcGpu << std::endl;
    return hipErrorInvalidDevice;
  }

  sdma_ep::SdmaQueueInfo qInfo0, qInfo1;
  if (sdma_ep::createQueue(srcGpu, dstGpu, &qInfo0) != 0) {
    std::cerr << "Failed to create SDMA queue (rank 0)" << std::endl;
    return hipErrorInvalidValue;
  }
  if (sdma_ep::createQueue(dstGpu, srcGpu, &qInfo1) != 0) {
    std::cerr << "Failed to create SDMA queue (rank 1)" << std::endl;
    return hipErrorInvalidValue;
  }

  std::map<int, anvil::SdmaQueueDeviceHandle*> sdmaHandles;
  sdmaHandles[0] = static_cast<anvil::SdmaQueueDeviceHandle*>(
    qInfo0.deviceHandle);
  sdmaHandles[1] = static_cast<anvil::SdmaQueueDeviceHandle*>(
    qInfo1.deviceHandle);

  // Set device for memory allocations
  err = hipSetDevice(srcGpu);
  if (err != hipSuccess)
    return err;

  // Calculate buffer sizes (transferSize from config, validated by endpoint)
  size_t totalSize = transferSize * config->iterations * 10;
  // if (testType == "buffer-reuse") {
  //   totalSize = transferSize * 10;
  // }

  unsigned srcMemFlags = useHostDst ? XIO_DEVICE_MEM_HIP
                                    : XIO_DEVICE_MEM_UNCACHED;
  void* srcBuf = nullptr;
  {
    hsa_status_t s = xio::allocDeviceMemory(totalSize, &srcBuf,
                                            "SDMA source buffer", srcMemFlags);
    if (s != HSA_STATUS_SUCCESS) {
      std::cerr << "Failed to allocate source buffer" << std::endl;
      return hipErrorMemoryAllocation;
    }
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
      xio::freeDeviceMemory(srcBuf, srcMemFlags);
      return err;
    }
  }

  void* dstBuf = nullptr;
  bool dstIsHost = useHostDst;
  unsigned dstMemFlags = XIO_DEVICE_MEM_UNCACHED;
  if (useHostDst) {
    err = xio::allocHostMemory(totalSize, &dstBuf, "SDMA host destination",
                               XIO_HOST_MEM_DEFAULT);
    if (err != hipSuccess) {
      std::cerr << "Failed to allocate pinned host destination buffer"
                << std::endl;
      xio::freeDeviceMemory(srcBuf, srcMemFlags);
      return err;
    }
  } else {
    err = hipSetDevice(dstGpu);
    if (err != hipSuccess) {
      xio::freeDeviceMemory(srcBuf, srcMemFlags);
      return err;
    }
    hsa_status_t s = xio::allocDeviceMemory(totalSize, &dstBuf,
                                            "SDMA destination buffer",
                                            XIO_DEVICE_MEM_UNCACHED);
    if (s != HSA_STATUS_SUCCESS) {
      std::cerr << "Failed to allocate destination buffer" << std::endl;
      xio::freeDeviceMemory(srcBuf, srcMemFlags);
      return hipErrorMemoryAllocation;
    }
    err = hipMemset(dstBuf, 0, totalSize);
    if (err != hipSuccess) {
      xio::freeDeviceMemory(dstBuf, XIO_DEVICE_MEM_UNCACHED);
      xio::freeDeviceMemory(srcBuf, srcMemFlags);
      return err;
    }
  }

  // Helper lambda for cleanup (defined early so it can be used in error paths)
  auto cleanupBuffers = [&]() {
    if (dstIsHost) {
      xio::freeHostMemory(dstBuf, XIO_HOST_MEM_DEFAULT);
    } else {
      ignoreHip(hipSetDevice(dstGpu));
      xio::freeDeviceMemory(dstBuf, dstMemFlags);
    }
    ignoreHip(hipSetDevice(srcGpu));
    xio::freeDeviceMemory(srcBuf, srcMemFlags);
  };

  // Allocate completion signals - use uncached memory for P2P access
  // For buffer-reuse, signals map stores pointers to device arrays of signal
  // pointers For p2p, signals map stores individual signal pointers
  std::map<int, uint64_t**> signals;

  // Allocate individual signal memory on each GPU
  uint64_t* signal0 = nullptr;
  uint64_t* signal1 = nullptr;

  auto cleanupSignals = [&]() {
    if (signals.count(0)) {
      ignoreHip(hipSetDevice(srcGpu));
      xio::freeDeviceMemory(signals[0], XIO_DEVICE_MEM_HIP);
    }
    if (signals.count(1)) {
      ignoreHip(hipSetDevice(dstGpu));
      xio::freeDeviceMemory(signals[1], XIO_DEVICE_MEM_HIP);
    }
    if (signal1 != nullptr) {
      ignoreHip(hipSetDevice(dstGpu));
      xio::freeDeviceMemory(signal1, XIO_DEVICE_MEM_UNCACHED);
    }
    if (signal0 != nullptr) {
      ignoreHip(hipSetDevice(srcGpu));
      xio::freeDeviceMemory(signal0, XIO_DEVICE_MEM_UNCACHED);
    }
  };

  // Allocate signal on source GPU (rank 0)
  err = hipSetDevice(srcGpu);
  if (err != hipSuccess) {
    cleanupBuffers();
    return err;
  }

  {
    hsa_status_t s = xio::allocDeviceMemory(sizeof(uint64_t), (void**)&signal0,
                                            "SDMA signal0",
                                            XIO_DEVICE_MEM_UNCACHED);
    if (s != HSA_STATUS_SUCCESS) {
      cleanupBuffers();
      return hipErrorMemoryAllocation;
    }
  }

  err = hipMemset(signal0, 0, sizeof(uint64_t));
  if (err != hipSuccess) {
    xio::freeDeviceMemory(signal0, XIO_DEVICE_MEM_UNCACHED);
    cleanupBuffers();
    return err;
  }

  if (!useHostDst) {
    err = hipSetDevice(dstGpu);
    if (err != hipSuccess) {
      ignoreHip(hipSetDevice(srcGpu));
      xio::freeDeviceMemory(signal0, XIO_DEVICE_MEM_UNCACHED);
      cleanupBuffers();
      return err;
    }

    hsa_status_t s = xio::allocDeviceMemory(sizeof(uint64_t), (void**)&signal1,
                                            "SDMA signal1",
                                            XIO_DEVICE_MEM_UNCACHED);
    if (s != HSA_STATUS_SUCCESS) {
      ignoreHip(hipSetDevice(srcGpu));
      xio::freeDeviceMemory(signal0, XIO_DEVICE_MEM_UNCACHED);
      cleanupBuffers();
      return hipErrorMemoryAllocation;
    }

    err = hipMemset(signal1, 0, sizeof(uint64_t));
    if (err != hipSuccess) {
      xio::freeDeviceMemory(signal1, XIO_DEVICE_MEM_UNCACHED);
      ignoreHip(hipSetDevice(srcGpu));
      xio::freeDeviceMemory(signal0, XIO_DEVICE_MEM_UNCACHED);
      cleanupBuffers();
      return err;
    }
  }

  uint64_t* signalsHost[2] = {signal0, signal1};

  err = hipSetDevice(srcGpu);
  if (err != hipSuccess) {
    cleanupSignals();
    cleanupBuffers();
    return err;
  }

  {
    hsa_status_t s = xio::allocDeviceMemory(2 * sizeof(uint64_t*),
                                            (void**)&signals[0],
                                            "SDMA signals[0]",
                                            XIO_DEVICE_MEM_HIP);
    if (s != HSA_STATUS_SUCCESS) {
      cleanupSignals();
      cleanupBuffers();
      return hipErrorMemoryAllocation;
    }
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

    {
      hsa_status_t s = xio::allocDeviceMemory(2 * sizeof(uint64_t*),
                                              (void**)&signals[1],
                                              "SDMA signals[1]",
                                              XIO_DEVICE_MEM_HIP);
      if (s != HSA_STATUS_SUCCESS) {
        cleanupSignals();
        cleanupBuffers();
        return hipErrorMemoryAllocation;
      }
    }

    err = hipMemcpy(signals[1], signalsHost, 2 * sizeof(uint64_t*),
                    hipMemcpyHostToDevice);
    if (err != hipSuccess) {
      xio::freeDeviceMemory(signals[1], XIO_DEVICE_MEM_HIP);
      signals.erase(1);
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

    {
      hsa_status_t s = xio::allocDeviceMemory(sizeof(uint64_t),
                                              (void**)&counter0,
                                              "SDMA counter0",
                                              XIO_DEVICE_MEM_UNCACHED);
      if (s != HSA_STATUS_SUCCESS) {
        cleanupSignals();
        cleanupBuffers();
        return hipErrorMemoryAllocation;
      }
    }

    err = hipMemset(counter0, 0, sizeof(uint64_t));
    if (err != hipSuccess) {
      xio::freeDeviceMemory(counter0, XIO_DEVICE_MEM_UNCACHED);
      cleanupSignals();
      cleanupBuffers();
      return err;
    }

    err = hipSetDevice(dstGpu);
    if (err != hipSuccess) {
      ignoreHip(hipSetDevice(srcGpu));
      xio::freeDeviceMemory(counter0, XIO_DEVICE_MEM_UNCACHED);
      cleanupSignals();
      cleanupBuffers();
      return err;
    }

    {
      hsa_status_t s = xio::allocDeviceMemory(sizeof(uint64_t),
                                              (void**)&counter1,
                                              "SDMA counter1",
                                              XIO_DEVICE_MEM_UNCACHED);
      if (s != HSA_STATUS_SUCCESS) {
        ignoreHip(hipSetDevice(srcGpu));
        xio::freeDeviceMemory(counter0, XIO_DEVICE_MEM_UNCACHED);
        cleanupSignals();
        cleanupBuffers();
        return hipErrorMemoryAllocation;
      }
    }

    err = hipMemset(counter1, 0, sizeof(uint64_t));
    if (err != hipSuccess) {
      xio::freeDeviceMemory(counter1, XIO_DEVICE_MEM_UNCACHED);
      ignoreHip(hipSetDevice(srcGpu));
      xio::freeDeviceMemory(counter0, XIO_DEVICE_MEM_UNCACHED);
      cleanupSignals();
      cleanupBuffers();
      return err;
    }
  }

  auto cleanupCounters = [&]() {
    if (useCounter) {
      ignoreHip(hipSetDevice(srcGpu));
      xio::freeDeviceMemory(counter0, XIO_DEVICE_MEM_UNCACHED);
      ignoreHip(hipSetDevice(dstGpu));
      xio::freeDeviceMemory(counter1, XIO_DEVICE_MEM_UNCACHED);
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
    hipLaunchKernelGGL(sdma_p2p_kernel, dim3(numBlocks),
                       dim3(threadsPerBlock), 0, 0,
                       sdmaHandles[0], dstBuf, srcBuf,
                       transferSize, config->iterations,
                       signals[0][0], config->startTimes,
                       config->endTimes,
                       config->stopRequested);
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
    hipLaunchKernelGGL(sdma_buffer_reuse_kernel,
                       dim3(numBlocks),
                       dim3(threadsPerBlock), 0, 0,
                       sdmaHandles[0], dstBuf, srcBuf,
                       nElem, config->iterations,
                       signals[0], /*rank*/ 0,
                       counter0, useCounter, useFlush,
                       config->startTimes,
                       config->endTimes,
                       config->stopRequested);

    // Launch rank 1 (responder) on destination GPU with dstGpu->srcGpu handle
    // Swap buffer arguments: rank 1's src should point to where rank 0 wrote
    // (dstBuf)
    err = hipSetDevice(dstGpu);
    if (err != hipSuccess) {
      cleanupAll();
      return err;
    }
    hipLaunchKernelGGL(sdma_buffer_reuse_kernel,
                       dim3(numBlocks),
                       dim3(threadsPerBlock), 0, 0,
                       sdmaHandles[1], srcBuf, dstBuf,
                       nElem, config->iterations,
                       signals[1], /*rank*/ 1,
                       counter1, useCounter, useFlush,
                       config->startTimes,
                       config->endTimes,
                       config->stopRequested);
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
    hipLaunchKernelGGL(sdma_ping_pong_kernel,
                       dim3(numBlocks),
                       dim3(threadsPerBlock), 0, 0,
                       sdmaHandles[0], dstBuf, srcBuf,
                       nElem, config->iterations,
                       signals[0], /*rank*/ 0,
                       counter0, useCounter, useFlush,
                       config->startTimes,
                       config->endTimes,
                       config->stopRequested);

    // Launch rank 1 (responder) on destination GPU with dstGpu->srcGpu handle
    // Swap buffer arguments: rank 1's src should point to where rank 0 wrote
    // (dstBuf)
    err = hipSetDevice(dstGpu);
    if (err != hipSuccess) {
      cleanupAll();
      return err;
    }
    hipLaunchKernelGGL(sdma_ping_pong_kernel,
                       dim3(numBlocks),
                       dim3(threadsPerBlock), 0, 0,
                       sdmaHandles[1], srcBuf, dstBuf,
                       nElem, config->iterations,
                       signals[1], /*rank*/ 1,
                       counter1, useCounter, useFlush,
                       config->startTimes,
                       config->endTimes,
                       config->stopRequested);
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
