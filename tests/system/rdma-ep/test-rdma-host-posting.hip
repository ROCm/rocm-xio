/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <system_error>
#include <vector>

#include <hip/hip_runtime.h>

#include "rdma-ep-host.h"

namespace fs = std::filesystem;
using xio::rdma_ep::Endpoint;

static constexpr size_t kHalf = 2048;

static std::string findMlx5Ib() {
  std::error_code ec;
  for (const auto& dev : fs::directory_iterator("/sys/class/infiniband", ec)) {
    std::string name = dev.path().filename();
    std::ifstream ll(dev.path() / "ports/1/link_layer");
    std::string layer;
    if (name.find("mlx5") != std::string::npos && ll >> layer &&
        layer == "InfiniBand")
      return name;
  }
  return "";
}

static void waitIdle(Endpoint& ep) {
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (ep.hostOutstanding() && std::chrono::steady_clock::now() < deadline)
    ep.hostPoll(1);
  if (ep.hostOutstanding())
    throw std::runtime_error("no completion within 5 s");
}

int main() {
  std::string dev = findMlx5Ib();
  int gpus = 0;
  if (dev.empty() || hipGetDeviceCount(&gpus) != hipSuccess || gpus < 1) {
    printf("SKIP: needs an mlx5 InfiniBand port and a GPU\n");
    return 77;
  }

  // [src: 2 halves][dst: 2 halves] in one registered buffer
  uint8_t* buf = nullptr;
  if (hipMalloc(&buf, 4 * kHalf) != hipSuccess ||
      hipMemset(buf, 0xA5, 2 * kHalf) != hipSuccess ||
      hipMemset(buf + 2 * kHalf, 0, 2 * kHalf) != hipSuccess ||
      hipDeviceSynchronize() != hipSuccess) {
    fprintf(stderr, "FAIL: GPU buffer setup\n");
    return 1;
  }
  uint8_t* src = buf;
  uint64_t dst = reinterpret_cast<uint64_t>(buf + 2 * kHalf);

  try {
    Endpoint ep("mlx5", dev, 0, true);
    ep.registerBuffer(buf, 4 * kHalf, true);
    ep.connect(ep.localInfo());

    ep.hostPostWrite(dst, src, kHalf);
    ep.hostRing();
    waitIdle(ep);

    // Ring by hand, as a DMA engine would
    ep.hostPostWrite(dst + kHalf, src + kHalf, kHalf);
    uint32_t rec = 0;
    uint64_t val = 0;
    uint64_t dbrec = 0, gpuDoorbell = 0, cpuDoorbell = 0;
    ep.hostStaged(&rec, &val);
    ep.hostAddresses(&dbrec, &gpuDoorbell, &cpuDoorbell);
    *reinterpret_cast<volatile uint32_t*>(dbrec) = rec;
    ep.hostFlush();
    *reinterpret_cast<volatile uint64_t*>(cpuDoorbell) = val;
    waitIdle(ep);
  } catch (const std::exception& e) {
    fprintf(stderr, "FAIL: %s\n", e.what());
    return 1;
  }

  std::vector<uint8_t> host(2 * kHalf);
  if (hipMemcpy(host.data(), buf + 2 * kHalf, host.size(),
                hipMemcpyDeviceToHost) != hipSuccess) {
    fprintf(stderr, "FAIL: reading back\n");
    return 1;
  }
  (void)hipFree(buf);
  for (size_t i = 0; i < host.size(); ++i) {
    if (host[i] != 0xA5) {
      fprintf(stderr, "FAIL: byte %zu is 0x%02x\n", i, host[i]);
      return 1;
    }
  }
  printf("PASS: host-posted WRITEs (hostRing and hand-rung) landed\n");
  return 0;
}
