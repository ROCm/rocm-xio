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

#include "gda-backend.hpp"
#include "queue-pair.hpp"
#include "rdma-ep.h"
#include "xio-data-pattern.hpp"
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

struct PingPongBuf {
  uint64_t seq;
  uint8_t payload[];
};

__device__ static void pp_fill(PingPongBuf* buf, uint32_t pp_size,
                               uint32_t iter) {
  uint32_t payload_size = pp_size - sizeof(uint64_t);
  xio::DataPatternParams p{buf->payload, payload_size, 0,
                           payload_size, iter,         nullptr};
  xio::dataPattern(false, p);
  __threadfence_system();
  buf->seq = iter;
  __threadfence_system();
}

__device__ static bool pp_verify(volatile PingPongBuf* buf, uint32_t pp_size,
                                 uint32_t iter) {
  uint32_t payload_size = pp_size - sizeof(uint64_t);
  xio::DataPatternParams p{(uint8_t*)buf->payload, payload_size, 0,
                           payload_size,           iter,         nullptr};
  return xio::dataPattern(true, p);
}

__global__ void rdma_write_kernel(QueuePair* qp, void* dst, void* src,
                                  uint32_t length) {
  if (threadIdx.x != 0)
    return;
  qp->put_nbi_single(dst, src, length, true);
  qp->quiet_single();
}

__global__ void pingpong_client_kernel(QueuePair* qp, PingPongBuf* send_buf,
                                       volatile PingPongBuf* recv_buf,
                                       void* remote_recv_addr, uint32_t pp_size,
                                       uint32_t iters, uint32_t* errors,
                                       unsigned long long* elapsed) {
  if (threadIdx.x != 0)
    return;

  *errors = 0;
  unsigned long long start = wall_clock64();

  for (uint32_t i = 0; i < iters; i++) {
    uint32_t iter = i + 1;

    pp_fill(send_buf, pp_size, iter);

    qp->put_nbi_single(remote_recv_addr, send_buf, pp_size, true);
    qp->quiet_single();

    while (recv_buf->seq != iter)
      __builtin_amdgcn_s_sleep(1);

    if (!pp_verify(recv_buf, pp_size, iter))
      (*errors)++;
  }

  *elapsed = wall_clock64() - start;
}

__global__ void pingpong_server_kernel(QueuePair* qp, PingPongBuf* send_buf,
                                       volatile PingPongBuf* recv_buf,
                                       void* remote_recv_addr, uint32_t pp_size,
                                       uint32_t iters, uint32_t* errors) {
  if (threadIdx.x != 0)
    return;

  *errors = 0;

  for (uint32_t i = 0; i < iters; i++) {
    uint32_t iter = i + 1;

    while (recv_buf->seq != iter)
      __builtin_amdgcn_s_sleep(1);

    if (!pp_verify(recv_buf, pp_size, iter))
      (*errors)++;

    pp_fill(send_buf, pp_size, iter);

    qp->put_nbi_single(remote_recv_addr, send_buf, pp_size, true);
    qp->quiet_single();
  }
}

} // namespace rdma_ep

#ifndef __HIP_DEVICE_COMPILE__

#include "tcp-exchange.hpp"
#include "xio-env.h"

namespace rdma_ep {

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

