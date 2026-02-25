/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstdint>
#include <cstring>
#include <iostream>
#include <vector>

#include <hip/hip_ext.h>
#include <hip/hip_runtime.h>

#include "anvil.hpp"
#include "anvil_device.hpp"
#include "sdma-ep.h"
#include "xio.h"

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
__global__ void sdma_transfer_kernel(anvil::SdmaQueueDeviceHandle* handle,
                                     void* dstBuf, void* srcBuf,
                                     size_t transferSize, unsigned iterations,
                                     HSAuint64* signal,
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
      anvil::putWithSignal(*handle, dst, src, transferSize, signal);
    } else {
      anvil::put(*handle, dst, src, transferSize);
    }

    if (endTimes != nullptr) {
      endTimes[i] = wall_clock64();
    }
  }
  // Kernel waits for SDMA completion so host can rely on hipDeviceSynchronize
  if (iterations > 0) {
    anvil::waitForSignal(signal, 1);
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
  if (config->endpointConfig) {
    const auto* epConfig = static_cast<const sdma_ep::SdmaEpConfig*>(
      config->endpointConfig);
    useHostDst = epConfig->useHostDst;
    verifyData = epConfig->verifyData;
    cfgSrc = epConfig->srcDeviceId;
    cfgDst = epConfig->dstDeviceId;
    transferSize = epConfig->transferSize;
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
  xioPrintGpuDeviceDetails(srcGpu);
  if (!useHostDst) {
    std::cout << "SDMA destination GPU:" << std::endl;
    xioPrintGpuDeviceDetails(dstGpu);
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
  }

  try {
    bool success = anvil::AnvilLib::getInstance().connect(srcGpu, dstGpu, 1);
    if (!success) {
      std::cerr << "Failed to connect SDMA (src=" << srcGpu
                << ", dst=" << dstGpu << ")" << std::endl;
      return hipErrorInvalidDevice;
    }
  } catch (const std::exception& e) {
    std::cerr << "SDMA connect error: " << e.what() << std::endl;
    return hipErrorInvalidDevice;
  }

  anvil::SdmaQueue* queue = nullptr;
  try {
    queue = anvil::AnvilLib::getInstance().getSdmaQueue(srcGpu, dstGpu, 0);
    if (queue == nullptr) {
      std::cerr << "Failed to get SDMA queue" << std::endl;
      return hipErrorInvalidValue;
    }
  } catch (const std::exception& e) {
    std::cerr << "SDMA queue error: " << e.what() << std::endl;
    return hipErrorInvalidValue;
  }

  // Set device for memory allocations
  err = hipSetDevice(srcGpu);
  if (err != hipSuccess)
    return err;

  // Calculate buffer sizes (transferSize from config, validated by endpoint)
  size_t totalSize = transferSize * config->iterations;

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

  // Ensure current device is srcGpu so signal is allocated on source (SDMA
  // on src writes completion there).
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

  // Completion signal on source GPU (device memory) so SDMA can update it
  HSAuint64* signal = nullptr;
  err = hipMalloc(&signal, sizeof(HSAuint64));
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

  HSAuint64 signalInit = 0;
  err = hipMemcpy(signal, &signalInit, sizeof(HSAuint64),
                  hipMemcpyHostToDevice);
  if (err != hipSuccess) {
    ignoreHip(hipFree(signal));
    if (useHostDst) {
      ignoreHip(hipFree(dstBuf));
    } else {
      ignoreHip(hipSetDevice(dstGpu));
      ignoreHip(hipFree(dstBuf));
    }
    ignoreHip(hipFree(srcBuf));
    return err;
  }

  // Get SDMA queue device handle
  anvil::SdmaQueueDeviceHandle* devHandle = queue->deviceHandle();

  // Launch kernel: one thread runs the loop over all iterations to avoid
  // anvil queue contention (multi-thread submit can stall).
  const unsigned numBlocks = 1;
  const unsigned threadsPerBlock = 1;

  std::cout << "Launching " << config->iterations
            << " SDMA transfers (grid: " << numBlocks << " blocks x "
            << threadsPerBlock << " threads)" << std::endl;

  hipLaunchKernelGGL(sdma_transfer_kernel, dim3(numBlocks),
                     dim3(threadsPerBlock), 0, 0, devHandle, dstBuf, srcBuf,
                     transferSize, config->iterations, signal,
                     config->startTimes, config->endTimes);

  err = hipGetLastError();
  if (err != hipSuccess) {
    std::cerr << "Kernel launch failed: " << hipGetErrorString(err)
              << std::endl;
    ignoreHip(hipFree(signal));
    if (useHostDst) {
      ignoreHip(hipFree(dstBuf));
    } else {
      ignoreHip(hipSetDevice(dstGpu));
      ignoreHip(hipFree(dstBuf));
    }
    ignoreHip(hipFree(srcBuf));
    return err;
  }

  // Wait for kernel to complete; kernel waits for SDMA completion signal
  // (no host-side signal polling).
  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    std::cerr << "Device sync after kernel failed: " << hipGetErrorString(err)
              << std::endl;
    ignoreHip(hipFree(signal));
    if (useHostDst) {
      ignoreHip(hipFree(dstBuf));
    } else {
      ignoreHip(hipSetDevice(dstGpu));
      ignoreHip(hipFree(dstBuf));
    }
    ignoreHip(hipFree(srcBuf));
    return err;
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
      ignoreHip(hipSetDevice(dstGpu));
      ignoreHip(hipFree(dstBuf));
      ignoreHip(hipSetDevice(srcGpu));
      ignoreHip(hipFree(signal));
      ignoreHip(hipFree(srcBuf));
      return hipErrorUnknown;
    }
  }

  // Cleanup (free on correct device: signal and srcBuf on srcGpu, dstBuf on
  // dstGpu)
  ignoreHip(hipSetDevice(dstGpu));
  ignoreHip(hipFree(dstBuf));
  ignoreHip(hipSetDevice(srcGpu));
  ignoreHip(hipFree(signal));
  ignoreHip(hipFree(srcBuf));

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
