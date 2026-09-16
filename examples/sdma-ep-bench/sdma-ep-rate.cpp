/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <numeric>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include <hip/hip_ext.h>
#include <hip/hip_runtime.h>

#include <CLI/CLI.hpp>

#include "endpoints/sdma-ep/sdma-ep.h"
#include "endpoints/sdma-ep/sdma-host-queue.h"
#include "sdma_rate_kernel.h"
#include "xio.h"

using namespace xio;

namespace {

constexpr uint32_t MAGIC_VALUE = 0xDEADBEEF;
constexpr double SDMA_TIMESTAMP_FREQUENCY_HZ = 100000000.0;

#define CHECK_HIP_ERROR(cmd)                                                   \
  do {                                                                         \
    hipError_t error = cmd;                                                    \
    if (error != hipSuccess) {                                                 \
      std::cerr << "HIP error " << error << ": " << hipGetErrorString(error)   \
                << " at " << __FILE__ << ":" << __LINE__ << std::endl;         \
      std::exit(EXIT_FAILURE);                                                 \
    }                                                                          \
  } while (0)

struct Params {
  size_t minCopySize = 64;
  size_t maxCopySize = 64;
  size_t numCopyCommands = 10000;
  size_t warmup = 1;
  size_t iterations = 10;
  size_t numQueues = 1;
  int srcGpu = 0;
  int dstGpu = 1;
  bool skipVerification = false;
  bool deviceTriggered = false;
  bool deviceTriggeredCopyOnly = false;
  bool deviceInitiatedPoll = false;
  bool pollOnly = false;
  bool atomicOnly = false;
  bool copyAtomic = false;
  std::string atomicMemory = "local";
  bool sdmaTimestamps = false;
  bool verbose = false;
  std::string outputFile = "packet_rate.csv";
};

std::pair<double, double> averageAndStd(const std::vector<double>& values) {
  const double mean = std::accumulate(values.begin(), values.end(), 0.0) /
                      values.size();
  double variance = 0.0;
  for (double value : values) {
    const double delta = value - mean;
    variance += delta * delta;
  }
  return {mean, std::sqrt(variance / values.size())};
}

void verifyData(const std::vector<uint32_t>& expected, void* dst,
                size_t bytes) {
  std::vector<uint32_t> actual(bytes / sizeof(uint32_t));
  CHECK_HIP_ERROR(hipMemcpy(actual.data(), dst, bytes, hipMemcpyDeviceToHost));
  for (size_t index = 0; index < actual.size(); ++index) {
    if (actual[index] != expected[index]) {
      std::cerr << "Data verification failed at word " << index << ": expected "
                << std::hex << expected[index] << ", got " << actual[index]
                << std::dec << std::endl;
      std::exit(EXIT_FAILURE);
    }
  }
}

void run(const Params& params) {
  if (params.maxCopySize > 0xFFFFFFFFULL ||
      params.maxCopySize >
        std::numeric_limits<size_t>::max() / params.numCopyCommands ||
      params.maxCopySize * params.numCopyCommands >
        std::numeric_limits<size_t>::max() / params.numQueues) {
    throw std::runtime_error("transfer size exceeds addressable memory");
  }
  const size_t pollBytes = sizeof(anvil::packets::PollRegmemPacket<uint32_t>);
  const size_t copyBytes = params.numCopyCommands *
                           sizeof(SDMA_PKT_COPY_LINEAR);
  const size_t pollCount = (params.deviceTriggered ||
                            params.deviceInitiatedPoll)
                             ? params.numCopyCommands
                             : (params.deviceTriggeredCopyOnly ? 1 : 0);
  const size_t timestampCount = params.sdmaTimestamps ? 2 : 0;
  const size_t requiredQueueBytes = copyBytes + pollCount * pollBytes +
                                    timestampCount *
                                      sizeof(SDMA_PKT_TIMESTAMP) +
                                    sizeof(SDMA_PKT_ATOMIC);
  if (requiredQueueBytes >= sdma_ep::SDMA_QUEUE_SIZE) {
    throw std::runtime_error("packet batch exceeds the 8 MiB SDMA queue");
  }

  int deviceCount = 0;
  CHECK_HIP_ERROR(hipGetDeviceCount(&deviceCount));
  if (params.srcGpu < 0 || params.dstGpu < 0 || params.srcGpu >= deviceCount ||
      params.dstGpu >= deviceCount || params.srcGpu == params.dstGpu) {
    throw std::runtime_error("source and destination GPU IDs are invalid");
  }

  int warpSize = 0;
  CHECK_HIP_ERROR(hipDeviceGetAttribute(&warpSize, hipDeviceAttributeWarpSize,
                                        params.srcGpu));
  int maxThreads = 0;
  CHECK_HIP_ERROR(hipDeviceGetAttribute(&maxThreads,
                                        hipDeviceAttributeMaxThreadsPerBlock,
                                        params.srcGpu));
  if (params.numQueues * static_cast<size_t>(warpSize) >
      static_cast<size_t>(maxThreads)) {
    throw std::runtime_error("numQueues exceeds the maximum block size");
  }

  CHECK_HIP_ERROR(hipSetDevice(params.srcGpu));
  if (sdma_ep::initEndpoint() != 0)
    throw std::runtime_error("failed to initialize SDMA endpoint");
  enablePeerAccess(params.srcGpu, params.dstGpu);

  const size_t maxTransfer = params.maxCopySize * params.numCopyCommands *
                             params.numQueues;
  void* src = nullptr;
  void* dst = nullptr;
  CHECK_HIP_ERROR(
    hipExtMallocWithFlags(&src, maxTransfer, hipDeviceMallocUncached));
  CHECK_HIP_ERROR(hipSetDevice(params.dstGpu));
  CHECK_HIP_ERROR(
    hipExtMallocWithFlags(&dst, maxTransfer, hipDeviceMallocUncached));
  CHECK_HIP_ERROR(hipSetDevice(params.srcGpu));

  std::vector<uint32_t> expected(maxTransfer / sizeof(uint32_t), MAGIC_VALUE);
  CHECK_HIP_ERROR(
    hipMemcpy(src, expected.data(), maxTransfer, hipMemcpyHostToDevice));

  std::vector<sdma_ep::SdmaQueueInfo> queueInfos(params.numQueues);
  const bool hostTriggered = params.deviceTriggered ||
                             params.deviceTriggeredCopyOnly;
  std::vector<sdma_ep::SdmaQueueHostHandle> hostQueueHandles;
  if (hostTriggered)
    hostQueueHandles.reserve(params.numQueues);
  std::vector<sdma_ep::SdmaQueueHandle*> hostHandles(params.numQueues);
  for (size_t queue = 0; queue < params.numQueues; ++queue) {
    int rc = hostTriggered
               ? sdma_ep::createHostQueue(params.srcGpu, params.dstGpu,
                                          &queueInfos[queue])
               : sdma_ep::createQueue(params.srcGpu, params.dstGpu,
                                      &queueInfos[queue]);
    if (rc != 0) {
      throw std::runtime_error("failed to create SDMA queue");
    }
    if (hostTriggered) {
      hostQueueHandles.push_back(
        sdma_ep::getHostHandle(params.srcGpu, params.dstGpu,
                               queueInfos[queue].channelIdx));
    } else {
      hostHandles[queue] = static_cast<sdma_ep::SdmaQueueHandle*>(
        queueInfos[queue].deviceHandle);
    }
  }

  sdma_ep::SdmaQueueHandle** deviceHandles = nullptr;
  CHECK_HIP_ERROR(
    hipMalloc(&deviceHandles, params.numQueues * sizeof(hostHandles.front())));
  CHECK_HIP_ERROR(hipMemcpy(deviceHandles, hostHandles.data(),
                            params.numQueues * sizeof(hostHandles.front()),
                            hipMemcpyHostToDevice));

  uint64_t* signals = nullptr;
  CHECK_HIP_ERROR(hipMalloc(&signals, params.numQueues * sizeof(uint64_t)));
  int64_t* startDevice = nullptr;
  int64_t* endDevice = nullptr;
  CHECK_HIP_ERROR(hipMalloc(&startDevice, params.iterations * params.numQueues *
                                            sizeof(int64_t)));
  CHECK_HIP_ERROR(hipMalloc(&endDevice, params.iterations * params.numQueues *
                                          sizeof(int64_t)));
  std::vector<int64_t> startHost(params.iterations * params.numQueues);
  std::vector<int64_t> endHost(params.iterations * params.numQueues);
  uint32_t* trigger = nullptr;
  uint64_t** atomicTargets = nullptr;
  std::vector<uint64_t*> atomicTargetHost(params.numQueues);
  uint64_t* sdmaStart = nullptr;
  uint64_t* sdmaEnd = nullptr;
  std::vector<uint64_t> sdmaStartHost(params.iterations * params.numQueues);
  std::vector<uint64_t> sdmaEndHost(params.iterations * params.numQueues);
  if (hostTriggered) {
    CHECK_HIP_ERROR(hipExtMallocWithFlags(reinterpret_cast<void**>(&trigger),
                                          sizeof(uint32_t),
                                          hipDeviceMallocUncached));
  }
  if (params.deviceInitiatedPoll) {
    CHECK_HIP_ERROR(hipExtMallocWithFlags(reinterpret_cast<void**>(&trigger),
                                          sizeof(uint32_t),
                                          hipDeviceMallocUncached));
    CHECK_HIP_ERROR(hipMemset(trigger, 1, sizeof(uint32_t)));
  }
  if (params.pollOnly) {
    CHECK_HIP_ERROR(hipExtMallocWithFlags(reinterpret_cast<void**>(&trigger),
                                          sizeof(uint32_t),
                                          hipDeviceMallocUncached));
    CHECK_HIP_ERROR(hipMemset(trigger, 1, sizeof(uint32_t)));
  }
  if (params.atomicOnly) {
    int targetGpu = params.atomicMemory == "remote" ? params.dstGpu
                                                    : params.srcGpu;
    CHECK_HIP_ERROR(hipSetDevice(targetGpu));
    for (auto& target : atomicTargetHost)
      CHECK_HIP_ERROR(hipExtMallocWithFlags(reinterpret_cast<void**>(&target),
                                            sizeof(uint64_t),
                                            hipDeviceMallocUncached));
    CHECK_HIP_ERROR(hipSetDevice(params.srcGpu));
    CHECK_HIP_ERROR(
      hipMalloc(&atomicTargets, params.numQueues * sizeof(uint64_t*)));
    CHECK_HIP_ERROR(hipMemcpy(atomicTargets, atomicTargetHost.data(),
                              params.numQueues * sizeof(uint64_t*),
                              hipMemcpyHostToDevice));
  }
  if (params.copyAtomic) {
    CHECK_HIP_ERROR(hipSetDevice(params.dstGpu));
    for (auto& target : atomicTargetHost)
      CHECK_HIP_ERROR(hipExtMallocWithFlags(reinterpret_cast<void**>(&target),
                                            sizeof(uint64_t),
                                            hipDeviceMallocUncached));
    CHECK_HIP_ERROR(hipSetDevice(params.srcGpu));
    CHECK_HIP_ERROR(
      hipMalloc(&atomicTargets, params.numQueues * sizeof(uint64_t*)));
    CHECK_HIP_ERROR(hipMemcpy(atomicTargets, atomicTargetHost.data(),
                              params.numQueues * sizeof(uint64_t*),
                              hipMemcpyHostToDevice));
  }
  if (params.sdmaTimestamps) {
    CHECK_HIP_ERROR(xio::allocHostMemory(
      params.iterations * params.numQueues * sizeof(uint64_t),
      reinterpret_cast<void**>(&sdmaStart), "SDMA timestamp begin",
      XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT));
    CHECK_HIP_ERROR(xio::allocHostMemory(
      params.iterations * params.numQueues * sizeof(uint64_t),
      reinterpret_cast<void**>(&sdmaEnd), "SDMA timestamp end",
      XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT));
  }

  std::ofstream output(params.outputFile);
  output << "Mode,Src,#Destinations,#Queues,GridDim,BlockDim,Copy Size [B],"
            "#Copy Commands,Device Latency [us],Host Latency [us],"
            "Device Bandwidth [GB/s],Host Bandwidth [GB/s],"
            "Copy Packet Rate [MPPS],SDMA Packet Rate [MPPS],"
            "Host Copy Packet Rate [MPPS],Copy Time [ns/packet],"
            "SDMA Time [ns/packet]\n";
  std::cout
    << "CopySize  Queues  Device(us)  Host(us)  Device(MPPS)  Host(MPPS)\n";

  dim3 grid(1, 1, 1);
  dim3 block(params.numQueues * warpSize, 1, 1);
  for (size_t copySize = params.minCopySize; copySize <= params.maxCopySize;
       copySize *= 2) {
    const size_t totalTransfer = copySize * params.numCopyCommands *
                                 params.numQueues;
    CHECK_HIP_ERROR(hipMemset(signals, 0, params.numQueues * sizeof(uint64_t)));
    if (trigger)
      CHECK_HIP_ERROR(
        hipMemset(trigger,
                  (params.deviceInitiatedPoll || params.pollOnly) ? 1 : 0,
                  sizeof(uint32_t)));
    if (params.atomicOnly || params.copyAtomic) {
      int targetGpu = params.atomicMemory == "remote" ? params.dstGpu
                                                      : params.srcGpu;
      CHECK_HIP_ERROR(hipSetDevice(targetGpu));
      for (auto* target : atomicTargetHost)
        CHECK_HIP_ERROR(hipMemset(target, 0, sizeof(uint64_t)));
      CHECK_HIP_ERROR(hipSetDevice(params.srcGpu));
    }
    CHECK_HIP_ERROR(hipDeviceSynchronize());
    uint64_t expectedSignal = 1;
    const bool isolatedMode = params.pollOnly || params.atomicOnly;

    auto preprogramBatch = [&](uint64_t* timestampStart = nullptr,
                               uint64_t* timestampEnd = nullptr) {
      for (size_t queue = 0; queue < params.numQueues; ++queue) {
        auto* queueSrc = static_cast<char*>(src) +
                         queue * copySize * params.numCopyCommands;
        auto* queueDst = static_cast<char*>(dst) +
                         queue * copySize * params.numCopyCommands;
        std::vector<sdma_ep::SdmaPacket> packets;
        packets.reserve(params.numCopyCommands * 2 + 1);
        if (params.deviceTriggeredCopyOnly) {
          packets.emplace_back(
            anvil::packets::PollRegmemPacket<uint32_t>(trigger, uint32_t{1}));
          if (timestampStart)
            packets.emplace_back(
              anvil::packets::TimestampPacket(timestampStart + queue));
        }
        for (size_t command = 0; command < params.numCopyCommands; ++command) {
          if (params.deviceTriggered) {
            packets.emplace_back(
              anvil::packets::PollRegmemPacket<uint32_t>(trigger, uint32_t{1}));
            if (command == 0 && timestampStart)
              packets.emplace_back(
                anvil::packets::TimestampPacket(timestampStart + queue));
          }
          packets.emplace_back(
            anvil::packets::CopyLinearPacket(queueSrc + command * copySize,
                                             queueDst + command * copySize,
                                             copySize));
        }
        if (timestampEnd)
          packets.emplace_back(
            anvil::packets::TimestampPacket(timestampEnd + queue));
        packets.emplace_back(
          anvil::packets::AtomicAddPacket<uint64_t>(signals + queue, 1));
        hostQueueHandles[queue].submit(packets);
      }
    };

    auto runTriggered = [&](int64_t* starts, int64_t* ends,
                            uint64_t* timestampStart = nullptr,
                            uint64_t* timestampEnd = nullptr) {
      preprogramBatch(timestampStart, timestampEnd);
      triggeredPacketRateKernel<<<grid, block>>>(trigger, signals,
                                                 expectedSignal, starts, ends);
      ++expectedSignal;
    };

    auto runPollOnly = [&](int64_t* starts, int64_t* ends) {
      pollOnlyRateKernel<<<grid, block>>>(deviceHandles, trigger, signals,
                                          params.numCopyCommands,
                                          expectedSignal, starts, ends);
      ++expectedSignal;
    };

    auto runAtomicOnly = [&](int64_t* starts, int64_t* ends) {
      atomicOnlyRateKernel<<<grid, block>>>(deviceHandles, atomicTargets,
                                            params.numCopyCommands,
                                            expectedSignal, starts, ends);
      expectedSignal += params.numCopyCommands;
    };

    if (!params.skipVerification && !isolatedMode) {
      if (hostTriggered) {
        runTriggered(startDevice, endDevice);
      } else {
        packetRateKernel<<<grid, block>>>(
          src, dst, copySize, params.numCopyCommands, deviceHandles, signals,
          expectedSignal, startDevice, endDevice, nullptr, nullptr,
          params.deviceInitiatedPoll ? trigger : nullptr,
          params.copyAtomic ? atomicTargets : nullptr, params.copyAtomic);
        ++expectedSignal;
      }
      CHECK_HIP_ERROR(hipDeviceSynchronize());
      verifyData(expected, dst, totalTransfer);
      if (hostTriggered) {
        for (auto& queue : hostQueueHandles)
          queue.quiet();
      }
    }

    for (size_t iteration = 0; iteration < params.warmup; ++iteration) {
      if (params.pollOnly) {
        runPollOnly(startDevice, endDevice);
      } else if (params.atomicOnly) {
        runAtomicOnly(startDevice, endDevice);
      } else if (hostTriggered) {
        runTriggered(startDevice, endDevice);
      } else {
        packetRateKernel<<<grid, block>>>(
          src, dst, copySize, params.numCopyCommands, deviceHandles, signals,
          expectedSignal, startDevice, endDevice, nullptr, nullptr,
          params.deviceInitiatedPoll ? trigger : nullptr,
          params.copyAtomic ? atomicTargets : nullptr, params.copyAtomic);
        ++expectedSignal;
      }
    }
    CHECK_HIP_ERROR(hipDeviceSynchronize());
    if (hostTriggered) {
      for (auto& queue : hostQueueHandles)
        queue.quiet();
    }

    std::vector<hipEvent_t> events(params.iterations + 1);
    for (auto& event : events)
      CHECK_HIP_ERROR(hipEventCreate(&event));
    for (size_t iteration = 0; iteration < params.iterations; ++iteration) {
      CHECK_HIP_ERROR(hipEventRecord(events[iteration]));
      if (params.pollOnly) {
        runPollOnly(startDevice + iteration * params.numQueues,
                    endDevice + iteration * params.numQueues);
      } else if (params.atomicOnly) {
        runAtomicOnly(startDevice + iteration * params.numQueues,
                      endDevice + iteration * params.numQueues);
      } else if (hostTriggered) {
        runTriggered(startDevice + iteration * params.numQueues,
                     endDevice + iteration * params.numQueues,
                     sdmaStart ? sdmaStart + iteration * params.numQueues
                               : nullptr,
                     sdmaEnd ? sdmaEnd + iteration * params.numQueues
                             : nullptr);
      } else {
        packetRateKernel<<<grid, block>>>(
          src, dst, copySize, params.numCopyCommands, deviceHandles, signals,
          expectedSignal, startDevice + iteration * params.numQueues,
          endDevice + iteration * params.numQueues,
          sdmaStart ? sdmaStart + iteration * params.numQueues : nullptr,
          sdmaEnd ? sdmaEnd + iteration * params.numQueues : nullptr,
          params.deviceInitiatedPoll ? trigger : nullptr,
          params.copyAtomic ? atomicTargets : nullptr, params.copyAtomic);
        ++expectedSignal;
      }
    }
    CHECK_HIP_ERROR(hipEventRecord(events.back()));
    CHECK_HIP_ERROR(hipDeviceSynchronize());
    if (hostTriggered) {
      for (auto& queue : hostQueueHandles)
        queue.quiet();
    }
    CHECK_HIP_ERROR(hipMemcpy(startHost.data(), startDevice,
                              startHost.size() * sizeof(int64_t),
                              hipMemcpyDeviceToHost));
    CHECK_HIP_ERROR(hipMemcpy(endHost.data(), endDevice,
                              endHost.size() * sizeof(int64_t),
                              hipMemcpyDeviceToHost));
    if (params.sdmaTimestamps) {
      CHECK_HIP_ERROR(hipMemcpy(sdmaStartHost.data(), sdmaStart,
                                sdmaStartHost.size() * sizeof(uint64_t),
                                hipMemcpyDeviceToHost));
      CHECK_HIP_ERROR(hipMemcpy(sdmaEndHost.data(), sdmaEnd,
                                sdmaEndHost.size() * sizeof(uint64_t),
                                hipMemcpyDeviceToHost));
    }

    std::vector<double> deviceUs(params.iterations);
    std::vector<double> hostUs(params.iterations);
    for (size_t iteration = 0; iteration < params.iterations; ++iteration) {
      const auto startBegin = startHost.begin() + iteration * params.numQueues;
      const auto startEnd = startBegin + params.numQueues;
      const auto endBegin = endHost.begin() + iteration * params.numQueues;
      const auto endEnd = endBegin + params.numQueues;
      const int64_t earliest = *std::min_element(startBegin, startEnd);
      const int64_t latest = *std::max_element(endBegin, endEnd);
      if (params.sdmaTimestamps) {
        const auto timestampStartBegin = sdmaStartHost.begin() +
                                         iteration * params.numQueues;
        const auto timestampStartEnd = timestampStartBegin + params.numQueues;
        const auto timestampEndBegin = sdmaEndHost.begin() +
                                       iteration * params.numQueues;
        const auto timestampEndEnd = timestampEndBegin + params.numQueues;
        const uint64_t timestampBegin = *std::min_element(timestampStartBegin,
                                                          timestampStartEnd);
        const uint64_t timestampEnd = *std::max_element(timestampEndBegin,
                                                        timestampEndEnd);
        deviceUs[iteration] = static_cast<double>(timestampEnd -
                                                  timestampBegin) *
                              1.0e6 / SDMA_TIMESTAMP_FREQUENCY_HZ;
      } else {
        deviceUs[iteration] = static_cast<double>(latest - earliest) / 100.0;
      }
      float milliseconds = 0.0f;
      CHECK_HIP_ERROR(hipEventElapsedTime(&milliseconds, events[iteration],
                                          events[iteration + 1]));
      hostUs[iteration] = milliseconds * 1000.0;
    }
    for (auto event : events)
      CHECK_HIP_ERROR(hipEventDestroy(event));

    auto [deviceMean, deviceStd] = averageAndStd(deviceUs);
    auto [hostMean, hostStd] = averageAndStd(hostUs);
    const double copyMpps = (params.numQueues * params.numCopyCommands) /
                            deviceMean;
    const size_t pollPackets = (params.deviceTriggered ||
                                params.deviceInitiatedPoll)
                                 ? params.numCopyCommands
                                 : (params.deviceTriggeredCopyOnly ? 1 : 0);
    const size_t measuredPackets = params.atomicOnly
                                     ? params.numCopyCommands
                                     : params.numCopyCommands + pollPackets +
                                         (params.copyAtomic
                                            ? params.numCopyCommands
                                            : 0) +
                                         1;
    const double sdmaMpps = params.numQueues * measuredPackets / deviceMean;
    const double hostMpps = (params.numQueues * params.numCopyCommands) /
                            hostMean;
    const double copyTimeNs = 1000.0 / copyMpps;
    const double sdmaTimeNs = 1000.0 / sdmaMpps;
    const double deviceGbps = isolatedMode ? 0.0
                                           : (totalTransfer / 1.0e9) /
                                               (deviceMean / 1.0e6);
    const double hostGbps = isolatedMode
                              ? 0.0
                              : (totalTransfer / 1.0e9) / (hostMean / 1.0e6);

    std::cout << std::fixed << std::setprecision(3) << std::setw(8) << copySize
              << std::setw(8) << params.numQueues << std::setw(14) << deviceMean
              << std::setw(14) << hostMean << std::setw(14) << copyMpps
              << std::setw(14) << hostMpps << std::setw(16) << copyTimeNs
              << std::setw(16) << sdmaTimeNs << std::endl;
    const char* mode =
      params.pollOnly
        ? "poll-only"
        : (params.atomicOnly
             ? (params.atomicMemory == "remote" ? "atomic-only-remote"
                                                : "atomic-only-local")
             : (params.deviceInitiatedPoll && params.copyAtomic
                  ? "poll-copy-atomic"
                  : (params.copyAtomic
                       ? (params.atomicMemory == "remote" ? "copy-atomic-remote"
                                                          : "copy-atomic-local")
                     : params.deviceTriggered
                       ? "device-triggered"
                       : (params.deviceTriggeredCopyOnly
                            ? "device-triggered-copy-only"
                            : (params.deviceInitiatedPoll
                                 ? "device-initiated-poll"
                                 : "regular")))));
    output << mode << "," << params.srcGpu << ",1," << params.numQueues << ",1,"
           << block.x << "," << copySize << "," << params.numCopyCommands << ","
           << deviceMean << "," << hostMean << "," << deviceGbps << ","
           << hostGbps << "," << copyMpps << "," << sdmaMpps << "," << hostMpps
           << "," << copyTimeNs << "," << sdmaTimeNs << "\n";
  }

  CHECK_HIP_ERROR(hipFree(startDevice));
  CHECK_HIP_ERROR(hipFree(endDevice));
  CHECK_HIP_ERROR(hipFree(signals));
  if (trigger)
    CHECK_HIP_ERROR(hipFree(trigger));
  if (atomicTargets)
    CHECK_HIP_ERROR(hipFree(atomicTargets));
  int targetGpu = params.atomicMemory == "remote" ? params.dstGpu
                                                  : params.srcGpu;
  CHECK_HIP_ERROR(hipSetDevice(targetGpu));
  for (auto* target : atomicTargetHost)
    if (target)
      CHECK_HIP_ERROR(hipFree(target));
  CHECK_HIP_ERROR(hipSetDevice(params.srcGpu));
  if (sdmaStart)
    xio::freeHostMemory(sdmaStart, XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
  if (sdmaEnd)
    xio::freeHostMemory(sdmaEnd, XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
  CHECK_HIP_ERROR(hipFree(deviceHandles));
  CHECK_HIP_ERROR(hipFree(src));
  CHECK_HIP_ERROR(hipSetDevice(params.dstGpu));
  CHECK_HIP_ERROR(hipFree(dst));
  CHECK_HIP_ERROR(hipSetDevice(params.srcGpu));
  for (auto& info : queueInfos)
    sdma_ep::destroyQueue(&info);
  sdma_ep::shutdownEndpoint();
}

} // namespace

int main(int argc, char** argv) {
  Params params;
  CLI::App app("SDMA packet submission rate benchmark");
  app.add_option("--srcGpu", params.srcGpu, "Source GPU device ID");
  app.add_option("--dstGpu", params.dstGpu, "Destination GPU device ID");
  app.add_option("-b,--minCopySize", params.minCopySize,
                 "Minimum copy size in bytes");
  app.add_option("-e,--maxCopySize", params.maxCopySize,
                 "Maximum copy size in bytes");
  app.add_option("-c,--numCopyCommands", params.numCopyCommands,
                 "Copy packets per queue and iteration");
  app.add_option("--numOfQueues", params.numQueues, "Number of SDMA queues");
  app.add_option("-w,--warmup", params.warmup, "Warmup iterations");
  app.add_option("-n,--iterations", params.iterations, "Measured iterations");
  app.add_option("-o,--outputFile", params.outputFile, "CSV output path");
  app.add_flag("--skip-verification", params.skipVerification,
               "Skip destination verification");
  app.add_flag("--device-triggered", params.deviceTriggered,
               "Preprogram POLL+COPY packets and release them from the GPU");
  app.add_flag("--sdma-timestamps", params.sdmaTimestamps,
               "Measure host-triggered batches with SDMA timestamps");
  app.add_flag("--device-triggered-copy-only", params.deviceTriggeredCopyOnly,
               "Preprogram one POLL followed by COPY packets");
  app.add_flag("--device-initiated-poll", params.deviceInitiatedPoll,
               "Add an immediately satisfied POLL before each device COPY");
  app.add_flag("--poll-only", params.pollOnly,
               "Submit only immediately satisfied POLL packets");
  app.add_flag("--atomic-only", params.atomicOnly,
               "Submit only SDMA atomic-add packets");
  app.add_flag("--copy-atomic", params.copyAtomic,
               "Use an SDMA atomic for copy completion");
  app.add_option("--atomic-memory", params.atomicMemory,
                 "Atomic target memory: local or remote");
  app.add_flag("-v,--verbose", params.verbose, "Verbose output");
  CLI11_PARSE(app, argc, argv);

  if (params.deviceTriggered && params.deviceTriggeredCopyOnly)
    throw std::runtime_error(
      "--device-triggered and --device-triggered-copy-only are mutually "
      "exclusive");
  if (params.deviceInitiatedPoll &&
      (params.deviceTriggered || params.deviceTriggeredCopyOnly))
    throw std::runtime_error("poll modes are mutually exclusive");
  if (params.pollOnly && params.atomicOnly)
    throw std::runtime_error(
      "poll-only and atomic-only are mutually exclusive");
  if (params.atomicOnly && params.atomicMemory != "local" &&
      params.atomicMemory != "remote")
    throw std::runtime_error("atomic-memory must be local or remote");
  if (params.sdmaTimestamps &&
      !(params.deviceTriggered || params.deviceTriggeredCopyOnly))
    throw std::runtime_error(
      "--sdma-timestamps is currently supported only for host-triggered "
      "queues; SDMA TIMESTAMP hangs on device-created queues");

  if (params.minCopySize == 0 || params.maxCopySize < params.minCopySize ||
      params.numCopyCommands == 0 || params.numQueues == 0 ||
      params.iterations == 0) {
    throw std::runtime_error("invalid benchmark parameters");
  }
  run(params);
}
