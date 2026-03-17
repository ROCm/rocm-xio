/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * RDMA Endpoint implementation -- GPU-Direct Access (GDA) for RDMA NICs.
 * Derived from ROCm/rocSHMEM GDA backend, adapted for rocm-xio.
 *
 * This endpoint uses real InfiniBand verbs to create QPs and CQs,
 * then GPU code posts WQEs directly to hardware via doorbell registers.
 */

#include <cstdio>
#include <string>

#include <hip/hip_runtime.h>

#include <CLI/CLI.hpp>

#include "gda-backend.hpp"
#include "queue-pair.hpp"
#include "rdma-ep.h"
#include "xio.h"

namespace rdma_ep {

__global__ void rdma_ep_kernel(QueuePair* qp,
                               unsigned long long int* startTimes,
                               unsigned long long int* endTimes,
                               unsigned iterations, uint32_t transferSize) {
  // GPU kernel that uses QueuePair to perform RDMA operations.
  // Vendor-specific WQE posting will be functional once Phase 5 (BNXT)
  // adds the real device-side implementation.
  (void)qp;
  (void)startTimes;
  (void)endTimes;
  (void)iterations;
  (void)transferSize;
}

} // namespace rdma_ep

#ifndef __HIP_DEVICE_COMPILE__

namespace rdma_ep {

__host__ void registerCliOptions(CLI::App& app, RdmaEpConfig* config) {
  const std::string group = "RDMA Endpoint Options";

  app
    .add_option("-n,--iterations", config->iterations,
                "Number of RDMA operations to perform")
    ->default_val(128)
    ->check(CLI::PositiveNumber)
    ->group(group);

  app
    .add_option("--provider", config->providerStr,
                "RDMA provider: bnxt, mlx5, or ionic")
    ->default_val("bnxt")
    ->check(CLI::IsMember({"bnxt", "bnxt_re", "mlx5", "ionic", "pensando"},
                          CLI::ignore_case))
    ->group(group);

  app
    .add_option("--sq-depth", config->sqDepth, "Send queue depth (power of 2)")
    ->default_val(256)
    ->group(group);

  app.add_option("--cq-depth", config->cqDepth, "Completion queue depth")
    ->default_val(256)
    ->group(group);

  app
    .add_option("--transfer-size", config->transferSize,
                "Transfer size per operation in bytes")
    ->default_val(4096)
    ->check(CLI::PositiveNumber)
    ->group(group);

  app
    .add_option("--inline-threshold", config->inlineThreshold,
                "Max bytes for inline sends")
    ->default_val(28)
    ->group(group);

  app
    .add_flag("--loopback,!--no-loopback", config->loopback,
              "Connect QP to itself for testing (default: on)")
    ->group(group);

  app.add_option("--gpu-device", config->gpuDeviceId, "HIP GPU device ID")
    ->default_val(0)
    ->group(group);

  app
    .add_flag("--pcie-relaxed-ordering", config->pcieRelaxedOrdering,
              "Enable PCIe relaxed ordering for MRs")
    ->group(group);

  app
    .add_option("--traffic-class", config->trafficClass,
                "Traffic class for QP AH attribute")
    ->default_val(0)
    ->group(group);
}

__host__ std::string validateConfig(RdmaEpConfig* config) {
  if (!config)
    return "Configuration pointer is null";

  config->provider = provider_from_string(config->providerStr.c_str());
  if (config->provider == Provider::UNKNOWN)
    return "Invalid provider. Must be: bnxt, mlx5, or ionic";

  if (config->iterations == 0)
    return "Iterations must be > 0";
  if (config->sqDepth == 0)
    return "SQ depth must be > 0";
  if (config->transferSize == 0)
    return "Transfer size must be > 0";

  return std::string();
}

__host__ unsigned getIterations(void* endpointConfig) {
  if (endpointConfig) {
    auto* cfg = static_cast<RdmaEpConfig*>(endpointConfig);
    return cfg->iterations;
  }
  return 128;
}

} // namespace rdma_ep

hipError_t rdma_ep_run(xio::XioEndpointConfig* config) {
  if (!config || !config->endpointConfig) {
    fprintf(stderr, "rdma-ep: Missing endpoint configuration\n");
    return hipErrorInvalidValue;
  }

  auto* cfg = static_cast<rdma_ep::RdmaEpConfig*>(config->endpointConfig);

  fprintf(stderr,
          "rdma-ep: Initializing GDA backend (provider=%s, "
          "loopback=%s, sq_depth=%u)\n",
          rdma_ep::provider_name(cfg->provider), cfg->loopback ? "yes" : "no",
          cfg->sqDepth);

  rdma_ep::BackendConfig bcfg;
  bcfg.provider = cfg->provider;
  bcfg.gpu_device_id = cfg->gpuDeviceId;
  bcfg.sq_depth = cfg->sqDepth;
  bcfg.cq_depth = cfg->cqDepth;
  bcfg.inline_threshold = cfg->inlineThreshold;
  bcfg.pcie_relaxed_ordering = cfg->pcieRelaxedOrdering;
  bcfg.traffic_class = cfg->trafficClass;
  bcfg.loopback = cfg->loopback;

  rdma_ep::Backend backend(bcfg);
  int ret = backend.init();
  if (ret != 0) {
    fprintf(stderr, "rdma-ep: Backend initialization failed\n");
    return hipErrorUnknown;
  }

  fprintf(stderr, "rdma-ep: Backend initialized successfully.\n");

  rdma_ep::QueuePair* gpu_qp = backend.get_gpu_qp();

  if (gpu_qp) {
    dim3 gridDim(1);
    dim3 blockDim(config->numThreads);

    hipLaunchKernelGGL(rdma_ep::rdma_ep_kernel, gridDim, blockDim, 0, 0, gpu_qp,
                       config->startTimes, config->endTimes, config->iterations,
                       cfg->transferSize);

    hipError_t launchErr = hipGetLastError();
    if (launchErr != hipSuccess) {
      fprintf(stderr, "rdma-ep: Kernel launch failed: %s\n",
              hipGetErrorString(launchErr));
      backend.shutdown();
      return launchErr;
    }

    hipError_t syncErr = hipDeviceSynchronize();
    if (syncErr != hipSuccess) {
      fprintf(stderr, "rdma-ep: Kernel sync failed: %s\n",
              hipGetErrorString(syncErr));
      backend.shutdown();
      return syncErr;
    }
  } else {
    fprintf(stderr, "rdma-ep: No GPU QueuePair available (vendor device code "
                    "not yet ported). Backend init verified OK.\n");
  }

  backend.shutdown();
  return hipSuccess;
}

#endif // !__HIP_DEVICE_COMPILE__
