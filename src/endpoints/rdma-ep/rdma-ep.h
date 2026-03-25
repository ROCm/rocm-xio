/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * RDMA Endpoint -- GPU-Direct Access (GDA) for RDMA NICs
 *
 * Derived from ROCm/rocSHMEM GDA backend, adapted for rocm-xio.
 * Supports three RDMA vendors:
 *   - BNXT (Broadcom Thor 2) -- primary, tested locally
 *   - MLX5 (Mellanox/NVIDIA ConnectX)
 *   - IONIC (Pensando)
 */

#ifndef RDMA_EP_H
#define RDMA_EP_H

#include <cstdint>
#include <string>

#include <hip/hip_runtime.h>

#include "vendor-ops.hpp"

#define RDMA_EP_SQE_SIZE 0
#define RDMA_EP_CQE_SIZE 0

namespace rdma_ep {

struct RdmaEpConfig {
  std::string providerStr = "bnxt";
  Provider provider = Provider::BNXT;
  unsigned iterations = 128;
  unsigned sqDepth = 256;
  unsigned cqDepth = 256;
  uint32_t transferSize = 4096;
  uint32_t inlineThreshold = 28;
  bool pcieRelaxedOrdering = false;
  int trafficClass = 0;
  bool loopback = true;
  int gpuDeviceId = 0;
  bool verify = false;
  uint32_t seed = 1;
  std::string deviceName;
};

} // namespace rdma_ep

namespace CLI {
class App;
}

namespace rdma_ep {

__host__ void registerCliOptions(CLI::App& app, RdmaEpConfig* config);
__host__ std::string validateConfig(RdmaEpConfig* config);
__host__ unsigned getIterations(void* endpointConfig);

} // namespace rdma_ep

#endif // RDMA_EP_H
