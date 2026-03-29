/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Example: GPU-initiated peer-to-peer DMA transfer via
 * the SDMA endpoint.
 *
 * Demonstrates using the rocm-xio SDMA endpoint public
 * API to perform a GPU-to-GPU memory copy driven entirely
 * from device (shader) code.
 *
 * Prerequisites:
 *   - Two AMD GPUs with XGMI / Infinity Fabric P2P
 *   - rocm-xio installed (find_package(rocm-xio))
 *   - Run as root (hsakmt requires /dev/kfd access)
 *
 * Usage:
 *   sudo ./sdma-ep-p2p
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <hip/hip_ext.h>
#include <hip/hip_runtime.h>

#include "endpoints/sdma-ep/sdma-ep.h"

#define HIP_CHECK(expr)                                                        \
  do {                                                                         \
    hipError_t _err = (expr);                                                  \
    if (_err != hipSuccess) {                                                  \
      fprintf(stderr, "HIP error %d (%s) at %s:%d\n", _err,                    \
              hipGetErrorString(_err), __FILE__, __LINE__);                    \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)

static constexpr int SRC_GPU = 0;
static constexpr int DST_GPU = 1;
static constexpr size_t TRANSFER_SIZE = 4096;
static constexpr int NUM_ITERATIONS = 8;

__global__ void sdmaP2pKernel(sdma_ep::SdmaQueueHandle* handle, void* dst,
                              void* src, size_t size, uint64_t* signal,
                              int iterations) {
  for (int i = 0; i < iterations; ++i) {
    sdma_ep::putSignal(*handle, dst, src, size, signal);
    sdma_ep::waitSignal(signal, static_cast<uint64_t>(i + 1));
  }
  sdma_ep::quiet(*handle);
}

int main() {
  int deviceCount = 0;
  HIP_CHECK(hipGetDeviceCount(&deviceCount));
  if (deviceCount < 2) {
    printf("SKIP: need >= 2 GPUs, found %d\n", deviceCount);
    return 0;
  }

  hipDeviceProp_t srcProp, dstProp;
  HIP_CHECK(hipGetDeviceProperties(&srcProp, SRC_GPU));
  HIP_CHECK(hipGetDeviceProperties(&dstProp, DST_GPU));
  printf("Source GPU %d: %s\n", SRC_GPU, srcProp.name);
  printf("Dest   GPU %d: %s\n", DST_GPU, dstProp.name);

  int canAccess = 0;
  HIP_CHECK(hipDeviceCanAccessPeer(&canAccess, SRC_GPU, DST_GPU));
  if (!canAccess) {
    printf("SKIP: GPU %d cannot access GPU %d\n", SRC_GPU, DST_GPU);
    return 0;
  }

  printf("Transfer size: %zu bytes\n", TRANSFER_SIZE);
  printf("Iterations:    %d\n\n", NUM_ITERATIONS);

  int rc = sdma_ep::initEndpoint();
  if (rc != 0) {
    fprintf(stderr, "ERROR: initEndpoint failed (%d)\n", rc);
    return 1;
  }

  sdma_ep::SdmaConnectionInfo connInfo = {};
  rc = sdma_ep::createConnection(SRC_GPU, DST_GPU, &connInfo);
  if (rc != 0) {
    fprintf(stderr, "ERROR: createConnection failed (%d)\n", rc);
    return 1;
  }
  printf("Connection: GPU %d -> GPU %d (engine %u)\n", connInfo.srcDeviceId,
         connInfo.dstDeviceId, connInfo.engineId);

  sdma_ep::SdmaQueueInfo queueInfo = {};
  rc = sdma_ep::createQueue(SRC_GPU, DST_GPU, &queueInfo);
  if (rc != 0) {
    fprintf(stderr, "ERROR: createQueue failed (%d)\n", rc);
    return 1;
  }
  printf("Queue created (channel %d)\n\n", queueInfo.channelIdx);

  HIP_CHECK(hipSetDevice(SRC_GPU));
  uint8_t* srcBuf = nullptr;
  HIP_CHECK(hipMalloc(&srcBuf, TRANSFER_SIZE));
  HIP_CHECK(hipMemset(srcBuf, 0xAB, TRANSFER_SIZE));

  HIP_CHECK(hipSetDevice(DST_GPU));
  uint8_t* dstBuf = nullptr;
  HIP_CHECK(hipMalloc(&dstBuf, TRANSFER_SIZE));
  HIP_CHECK(hipMemset(dstBuf, 0x00, TRANSFER_SIZE));

  uint64_t* signalBuf = nullptr;
  HIP_CHECK(hipExtMallocWithFlags(reinterpret_cast<void**>(&signalBuf),
                                  sizeof(uint64_t), hipDeviceMallocUncached));
  HIP_CHECK(hipMemset(signalBuf, 0, sizeof(uint64_t)));

  HIP_CHECK(hipSetDevice(SRC_GPU));
  printf("Launching P2P kernel...\n");
  hipLaunchKernelGGL(sdmaP2pKernel, dim3(1), dim3(1), 0, nullptr,
                     static_cast<sdma_ep::SdmaQueueHandle*>(
                       queueInfo.deviceHandle),
                     dstBuf, srcBuf, TRANSFER_SIZE, signalBuf, NUM_ITERATIONS);
  HIP_CHECK(hipDeviceSynchronize());
  printf("Kernel completed.\n");

  uint8_t* hostVerify = static_cast<uint8_t*>(malloc(TRANSFER_SIZE));
  HIP_CHECK(hipSetDevice(DST_GPU));
  HIP_CHECK(
    hipMemcpy(hostVerify, dstBuf, TRANSFER_SIZE, hipMemcpyDeviceToHost));

  bool pass = true;
  for (size_t i = 0; i < TRANSFER_SIZE; ++i) {
    if (hostVerify[i] != 0xAB) {
      fprintf(stderr, "FAIL: byte %zu = 0x%02x (expected 0xAB)\n", i,
              hostVerify[i]);
      pass = false;
      break;
    }
  }
  free(hostVerify);

  if (pass) {
    printf("PASS: %d P2P transfers of %zu bytes verified.\n", NUM_ITERATIONS,
           TRANSFER_SIZE);
  }

  sdma_ep::destroyQueue(&queueInfo);
  sdma_ep::shutdownEndpoint();

  HIP_CHECK(hipSetDevice(SRC_GPU));
  HIP_CHECK(hipFree(srcBuf));
  HIP_CHECK(hipSetDevice(DST_GPU));
  HIP_CHECK(hipFree(dstBuf));
  HIP_CHECK(hipFree(signalBuf));

  return pass ? 0 : 1;
}
