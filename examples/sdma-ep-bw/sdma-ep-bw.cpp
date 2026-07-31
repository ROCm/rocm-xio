/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <stdio.h>

#include <hip/hip_ext.h>
#include <hip/hip_runtime.h>
#include <hip/hip_runtime_api.h>

#include "endpoints/sdma-ep/sdma-ep.h"

#include "sdma_bw_kernel.h"
#include "xio.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <optional>
#include <sstream>
#include <vector>

#include <CLI/CLI.hpp>

using namespace xio;

constexpr uint32_t MAGIC_VALUE = 0xDEADBEEF;

struct ExperimentParams {
  size_t minCopySize;
  size_t maxCopySize;
  size_t numCopyCommands;
  bool skipVerification;
  size_t nWarmupIterations;
  size_t numIterations;
  size_t numDestinations;
  size_t numOfQueues;
  size_t numOfWarpsPerWG;
  size_t numOfWGPerQueue;
  std::string resultFileName;
  bool verbose;
};

#define CHECK_HIP_ERROR(cmd)                                                   \
  do {                                                                         \
    hipError_t error = cmd;                                                    \
    if (error != hipSuccess) {                                                 \
      fprintf(stderr, "HIP error %d: %s at %s:%d\n", error,                    \
              hipGetErrorString(error), __FILE__, __LINE__);                   \
      exit(EXIT_FAILURE);                                                      \
    }                                                                          \
  } while (0)

std::pair<double, double> avg_std(const std::vector<double>& values) {
  double mean =
    std::accumulate(values.begin(), values.end(), 0.0) / values.size();
  double variance = 0.0;
  for (double v : values) {
    double delta = v - mean;
    variance += delta * delta;
  }
  variance /= values.size();
  return {mean, std::sqrt(variance)};
}

double calcMeanLatencyofGPUTransfer(int64_t* start, int64_t* end,
                                    size_t numDestinations,
                                    size_t numWGsPerDst, size_t numWarpsPerWG) {
  double totalTicks = 0.0;
  size_t warpsPerDst = numWGsPerDst * numWarpsPerWG;
  for (size_t d = 0; d < numDestinations; ++d) {
    int64_t* dstStart = start + d * warpsPerDst;
    int64_t* dstEnd = end + d * warpsPerDst;
    int64_t earliest = *std::min_element(dstStart, dstStart + warpsPerDst);
    int64_t latest = *std::max_element(dstEnd, dstEnd + warpsPerDst);
    totalTicks += static_cast<double>(latest - earliest);
  }
  return totalTicks / static_cast<double>(numDestinations);
}

std::optional<size_t> verifyData(const std::vector<uint32_t>& hostSrc,
                                 void** dstBufs_d, size_t numDests,
                                 size_t transferSize) {
  std::vector<uint32_t> hostDst(transferSize / sizeof(uint32_t));
  size_t errors = 0;
  for (size_t d = 0; d < numDests; ++d) {
    void* dstPtr;
    CHECK_HIP_ERROR(
      hipMemcpy(&dstPtr, &dstBufs_d[d], sizeof(void*), hipMemcpyDeviceToHost));
    CHECK_HIP_ERROR(
      hipMemcpy(hostDst.data(), dstPtr, transferSize, hipMemcpyDeviceToHost));
    for (size_t i = 0; i < hostDst.size(); ++i) {
      if (hostDst[i] != hostSrc[i]) {
        if (errors < 10) {
          fprintf(stderr,
                  "Mismatch on dest %zu at word %zu: expected 0x%08x, got "
                  "0x%08x\n",
                  d, i, hostSrc[i], hostDst[i]);
        }
        ++errors;
      }
    }
  }
  return errors;
}

void printHeader(std::ostream& os) {
  os << std::left << std::setw(6) << "Src" << std::setw(6) << "Dests"
     << std::setw(8) << "Grid" << std::setw(8) << "Block" << std::setw(14)
     << "TransferSize" << std::setw(12) << "CopySize" << std::setw(8) << "Copies"
     << std::setw(14) << "Device(us)" << std::setw(12) << "DevStd"
     << std::setw(14) << "DeviceBW" << std::setw(14) << "Host(us)"
     << std::setw(12) << "HostStd" << std::setw(12) << "HostBW";
}