  if (config->isServer && config->isClient)
    return "--server and --client are mutually exclusive";
  if (config->isServer || config->isClient)
    config->loopback = false;
  if (!config->loopback && !config->isServer && !config->isClient)
    return "--no-loopback requires --server or --client";
  if (config->isClient && config->serverHost.empty())
    return "--client requires --server-host";
  if ((config->isServer || config->isClient) && config->ppSize < 16)
    return "Ping-pong size must be >= 16 bytes"
           " (8-byte seq header + payload)";
  if ((config->isServer || config->isClient) && (config->ppSize % 8) != 0)
    return "Ping-pong size must be a multiple of 8"
           " (PingPongBuf alignment)";

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
    ROCXIO_LOG_ERROR("rdma-ep: Missing endpoint config\n");
    return hipErrorInvalidValue;
  }

  auto* cfg = static_cast<rdma_ep::RdmaEpConfig*>(config->endpointConfig);

  const char* mode_str = cfg->isServer   ? "server"
                         : cfg->isClient ? "client"
                                         : "loopback";

  ROCXIO_LOG_INFO("rdma-ep: provider=%s mode=%s"
                  " sq_depth=%u iters=%u size=%u\n",
                  rdma_ep::provider_name(cfg->provider), mode_str, cfg->sqDepth,
                  cfg->iterations, cfg->transferSize);

  rdma_ep::BackendConfig bcfg;
  bcfg.provider = cfg->provider;
  bcfg.gpu_device_id = cfg->gpuDeviceId;
  bcfg.sq_depth = cfg->sqDepth;
  bcfg.cq_depth = cfg->cqDepth;
  bcfg.inline_threshold = cfg->inlineThreshold;
  bcfg.pcie_relaxed_ordering = cfg->pcieRelaxedOrdering;
  bcfg.traffic_class = cfg->trafficClass;
  bcfg.loopback = cfg->loopback;
  bcfg.pci_mmio_bridge = config->pciMmioBridge;

  rdma_ep::Backend backend(bcfg);
  int ret = backend.init();
  if (ret != 0) {
    ROCXIO_LOG_ERROR("rdma-ep: Backend init failed\n");
    return hipErrorUnknown;
  }

  ROCXIO_LOG_INFO("rdma-ep: Backend initialized.\n");

  rdma_ep::QueuePair* gpu_qp = backend.get_gpu_qp();

  if (!gpu_qp) {
    ROCXIO_LOG_INFO("rdma-ep: No GPU QueuePair available."
                    " Backend init verified OK.\n");
    backend.shutdown();
    return hipSuccess;
  }

  if (cfg->loopback) {
    // ==========================================================
    // Loopback path -- existing single-node RDMA WRITE test
    // ==========================================================
    size_t xfer = cfg->transferSize;
    size_t buf_size = xfer * 2;
    void* buf = nullptr;
    if (posix_memalign(&buf, 4096, buf_size)) {
      ROCXIO_LOG_ERROR("rdma-ep: posix_memalign failed\n");
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
      ROCXIO_LOG_ERROR("rdma-ep: register_data_buffer failed\n");
      free(buf);
      backend.shutdown();
      return hipErrorUnknown;
    }

    ROCXIO_LOG_DEBUG("rdma-ep: Buffer registered:"
                     " lkey=0x%x rkey=0x%x\n",
                     backend.get_lkey(), backend.get_rkey());
    ROCXIO_LOG_DEBUG("rdma-ep: src=%p dst=%p size=%zu\n", (void*)src,
                     (void*)dst, xfer);

    hipLaunchKernelGGL(rdma_ep::rdma_ep_kernel, dim3(1), dim3(1), 0, 0, gpu_qp,
                       (void*)src, (void*)dst, config->startTimes,
                       config->endTimes, config->timingStats,
                       config->iterations, cfg->transferSize);

    hipError_t launchErr = hipGetLastError();
    if (launchErr != hipSuccess) {
      ROCXIO_LOG_ERROR("rdma-ep: Kernel launch failed: %s\n",
                       hipGetErrorString(launchErr));
      free(buf);
      backend.shutdown();
      return launchErr;
    }

    hipError_t syncErr = hipDeviceSynchronize();
    if (syncErr != hipSuccess) {
      ROCXIO_LOG_ERROR("rdma-ep: Kernel sync failed: %s\n",
                       hipGetErrorString(syncErr));
      free(buf);
      backend.shutdown();
      return syncErr;
    }

    ROCXIO_LOG_INFO("rdma-ep: Kernel completed"
                    " %u iterations.\n",
                    config->iterations);

    if (cfg->verify) {
      size_t errOff = 0;
      xio::DataPatternParams vp{dst,       xfer,
                                0,         static_cast<uint32_t>(xfer),
                                cfg->seed, &errOff};
      bool ok = xio::dataPattern(true, vp);
      if (ok) {
        ROCXIO_LOG_INFO("rdma-ep: VERIFY PASSED"
                        " (%zu bytes, seed=%u)\n",
                        xfer, cfg->seed);
      } else {
        ROCXIO_LOG_ERROR("rdma-ep: VERIFY FAILED at"
                         " offset %zu (seed=%u)\n",
                         errOff, cfg->seed);
      }
    }

    free(buf);
  } else {
    // ==========================================================
    // 2-node path -- TCP QP exchange, RDMA WRITE + ping-pong
    // ==========================================================
    static constexpr uint8_t DATA_PATTERN = 0xA5;

    uint32_t write_size = cfg->transferSize;
    uint32_t pp_size = cfg->ppSize;
    uint32_t pp_iters = cfg->ppIters;

    // Buffer layout:
    //   [data (write_size) | pp_send (pp_size) | pp_recv (pp_size) | pad]
    // hipHostMallocCoherent so GPU sees RDMA writes from remote NIC.
    size_t pp_send_offset = write_size;
    size_t pp_recv_offset = write_size + pp_size;
    size_t total_reg_size = write_size + pp_size * 2 + 4096;

    ROCXIO_LOG_DEBUG("rdma-ep: 2-node buffer: total_reg=%zu"
                     " write=%u pp=%u\n",
                     total_reg_size, write_size, pp_size);

    void* reg_buf = nullptr;
    hipError_t herr = hipHostMalloc(&reg_buf, total_reg_size,
                                    hipHostMallocMapped |
                                      hipHostMallocCoherent);
    if (herr != hipSuccess) {
      ROCXIO_LOG_ERROR("rdma-ep: hipHostMalloc(coherent)"
                       " failed: %s\n",
                       hipGetErrorString(herr));
      backend.shutdown();
      return herr;
    }
    memset(reg_buf, 0, total_reg_size);

    auto* data_region = static_cast<uint8_t*>(reg_buf);
    uint8_t* pp_send_buf = data_region + pp_send_offset;
    uint8_t* pp_recv_buf = data_region + pp_recv_offset;

    if (cfg->isClient)
      memset(data_region, DATA_PATTERN, write_size);
    else
      memset(data_region, 0, write_size);
    memset(pp_send_buf, 0, pp_size);
    memset(pp_recv_buf, 0, pp_size);

    ret = backend.register_data_buffer(reg_buf, total_reg_size);
    if (ret != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: register_data_buffer failed\n");
      (void)hipHostFree(reg_buf);
      backend.shutdown();
      return hipErrorUnknown;
    }

    ROCXIO_LOG_DEBUG("rdma-ep: Buffer registered:"
                     " lkey=0x%x rkey=0x%x size=%zu\n",
                     backend.get_lkey(), backend.get_rkey(), total_reg_size);

    // --- TCP QP exchange ---
    int tcp_fd;
    if (cfg->isServer) {
      tcp_fd = xio::tcp_server_accept();
    } else {
      tcp_fd = xio::tcp_client_connect(cfg->serverHost.c_str());
    }
    if (tcp_fd < 0) {
      ROCXIO_LOG_ERROR("rdma-ep: TCP setup failed\n");
      (void)hipHostFree(reg_buf);
      backend.shutdown();
      return hipErrorUnknown;
    }

    rdma_ep::DestInfo local_dest = backend.get_local_dest_info();
    xio::ExchangeMsg local_msg{};
    local_msg.qpn = local_dest.qpn;
    local_msg.rkey = backend.get_rkey();
    local_msg.lid = static_cast<uint16_t>(local_dest.lid);
    local_msg.pad = 0;
    local_msg.remote_addr = reinterpret_cast<uint64_t>(reg_buf);
    memcpy(local_msg.gid, local_dest.gid.raw, 16);

    xio::ExchangeMsg remote_msg{};
    ret = xio::exchange_info(tcp_fd, local_msg, &remote_msg);
    if (ret != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: TCP exchange failed\n");
      close(tcp_fd);
      (void)hipHostFree(reg_buf);
      backend.shutdown();
      return hipErrorUnknown;
    }

    ROCXIO_LOG_DEBUG("rdma-ep: Local  QPN=%u rkey=0x%x"
                     " addr=0x%lx\n",
                     local_msg.qpn, local_msg.rkey,
                     (unsigned long)local_msg.remote_addr);
    ROCXIO_LOG_DEBUG("rdma-ep: Remote QPN=%u rkey=0x%x"
                     " addr=0x%lx\n",
                     remote_msg.qpn, remote_msg.rkey,
                     (unsigned long)remote_msg.remote_addr);

    // --- Connect QP to peer ---
    rdma_ep::DestInfo peer{};
    peer.lid = remote_msg.lid;
    peer.qpn = remote_msg.qpn;
    peer.psn = 0;
    memcpy(peer.gid.raw, remote_msg.gid, 16);

    ret = backend.connect_to_peer(peer);
    if (ret != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: connect_to_peer failed\n");
      close(tcp_fd);
      (void)hipHostFree(reg_buf);
      backend.shutdown();
      return hipErrorUnknown;
    }
    ROCXIO_LOG_INFO("rdma-ep: QP connected to peer.\n");

    ret = backend.set_remote_rkey(remote_msg.rkey);
    if (ret != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: set_remote_rkey failed\n");
      close(tcp_fd);
      (void)hipHostFree(reg_buf);
      backend.shutdown();
      return hipErrorUnknown;
    }
    ROCXIO_LOG_DEBUG("rdma-ep: Remote rkey set to 0x%x\n", remote_msg.rkey);

    if (xio::tcp_sync(tcp_fd) != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: tcp_sync failed\n");
      close(tcp_fd);
      (void)hipHostFree(reg_buf);
      backend.shutdown();
      return hipErrorUnknown;
    }

    // --- Test 1: RDMA WRITE correctness ---
    ROCXIO_LOG_INFO("\nrdma-ep: --- RDMA WRITE Correctness"
                    " ---\n");

    if (cfg->isClient) {
      void* remote_data = reinterpret_cast<void*>(remote_msg.remote_addr);

      ROCXIO_LOG_INFO("rdma-ep: WRITE %u bytes"
                      " to server...\n",
                      write_size);
      hipLaunchKernelGGL(rdma_ep::rdma_write_kernel, dim3(1), dim3(1), 0, 0,
                         gpu_qp, remote_data, data_region, write_size);
      herr = hipDeviceSynchronize();
      if (herr != hipSuccess) {
        ROCXIO_LOG_ERROR("rdma-ep: WRITE kernel failed:"
                         " %s\n",
                         hipGetErrorString(herr));
        close(tcp_fd);
        (void)hipHostFree(reg_buf);
        backend.shutdown();
        return herr;
      }
      ROCXIO_LOG_INFO("rdma-ep: WRITE complete.\n");
    }

    if (xio::tcp_sync(tcp_fd) != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: tcp_sync failed\n");
      close(tcp_fd);
      (void)hipHostFree(reg_buf);
      backend.shutdown();
      return hipErrorUnknown;
    }

    if (cfg->isServer) {
      int errors = 0;
      for (uint32_t i = 0; i < write_size; i++) {
        if (data_region[i] != DATA_PATTERN) {
          if (errors < 5)
            ROCXIO_LOG_ERROR("  MISMATCH at %u:"
                             " expected 0x%02x,"
                             " got 0x%02x\n",
                             i, DATA_PATTERN, data_region[i]);
          errors++;
        }
      }
      if (errors == 0) {
        ROCXIO_LOG_INFO("rdma-ep: WRITE PASSED:"
                        " all %u bytes correct.\n",
                        write_size);
      } else {
        ROCXIO_LOG_ERROR("rdma-ep: WRITE FAILED:"
                         " %d/%u bytes wrong.\n",
                         errors, write_size);
        close(tcp_fd);
        (void)hipHostFree(reg_buf);
        backend.shutdown();
        return hipErrorUnknown;
      }
    }

    if (xio::tcp_sync(tcp_fd) != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: tcp_sync failed\n");
      close(tcp_fd);
      (void)hipHostFree(reg_buf);
      backend.shutdown();
      return hipErrorUnknown;
    }

    // --- Test 2: Ping-pong with LFSR verification ---
    ROCXIO_LOG_INFO("\nrdma-ep: --- Ping-Pong LFSR"
                    " (%u iters, %u bytes) ---\n",
                    pp_iters, pp_size);

    memset(pp_send_buf, 0, pp_size);
    memset(pp_recv_buf, 0, pp_size);

    void* remote_recv = reinterpret_cast<void*>(remote_msg.remote_addr +
                                                pp_recv_offset);

    uint32_t* d_errors = nullptr;
    unsigned long long* d_elapsed = nullptr;
    herr = hipMalloc(&d_errors, sizeof(uint32_t));
    if (herr != hipSuccess) {
      ROCXIO_LOG_ERROR("rdma-ep: hipMalloc d_errors: %s\n",
                       hipGetErrorString(herr));
      close(tcp_fd);
      (void)hipHostFree(reg_buf);
      backend.shutdown();
      return herr;
    }
    herr = hipMalloc(&d_elapsed, sizeof(unsigned long long));
    if (herr != hipSuccess) {
      ROCXIO_LOG_ERROR("rdma-ep: hipMalloc d_elapsed: %s\n",
                       hipGetErrorString(herr));
      (void)hipFree(d_errors);
      close(tcp_fd);
      (void)hipHostFree(reg_buf);
      backend.shutdown();
      return herr;
    }
    uint32_t h_errors = 0;
    unsigned long long h_elapsed = 0;
    (void)hipMemcpy(d_errors, &h_errors, sizeof(h_errors),
                    hipMemcpyHostToDevice);
    (void)hipMemcpy(d_elapsed, &h_elapsed, sizeof(h_elapsed),
                    hipMemcpyHostToDevice);

    if (xio::tcp_sync(tcp_fd) != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: tcp_sync failed\n");
      (void)hipFree(d_errors);
      (void)hipFree(d_elapsed);
      close(tcp_fd);
      (void)hipHostFree(reg_buf);
      backend.shutdown();
      return hipErrorUnknown;
    }

    if (cfg->isClient) {
      hipLaunchKernelGGL(rdma_ep::pingpong_client_kernel, dim3(1), dim3(1), 0,
                         0, gpu_qp,
                         reinterpret_cast<rdma_ep::PingPongBuf*>(pp_send_buf),
                         reinterpret_cast<volatile rdma_ep::PingPongBuf*>(
                           pp_recv_buf),
                         remote_recv, pp_size, pp_iters, d_errors, d_elapsed);
      herr = hipDeviceSynchronize();
      if (herr != hipSuccess) {
        ROCXIO_LOG_ERROR("rdma-ep: Pingpong client kernel"
                         " failed: %s\n",
                         hipGetErrorString(herr));
        (void)hipFree(d_errors);
        (void)hipFree(d_elapsed);
        close(tcp_fd);
        (void)hipHostFree(reg_buf);
        backend.shutdown();
        return herr;
      }

      (void)hipMemcpy(&h_errors, d_errors, sizeof(h_errors),
                      hipMemcpyDeviceToHost);
      (void)hipMemcpy(&h_elapsed, d_elapsed, sizeof(h_elapsed),
                      hipMemcpyDeviceToHost);

      int wallClkRate;
      (void)hipDeviceGetAttribute(&wallClkRate, hipDeviceAttributeWallClockRate,
                                  cfg->gpuDeviceId);
      double freq_khz = static_cast<double>(wallClkRate);
      double total_us = (static_cast<double>(h_elapsed) / freq_khz) * 1000.0;
      double per_iter_us = total_us / pp_iters;

      ROCXIO_LOG_INFO("rdma-ep: %u round-trips, %u bytes:"
                      " %.1f us total = %.2f us/iter\n",
                      pp_iters, pp_size, total_us, per_iter_us);
      if (h_errors > 0) {
        ROCXIO_LOG_ERROR("rdma-ep: LFSR FAILED:"
                         " %u errors\n",
                         h_errors);
        (void)hipFree(d_errors);
        (void)hipFree(d_elapsed);
        close(tcp_fd);
        (void)hipHostFree(reg_buf);
        backend.shutdown();
        return hipErrorUnknown;
      }
      ROCXIO_LOG_INFO("rdma-ep: LFSR PASSED:"
                      " all %u iterations correct.\n",
                      pp_iters);
    } else {
      hipLaunchKernelGGL(rdma_ep::pingpong_server_kernel, dim3(1), dim3(1), 0,
                         0, gpu_qp,
                         reinterpret_cast<rdma_ep::PingPongBuf*>(pp_send_buf),
                         reinterpret_cast<volatile rdma_ep::PingPongBuf*>(
                           pp_recv_buf),
                         remote_recv, pp_size, pp_iters, d_errors);
      herr = hipDeviceSynchronize();
      if (herr != hipSuccess) {
        ROCXIO_LOG_ERROR("rdma-ep: Pingpong server kernel"
                         " failed: %s\n",
                         hipGetErrorString(herr));
        (void)hipFree(d_errors);
        (void)hipFree(d_elapsed);
        close(tcp_fd);
        (void)hipHostFree(reg_buf);
        backend.shutdown();
        return herr;
      }

      (void)hipMemcpy(&h_errors, d_errors, sizeof(h_errors),
                      hipMemcpyDeviceToHost);
      if (h_errors > 0) {
        ROCXIO_LOG_ERROR("rdma-ep: LFSR FAILED:"
                         " %u errors\n",
                         h_errors);
        (void)hipFree(d_errors);
        (void)hipFree(d_elapsed);
        close(tcp_fd);
        (void)hipHostFree(reg_buf);
        backend.shutdown();
        return hipErrorUnknown;
      }
      ROCXIO_LOG_INFO("rdma-ep: Ping-pong complete,"
                      " LFSR verified %u iters.\n",
                      pp_iters);
    }

    (void)hipFree(d_errors);
    (void)hipFree(d_elapsed);

    if (xio::tcp_sync(tcp_fd) != 0)
      ROCXIO_LOG_WARN("rdma-ep: final tcp_sync failed"
                      " (non-fatal)\n");

    close(tcp_fd);
    (void)hipHostFree(reg_buf);
  }

  backend.shutdown();
  return hipSuccess;
}

#endif // !__HIP_DEVICE_COMPILE__
