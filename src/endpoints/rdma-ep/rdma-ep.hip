/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * RDMA Endpoint -- GPU-Direct Access (GDA).
 * Derived from ROCm/rocSHMEM GDA backend,
 * adapted for rocm-xio. Shared RDMA orchestration helpers live in
 * rdma-common.h and rdma-common.hip.
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
#include "rdma-common.h"
#include "rdma-ep.h"
#include "xio-data-pattern.hpp"
#include "xio-timing.h"
#include "xio.h"

namespace xio {
namespace rdma_ep {

__global__ void rdma_ep_kernel(QueuePair* qp, void* src_ptr, void* dst_ptr,
                               unsigned long long int* startTimes,
                               unsigned long long int* endTimes,
                               xio::XioTimingStats* timingStats,
                               unsigned iterations, uint32_t transferSize,
                               volatile bool* stopRequested, bool doVerify,
                               uint32_t baseSeed, uint32_t* verifyPass,
                               uint32_t* verifyFail,
                               xio::XioSubstepStats* substepStats) {
  if (threadIdx.x != 0)
    return;

  bool infinite = (iterations == 0);
  unsigned i = 0;
  auto* src = static_cast<uint8_t*>(src_ptr);
  auto* dst = static_cast<uint8_t*>(dst_ptr);

  qp->stopRequested_ = stopRequested;

  while ((infinite || i < iterations) && (!stopRequested || !*stopRequested)) {
    uint32_t iterSeed = baseSeed + i;

    if (doVerify)
      prepare_verify_buffer(src, dst, transferSize, iterSeed);

    unsigned long long int t0 = wall_clock64();

    if (startTimes && !infinite)
      startTimes[i] = t0;

    unsigned long long int ss_t0 = 0, ss_t1 = 0;
    if (substepStats)
      ss_t0 = wall_clock64();

    qp->put_nbi_single(dst_ptr, src_ptr, transferSize, true);

    if (substepStats) {
      ss_t1 = wall_clock64();
      substepStats->sqeEnqueue += ss_t1 - ss_t0;
      substepStats->doorbell += ss_t1 - ss_t0;
      ss_t0 = ss_t1;
    }

    qp->quiet_single();

    if (substepStats) {
      ss_t1 = wall_clock64();
      substepStats->cqPoll += ss_t1 - ss_t0;
      substepStats->count++;
    }

    unsigned long long int t1 = wall_clock64();

    if (endTimes && !infinite)
      endTimes[i] = t1;

    if (timingStats && t1 > t0)
      updateTimingStats(timingStats, t1 - t0);

    if (doVerify)
      verify_buffer(dst, transferSize, iterSeed, "single", i, verifyPass,
                    verifyFail);

    i++;
  }
}

__global__ void rdma_ep_batch_kernel(
  QueuePair* qp, uint8_t* buf, uint32_t transferSize, uint32_t batchSize,
  unsigned iterations, xio::XioTimingStats* timingStats,
  volatile bool* stopRequested, bool doVerify, uint32_t baseSeed,
  uint32_t* verifyPass, uint32_t* verifyFail) {
  extern __shared__ unsigned long long int sh_start[];
  __shared__ unsigned sh_ops_done;
  __shared__ unsigned sh_batch_count;
  __shared__ bool sh_stop;

  unsigned tid = threadIdx.x;
  bool infinite = (iterations == 0);

  if (tid == 0) {
    qp->stopRequested_ = stopRequested;
    sh_ops_done = 0;
    sh_stop = false;
  }
  __syncthreads();

  while (!sh_stop) {
    // Phase 1: coordinator sets batch count
    if (tid == 0) {
      unsigned remaining = infinite ? batchSize : iterations - sh_ops_done;
      if (remaining == 0) {
        sh_stop = true;
      } else {
        sh_batch_count = remaining < batchSize ? remaining : batchSize;
      }
      if (stopRequested && *stopRequested)
        sh_stop = true;
    }
    __syncthreads();
    if (sh_stop)
      break;

    unsigned batch_count = sh_batch_count;

    // Phase 2a: workers fill src and zero dst
    if (tid >= 1 && doVerify) {
      unsigned b = tid - 1;
      if (b < batch_count) {
        unsigned op = infinite ? b : sh_ops_done + b;
        uint8_t* src = buf + (size_t)b * 2 * transferSize;
        uint8_t* dst = src + transferSize;
        prepare_verify_buffer(src, dst, transferSize, baseSeed + op);
      }
    }
    __syncthreads();

    // Phase 2b + 3: coordinator posts WQEs
    // serially (SQ state is not thread-safe),
    // then rings one doorbell and drains CQ.
    if (tid == 0) {
      for (unsigned b = 0; b < batch_count; b++) {
        uint8_t* src = buf + (size_t)b * 2 * transferSize;
        uint8_t* dst = src + transferSize;
        sh_start[b] = wall_clock64();
        qp->put_nbi_single(dst, src, transferSize, false);
      }
      qp->ring_doorbell_single();
      qp->quiet_single();
      unsigned long long int t1 = wall_clock64();

      for (unsigned b = 0; b < batch_count; b++) {
        if (timingStats && t1 > sh_start[b])
          updateTimingStats(timingStats, t1 - sh_start[b]);
      }

      if (doVerify) {
        for (unsigned b = 0; b < batch_count; b++) {
          unsigned op = infinite ? b : sh_ops_done + b;
          uint8_t* dst = buf + (size_t)b * 2 * transferSize + transferSize;
          verify_buffer(dst, transferSize, baseSeed + op, "batch", op,
                        verifyPass, verifyFail);
        }
      }

      sh_ops_done += batch_count;
      if (!infinite && sh_ops_done >= iterations)
        sh_stop = true;
      if (stopRequested && *stopRequested)
        sh_stop = true;
    }
    __syncthreads();
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
} // namespace xio

#ifndef __HIP_DEVICE_COMPILE__

#include <climits>
#include <vector>

#include "tcp-exchange.hpp"
#include "xio-env.h"

namespace xio {
namespace rdma_ep {

__host__ std::string validateConfig(RdmaEpConfig* config) {
  if (!config)
    return "Configuration pointer is null";

  config->provider = provider_from_string(config->providerStr.c_str());
  if (config->provider == Provider::UNKNOWN)
    return std::string("Invalid provider. Must be: ") +
           provider_allowed_names();

  if (config->infiniteMode)
    config->iterations = 0;

  if (config->sqDepth == 0)
    return "SQ depth must be > 0";
  if (config->transferSize == 0)
    return "Transfer size must be > 0";

  if (config->batchSize > 0 && config->batchSize >= config->sqDepth)
    return "--batch-size must be < --sq-depth";
  if (config->batchSize > 1 && !config->loopback)
    return "--batch-size > 1 requires loopback mode";
  if (config->batchSize > 1) {
    int maxBlock = 0;
    (void)hipDeviceGetAttribute(&maxBlock, hipDeviceAttributeMaxThreadsPerBlock,
                                config->gpuDeviceId);
    if (maxBlock > 0 && config->batchSize + 1 > static_cast<unsigned>(maxBlock))
      return "--batch-size + 1 exceeds GPU"
             " max threads per block";
  }
  if (config->numQueues > 1 && !config->loopback)
    return "--num-queues > 1 requires loopback mode";

  if (config->isServer && config->isClient)
    return "--server and --client are"
           " mutually exclusive";
  if (config->isServer || config->isClient)
    config->loopback = false;
  if (!config->loopback && !config->isServer && !config->isClient)
    return "--no-loopback requires"
           " --server or --client";
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
    if (cfg->infiniteMode)
      return 0;
    return cfg->iterations;
  }
  return 128;
}

} // namespace rdma_ep
} // namespace xio

static hipError_t rdma_ep_loopback(xio::XioEndpointConfig* config,
                                   rdma_ep::RdmaEpConfig* cfg) {
  bool data_on_device = (config->memoryMode & XIO_MEM_MODE_DATA_DEVICE) != 0;

  uint16_t numQueues = cfg->numQueues;
  uint32_t batchSize = cfg->batchSize;
  size_t xfer = cfg->transferSize;

  bool useBatch = (batchSize > 1);
  bool forceLessTiming = (useBatch || numQueues > 1) &&
                         config->startTimes != nullptr;

  if (forceLessTiming) {
    ROCXIO_LOG_INFO("rdma-ep: Forcing less-timing"
                    " (batch=%u queues=%u)\n",
                    batchSize, numQueues);
    if (!config->timingStats) {
      (void)hipHostMalloc((void**)&config->timingStats,
                          sizeof(xio::XioTimingStats), hipHostMallocMapped);
      if (config->timingStats) {
        config->timingStats->minDuration = ULLONG_MAX;
        config->timingStats->maxDuration = 0;
        config->timingStats->sumDuration = 0;
        config->timingStats->count = 0;
      }
    }
  }

  // Per-buffer pairs: batch needs batchSize pairs
  uint32_t pairs = useBatch ? batchSize : 1;
  size_t buf_size = (size_t)pairs * 2 * xfer;

  struct QueueState {
    rdma_ep::Backend* backend;
    void* buf;
    rdma_ep::QueuePair* gpu_qp;
    hipStream_t stream;
    xio::XioTimingStats* stats;
    uint32_t* verifyPass;
    uint32_t* verifyFail;
  };

  std::vector<QueueState> queues(numQueues);
  for (auto& qs : queues) {
    qs.backend = nullptr;
    qs.buf = nullptr;
    qs.gpu_qp = nullptr;
    qs.stream = nullptr;
    qs.stats = nullptr;
    qs.verifyPass = nullptr;
    qs.verifyFail = nullptr;
  }

  hipError_t result = hipSuccess;

  // Initialize all backends and buffers
  for (uint16_t q = 0; q < numQueues; q++) {
    rdma_ep::BackendConfig bcfg = rdma_ep::make_backend_config(*config, *cfg,
                                                               true);

    queues[q].backend = new rdma_ep::Backend(bcfg);
    int ret = queues[q].backend->init();
    if (ret != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: Backend init"
                       " failed (queue %u)\n",
                       q);
      result = hipErrorUnknown;
      goto cleanup;
    }

    queues[q].gpu_qp = queues[q].backend->get_gpu_qp();
    if (!queues[q].gpu_qp) {
      ROCXIO_LOG_INFO("rdma-ep: No GPU QueuePair"
                      " (queue %u)\n",
                      q);
      result = hipSuccess;
      goto cleanup;
    }

    if (data_on_device) {
      hsa_status_t hsa_err = xio::allocDeviceMemory(buf_size, &queues[q].buf,
                                                    "RDMA loopback buffer",
                                                    XIO_DEVICE_MEM_FINE_GRAINED,
                                                    cfg->gpuDeviceId);
      if (hsa_err != HSA_STATUS_SUCCESS) {
        ROCXIO_LOG_ERROR("rdma-ep: allocDeviceMemory"
                         " failed (queue %u)\n",
                         q);
        result = hipErrorMemoryAllocation;
        goto cleanup;
      }
    } else {
      hipError_t hip_err = xio::allocHostMemory(buf_size, &queues[q].buf,
                                                "RDMA loopback buffer",
                                                XIO_HOST_MEM_PINNED);
      if (hip_err != hipSuccess) {
        ROCXIO_LOG_ERROR("rdma-ep: allocHostMemory"
                         " failed (queue %u)\n",
                         q);
        result = hipErrorMemoryAllocation;
        goto cleanup;
      }
    }

    if (!useBatch) {
      auto* src = static_cast<uint8_t*>(queues[q].buf);
      auto* dst = src + xfer;
      if (data_on_device) {
        (void)hipMemset(dst, 0x00, xfer);
        uint8_t* hf = nullptr;
        (void)xio::allocHostMemory(xfer, (void**)&hf, "RDMA pattern fill",
                                   XIO_HOST_MEM_PINNED);
        if (hf) {
          xio::DataPatternParams fp{hf,        xfer,
                                    0,         static_cast<uint32_t>(xfer),
                                    cfg->seed, nullptr};
          xio::dataPattern(false, fp);
          (void)hipMemcpy(src, hf, xfer, hipMemcpyHostToDevice);
          xio::freeHostMemory(hf, XIO_HOST_MEM_PINNED);
        }
      } else {
        xio::DataPatternParams fp{src,       xfer,
                                  0,         static_cast<uint32_t>(xfer),
                                  cfg->seed, nullptr};
        xio::dataPattern(false, fp);
        memset(dst, 0x00, xfer);
      }
    }

    int reg = queues[q].backend->register_data_buffer(queues[q].buf, buf_size);
    if (reg != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: register_data_buffer"
                       " failed (queue %u)\n",
                       q);
      result = hipErrorUnknown;
      goto cleanup;
    }

