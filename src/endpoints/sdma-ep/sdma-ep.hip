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

int createHostQueue(int srcDeviceId, int dstDeviceId, SdmaQueueInfo* info) {
  if (!s_initialized) {
    std::cerr << "sdma_ep::createHostQueue: " << "call initEndpoint() first"
              << std::endl;
    return -1;
  }
  try {
    if (!anvil::AnvilLib::getInstance().connect(srcDeviceId, dstDeviceId, 1, true)) {
      std::cerr << "sdma_ep::createHostQueue: " << "queue creation failed"
                << std::endl;
      return -1;
    }
    if (info) {
      info->deviceHandle = nullptr;
      info->srcDeviceId = srcDeviceId;
      info->dstDeviceId = dstDeviceId;
      info->channelIdx = 0;
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

SdmaQueuePythonDeviceCtx get_queue_device_ctx(int srcDeviceId, int dstDeviceId) {
  return anvil::AnvilLib::getInstance().get_queue_device_ctx(srcDeviceId, dstDeviceId);
}

void put(int srcDeviceId, int dstDeviceId, int channelIdx,
         void* src, void* dst, size_t size) {
  anvil::AnvilLib::getInstance().put(srcDeviceId, dstDeviceId, channelIdx,
                                     src, dst, size);
}

void put_signal(int srcDeviceId, int dstDeviceId, int channelIdx,
                void* src, void* dst, size_t size,
                void* flag_ptr, uint64_t flag_value, int flag_bits) {
  anvil::AnvilLib::getInstance().put_signal(srcDeviceId, dstDeviceId, channelIdx,
                                            src, dst, size, flag_ptr, flag_value,
                                            flag_bits);
}

void put_tile(int srcDeviceId, int dstDeviceId, int channelIdx,
              const Tile& tile, void* dst_ptr, size_t dst_stride) {
  anvil::AnvilLib::getInstance().put_tile(srcDeviceId, dstDeviceId, channelIdx,
                                          tile, dst_ptr, dst_stride);
}

void put_tiles(int srcDeviceId, int dstDeviceId, int channelIdx,
               const std::vector<Tile>& tiles,
               const std::vector<void*>& dst_ptrs,
               const std::vector<size_t>& dst_strides) {
  anvil::AnvilLib::getInstance().put_tiles(srcDeviceId, dstDeviceId, channelIdx,
                                           tiles, dst_ptrs, dst_strides);
}

void put_tile_signal(int srcDeviceId, int dstDeviceId, int channelIdx,
                     const Tile& tile, void* dst_ptr, size_t dst_stride,
                     void* flag_ptr, uint64_t flag_value, int flag_bits) {
  anvil::AnvilLib::getInstance().put_tile_signal(srcDeviceId, dstDeviceId, channelIdx,
                                                 tile, dst_ptr, dst_stride,
                                                 flag_ptr, flag_value, flag_bits);
}

void put_tiles_signal(int srcDeviceId, int dstDeviceId, int channelIdx,
                      const std::vector<Tile>& tiles,
                      const std::vector<void*>& dst_ptrs,
                      const std::vector<size_t>& dst_strides,
                      void* flag_ptr, uint64_t flag_value, int flag_bits) {
  anvil::AnvilLib::getInstance().put_tiles_signal(srcDeviceId, dstDeviceId, channelIdx,
                                                   tiles, dst_ptrs, dst_strides,
                                                   flag_ptr, flag_value, flag_bits);
}

void wait_flag_then_put(int srcDeviceId, int dstDeviceId, int channelIdx,
                        void* flag_ptr, uint32_t expected_value,
                        void* src, void* dst, size_t size, int flag_bits) {
  anvil::AnvilLib::getInstance().wait_flag_then_put(srcDeviceId, dstDeviceId, channelIdx,
                                                     flag_ptr, expected_value,
                                                     src, dst, size, flag_bits);
}

void wait_flag_then_put_tile(int srcDeviceId, int dstDeviceId, int channelIdx,
                              void* flag_ptr, uint32_t expected_value,
                              const Tile& tile, void* dst_ptr,
                              size_t dst_stride, int flag_bits) {
  anvil::AnvilLib::getInstance().wait_flag_then_put_tile(srcDeviceId, dstDeviceId, channelIdx,
                                                          flag_ptr, expected_value,
                                                          tile, dst_ptr, dst_stride,
                                                          flag_bits);
}

void wait_flag_then_put_tiles(int srcDeviceId, int dstDeviceId, int channelIdx,
                               void* flag_ptr, uint32_t expected_value,
                               const std::vector<Tile>& tiles,
                               const std::vector<void*>& dst_ptrs,
                               const std::vector<size_t>& dst_strides,
                               int flag_bits) {
  anvil::AnvilLib::getInstance().wait_flag_then_put_tiles(srcDeviceId, dstDeviceId, channelIdx,
                                                           flag_ptr, expected_value,
                                                           tiles, dst_ptrs, dst_strides,
                                                           flag_bits);
}

void signal(int srcDeviceId, int dstDeviceId, int channelIdx,
            void* flag_ptr, uint64_t flag_value, int flag_bits) {
  anvil::AnvilLib::getInstance().signal(srcDeviceId, dstDeviceId, channelIdx,
                                        flag_ptr, flag_value, flag_bits);
}

void timestamp(int srcDeviceId, int dstDeviceId, int channelIdx,
               void* timestamp_ptr) {
  anvil::AnvilLib::getInstance().timestamp(srcDeviceId, dstDeviceId, channelIdx,
                                           timestamp_ptr);
}

void quiet(int srcDeviceId, int dstDeviceId, int channelIdx) {
  anvil::AnvilLib::getInstance().quiet(srcDeviceId, dstDeviceId, channelIdx);
}

} // namespace sdma_ep