void runExperiment(int srcDeviceId, const ExperimentParams& params) {
  int hipDeviceCount = 0;
  CHECK_HIP_ERROR(hipGetDeviceCount(&hipDeviceCount));

  std::cout << "Src GPU Device Id: " << srcDeviceId << std::endl;

  std::vector<int> dstDeviceIds;
  for (int i = 0; i < hipDeviceCount; ++i) {
    if (srcDeviceId != i) {
      dstDeviceIds.push_back(i);
      if (params.verbose) {
        std::cout << "Device Id: " << i << std::endl;
      }
      if (dstDeviceIds.size() == params.numDestinations) {
        break;
      }
    }
  }

  if (params.verbose) {
    std::cout << "Dest GPU Ids: ";
    for (int id : dstDeviceIds)
      std::cout << id << " ";
    std::cout << std::endl;
  }

  std::vector<void*> sdmaDestBufferPtr;

  CHECK_HIP_ERROR(hipSetDevice(srcDeviceId));

  int warpSize;
  CHECK_HIP_ERROR(
    hipDeviceGetAttribute(&warpSize, hipDeviceAttributeWarpSize, srcDeviceId));
  int wgSize = params.numOfWarpsPerWG * warpSize;
  size_t totalNumWarps = params.numDestinations * params.numOfQueues *
                         params.numOfWGPerQueue * params.numOfWarpsPerWG;

  uint64_t* signalPtrs;
  CHECK_HIP_ERROR(hipMalloc(&signalPtrs, sizeof(uint64_t) * totalNumWarps));

  size_t maxP2PTransferSize = params.maxCopySize * params.numCopyCommands *
                              params.numOfWarpsPerWG * params.numOfWGPerQueue *
                              params.numOfQueues;

  void* sdma_src_buf = nullptr;
  CHECK_HIP_ERROR(
    hipExtMallocWithFlags(&sdma_src_buf, maxP2PTransferSize, hipDeviceMallocUncached));

  size_t num_elements = maxP2PTransferSize / sizeof(uint32_t);
  std::vector<uint32_t> hostSrcBuffer(num_elements, MAGIC_VALUE);
  CHECK_HIP_ERROR(hipMemcpy(sdma_src_buf, hostSrcBuffer.data(),
                            maxP2PTransferSize, hipMemcpyHostToDevice));

  for (size_t d = 0; d < dstDeviceIds.size(); d++) {
    int dstGPUId = dstDeviceIds[d];
    void* buf;
    CHECK_HIP_ERROR(hipSetDevice(dstGPUId));
    CHECK_HIP_ERROR(
      hipExtMallocWithFlags(&buf, maxP2PTransferSize, hipDeviceMallocUncached));
    enablePeerAccess(srcDeviceId, dstGPUId);
    sdmaDestBufferPtr.push_back(buf);
  }

  CHECK_HIP_ERROR(hipSetDevice(srcDeviceId));

  void** sdma_dst_bufs_d;
  CHECK_HIP_ERROR(
    hipMalloc((void**)&sdma_dst_bufs_d, sdmaDestBufferPtr.size() * sizeof(void*)));
  CHECK_HIP_ERROR(hipMemcpy(sdma_dst_bufs_d, sdmaDestBufferPtr.data(),
                            sdmaDestBufferPtr.size() * sizeof(void*),
                            hipMemcpyHostToDevice));

  // Queue Setup
  size_t totalNumQueues = params.numOfQueues * params.numDestinations;

  if (sdma_ep::initEndpoint() != 0) {
    std::cerr << "ERROR: failed to initialize SDMA endpoint" << std::endl;
    exit(EXIT_FAILURE);
  }

  std::vector<sdma_ep::SdmaQueueInfo> queueInfos;
  queueInfos.reserve(totalNumQueues);

  sdma_ep::SdmaQueueHandle** deviceHandles_d = nullptr;
  CHECK_HIP_ERROR(
    hipMalloc(&deviceHandles_d, totalNumQueues * sizeof(sdma_ep::SdmaQueueHandle*)));

  size_t queueIdx = 0;
  for (auto& dstDeviceId : dstDeviceIds) {
    for (size_t q = 0; q < params.numOfQueues; q++) {
      sdma_ep::SdmaQueueInfo info = {};
      if (sdma_ep::createQueue(srcDeviceId, dstDeviceId, &info) != 0) {
        std::cerr << "ERROR: failed to create queue " << q << " for GPU "
                  << dstDeviceId << std::endl;
        exit(EXIT_FAILURE);
      }
      queueInfos.push_back(info);
      deviceHandles_d[queueIdx] =
        static_cast<sdma_ep::SdmaQueueHandle*>(info.deviceHandle);
      queueIdx++;
    }
  }

  // Allocate memories for timestamps
  int64_t* start_clock_count;
  int64_t* end_clock_count;
  int64_t* start_clock_count_d;
  int64_t* end_clock_count_d;

  CHECK_HIP_ERROR(hipHostMalloc(&start_clock_count,
                                params.numIterations * totalNumWarps * sizeof(int64_t)));
  CHECK_HIP_ERROR(hipHostMalloc(&end_clock_count,
                                params.numIterations * totalNumWarps * sizeof(int64_t)));
  CHECK_HIP_ERROR(hipMalloc(&start_clock_count_d,
                            params.numIterations * totalNumWarps * sizeof(int64_t)));
  CHECK_HIP_ERROR(hipMalloc(&end_clock_count_d,
                            params.numIterations * totalNumWarps * sizeof(int64_t)));

  CHECK_HIP_ERROR(hipMemset(start_clock_count_d, 0,
                            params.numIterations * totalNumWarps * sizeof(int64_t)));
  CHECK_HIP_ERROR(hipMemset(end_clock_count_d, 0,
                            params.numIterations * totalNumWarps * sizeof(int64_t)));

  // Kernel Launch
  int numWgs = params.numDestinations * params.numOfQueues * params.numOfWGPerQueue;
  if (params.verbose) {
    std::cout << "BlockDim.x: " << wgSize << ", GridDim.x: " << numWgs
              << std::endl;
    std::cout << "#Warps/Q or #Warps/WG: " << params.numOfWarpsPerWG
              << std::endl;
  }

  dim3 grid(numWgs, 1, 1);
  dim3 block(wgSize, 1, 1);

  printHeader(std::cout);
  std::cout << std::endl;

  std::ofstream csvFile(params.resultFileName);
  csvFile << "Src,#Destinations,#Queues,GridDim,BlockDim,Total Transfer Size "
             "[B],Copy Size [B],#Copies,Device Latency [us] (Mean),Device "
             "Latency [us] (Std),Bandwidth [GB/s] (Device),Host Latency [us] "
             "(Mean),Host Latency [us] (Std),Bandwidth [GB/s] (Host)\n";

  for (size_t copySize = params.minCopySize; copySize <= params.maxCopySize;
       copySize *= 2) {
    size_t totalTransferSize = copySize * params.numCopyCommands *
                               params.numOfWarpsPerWG * params.numOfWGPerQueue *
                               params.numOfQueues;

    if (params.verbose) {
      std::cout << "Copy Size: " << copySize << " bytes." << std::endl;
      std::cout << "Transfer Size Per xGMI link: " << totalTransferSize
                << " bytes." << std::endl;
    }

    for (void* buf : sdmaDestBufferPtr) {
      CHECK_HIP_ERROR(hipMemset(buf, 0, totalTransferSize));
    }

    CHECK_HIP_ERROR(
      hipMemset(signalPtrs, 0, sizeof(uint64_t) * totalNumWarps));
    uint64_t expectedSignal = 1;

    std::optional<size_t> numErrors;
    if (!params.skipVerification) {
      hipLaunchKernelGGL(multiQueueSDMATransferQueueMapWG, grid, block, 0, 0, 0,
                         sdma_src_buf, sdma_dst_bufs_d, copySize,
                         params.numCopyCommands, params.numDestinations,
                         params.numOfQueues, params.numOfWGPerQueue,
                         deviceHandles_d, signalPtrs, expectedSignal,
                         start_clock_count_d, end_clock_count_d);
      CHECK_HIP_ERROR(hipDeviceSynchronize());
      expectedSignal++;
      numErrors =
        verifyData(hostSrcBuffer, sdma_dst_bufs_d, dstDeviceIds.size(), totalTransferSize);
      if (numErrors != 0) {
        std::cerr << "Data verification failed\n";
        exit(-1);
      }
    }

    // Warming up
    for (size_t i = 0; i < params.nWarmupIterations; ++i) {
      hipLaunchKernelGGL(multiQueueSDMATransferQueueMapWG, grid, block, 0, 0, i,
                         sdma_src_buf, sdma_dst_bufs_d, copySize,
                         params.numCopyCommands, params.numDestinations,
                         params.numOfQueues, params.numOfWGPerQueue,
                         deviceHandles_d, signalPtrs, expectedSignal,
                         start_clock_count_d, end_clock_count_d);
      expectedSignal++;
    }
    CHECK_HIP_ERROR(hipDeviceSynchronize());

    // Setup hipEvents
    std::vector<hipEvent_t> timestamps_events(params.numIterations * 2);
    for (size_t iter = 0; iter < params.numIterations * 2; iter++) {
      CHECK_HIP_ERROR(hipEventCreate(&timestamps_events[iter]));
    }

    std::vector<double> latency_device;
    std::vector<double> latency_host;
    int64_t* startTimestampPtr = start_clock_count_d;
    int64_t* endTimestampPtr = end_clock_count_d;

    for (size_t iter = 0; iter < params.numIterations; ++iter) {
      hipExtLaunchKernelGGL(multiQueueSDMATransferQueueMapWG, grid, block, 0, 0,
                            timestamps_events[iter * 2],
                            timestamps_events[iter * 2 + 1], 0, iter,
                            sdma_src_buf, sdma_dst_bufs_d, copySize,
                            params.numCopyCommands, params.numDestinations,
                            params.numOfQueues, params.numOfWGPerQueue,
                            deviceHandles_d, signalPtrs, expectedSignal,
                            startTimestampPtr, endTimestampPtr);
      startTimestampPtr += totalNumWarps;
      endTimestampPtr += totalNumWarps;
      expectedSignal++;
    }
    CHECK_HIP_ERROR(hipDeviceSynchronize());

    // Performance Metrics
    CHECK_HIP_ERROR(hipMemcpy(start_clock_count, start_clock_count_d,
                              params.numIterations * totalNumWarps * sizeof(int64_t),
                              hipMemcpyDeviceToHost));
    CHECK_HIP_ERROR(hipMemcpy(end_clock_count, end_clock_count_d,
                              params.numIterations * totalNumWarps * sizeof(int64_t),
                              hipMemcpyDeviceToHost));

    for (size_t iter = 0; iter < params.numIterations; ++iter) {
      double device_latency_ms =
        calcMeanLatencyofGPUTransfer(
          start_clock_count + (iter * totalNumWarps),
          end_clock_count + (iter * totalNumWarps), params.numDestinations,
          params.numOfQueues * params.numOfWGPerQueue, params.numOfWarpsPerWG) /
        1e5;

      float host_latency_ms;
      CHECK_HIP_ERROR(hipEventElapsedTime(&host_latency_ms,
                                          timestamps_events[iter * 2],
                                          timestamps_events[iter * 2 + 1]));

      latency_device.push_back(device_latency_ms);
      latency_host.push_back(host_latency_ms);
    }

    auto [latency_device_mean, latency_device_std] = avg_std(latency_device);
    auto [latency_host_mean, latency_host_std] = avg_std(latency_host);

    double sizeAcrossAllLinks = (double)dstDeviceIds.size() * totalTransferSize;

    double deviceBandwidth_gbs =
      (sizeAcrossAllLinks / 1.0E9) / (latency_device_mean / 1000);
    double hostBandwidth_gbs =
      (sizeAcrossAllLinks / 1.0E9) / (latency_host_mean / 1000);

    std::cout << std::left << std::setw(6) << srcDeviceId << std::setw(6)
              << dstDeviceIds.size() << std::setw(8) << numWgs << std::setw(8)
              << wgSize << std::setw(14) << totalTransferSize << std::setw(12)
              << copySize << std::setw(8) << params.numCopyCommands
              << std::setw(14) << latency_device_mean * 1000 << std::setw(12)
              << latency_device_std << std::setw(14) << deviceBandwidth_gbs
              << std::setw(14) << latency_host_mean * 1000 << std::setw(12)
              << latency_host_std << std::setw(12) << hostBandwidth_gbs
              << std::endl;

    csvFile << srcDeviceId << "," << dstDeviceIds.size() << ","
            << params.numOfQueues << "," << numWgs << "," << wgSize << ","
            << totalTransferSize << "," << copySize << ","
            << params.numCopyCommands << "," << latency_device_mean * 1000
            << "," << latency_device_std << "," << deviceBandwidth_gbs << ","
            << latency_host_mean * 1000 << "," << latency_host_std << ","
            << hostBandwidth_gbs << "\n";

    for (size_t iter = 0; iter < params.numIterations * 2; iter++) {
      CHECK_HIP_ERROR(hipEventDestroy(timestamps_events[iter]));
    }
  }

  csvFile.close();

  // Resource Cleanup
  CHECK_HIP_ERROR(hipFreeHost(start_clock_count));
  CHECK_HIP_ERROR(hipFreeHost(end_clock_count));
  CHECK_HIP_ERROR(hipFree(start_clock_count_d));
  CHECK_HIP_ERROR(hipFree(end_clock_count_d));
  CHECK_HIP_ERROR(hipFree(deviceHandles_d));
  CHECK_HIP_ERROR(hipFree(signalPtrs));
  CHECK_HIP_ERROR(hipFree(sdma_src_buf));
  CHECK_HIP_ERROR(hipFree(sdma_dst_bufs_d));
  for (void* buf : sdmaDestBufferPtr) {
    CHECK_HIP_ERROR(hipFree(buf));
  }
  for (auto& info : queueInfos) {
    sdma_ep::destroyQueue(&info);
  }
  sdma_ep::shutdownEndpoint();
}