    if (numQueues > 1) {
      hipError_t se = hipStreamCreate(&queues[q].stream);
      if (se != hipSuccess) {
        ROCXIO_LOG_ERROR("rdma-ep: hipStreamCreate"
                         " failed (queue %u)\n",
                         q);
        result = se;
        goto cleanup;
      }
    }

    bool useLessTiming = forceLessTiming || config->timingStats != nullptr;
    if (useLessTiming) {
      (void)hipHostMalloc((void**)&queues[q].stats, sizeof(xio::XioTimingStats),
                          hipHostMallocMapped);
      if (queues[q].stats) {
        queues[q].stats->minDuration = ULLONG_MAX;
        queues[q].stats->maxDuration = 0;
        queues[q].stats->sumDuration = 0;
        queues[q].stats->count = 0;
      }
    }

    if (cfg->verify) {
      (void)hipHostMalloc((void**)&queues[q].verifyPass, sizeof(uint32_t),
                          hipHostMallocMapped);
      (void)hipHostMalloc((void**)&queues[q].verifyFail, sizeof(uint32_t),
                          hipHostMallocMapped);
      if (queues[q].verifyPass)
        *queues[q].verifyPass = 0;
      if (queues[q].verifyFail)
        *queues[q].verifyFail = 0;
    }

