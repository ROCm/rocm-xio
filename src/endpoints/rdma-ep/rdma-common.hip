/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 */

#include <cstdio>
#include <cstring>

#include <endian.h>

#include "gda-backend.hpp"
#include "ibv-wrapper.hpp"
#include "rdma-common.h"
#include "rdma-ep.h"
#include "xio-data-pattern.hpp"
#include "xio.h"

#if defined(GDA_BNXT)
namespace xio {
namespace rdma_ep {
int bnxt_dv_modify_qp(struct ibv_qp* qp, struct ibv_qp_attr* attr,
                      int attr_mask);
} // namespace rdma_ep
} // namespace xio
#endif

#if defined(GDA_ERNIC)
namespace xio {
namespace rdma_ep {
int ernic_dv_modify_qp(struct ibv_qp* qp, struct ibv_qp_attr* attr,
                       int attr_mask);
} // namespace rdma_ep
} // namespace xio
#endif

namespace xio {
namespace rdma_ep {

__host__ const char* provider_allowed_names() {
  return "bnxt, mlx5, ionic, or ernic";
}

__host__ BackendConfig make_backend_config(const XioEndpointConfig& config,
                                           const RdmaEpConfig& rdmaConfig,
                                           bool loopback) {
  bool sq_on_device = (config.memoryMode & XIO_MEM_MODE_SQ_DEVICE) != 0;

  BackendConfig backendConfig;
  backendConfig.provider = rdmaConfig.provider;
  backendConfig.gpu_device_id = rdmaConfig.gpuDeviceId;
  backendConfig.sq_depth = rdmaConfig.sqDepth;
  backendConfig.cq_depth = rdmaConfig.cqDepth;
  backendConfig.inline_threshold = rdmaConfig.inlineThreshold;
  backendConfig.pcie_relaxed_ordering = rdmaConfig.pcieRelaxedOrdering;
  backendConfig.traffic_class = rdmaConfig.trafficClass;
  backendConfig.loopback = loopback;
  backendConfig.queue_mem = sq_on_device ? QueueMemMode::DEVICE_VRAM
                                         : QueueMemMode::HOST_COHERENT;
  backendConfig.pci_mmio_bridge = config.pciMmioBridge;
  if (!rdmaConfig.deviceName.empty())
    backendConfig.hca_list = rdmaConfig.deviceName.c_str();
  return backendConfig;
}

__host__ uint32_t normalize_qp_key(Provider provider, uint32_t key) {
  return provider == Provider::MLX5 ? htobe32(key) : key;
}

__host__ void normalize_mr_keys(Provider provider, uint32_t lkey, uint32_t rkey,
                                uint32_t* normalizedLkey,
                                uint32_t* normalizedRkey) {
  if (normalizedLkey)
    *normalizedLkey = normalize_qp_key(provider, lkey);
  if (normalizedRkey)
    *normalizedRkey = normalize_qp_key(provider, rkey);
}

__host__ uint8_t rd_atomic_cap(Provider provider,
                               const struct ibv_device_attr& deviceAttr) {
  if (provider == Provider::IONIC)
    return 15;
  if (deviceAttr.max_qp_rd_atom == 0)
    return 1;
  uint32_t cap = deviceAttr.max_qp_rd_atom;
  if (cap > 255)
    cap = 255;
  return static_cast<uint8_t>(cap);
}

__host__ void fill_rc_qp_init_attr(struct ibv_qp_init_attr_ex* attr,
                                   struct ibv_pd* pd, struct ibv_cq* cq,
                                   int sqDepth, int recvWr, int recvSge,
                                   uint32_t inlineThreshold) {
  memset(attr, 0, sizeof(*attr));
  attr->send_cq = cq;
  attr->recv_cq = cq;
  attr->srq = nullptr;
  attr->cap.max_send_wr = sqDepth;
  attr->cap.max_recv_wr = recvWr;
  attr->cap.max_send_sge = 1;
  attr->cap.max_recv_sge = recvSge;
  attr->cap.max_inline_data = inlineThreshold;
  attr->qp_type = IBV_QPT_RC;
  attr->sq_sig_all = 0;
  attr->comp_mask = IBV_QP_INIT_ATTR_PD;
  attr->pd = pd;
}

__host__ int modify_qp_dispatch(Provider provider, struct ibv_qp* qp,
                                struct ibv_qp_attr* attr, int attrMask) {
#if defined(GDA_BNXT)
  if (provider == Provider::BNXT)
    return bnxt_dv_modify_qp(qp, attr, attrMask);
#endif

#if defined(GDA_ERNIC)
  if (provider == Provider::ROCM_ERNIC)
    return ernic_dv_modify_qp(qp, attr, attrMask);
#endif

  return ibv.modify_qp(qp, attr, attrMask);
}

__device__ void prepare_verify_buffer(uint8_t* src, uint8_t* dst,
                                      uint32_t transferSize, uint32_t seed) {
  xio::DataPatternParams fp{src, transferSize, 0, transferSize, seed, nullptr};
  xio::dataPattern(false, fp);
  for (uint32_t b = 0; b < transferSize; b++)
    dst[b] = 0;
  __threadfence_system();
}

__device__ void verify_buffer(uint8_t* dst, uint32_t transferSize,
                              uint32_t seed, const char* label, unsigned op,
                              uint32_t* verifyPass, uint32_t* verifyFail) {
  size_t errOff = 0;
  xio::DataPatternParams vp{dst, transferSize, 0, transferSize, seed, &errOff};
  bool ok = xio::dataPattern(true, vp);
  if (ok) {
    if (verifyPass)
      atomicAdd(verifyPass, 1u);
  } else {
    if (verifyFail)
      atomicAdd(verifyFail, 1u);
    printf("rdma-ep: %s VERIFY FAILED op=%u seed=%u offset=%zu\n", label, op,
           seed, errOff);
  }
}

} // namespace rdma_ep
} // namespace xio
