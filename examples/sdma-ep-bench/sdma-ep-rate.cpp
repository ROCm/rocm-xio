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

#include "csv_writer.hpp"
#include "endpoints/sdma-ep/sdma-ep.h"
#include "endpoints/sdma-ep/sdma-host-queue.h"
#include "sdma_rate_kernel.h"
#include "xio.h"

using namespace xio;

namespace {

constexpr uint32_t MAGIC_VALUE = 0xDEADBEEF;

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
  size_t numCommands = 10000;
  size_t warmup = 1;
  size_t iterations = 10;
  size_t numQueues = 1;
  int srcGpu = 0;
  int dstGpu = 1;
  bool skipVerification = false;
  std::string mode = "copy";
  std::string atomicMemory = "local";
  bool verbose = false;
  std::string outputFile = "packet_rate.csv";
};

RateMode parseRateMode(const std::string& mode) {
  if (mode == "copy")
    return RateMode::Copy;
  if (mode == "poll-copy")
    return RateMode::PollCopy;
  if (mode == "copy-atomic")
    return RateMode::CopyAtomic;
  if (mode == "poll-copy-atomic")
    return RateMode::PollCopyAtomic;
  if (mode == "poll-only")
    return RateMode::PollOnly;
  if (mode == "atomic-only")
    return RateMode::AtomicOnly;
  throw std::runtime_error("mode must be copy, poll-copy, copy-atomic, "
                           "poll-copy-atomic, poll-only, or atomic-only");
}

