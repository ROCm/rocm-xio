/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * RDMA Endpoint -- GPU-Direct Access (GDA).
 * Derived from ROCm/rocSHMEM GDA backend,
 * adapted for rocm-xio.
 *
 * GPU kernels post WQEs directly to NIC send queues
 * and ring hardware doorbells with zero CPU
 * involvement in the data path.
 */

#include <cstdio>
#include <cstring>
#include <string>

#include <hip/hip_runtime.h>

#include <CLI/CLI.hpp>

#include "gda-backend.hpp"
#include "queue-pair.hpp"
#include "rdma-ep.h"
#include "xio-timing.h"
#include "xio.h"

namespace rdma_ep {

__global__ void rdma_ep_kernel(QueuePair* qp, void* src_ptr, void* dst_ptr,
                               unsigned long long int* startTimes,
                               unsigned long long int* endTimes,
                               xio::XioTimingStats* timingStats,
                               unsigned iterations, uint32_t transferSize) {
  if (threadIdx.x != 0)
    return;

  for (unsigned i = 0; i < iterations; i++) {
    unsigned long long int t0 = wall_clock64();

    if (startTimes)
      startTimes[i] = t0;

    qp->put_nbi_single(dst_ptr, src_ptr, transferSize, true);
    qp->quiet_single();

    unsigned long long int t1 = wall_clock64();

    if (endTimes)
      endTimes[i] = t1;

    if (timingStats && t1 > t0)
      updateTimingStats(timingStats, t1 - t0);
  }
}

} // namespace rdma_ep

#ifndef __HIP_DEVICE_COMPILE__

#include "xio-data-pattern.hpp"

namespace rdma_ep {

__host__ void registerCliOptions(CLI::App& app, RdmaEpConfig* config) {
  const std::string group = "RDMA Endpoint Options";

  app
    .add_option("-n,--iterations", config->iterations,
                "Number of RDMA operations")
    ->default_val(128)
    ->check(CLI::PositiveNumber)
    ->group(group);

  app
    .add_option("--provider", config->providerStr,
                "RDMA provider: bnxt, mlx5, ionic,"
                " or ernic")
    ->default_val("bnxt")
    ->check(CLI::IsMember({"bnxt", "bnxt_re", "mlx5", "ionic", "pensando",
                           "ernic", "rocm_ernic", "rocm-ernic"},
                          CLI::ignore_case))
    ->group(group);

  app
    .add_option("--device", config->deviceName,
                "RDMA device name"
                " (e.g. rocm-rdma-bnxt0)")
    ->default_val("")
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
                "Transfer size per operation"
                " in bytes")
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
              "Connect QP to itself (default: on)")
    ->group(group);

  app.add_option("--gpu-device", config->gpuDeviceId, "HIP GPU device ID")
    ->default_val(0)
    ->group(group);

  app
    .add_flag("--pcie-relaxed-ordering", config->pcieRelaxedOrdering,
              "Enable PCIe relaxed ordering")
    ->group(group);

  app
    .add_option("--traffic-class", config->trafficClass,
                "Traffic class for QP AH")
    ->default_val(0)
    ->group(group);

  app
    .add_flag("--verify", config->verify,
              "Verify data with LFSR pattern"
              " after each run")
    ->group(group);

  app.add_option("--seed", config->seed, "LFSR seed for data pattern")
    ->default_val(1)
    ->check(CLI::PositiveNumber)
    ->group(group);
}