    ROCXIO_LOG_DEBUG("rdma-ep: Queue %u ready:"
                     " lkey=0x%x rkey=0x%x\n",
                     q, queues[q].backend->get_lkey(),
                     queues[q].backend->get_rkey());
  }

  // Launch kernels
  for (uint16_t q = 0; q < numQueues; q++) {
    unsigned long long int* kStart = nullptr;
    unsigned long long int* kEnd = nullptr;
    xio::XioTimingStats* kStats = queues[q].stats;

    if (!forceLessTiming && config->iterations > 0 && numQueues == 1 &&
        !useBatch) {
      kStart = config->startTimes;
      kEnd = config->endTimes;
    }
    if (!kStats && !forceLessTiming)
      kStats = config->timingStats;

    if (useBatch) {
      size_t shmem = batchSize * sizeof(unsigned long long int);
      unsigned threads = batchSize + 1;
      hipLaunchKernelGGL(rdma_ep::rdma_ep_batch_kernel, dim3(1), dim3(threads),
                         shmem, queues[q].stream, queues[q].gpu_qp,
                         static_cast<uint8_t*>(queues[q].buf),
                         cfg->transferSize, batchSize, config->iterations,
                         kStats, config->stopRequested, cfg->verify, cfg->seed,
                         queues[q].verifyPass, queues[q].verifyFail);
    } else {
      auto* src = queues[q].buf;
      auto* dst = static_cast<uint8_t*>(src) + xfer;
      hipLaunchKernelGGL(rdma_ep::rdma_ep_kernel, dim3(1), dim3(1), 0,
                         queues[q].stream, queues[q].gpu_qp, src, (void*)dst,
                         kStart, kEnd, kStats, config->iterations,
                         cfg->transferSize, config->stopRequested, cfg->verify,
                         cfg->seed, queues[q].verifyPass, queues[q].verifyFail,
                         config->substepStats);
    }

    hipError_t le = hipGetLastError();
    if (le != hipSuccess) {
      ROCXIO_LOG_ERROR("rdma-ep: Kernel launch failed"
                       " (queue %u): %s\n",
                       q, hipGetErrorString(le));
      result = le;
      goto cleanup;
    }
  }

