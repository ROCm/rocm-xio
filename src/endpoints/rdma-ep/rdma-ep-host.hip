/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 */

#include <cstring>
#include <stdexcept>

#include <hip/hip_runtime.h>

#include "gda-backend.hpp"
#include "queue-pair.hpp"
#include "rdma-ep-host.h"
#include "rdma-ep.h"

namespace xio {
namespace rdma_ep {

namespace {

/** One thread posts the WRITE, rings the doorbell and waits for completion. */
__global__ void putKernel(QueuePair* qp, void* dst, const void* src,
                          size_t bytes) {
  if (threadIdx.x != 0)
    return;
  qp->put_nbi_single(dst, src, bytes, true);
  qp->quiet_single();
}

/** The WRITE, then an atomic add behind it on the same QP, then wait for both.
 */
__global__ void putSignalKernel(QueuePair* qp, void* dst, const void* src,
                                size_t bytes, void* signal, int64_t value) {
  if (threadIdx.x != 0)
    return;
  qp->put_nbi_single(dst, src, bytes, true);
  qp->atomic_nofetch(signal, value, 0);
  qp->quiet_single();
}

void check(hipError_t err, const char* what) {
  if (err != hipSuccess)
    throw std::runtime_error(std::string(what) + ": " + hipGetErrorString(err));
}

} // namespace

Endpoint::Endpoint(const std::string& provider, const std::string& device,
                   int gpu, int sqDepth, int cqDepth, bool deviceQueues) {
  Provider prov = provider_from_string(provider.c_str());
  if (prov == Provider::UNKNOWN)
    throw std::runtime_error("unknown RDMA provider: " + provider);

  check(hipInit(0), "hipInit");
  check(hipSetDevice(gpu), "hipSetDevice");
  gpu_ = gpu;
  device_ = device;

  BackendConfig cfg;
  cfg.provider = prov;
  cfg.gpu_device_id = gpu;
  cfg.sq_depth = sqDepth;
  cfg.cq_depth = cqDepth;
  cfg.inline_threshold = 28;
  cfg.loopback = false;
  cfg.queue_mem = deviceQueues ? QueueMemMode::DEVICE_VRAM
                               : QueueMemMode::HOST_COHERENT;
  if (!device_.empty())
    cfg.hca_list = device_.c_str();

  backend_ = std::make_unique<Backend>(cfg);
  if (backend_->init() != 0)
    throw std::runtime_error("RDMA backend init failed (is the provider "
                             "compiled in and the device present?)");
}

Endpoint::~Endpoint() {
  if (state_)
    (void)hipFree(state_);
}

void Endpoint::registerBuffer(void* ptr, size_t size, bool device) {
  int rc = device ? backend_->register_device_buffer(ptr, size)
                  : backend_->register_data_buffer(ptr, size);
  if (rc != 0)
    throw std::runtime_error("RDMA buffer registration failed");
  bufAddr_ = reinterpret_cast<uint64_t>(ptr);
}

EndpointInfo Endpoint::localInfo() const {
  DestInfo d = backend_->get_local_dest_info();
  EndpointInfo info;
  info.lid = static_cast<uint32_t>(d.lid);
  info.qpn = static_cast<uint32_t>(d.qpn);
  info.psn = static_cast<uint32_t>(d.psn);
  std::memcpy(info.gid, d.gid.raw, sizeof(info.gid));
  info.rkey = backend_->get_rkey();
  info.addr = bufAddr_;
  return info;
}

void Endpoint::connect(const EndpointInfo& remote) {
  DestInfo peer{};
  peer.lid = static_cast<int>(remote.lid);
  peer.qpn = static_cast<int>(remote.qpn);
  peer.psn = static_cast<int>(remote.psn);
  std::memcpy(peer.gid.raw, remote.gid, sizeof(remote.gid));
  if (backend_->connect_to_peer(peer) != 0)
    throw std::runtime_error("connecting the QP to the peer failed");
  if (backend_->set_remote_rkey(remote.rkey) != 0)
    throw std::runtime_error("setting the remote rkey failed");
}

void Endpoint::put(uint64_t remoteAddr, const void* local, size_t bytes) {
  QueuePair* qp = backend_->get_gpu_qp();
  if (!qp)
    throw std::runtime_error("no GPU queue pair");
  check(hipSetDevice(gpu_), "hipSetDevice");
  hipLaunchKernelGGL(putKernel, dim3(1), dim3(64), 0, 0, qp,
                     reinterpret_cast<void*>(remoteAddr), local, bytes);
  check(hipGetLastError(), "launching the RDMA put kernel");
  check(hipDeviceSynchronize(), "RDMA put kernel");
}

void Endpoint::putSignal(uint64_t remoteAddr, const void* local, size_t bytes,
                         uint64_t signalAddr, int64_t value) {
  QueuePair* qp = backend_->get_gpu_qp();
  if (!qp)
    throw std::runtime_error("no GPU queue pair");
  check(hipSetDevice(gpu_), "hipSetDevice");
  hipLaunchKernelGGL(putSignalKernel, dim3(1), dim3(64), 0, 0, qp,
                     reinterpret_cast<void*>(remoteAddr), local, bytes,
                     reinterpret_cast<void*>(signalAddr), value);
  check(hipGetLastError(), "launching the RDMA put+signal kernel");
  check(hipDeviceSynchronize(), "RDMA put+signal kernel");
}

std::vector<uint64_t> Endpoint::deviceContext() {
#if defined(GDA_MLX5)
  if (backend_->get_provider() != Provider::MLX5)
    throw std::runtime_error("deviceContext() is implemented for mlx5 only");
  QueuePair* q = backend_->get_host_qp();
  if (!q)
    throw std::runtime_error("no queue pair");

  if (!state_) {
    check(hipSetDevice(gpu_), "hipSetDevice");
    check(hipMalloc(reinterpret_cast<void**>(&state_), 8 * sizeof(uint64_t)),
          "allocating the state block");
    // The QP may already carry traffic (the backend's smoke test): continue
    // from its indices.
    uint64_t init[8] = {q->mlx5_sq_.tail,
                        q->mlx5_sq_.tail,
                        q->mlx5_sq_.tail,
                        q->mlx5_cq_.cons_index,
                        0,
                        0,
                        0,
                        0};
    check(hipMemcpy(state_, init, sizeof(init), hipMemcpyHostToDevice),
          "initializing the state block");
  }

  auto word = [](const void* p) {
    return reinterpret_cast<uint64_t>(p);
  };
  std::vector<uint64_t> ctx(kDeviceCtxWords, 0);
  ctx[0] = word(q->mlx5_sq_.buf);
  ctx[1] = word(q->mlx5_sq_.dbrec);
  ctx[2] = word(q->mlx5_sq_.db);
  ctx[3] = q->mlx5_sq_.depth;
  ctx[4] = word(q->mlx5_cq_.buf);
  ctx[5] = word(q->mlx5_cq_.dbrec);
  ctx[6] = q->mlx5_cq_.depth;
  ctx[7] = q->qp_num_;
  ctx[8] = q->lkey_;
  ctx[9] = q->rkey_;
  ctx[10] = word(state_);
  ctx[11] = q->op_rdma_write_;
  ctx[12] = q->op_atomic_fa_;
  ctx[13] = word(q->nonfetching_atomic_);
  ctx[14] = q->nonfetching_atomic_lkey_;
  return ctx;
#else
  throw std::runtime_error("built without GDA_MLX5");
#endif
}

QueuePair* Endpoint::gpuQueuePair() const {
  return backend_->get_gpu_qp();
}

} // namespace rdma_ep
} // namespace xio
