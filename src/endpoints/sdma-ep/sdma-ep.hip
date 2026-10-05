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
