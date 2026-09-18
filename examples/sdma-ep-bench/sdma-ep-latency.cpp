/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <stdexcept>
#include <string>
#include <vector>

#include <hip/hip_ext.h>
#include <hip/hip_runtime.h>

#include <CLI/CLI.hpp>

#include "endpoints/sdma-ep/sdma-ep.h"
#include "sdma_latency_kernel.h"
#include "xio.h"

namespace {
constexpr uint32_t kMagic = 0xDEADBEEF;

struct Params {
  size_t minSize = 256;
  size_t maxSize = 1 << 20;
  size_t commands = 1;
  size_t warmup = 3;
  size_t iterations = 100;
  int srcGpu = 0;
  int dstGpu = 1;
  bool skipVerification = false;
  bool fine = false;
  bool noQueueState = false;
  std::string output = "latency.csv";
};

std::pair<double, double> stats(const std::vector<double>& values) {
  double mean = std::accumulate(values.begin(), values.end(), 0.0) /
                values.size();
  double variance = 0;
  for (double value : values)
    variance += (value - mean) * (value - mean);
  return {mean, std::sqrt(variance / values.size())};
}

void verify(void* dst, size_t bytes) {
  std::vector<uint32_t> actual(bytes / sizeof(uint32_t));
  HIP_CHECK(hipMemcpy(actual.data(), dst, bytes, hipMemcpyDeviceToHost));
  for (size_t i = 0; i < actual.size(); ++i) {
    if (actual[i] != kMagic)
      throw std::runtime_error("SDMA latency verification failed");
  }
}

void run(const Params& p) {
  int count = 0;
  HIP_CHECK(hipGetDeviceCount(&count));
  if (p.srcGpu < 0 || p.dstGpu < 0 || p.srcGpu >= count || p.dstGpu >= count ||
      p.srcGpu == p.dstGpu)
    throw std::runtime_error("invalid source/destination GPU");
  HIP_CHECK(hipSetDevice(p.srcGpu));
  xio::enablePeerAccess(p.srcGpu, p.dstGpu);
  if (xio::sdma_ep::initEndpoint() != 0)
    throw std::runtime_error("failed to initialize SDMA endpoint");

  int warp = 0;
  HIP_CHECK(hipDeviceGetAttribute(&warp, hipDeviceAttributeWarpSize, p.srcGpu));
  void* src = nullptr;
  void* dst = nullptr;
  size_t maxBytes = p.maxSize * p.commands;
  HIP_CHECK(hipExtMallocWithFlags(&src, maxBytes, hipDeviceMallocUncached));
  HIP_CHECK(hipSetDevice(p.dstGpu));
  HIP_CHECK(hipExtMallocWithFlags(&dst, maxBytes, hipDeviceMallocUncached));
  HIP_CHECK(hipSetDevice(p.srcGpu));
  std::vector<uint32_t> pattern(maxBytes / sizeof(uint32_t), kMagic);
  HIP_CHECK(hipMemcpy(src, pattern.data(), maxBytes, hipMemcpyHostToDevice));

  xio::sdma_ep::SdmaQueueInfo queueInfo = {};
  if (xio::sdma_ep::createQueue(p.srcGpu, p.dstGpu, &queueInfo) != 0)
    throw std::runtime_error("failed to create SDMA queue");
  auto* handle = static_cast<xio::sdma_ep::SdmaQueueHandle*>(
    queueInfo.deviceHandle);
  xio::sdma_ep::SdmaQueueHandle** handleDevice = nullptr;
  HIP_CHECK(hipMalloc(&handleDevice, sizeof(handle)));
  HIP_CHECK(
    hipMemcpy(handleDevice, &handle, sizeof(handle), hipMemcpyHostToDevice));
  uint64_t* signal = nullptr;
  HIP_CHECK(hipMalloc(&signal, sizeof(uint64_t)));
  int64_t* startDevice = nullptr;
  int64_t* endDevice = nullptr;
  HIP_CHECK(hipMalloc(&startDevice, sizeof(int64_t)));
  HIP_CHECK(hipMalloc(&endDevice, sizeof(int64_t)));

  size_t n = p.commands;
  std::vector<int64_t> reserveStart(n), reserveEnd(n), buildStart(n),
    buildEnd(n), submitStart(n), submitEnd(n), atomicReserveStart(1),
    atomicReserveEnd(1), atomicBuildStart(1), atomicBuildEnd(1),
    atomicSubmitStart(1), atomicSubmitEnd(1), transferStart(1), transferEnd(1);
  LatencyBreakdown breakdown{};
  HIP_CHECK(hipMalloc(&breakdown.reserveStart, n * sizeof(int64_t)));
  HIP_CHECK(hipMalloc(&breakdown.reserveEnd, n * sizeof(int64_t)));
  HIP_CHECK(hipMalloc(&breakdown.buildStart, n * sizeof(int64_t)));
  HIP_CHECK(hipMalloc(&breakdown.buildEnd, n * sizeof(int64_t)));
  HIP_CHECK(hipMalloc(&breakdown.submitStart, n * sizeof(int64_t)));
  HIP_CHECK(hipMalloc(&breakdown.submitEnd, n * sizeof(int64_t)));
  HIP_CHECK(hipMalloc(&breakdown.atomicReserveStart, sizeof(int64_t)));
  HIP_CHECK(hipMalloc(&breakdown.atomicReserveEnd, sizeof(int64_t)));
  HIP_CHECK(hipMalloc(&breakdown.atomicBuildStart, sizeof(int64_t)));
  HIP_CHECK(hipMalloc(&breakdown.atomicBuildEnd, sizeof(int64_t)));
  HIP_CHECK(hipMalloc(&breakdown.atomicSubmitStart, sizeof(int64_t)));
  HIP_CHECK(hipMalloc(&breakdown.atomicSubmitEnd, sizeof(int64_t)));
  HIP_CHECK(hipMalloc(&breakdown.transferStart, sizeof(int64_t)));
  HIP_CHECK(hipMalloc(&breakdown.transferEnd, sizeof(int64_t)));
  LatencyBreakdown* breakdownDevice = nullptr;
  HIP_CHECK(hipMalloc(&breakdownDevice, sizeof(breakdown)));
  HIP_CHECK(hipMemcpy(breakdownDevice, &breakdown, sizeof(breakdown),
                      hipMemcpyHostToDevice));

  std::ofstream csv(p.output);
  csv << "Copy Size [B],#Copy Commands,Device Latency [us] (Mean),"
         "Device Latency [us] (Std),Host Latency [us] (Mean),"
         "Host Latency [us] (Std),Device Bandwidth [GB/s],"
         "Reserve [us],Build [us],Submit [us],Atomic Reserve [us],"
         "Atomic Build [us],Atomic Submit [us],Transfer [us]\n";
  std::cout << "CopySize  Device(us)  Host(us)  DeviceBW(GB/s)\n";

  dim3 grid(1), block(warp);
  uint64_t expected = 1;
  for (size_t size = p.minSize; size <= p.maxSize; size *= 2) {
    size_t bytes = size * p.commands;
    HIP_CHECK(hipMemset(signal, 0, sizeof(uint64_t)));
    HIP_CHECK(hipMemset(dst, 0, bytes));
    HIP_CHECK(hipDeviceSynchronize());
    if (!p.skipVerification) {
      if (p.fine)
        sdmaLatencyKernel<true>
          <<<grid, block>>>(src, dst, size, p.commands, handleDevice, signal,
                            expected, startDevice, endDevice, breakdownDevice,
                            !p.noQueueState);
      else
        sdmaLatencyKernel<false>
          <<<grid, block>>>(src, dst, size, p.commands, handleDevice, signal,
                            expected, startDevice, endDevice, breakdownDevice,
                            !p.noQueueState);
      HIP_CHECK(hipDeviceSynchronize());
      verify(dst, bytes);
      ++expected;
    }
    for (size_t i = 0; i < p.warmup; ++i) {
      sdmaLatencyKernel<false>
        <<<grid, block>>>(src, dst, size, p.commands, handleDevice, signal,
                          expected, startDevice, endDevice, breakdownDevice,
                          !p.noQueueState);
      ++expected;
    }
    HIP_CHECK(hipDeviceSynchronize());
    std::vector<hipEvent_t> events(p.iterations + 1);
    for (auto& event : events)
      HIP_CHECK(hipEventCreate(&event));
    std::vector<double> deviceUs, hostUs;
    for (size_t i = 0; i < p.iterations; ++i) {
      HIP_CHECK(hipEventRecord(events[i]));
      if (p.fine)
        sdmaLatencyKernel<true>
          <<<grid, block>>>(src, dst, size, p.commands, handleDevice, signal,
                            expected, startDevice, endDevice, breakdownDevice,
                            !p.noQueueState);
      else
        sdmaLatencyKernel<false>
          <<<grid, block>>>(src, dst, size, p.commands, handleDevice, signal,
                            expected, startDevice, endDevice, breakdownDevice,
                            !p.noQueueState);
      ++expected;
    }
    HIP_CHECK(hipEventRecord(events.back()));
    HIP_CHECK(hipDeviceSynchronize());
    int64_t start = 0, end = 0;
    HIP_CHECK(
      hipMemcpy(&start, startDevice, sizeof(start), hipMemcpyDeviceToHost));
    HIP_CHECK(hipMemcpy(&end, endDevice, sizeof(end), hipMemcpyDeviceToHost));
    if (p.fine) {
      HIP_CHECK(hipMemcpy(reserveStart.data(), breakdown.reserveStart,
                          n * sizeof(int64_t), hipMemcpyDeviceToHost));
      HIP_CHECK(hipMemcpy(reserveEnd.data(), breakdown.reserveEnd,
                          n * sizeof(int64_t), hipMemcpyDeviceToHost));
      HIP_CHECK(hipMemcpy(buildStart.data(), breakdown.buildStart,
                          n * sizeof(int64_t), hipMemcpyDeviceToHost));
      HIP_CHECK(hipMemcpy(buildEnd.data(), breakdown.buildEnd,
                          n * sizeof(int64_t), hipMemcpyDeviceToHost));
      HIP_CHECK(hipMemcpy(submitStart.data(), breakdown.submitStart,
                          n * sizeof(int64_t), hipMemcpyDeviceToHost));
      HIP_CHECK(hipMemcpy(submitEnd.data(), breakdown.submitEnd,
                          n * sizeof(int64_t), hipMemcpyDeviceToHost));
      HIP_CHECK(hipMemcpy(atomicReserveStart.data(),
                          breakdown.atomicReserveStart, sizeof(int64_t),
                          hipMemcpyDeviceToHost));
      HIP_CHECK(hipMemcpy(atomicReserveEnd.data(), breakdown.atomicReserveEnd,
                          sizeof(int64_t), hipMemcpyDeviceToHost));
      HIP_CHECK(hipMemcpy(atomicBuildStart.data(), breakdown.atomicBuildStart,
                          sizeof(int64_t), hipMemcpyDeviceToHost));
      HIP_CHECK(hipMemcpy(atomicBuildEnd.data(), breakdown.atomicBuildEnd,
                          sizeof(int64_t), hipMemcpyDeviceToHost));
      HIP_CHECK(hipMemcpy(atomicSubmitStart.data(), breakdown.atomicSubmitStart,
                          sizeof(int64_t), hipMemcpyDeviceToHost));
      HIP_CHECK(hipMemcpy(atomicSubmitEnd.data(), breakdown.atomicSubmitEnd,
                          sizeof(int64_t), hipMemcpyDeviceToHost));
      HIP_CHECK(hipMemcpy(transferStart.data(), breakdown.transferStart,
                          sizeof(int64_t), hipMemcpyDeviceToHost));
      HIP_CHECK(hipMemcpy(transferEnd.data(), breakdown.transferEnd,
                          sizeof(int64_t), hipMemcpyDeviceToHost));
    }
    float ms = 0;
    HIP_CHECK(hipEventElapsedTime(&ms, events[0], events.back()));
    double oneDeviceUs = static_cast<double>(end - start) / 100.0;
    double oneHostUs = ms * 1000.0 / p.iterations;
    deviceUs.assign(p.iterations, oneDeviceUs);
    hostUs.assign(p.iterations, oneHostUs);
    for (auto event : events)
      HIP_CHECK(hipEventDestroy(event));
    auto [deviceMean, deviceStd] = stats(deviceUs);
    auto [hostMean, hostStd] = stats(hostUs);
    double bandwidth = (bytes / 1.0e9) / (deviceMean / 1.0e6);
    double reserve = 0, build = 0, submit = 0, transfer = 0;
    if (p.fine) {
      double reserveSum = 0, buildSum = 0, submitSum = 0;
      for (size_t command = 0; command < n; ++command) {
        reserveSum += reserveEnd[command] - reserveStart[command];
        buildSum += buildEnd[command] - buildStart[command];
        submitSum += submitEnd[command] - submitStart[command];
      }
      reserve = reserveSum / (100.0 * n);
      build = buildSum / (100.0 * n);
      submit = submitSum / (100.0 * n);
      transfer = static_cast<double>(transferEnd[0] - transferStart[0]) / 100.0;
    }
    std::cout << std::setw(8) << size << std::setw(13) << deviceMean
              << std::setw(10) << hostMean << std::setw(16) << bandwidth
              << '\n';
    csv << size << ',' << p.commands << ',' << deviceMean << ',' << deviceStd
        << ',' << hostMean << ',' << hostStd << ',' << bandwidth << ','
        << reserve << ',' << build << ',' << submit << ','
        << (atomicReserveEnd[0] - atomicReserveStart[0]) / 100.0 << ','
        << (atomicBuildEnd[0] - atomicBuildStart[0]) / 100.0 << ','
        << (atomicSubmitEnd[0] - atomicSubmitStart[0]) / 100.0 << ','
        << transfer << '\n';
  }
  HIP_CHECK(hipFree(breakdown.reserveStart));
  HIP_CHECK(hipFree(breakdown.reserveEnd));
  HIP_CHECK(hipFree(breakdown.buildStart));
  HIP_CHECK(hipFree(breakdown.buildEnd));
  HIP_CHECK(hipFree(breakdown.submitStart));
  HIP_CHECK(hipFree(breakdown.submitEnd));
  HIP_CHECK(hipFree(breakdown.atomicReserveStart));
  HIP_CHECK(hipFree(breakdown.atomicReserveEnd));
  HIP_CHECK(hipFree(breakdown.atomicBuildStart));
  HIP_CHECK(hipFree(breakdown.atomicBuildEnd));
  HIP_CHECK(hipFree(breakdown.atomicSubmitStart));
  HIP_CHECK(hipFree(breakdown.atomicSubmitEnd));
  HIP_CHECK(hipFree(breakdown.transferStart));
  HIP_CHECK(hipFree(breakdown.transferEnd));
  HIP_CHECK(hipFree(breakdownDevice));
  HIP_CHECK(hipFree(startDevice));
  HIP_CHECK(hipFree(endDevice));
  HIP_CHECK(hipFree(signal));
  HIP_CHECK(hipFree(handleDevice));
  HIP_CHECK(hipFree(src));
  HIP_CHECK(hipSetDevice(p.dstGpu));
  HIP_CHECK(hipFree(dst));
  xio::sdma_ep::destroyQueue(&queueInfo);
  xio::sdma_ep::shutdownEndpoint();
}
} // namespace

int main(int argc, char** argv) {
  Params p;
  CLI::App app("SDMA GPU-initiated latency benchmark");
  app.add_option("--srcGpu", p.srcGpu);
  app.add_option("--dstGpu", p.dstGpu);
  app.add_option("-b,--minCopySize", p.minSize);
  app.add_option("-e,--maxCopySize", p.maxSize);
  app.add_option("-c,--numCopyCommands", p.commands);
  app.add_option("-w,--warmup", p.warmup);
  app.add_option("-n,--iterations", p.iterations);
  app.add_option("-o,--outputFile", p.output);
  app.add_flag("--skip-verification", p.skipVerification);
  app.add_flag("-l,--fine-grained", p.fine);
  app.add_flag("--no-queue-state", p.noQueueState,
               "Disable cached queue read-pointer checks");
  CLI11_PARSE(app, argc, argv);
  if (p.minSize == 0 || p.maxSize < p.minSize || p.commands == 0 ||
      p.iterations == 0)
    throw std::runtime_error("invalid latency parameters");
  run(p);
}