  {
    hipError_t syncErr = hipDeviceSynchronize();
    if (syncErr != hipSuccess) {
      ROCXIO_LOG_ERROR("rdma-ep: Kernel sync failed: %s\n",
                       hipGetErrorString(syncErr));
      result = syncErr;
      goto cleanup;
    }
  }

  if (config->iterations > 0) {
    ROCXIO_LOG_INFO("rdma-ep: Kernel completed"
                    " %u iterations",
                    config->iterations);
    if (numQueues > 1)
      ROCXIO_LOG_INFO(" x %u queues", numQueues);
    ROCXIO_LOG_INFO(".\n");
  }

  // Aggregate verify counts
  if (cfg->verify) {
    uint32_t totalPass = 0, totalFail = 0;
    for (uint16_t q = 0; q < numQueues; q++) {
      if (queues[q].verifyPass)
        totalPass += *queues[q].verifyPass;
      if (queues[q].verifyFail)
        totalFail += *queues[q].verifyFail;
    }
    config->verifyPass = totalPass;
    config->verifyFail = totalFail;
  }

  // Aggregate timing stats from per-queue buffers
  // into the harness-owned timingStats.
  if (config->timingStats && queues[0].stats) {
    config->timingStats->minDuration = ULLONG_MAX;
    config->timingStats->maxDuration = 0;
    config->timingStats->sumDuration = 0;
    config->timingStats->count = 0;
    for (uint16_t q = 0; q < numQueues; q++) {
      if (!queues[q].stats)
        continue;
      auto* s = queues[q].stats;
      if (s->minDuration < config->timingStats->minDuration)
        config->timingStats->minDuration = s->minDuration;
      if (s->maxDuration > config->timingStats->maxDuration)
        config->timingStats->maxDuration = s->maxDuration;
      config->timingStats->sumDuration += s->sumDuration;
      config->timingStats->count += s->count;
    }
    if (numQueues > 1)
      ROCXIO_LOG_INFO("rdma-ep: Aggregated timing"
                      " across %u queues: %llu ops\n",
                      numQueues,
                      (unsigned long long)config->timingStats->count);
  }

cleanup:
  for (uint16_t q = 0; q < numQueues; q++) {
    if (queues[q].verifyPass)
      (void)hipHostFree(queues[q].verifyPass);
    if (queues[q].verifyFail)
      (void)hipHostFree(queues[q].verifyFail);
    if (queues[q].stats)
      (void)hipHostFree(queues[q].stats);
    if (queues[q].stream)
      (void)hipStreamDestroy(queues[q].stream);
    if (queues[q].buf) {
      if (data_on_device)
        xio::freeDeviceMemory(queues[q].buf, XIO_DEVICE_MEM_FINE_GRAINED);
      else
        xio::freeHostMemory(queues[q].buf, XIO_HOST_MEM_PINNED);
    }
    if (queues[q].backend) {
      queues[q].backend->shutdown();
      delete queues[q].backend;
    }
  }
  return result;
}

