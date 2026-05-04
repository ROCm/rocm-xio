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

namespace xio {
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
      info->engineId = engineId;
      info->channelIdx = channelIdx;
    }
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "sdma_ep::createQueue: " << e.what() << std::endl;
    return -1;
  }
}

int createHostQueue(int srcDeviceId, int dstDeviceId, SdmaQueueInfo* info) {
  if (!s_initialized) {
    std::cerr << "sdma_ep::createHostQueue: " << "call initEndpoint() first"
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
      std::cerr << "sdma_ep::createHostQueue: " << "queue creation failed"
                << std::endl;
      return -1;
    }
    if (info) {
      info->deviceHandle = nullptr;  // Host queues have no device handle
      info->srcDeviceId = srcDeviceId;
      info->dstDeviceId = dstDeviceId;
      info->engineId = engineId;
      info->channelIdx = channelIdx;
    }
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "sdma_ep::createHostQueue: " << e.what() << std::endl;
    return -1;
  }
}

void destroyQueue(SdmaQueueInfo* info) {
  if (info) {
    info->deviceHandle = nullptr;
  }
}

SdmaQueuePythonDeviceCtx getPythonDeviceContext(int srcDeviceId, int dstDeviceId) {
  return anvil::AnvilLib::getInstance().getPythonDeviceCtx(srcDeviceId, dstDeviceId);
}

anvil::SdmaQueueHostHandle getHostHandle(int srcDeviceId, int dstDeviceId, int channelIdx) {
  return anvil::AnvilLib::getInstance().getHostHandle(srcDeviceId, dstDeviceId, channelIdx);
}

} // namespace sdma_ep
} // namespace xio

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