__host__ std::string validateConfig(RdmaEpConfig* config) {
  if (!config)
    return "Configuration pointer is null";

  config->provider = provider_from_string(config->providerStr.c_str());
  if (config->provider == Provider::UNKNOWN)
    return "Invalid provider."
           " Must be: bnxt, mlx5, ionic, or ernic";

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
    fprintf(stderr, "rdma-ep: Missing endpoint config\n");
    return hipErrorInvalidValue;
  }

  auto* cfg = static_cast<rdma_ep::RdmaEpConfig*>(config->endpointConfig);

  fprintf(stderr,
          "rdma-ep: provider=%s loopback=%s"
          " sq_depth=%u iters=%u size=%u\n",
          rdma_ep::provider_name(cfg->provider), cfg->loopback ? "yes" : "no",
          cfg->sqDepth, cfg->iterations, cfg->transferSize);

  rdma_ep::BackendConfig bcfg;
  bcfg.provider = cfg->provider;
  bcfg.gpu_device_id = cfg->gpuDeviceId;
  bcfg.sq_depth = cfg->sqDepth;
  bcfg.cq_depth = cfg->cqDepth;
  bcfg.inline_threshold = cfg->inlineThreshold;
  bcfg.pcie_relaxed_ordering = cfg->pcieRelaxedOrdering;
  bcfg.traffic_class = cfg->trafficClass;
  bcfg.loopback = cfg->loopback;
  bcfg.pci_mmio_bridge = cfg->pciMmioBridge;
  if (!cfg->deviceName.empty())
    bcfg.hca_list = cfg->deviceName.c_str();

  rdma_ep::Backend backend(bcfg);
  int ret = backend.init();
  if (ret != 0) {
    fprintf(stderr, "rdma-ep: Backend init failed\n");
    return hipErrorUnknown;
  }

  fprintf(stderr, "rdma-ep: Backend initialized.\n");

  rdma_ep::QueuePair* gpu_qp = backend.get_gpu_qp();

  if (!gpu_qp) {
    fprintf(stderr, "rdma-ep: No GPU QueuePair available."
                    " Backend init verified OK.\n");
    backend.shutdown();
    return hipSuccess;
  }

  // --- Allocate and register data buffer ---
  size_t xfer = cfg->transferSize;
  size_t buf_size = xfer * 2;
  void* buf = nullptr;
  if (posix_memalign(&buf, 4096, buf_size)) {
    fprintf(stderr, "rdma-ep: posix_memalign failed\n");
    backend.shutdown();
    return hipErrorMemoryAllocation;
  }

  auto* src = static_cast<uint8_t*>(buf);
  auto* dst = src + xfer;

  xio::DataPatternParams fill_p{src,       xfer,
                                0,         static_cast<uint32_t>(xfer),
                                cfg->seed, nullptr};
  xio::dataPattern(false, fill_p);
  memset(dst, 0x00, xfer);

  ret = backend.register_data_buffer(buf, buf_size);
  if (ret != 0) {
    fprintf(stderr, "rdma-ep: register_data_buffer failed\n");
    free(buf);
    backend.shutdown();
    return hipErrorUnknown;
  }

  fprintf(stderr,
          "rdma-ep: Buffer registered:"
          " lkey=0x%x rkey=0x%x\n",
          backend.get_lkey(), backend.get_rkey());
  fprintf(stderr, "rdma-ep: src=%p dst=%p size=%zu\n", (void*)src, (void*)dst,
          xfer);

  // --- Launch kernel ---
  hipLaunchKernelGGL(rdma_ep::rdma_ep_kernel, dim3(1), dim3(1), 0, 0, gpu_qp,
                     (void*)src, (void*)dst, config->startTimes,
                     config->endTimes, config->timingStats, config->iterations,
                     cfg->transferSize);

  hipError_t launchErr = hipGetLastError();
  if (launchErr != hipSuccess) {
    fprintf(stderr, "rdma-ep: Kernel launch failed: %s\n",
            hipGetErrorString(launchErr));
    free(buf);
    backend.shutdown();
    return launchErr;
  }

  hipError_t syncErr = hipDeviceSynchronize();
  if (syncErr != hipSuccess) {
    fprintf(stderr, "rdma-ep: Kernel sync failed: %s\n",
            hipGetErrorString(syncErr));
    free(buf);
    backend.shutdown();
    return syncErr;
  }

  fprintf(stderr,
          "rdma-ep: Kernel completed"
          " %u iterations.\n",
          config->iterations);

  // --- Optional LFSR verification ---
  if (cfg->verify) {
    size_t errOff = 0;
    xio::DataPatternParams vp{dst,       xfer,   0, static_cast<uint32_t>(xfer),
                              cfg->seed, &errOff};
    bool ok = xio::dataPattern(true, vp);
    if (ok) {
      fprintf(stderr,
              "rdma-ep: VERIFY PASSED"
              " (%zu bytes, seed=%u)\n",
              xfer, cfg->seed);
    } else {
      fprintf(stderr,
              "rdma-ep: VERIFY FAILED at"
              " offset %zu (seed=%u)\n",
              errOff, cfg->seed);
    }
  }

  free(buf);
  backend.shutdown();
  return hipSuccess;
}

#endif // !__HIP_DEVICE_COMPILE__
