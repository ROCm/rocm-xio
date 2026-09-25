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

namespace xio {
namespace sdma_ep {

static bool s_initialized = false;

int initEndpoint() {
  if (s_initialized)
    return 0;
  try {
    ::anvil::AnvilLib::getInstance().init();
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
    uint32_t engineId = ::anvil::AnvilLib::getInstance().getSdmaEngineId(
      srcDeviceId, dstDeviceId);
    int channelIdx = 0;
    ::anvil::SdmaQueue* q = ::anvil::AnvilLib::getInstance().createSdmaQueue(
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
    uint32_t engineId = ::anvil::AnvilLib::getInstance().getSdmaEngineId(
      srcDeviceId, dstDeviceId);
    int channelIdx = 0;
    ::anvil::SdmaQueue* q = ::anvil::AnvilLib::getInstance().createSdmaQueue(
      srcDeviceId, dstDeviceId, engineId, &channelIdx, true);

    if (!q) {
      std::cerr << "sdma_ep::createHostQueue: " << "queue creation failed"
                << std::endl;
      return -1;
    }
    if (info) {
      info->deviceHandle = nullptr; // Host queues have no device handle
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

SdmaQueuePythonDeviceCtx getPythonDeviceContext(int srcDeviceId,
                                                int dstDeviceId) {
  return ::anvil::AnvilLib::getInstance().getPythonDeviceCtx(srcDeviceId,
                                                             dstDeviceId);
}

uintptr_t getQueueDeviceHandle(int srcDeviceId, int dstDeviceId) {
  auto* queue = ::anvil::AnvilLib::getInstance().getSdmaQueue(srcDeviceId,
                                                              dstDeviceId);
  if (queue == nullptr || queue->deviceHandle() == nullptr) {
    throw std::runtime_error("device queue is not initialized");
  }
  return reinterpret_cast<uintptr_t>(queue->deviceHandle());
}

std::vector<uint64_t> getQueueDeviceState(int srcDeviceId, int dstDeviceId) {
  const auto ctx = getPythonDeviceContext(srcDeviceId, dstDeviceId);
  std::vector<uint64_t> state = {
    *reinterpret_cast<const uint64_t*>(ctx.rptr),
    *reinterpret_cast<const uint64_t*>(ctx.wptr),
  };
  for (const uintptr_t address : {ctx.cachedWptr, ctx.committedWptr}) {
    uint64_t value = 0;
    const hipError_t error = hipMemcpy(&value,
                                       reinterpret_cast<const void*>(address),
                                       sizeof(value), hipMemcpyDeviceToHost);
    if (error != hipSuccess) {
      throw std::runtime_error(hipGetErrorString(error));
    }
    state.push_back(value);
  }
  return state;
}

SdmaQueueHostHandle getHostHandle(int srcDeviceId, int dstDeviceId,
                                  int channelIdx) {
  return ::anvil::AnvilLib::getInstance().getHostHandle(srcDeviceId,
                                                        dstDeviceId,
                                                        channelIdx);
}

int initQueue(int srcDeviceId, int dstDeviceId) {
  if (!s_initialized) {
    std::cerr << "sdma_ep::initQueue: call initEndpoint() first" << std::endl;
    return -1;
  }
  try {
    bool success = ::anvil::AnvilLib::getInstance().connect(srcDeviceId,
                                                            dstDeviceId, 1,
                                                            false);
    return success ? 0 : -1;
  } catch (const std::exception& e) {
    std::cerr << "sdma_ep::initQueue: " << e.what() << std::endl;
    return -1;
  }
}

int initHostQueue(int srcDeviceId, int dstDeviceId) {
  if (!s_initialized) {
    std::cerr << "sdma_ep::initHostQueue: call initEndpoint() first"
              << std::endl;
    return -1;
  }
  try {
    bool success = ::anvil::AnvilLib::getInstance().connect(srcDeviceId,
                                                            dstDeviceId, 1,
                                                            true);
    return success ? 0 : -1;
  } catch (const std::exception& e) {
    std::cerr << "sdma_ep::initHostQueue: " << e.what() << std::endl;
    return -1;
  }
}

} // namespace sdma_ep
} // namespace xio