int main(int argc, char** argv) {
  CLI::App app("Shader-initiated SDMA");

  int srcGpuId{0};
  app.add_option("--srcGpu", srcGpuId, "Source GPU device ID");

  size_t minCopySize{1024};
  app.add_option("-b,--minCopySize", minCopySize,
                 "Minimum Transfer Size [B] (per copy command)");
  size_t maxCopySize{1024};
  app.add_option("-e,--maxCopySize", maxCopySize,
                 "Maximum Transfer Size [B] (per copy command)");
  size_t numCopyCommands{1};
  app.add_option("-c,--numCopyCommands", numCopyCommands,
                 "Number of copy commands (per warp)");

  bool skipVerification{false};
  app.add_flag("--skip-verification", skipVerification, "Skip verification");

  size_t nWarmupIterations{3};
  app.add_option("-w,--warmup", nWarmupIterations,
                 "Number of warmup iterations");

  size_t numIterations{50};
  app.add_option("-n,--iterations", numIterations, "Number of iterations");

  size_t numDestinations{1};
  app.add_option("-d,--numDestinations", numDestinations,
                 "Number of destination GPUs");

  size_t numOfQueues{1};
  app.add_option("--numOfQueuesPerDestination", numOfQueues,
                 "Number of queues per destination");

  size_t numOfWarpsPerWG{1};
  app.add_option("--warpsPerWG", numOfWarpsPerWG,
                 "Number of warps shared the same queue resources");

  size_t numOfWGPerQueue{1};
  app.add_option("--wgsPerQueue", numOfWGPerQueue,
                 "Number of workgroups shared the same queue resources");

  std::string resultFileName = "MultiQueueGPU2GPU_Performance.csv";
  app.add_option("-o,--outputFile", resultFileName, "Filename for result");

  bool verbose{false};
  app.add_flag("-v, --verbose", verbose, "verbose output");

  CLI11_PARSE(app, argc, argv);

  std::cout << "==== Running shader_bw doing " << numCopyCommands
            << " copies of size " << minCopySize << " to " << maxCopySize
            << " ====" << std::endl;

  ExperimentParams params{
    .minCopySize = minCopySize,
    .maxCopySize = maxCopySize,
    .numCopyCommands = numCopyCommands,
    .skipVerification = skipVerification,
    .nWarmupIterations = nWarmupIterations,
    .numIterations = numIterations,
    .numDestinations = numDestinations,
    .numOfQueues = numOfQueues,
    .numOfWarpsPerWG = numOfWarpsPerWG,
    .numOfWGPerQueue = numOfWGPerQueue,
    .resultFileName = resultFileName,
    .verbose = verbose,
  };

  runExperiment(srcGpuId, params);

  return 0;
}