const char* rateModeName(RateMode mode) {
  switch (mode) {
    case RateMode::Copy:
      return "copy";
    case RateMode::PollCopy:
      return "poll-copy";
    case RateMode::CopyAtomic:
      return "copy-atomic";
    case RateMode::PollCopyAtomic:
      return "poll-copy-atomic";
    case RateMode::PollOnly:
      return "poll-only";
    case RateMode::AtomicOnly:
      return "atomic-only";
  }
  return "unknown";
}

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
  const RateMode rateMode = parseRateMode(params.mode);
  const bool hasPoll = rateMode == RateMode::PollCopy ||
                       rateMode == RateMode::PollCopyAtomic ||
                       rateMode == RateMode::PollOnly;
  const bool hasCopy = rateMode == RateMode::Copy ||
                       rateMode == RateMode::PollCopy ||
                       rateMode == RateMode::CopyAtomic ||
                       rateMode == RateMode::PollCopyAtomic;
  const bool hasAtomic = rateMode == RateMode::CopyAtomic ||
                         rateMode == RateMode::PollCopyAtomic ||
                         rateMode == RateMode::AtomicOnly;
  if (params.maxCopySize > 0xFFFFFFFFULL ||
      params.maxCopySize >
        std::numeric_limits<size_t>::max() / params.numCommands ||
      params.maxCopySize * params.numCommands >
        std::numeric_limits<size_t>::max() / params.numQueues) {
    throw std::runtime_error("transfer size exceeds addressable memory");
  }
  const size_t pollBytes = sizeof(anvil::packets::PollRegmemPacket<uint32_t>);
  size_t commandBytes = 0;
  if (hasPoll) {
    commandBytes += sizeof(SDMA_PKT_POLL_REGMEM);
  }
  if (hasCopy) {
    commandBytes += sizeof(SDMA_PKT_COPY_LINEAR);
  }
  if (hasAtomic) {
    commandBytes += sizeof(SDMA_PKT_ATOMIC);
  }

  const size_t requiredQueueBytes = params.numCommands * commandBytes +
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

  const size_t maxTransfer = params.maxCopySize * params.numCommands *
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
  std::vector<sdma_ep::SdmaQueueHandle*> hostHandles(params.numQueues);
  for (size_t queue = 0; queue < params.numQueues; ++queue) {
    int rc = sdma_ep::createQueue(params.srcGpu, params.dstGpu,
                                  &queueInfos[queue]);
    if (rc != 0) {
      throw std::runtime_error("failed to create SDMA queue");
    }
    hostHandles[queue] = static_cast<sdma_ep::SdmaQueueHandle*>(
      queueInfos[queue].deviceHandle);
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
  if (hasPoll) {
    CHECK_HIP_ERROR(hipExtMallocWithFlags(reinterpret_cast<void**>(&trigger),
                                          sizeof(uint32_t),
                                          hipDeviceMallocUncached));
    CHECK_HIP_ERROR(hipMemset(trigger, 1, sizeof(uint32_t)));
  }
  if (hasAtomic) {
    int targetGpu = params.atomicMemory == "remote" ? params.dstGpu
                                                    : params.srcGpu;
    CHECK_HIP_ERROR(hipSetDevice(targetGpu));
    for (auto& target : atomicTargetHost) {
      CHECK_HIP_ERROR(hipExtMallocWithFlags(reinterpret_cast<void**>(&target),
                                            sizeof(uint64_t),
                                            hipDeviceMallocUncached));
    }
    CHECK_HIP_ERROR(hipSetDevice(params.srcGpu));
    CHECK_HIP_ERROR(
      hipMalloc(&atomicTargets, params.numQueues * sizeof(uint64_t*)));
    CHECK_HIP_ERROR(hipMemcpy(atomicTargets, atomicTargetHost.data(),
                              params.numQueues * sizeof(uint64_t*),
                              hipMemcpyHostToDevice));
  }

  CsvWriter output(params.outputFile);
  output.writeHeader({
    "Mode",
    "Src",
    "#Destinations",
    "#Queues",
    "GridDim",
    "BlockDim",
    "Copy Size [B]",
    "#Commands",
    "Device Latency [us] (Mean)",
    "Host Latency [us] (Mean)",
    "Device Bandwidth [GB/s]",
    "Host Bandwidth [GB/s]",
    "Command Rate [MPPS]",
    "SDMA Packet Rate [MPPS]",
    "Host Command Rate [MPPS]",
    "Command Time [ns/command]",
    "SDMA Time [ns/packet]",
  });
  std::cout
    << "CopySize  Queues  Device(us)  Host(us)  Device(MPPS)  Host(MPPS)\n";

  dim3 grid(1, 1, 1);
  dim3 block(params.numQueues * warpSize, 1, 1);
  for (size_t copySize = params.minCopySize; copySize <= params.maxCopySize;
       copySize *= 2) {
    const size_t totalTransfer = copySize * params.numCommands *
                                 params.numQueues;
    CHECK_HIP_ERROR(hipMemset(signals, 0, params.numQueues * sizeof(uint64_t)));
    if (trigger)
      CHECK_HIP_ERROR(hipMemset(trigger, hasPoll ? 1 : 0, sizeof(uint32_t)));
    if (hasAtomic) {
      int targetGpu = params.atomicMemory == "remote" ? params.dstGpu
                                                      : params.srcGpu;
      CHECK_HIP_ERROR(hipSetDevice(targetGpu));
      for (auto* target : atomicTargetHost) {
        CHECK_HIP_ERROR(hipMemset(target, 0, sizeof(uint64_t)));
      }
      CHECK_HIP_ERROR(hipSetDevice(params.srcGpu));
    }
    CHECK_HIP_ERROR(hipDeviceSynchronize());
    uint64_t expectedSignal = 1;
    auto runRate = [&](int64_t* starts, int64_t* ends) {
      RateKernelArgs args{deviceHandles,
                          src,
                          dst,
                          signals,
                          atomicTargets,
                          hasPoll ? trigger : nullptr,
                          starts,
                          ends,
                          copySize,
                          params.numCommands,
                          expectedSignal,
                          rateMode};
      sdmaRateKernel<<<grid, block>>>(args);
      expectedSignal++;
    };

    if (!params.skipVerification && hasCopy) {
      runRate(startDevice, endDevice);
      CHECK_HIP_ERROR(hipDeviceSynchronize());
      verifyData(expected, dst, totalTransfer);
    }

    for (size_t iteration = 0; iteration < params.warmup; ++iteration) {
      runRate(startDevice, endDevice);
    }
    CHECK_HIP_ERROR(hipDeviceSynchronize());

    std::vector<hipEvent_t> events(params.iterations + 1);
    for (auto& event : events)
      CHECK_HIP_ERROR(hipEventCreate(&event));
    for (size_t iteration = 0; iteration < params.iterations; ++iteration) {
      CHECK_HIP_ERROR(hipEventRecord(events[iteration]));
      runRate(startDevice + iteration * params.numQueues,
              endDevice + iteration * params.numQueues);
    }
    CHECK_HIP_ERROR(hipEventRecord(events.back()));
    CHECK_HIP_ERROR(hipDeviceSynchronize());
    CHECK_HIP_ERROR(hipMemcpy(startHost.data(), startDevice,
                              startHost.size() * sizeof(int64_t),
                              hipMemcpyDeviceToHost));
    CHECK_HIP_ERROR(hipMemcpy(endHost.data(), endDevice,
                              endHost.size() * sizeof(int64_t),
                              hipMemcpyDeviceToHost));
    std::vector<double> deviceUs(params.iterations);
    std::vector<double> hostUs(params.iterations);
    for (size_t iteration = 0; iteration < params.iterations; ++iteration) {
      const auto startBegin = startHost.begin() + iteration * params.numQueues;
      const auto startEnd = startBegin + params.numQueues;
      const auto endBegin = endHost.begin() + iteration * params.numQueues;
      const auto endEnd = endBegin + params.numQueues;
      const int64_t earliest = *std::min_element(startBegin, startEnd);
      const int64_t latest = *std::max_element(endBegin, endEnd);
      deviceUs[iteration] = static_cast<double>(latest - earliest) / 100.0;
      float milliseconds = 0.0f;
      CHECK_HIP_ERROR(hipEventElapsedTime(&milliseconds, events[iteration],
                                          events[iteration + 1]));
      hostUs[iteration] = milliseconds * 1000.0;
    }
    for (auto event : events)
      CHECK_HIP_ERROR(hipEventDestroy(event));

    auto [deviceMean, deviceStd] = averageAndStd(deviceUs);
    auto [hostMean, hostStd] = averageAndStd(hostUs);
    const double copyMpps = (params.numQueues * params.numCommands) /
                            deviceMean;
    const size_t measuredPackets = params.numCommands *
                                     (hasPoll + hasCopy + hasAtomic) +
                                   1;
    const double sdmaMpps = params.numQueues * measuredPackets / deviceMean;
    const double hostMpps = (params.numQueues * params.numCommands) / hostMean;
    const double copyTimeNs = 1000.0 / copyMpps;
    const double sdmaTimeNs = 1000.0 / sdmaMpps;
    const double deviceGbps = hasCopy
                                ? (totalTransfer / 1.0e9) / (deviceMean / 1.0e6)
                                : 0.0;
    const double hostGbps = hasCopy
                              ? (totalTransfer / 1.0e9) / (hostMean / 1.0e6)
                              : 0.0;

    std::cout << std::fixed << std::setprecision(3) << std::setw(8) << copySize
              << std::setw(8) << params.numQueues << std::setw(14) << deviceMean
              << std::setw(14) << hostMean << std::setw(14) << copyMpps
              << std::setw(14) << hostMpps << std::setw(16) << copyTimeNs
              << std::setw(16) << sdmaTimeNs << std::endl;
    const char* modeName = rateModeName(rateMode);
    output.writeRow(modeName, params.srcGpu, 1, params.numQueues, 1, block.x,
                    copySize, params.numCommands, deviceMean, hostMean,
                    deviceGbps, hostGbps, copyMpps, sdmaMpps, hostMpps,
                    copyTimeNs, sdmaTimeNs);
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
  app.add_option("-c,--numCommands", params.numCommands,
                 "Copy packets per queue and iteration");
  app.add_option("--numOfQueues", params.numQueues, "Number of SDMA queues");
  app.add_option("-w,--warmup", params.warmup, "Warmup iterations");
  app.add_option("-n,--iterations", params.iterations, "Measured iterations");
  app.add_option("-o,--outputFile", params.outputFile, "CSV output path");
  app.add_flag("--skip-verification", params.skipVerification,
               "Skip destination verification");
  app.add_option("--mode", params.mode,
                 "Mode: copy, poll-copy, copy-atomic, poll-copy-atomic, "
                 "poll-only, or atomic-only");
  app.add_option("--atomic-memory", params.atomicMemory,
                 "Atomic target memory: local or remote");
  app.add_flag("-v,--verbose", params.verbose, "Verbose output");
  CLI11_PARSE(app, argc, argv);

  const RateMode mode = parseRateMode(params.mode);
  if ((mode == RateMode::AtomicOnly || mode == RateMode::CopyAtomic ||
       mode == RateMode::PollCopyAtomic) &&
      params.atomicMemory != "local" && params.atomicMemory != "remote")
    throw std::runtime_error("atomic-memory must be local or remote");

  if (params.minCopySize == 0 || params.maxCopySize < params.minCopySize ||
      params.numCommands == 0 || params.numQueues == 0 ||
      params.iterations == 0) {
    throw std::runtime_error("invalid benchmark parameters");
  }
  run(params);
}