namespace xio {
namespace rdma_ep {

hipError_t run(XioEndpointConfig* config) {
  if (!config || !config->endpointConfig) {
    ROCXIO_LOG_ERROR("rdma-ep: Missing endpoint config\n");
    return hipErrorInvalidValue;
  }

  auto* cfg = static_cast<RdmaEpConfig*>(config->endpointConfig);

  const char* mode_str = cfg->isServer   ? "server"
                         : cfg->isClient ? "client"
                                         : "loopback";

  ROCXIO_LOG_INFO("rdma-ep: provider=%s mode=%s"
                  " sq_depth=%u iters=%u size=%u"
                  " batch=%u queues=%u\n",
                  provider_name(cfg->provider), mode_str, cfg->sqDepth,
                  cfg->iterations, cfg->transferSize, cfg->batchSize,
                  cfg->numQueues);

  if (cfg->loopback) {
    return rdma_ep_loopback(config, cfg);
  } else {
    // ==========================================================
    // 2-node path -- TCP QP exchange, RDMA WRITE + ping-pong
    // ==========================================================
    BackendConfig bcfg = make_backend_config(*config, *cfg, false);

    Backend backend(bcfg);
    int ret = backend.init();
    if (ret != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: Backend init failed\n");
      return hipErrorUnknown;
    }
    ROCXIO_LOG_INFO("rdma-ep: Backend initialized.\n");

    QueuePair* gpu_qp = backend.get_gpu_qp();
    if (!gpu_qp) {
      ROCXIO_LOG_INFO("rdma-ep: No GPU QueuePair available."
                      " Backend init verified OK.\n");
      backend.shutdown();
      return hipSuccess;
    }

    static constexpr uint8_t DATA_PATTERN = 0xA5;

    uint32_t write_size = cfg->transferSize;
    uint32_t pp_size = cfg->ppSize;
    uint32_t pp_iters = cfg->ppIters;

    size_t pp_send_offset = write_size;
    size_t pp_recv_offset = write_size + pp_size;
    size_t total_reg_size = write_size + pp_size * 2 + 4096;

    ROCXIO_LOG_DEBUG("rdma-ep: 2-node buffer: total_reg=%zu"
                     " write=%u pp=%u\n",
                     total_reg_size, write_size, pp_size);

    void* reg_buf = nullptr;
    hipError_t herr = xio::allocHostMemory(total_reg_size, &reg_buf,
                                           "RDMA 2-node buffer",
                                           XIO_HOST_MEM_MAPPED |
                                             XIO_HOST_MEM_COHERENT);
    if (herr != hipSuccess) {
      ROCXIO_LOG_ERROR("rdma-ep: allocHostMemory"
                       "(coherent) failed\n");
      backend.shutdown();
      return herr;
    }

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
      xio::freeHostMemory(reg_buf, XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
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
      xio::freeHostMemory(reg_buf, XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
      backend.shutdown();
      return hipErrorUnknown;
    }

    DestInfo local_dest = backend.get_local_dest_info();
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
      xio::freeHostMemory(reg_buf, XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
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
    DestInfo peer{};
    peer.lid = remote_msg.lid;
    peer.qpn = remote_msg.qpn;
    peer.psn = 0;
    memcpy(peer.gid.raw, remote_msg.gid, 16);

    ret = backend.connect_to_peer(peer);
    if (ret != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: connect_to_peer failed\n");
      close(tcp_fd);
      xio::freeHostMemory(reg_buf, XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
      backend.shutdown();
      return hipErrorUnknown;
    }
    ROCXIO_LOG_INFO("rdma-ep: QP connected to peer.\n");

    ret = backend.set_remote_rkey(remote_msg.rkey);
    if (ret != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: set_remote_rkey failed\n");
      close(tcp_fd);
      xio::freeHostMemory(reg_buf, XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
      backend.shutdown();
      return hipErrorUnknown;
    }
    ROCXIO_LOG_DEBUG("rdma-ep: Remote rkey set to 0x%x\n", remote_msg.rkey);

    if (xio::tcp_sync(tcp_fd) != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: tcp_sync failed\n");
      close(tcp_fd);
      xio::freeHostMemory(reg_buf, XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
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
      hipLaunchKernelGGL(rdma_write_kernel, dim3(1), dim3(1), 0, 0, gpu_qp,
                         remote_data, data_region, write_size);
      herr = hipDeviceSynchronize();
      if (herr != hipSuccess) {
        ROCXIO_LOG_ERROR("rdma-ep: WRITE kernel failed:"
                         " %s\n",
                         hipGetErrorString(herr));
        close(tcp_fd);
        xio::freeHostMemory(reg_buf,
                            XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
        backend.shutdown();
        return herr;
      }
      ROCXIO_LOG_INFO("rdma-ep: WRITE complete.\n");
    }

    if (xio::tcp_sync(tcp_fd) != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: tcp_sync failed\n");
      close(tcp_fd);
      xio::freeHostMemory(reg_buf, XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
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
        xio::freeHostMemory(reg_buf,
                            XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
        backend.shutdown();
        return hipErrorUnknown;
      }
    }

    if (xio::tcp_sync(tcp_fd) != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: tcp_sync failed\n");
      close(tcp_fd);
      xio::freeHostMemory(reg_buf, XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
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
    {
      hsa_status_t s;
      s = xio::allocDeviceMemory(sizeof(uint32_t), (void**)&d_errors,
                                 "RDMA error counter", XIO_DEVICE_MEM_HIP);
      if (s != HSA_STATUS_SUCCESS) {
        ROCXIO_LOG_ERROR("rdma-ep: allocDeviceMemory d_errors failed\n");
        close(tcp_fd);
        xio::freeHostMemory(reg_buf,
                            XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
        backend.shutdown();
        return hipErrorMemoryAllocation;
      }
      s = xio::allocDeviceMemory(sizeof(unsigned long long), (void**)&d_elapsed,
                                 "RDMA elapsed counter", XIO_DEVICE_MEM_HIP);
      if (s != HSA_STATUS_SUCCESS) {
        ROCXIO_LOG_ERROR("rdma-ep: allocDeviceMemory d_elapsed failed\n");
        xio::freeDeviceMemory(d_errors, XIO_DEVICE_MEM_HIP);
        close(tcp_fd);
        xio::freeHostMemory(reg_buf,
                            XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
        backend.shutdown();
        return hipErrorMemoryAllocation;
      }
    }
    uint32_t h_errors = 0;
    unsigned long long h_elapsed = 0;
    (void)hipMemcpy(d_errors, &h_errors, sizeof(h_errors),
                    hipMemcpyHostToDevice);
    (void)hipMemcpy(d_elapsed, &h_elapsed, sizeof(h_elapsed),
                    hipMemcpyHostToDevice);

    if (xio::tcp_sync(tcp_fd) != 0) {
      ROCXIO_LOG_ERROR("rdma-ep: tcp_sync failed\n");
      xio::freeDeviceMemory(d_errors, XIO_DEVICE_MEM_HIP);
      xio::freeDeviceMemory(d_elapsed, XIO_DEVICE_MEM_HIP);
      close(tcp_fd);
      xio::freeHostMemory(reg_buf, XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
      backend.shutdown();
      return hipErrorUnknown;
    }

    if (cfg->isClient) {
      hipLaunchKernelGGL(pingpong_client_kernel, dim3(1), dim3(1), 0, 0, gpu_qp,
                         reinterpret_cast<PingPongBuf*>(pp_send_buf),
                         reinterpret_cast<volatile PingPongBuf*>(pp_recv_buf),
                         remote_recv, pp_size, pp_iters, d_errors, d_elapsed);
      herr = hipDeviceSynchronize();
      if (herr != hipSuccess) {
        ROCXIO_LOG_ERROR("rdma-ep: Pingpong client kernel"
                         " failed: %s\n",
                         hipGetErrorString(herr));
        xio::freeDeviceMemory(d_errors, XIO_DEVICE_MEM_HIP);
        xio::freeDeviceMemory(d_elapsed, XIO_DEVICE_MEM_HIP);
        close(tcp_fd);
        xio::freeHostMemory(reg_buf,
                            XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
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
        xio::freeDeviceMemory(d_errors, XIO_DEVICE_MEM_HIP);
        xio::freeDeviceMemory(d_elapsed, XIO_DEVICE_MEM_HIP);
        close(tcp_fd);
        xio::freeHostMemory(reg_buf,
                            XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
        backend.shutdown();
        return hipErrorUnknown;
      }
      ROCXIO_LOG_INFO("rdma-ep: LFSR PASSED:"
                      " all %u iterations correct.\n",
                      pp_iters);
    } else {
      hipLaunchKernelGGL(pingpong_server_kernel, dim3(1), dim3(1), 0, 0, gpu_qp,
                         reinterpret_cast<PingPongBuf*>(pp_send_buf),
                         reinterpret_cast<volatile PingPongBuf*>(pp_recv_buf),
                         remote_recv, pp_size, pp_iters, d_errors);
      herr = hipDeviceSynchronize();
      if (herr != hipSuccess) {
        ROCXIO_LOG_ERROR("rdma-ep: Pingpong server kernel"
                         " failed: %s\n",
                         hipGetErrorString(herr));
        xio::freeDeviceMemory(d_errors, XIO_DEVICE_MEM_HIP);
        xio::freeDeviceMemory(d_elapsed, XIO_DEVICE_MEM_HIP);
        close(tcp_fd);
        xio::freeHostMemory(reg_buf,
                            XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
        backend.shutdown();
        return herr;
      }

      (void)hipMemcpy(&h_errors, d_errors, sizeof(h_errors),
                      hipMemcpyDeviceToHost);
      if (h_errors > 0) {
        ROCXIO_LOG_ERROR("rdma-ep: LFSR FAILED:"
                         " %u errors\n",
                         h_errors);
        xio::freeDeviceMemory(d_errors, XIO_DEVICE_MEM_HIP);
        xio::freeDeviceMemory(d_elapsed, XIO_DEVICE_MEM_HIP);
        close(tcp_fd);
        xio::freeHostMemory(reg_buf,
                            XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);
        backend.shutdown();
        return hipErrorUnknown;
      }
      ROCXIO_LOG_INFO("rdma-ep: Ping-pong complete,"
                      " LFSR verified %u iters.\n",
                      pp_iters);
    }

    xio::freeDeviceMemory(d_errors, XIO_DEVICE_MEM_HIP);
    xio::freeDeviceMemory(d_elapsed, XIO_DEVICE_MEM_HIP);

    if (xio::tcp_sync(tcp_fd) != 0)
      ROCXIO_LOG_WARN("rdma-ep: final tcp_sync failed"
                      " (non-fatal)\n");

    close(tcp_fd);
    xio::freeHostMemory(reg_buf, XIO_HOST_MEM_MAPPED | XIO_HOST_MEM_COHERENT);

    backend.shutdown();
    return hipSuccess;
  }

  return hipSuccess;
}

} // namespace rdma_ep
} // namespace xio

#endif // !__HIP_DEVICE_COMPILE__
