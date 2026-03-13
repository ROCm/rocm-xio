/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/backend_gda.cpp, adapted for rocm-xio.
 * Simplified from full-mesh PE topology to single-endpoint model.
 * This file handles IB device setup, QP/CQ creation, and QP state transitions
 * for a single connection (1 QP, 1 CQ pair).
 */

#include "gda-backend.hpp"
#include "queue-pair.hpp"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <unistd.h>

#include <hip/hip_runtime.h>

#include "ibv-wrapper.hpp"
#include "rdma-topology.hpp"

#if defined(GDA_BNXT)
#include "bnxt/bnxt-provider.hpp"
namespace rdma_ep {
int bnxt_dv_modify_qp(struct ibv_qp *qp, struct ibv_qp_attr *attr,
                       int attr_mask);
} // namespace rdma_ep
#endif

#if defined(GDA_ERNIC)
#include "rocm-ernic/ernic-provider.hpp"
namespace rdma_ep {
int ernic_dv_modify_qp(struct ibv_qp *qp, struct ibv_qp_attr *attr,
                        int attr_mask);
} // namespace rdma_ep
#endif

namespace rdma_ep {

#define XIO_CHECK_ZERO(expr, msg)                                              \
  do {                                                                         \
    int _err = (expr);                                                         \
    if (_err != 0) {                                                           \
      fprintf(stderr, "rdma_ep: %s failed: %d at %s:%d\n", (msg), _err,       \
              __FILE__, __LINE__);                                             \
      abort();                                                                 \
    }                                                                          \
  } while (0)

#define XIO_CHECK_NNULL(expr, msg)                                             \
  do {                                                                         \
    if (!(expr)) {                                                             \
      fprintf(stderr, "rdma_ep: %s returned null at %s:%d\n", (msg),           \
              __FILE__, __LINE__);                                             \
      abort();                                                                 \
    }                                                                          \
  } while (0)

Backend::Backend(const BackendConfig &config) : config_(config) {}

Backend::~Backend() { shutdown(); }

int Backend::init() {
  if (!ibv.is_initialized) {
    fprintf(stderr, "rdma_ep: IBV wrapper not initialized. Cannot init backend.\n");
    return -1;
  }

  open_dv_libs();
  open_ib_device();
  create_queues();

  if (config_.loopback) {
    setup_qp_loopback();
  }
  // When not loopback, QP state transitions are deferred until
  // connect_to_peer() is called after TCP exchange of connection info.

  setup_gpu_qp();
  return 0;
}

void Backend::shutdown() {
  cleanup_gpu_qp();

  if (qp_) {
    ibv.destroy_qp(qp_);
    qp_ = nullptr;
  }
  if (cq_) {
    ibv.destroy_cq(cq_);
    cq_ = nullptr;
  }
  if (heap_mr_) {
    ibv.dereg_mr(heap_mr_);
    heap_mr_ = nullptr;
  }
  if (pd_parent_) {
    ibv.dealloc_pd(pd_parent_);
    pd_parent_ = nullptr;
  }
  if (pd_) {
    ibv.dealloc_pd(pd_);
    pd_ = nullptr;
  }
  if (context_) {
    ibv.close_device(context_);
    context_ = nullptr;
  }

  close_dv_libs();
}

void Backend::open_dv_libs() {
  Provider requested = config_.provider;
  provider_ = Provider::UNKNOWN;

#if defined(GDA_BNXT)
  if (provider_ == Provider::UNKNOWN &&
      (requested == Provider::UNKNOWN || requested == Provider::BNXT)) {
    if (bnxt_dv_dl_init() == 0) {
      provider_ = Provider::BNXT;
      fprintf(stderr, "rdma_ep: BNXT DV library loaded.\n");
    } else {
      fprintf(stderr, "rdma_ep: BNXT DV library not available.\n");
    }
  }
#endif

#if defined(GDA_MLX5)
  if (provider_ == Provider::UNKNOWN &&
      (requested == Provider::UNKNOWN || requested == Provider::MLX5)) {
    // MLX5 DV init will be added in Phase 6
    fprintf(stderr, "rdma_ep: MLX5 DV support not yet implemented.\n");
  }
#endif

#if defined(GDA_IONIC)
  if (provider_ == Provider::UNKNOWN &&
      (requested == Provider::UNKNOWN || requested == Provider::IONIC)) {
    // IONIC DV init will be added in Phase 6
    fprintf(stderr, "rdma_ep: IONIC DV support not yet implemented.\n");
  }
#endif

#if defined(GDA_ERNIC)
  if (provider_ == Provider::UNKNOWN &&
      (requested == Provider::UNKNOWN ||
       requested == Provider::ROCM_ERNIC)) {
    if (ernic_dv_dl_init() == 0) {
      provider_ = Provider::ROCM_ERNIC;
      fprintf(stderr,
              "rdma_ep: ERNIC DV library "
              "loaded.\n");
    } else {
      fprintf(stderr,
              "rdma_ep: ERNIC DV library "
              "not available.\n");
    }
  }
#endif

  if (provider_ == Provider::UNKNOWN) {
    fprintf(stderr, "rdma_ep: No DV library available. "
                    "Using standard ibverbs path.\n");
    provider_ = requested;
  }
}

void Backend::close_dv_libs() {
  if (dv_handle_) {
    dlclose(dv_handle_);
    dv_handle_ = nullptr;
  }
}

void Backend::open_ib_device() {
  int num_devices = 0;
  struct ibv_device **device_list = ibv.get_device_list(&num_devices);
  XIO_CHECK_NNULL(device_list, "ibv_get_device_list");

  if (num_devices == 0) {
    fprintf(stderr, "rdma_ep: No IB devices found.\n");
    ibv.free_device_list(device_list);
    abort();
  }

  // Use topology to find closest NIC to GPU
  const char *dev_name = nullptr;
  int nic_idx = GetClosestNicToGpu(config_.gpu_device_id, config_.hca_list,
                                   &dev_name);

  if (nic_idx >= 0 && dev_name) {
    for (int i = 0; i < num_devices; i++) {
      const char *name = ibv.get_device_name(device_list[i]);
      if (name && strcmp(name, dev_name) == 0) {
        device_ = device_list[i];
        break;
      }
    }
    free(const_cast<char *>(dev_name));
  }

  if (!device_) {
    fprintf(stderr, "rdma_ep: Using first available IB device.\n");
    device_ = device_list[0];
  }

  context_ = ibv.open_device(device_);
  XIO_CHECK_NNULL(context_, "ibv_open_device");

  int err = ibv.query_device(context_, &device_attr_);
  XIO_CHECK_ZERO(err, "ibv_query_device");

  fprintf(stderr, "rdma_ep: Opened device: %s (vendor=0x%x, part=0x%x, fw=%s)\n",
          ibv.get_device_name(device_), device_attr_.vendor_id,
          device_attr_.vendor_part_id, device_attr_.fw_ver);

  pd_ = ibv.alloc_pd(context_);
  XIO_CHECK_NNULL(pd_, "ibv_alloc_pd");

  err = ibv.query_port(context_, port_, &port_attr_);
  XIO_CHECK_ZERO(err, "ibv_query_port");

  gid_index_ = SelectBestGid(context_, port_);
  if (gid_index_ < 0) {
    fprintf(stderr, "rdma_ep: Warning: could not auto-select GID index, using 0.\n");
    gid_index_ = 0;
  }

  err = ibv.query_gid(context_, port_, gid_index_, &local_gid_);
  XIO_CHECK_ZERO(err, "ibv_query_gid");

  ibv.free_device_list(device_list);
}

void Backend::create_queues() {
  int ncqes = config_.cq_depth;
  if (provider_ == Provider::IONIC)
    ncqes = config_.sq_depth * 2;

#if defined(GDA_BNXT)
  if (provider_ == Provider::BNXT) {
    bnxt_create_cqs(ncqes);
    bnxt_create_qps(config_.sq_depth);
    fprintf(stderr, "rdma_ep: Created QP num=%u via BNXT DV, SQ depth=%d\n",
            qp_ ? qp_->qp_num : 0, config_.sq_depth);
    return;
  }
#endif

#if defined(GDA_ERNIC)
  if (provider_ == Provider::ROCM_ERNIC) {
    ernic_create_cqs(ncqes);
    ernic_create_qps(config_.sq_depth);
    fprintf(stderr,
            "rdma_ep: Created QP num=%u "
            "via ERNIC DV, SQ depth=%d\n",
            qp_ ? qp_->qp_num : 0,
            config_.sq_depth);
    return;
  }
#endif

  // Standard ibverbs path for non-BNXT providers
  cq_ = ibv.create_cq(context_, ncqes, nullptr, nullptr, 0);
  XIO_CHECK_NNULL(cq_, "ibv_create_cq");

  struct ibv_qp_init_attr_ex qp_init;
  memset(&qp_init, 0, sizeof(qp_init));
  qp_init.send_cq = cq_;
  qp_init.recv_cq = cq_;
  qp_init.srq = nullptr;
  qp_init.cap.max_send_wr = config_.sq_depth;
  qp_init.cap.max_recv_wr = 0;
  qp_init.cap.max_send_sge = 1;
  qp_init.cap.max_recv_sge = 0;
  qp_init.cap.max_inline_data = config_.inline_threshold;
  qp_init.qp_type = IBV_QPT_RC;
  qp_init.sq_sig_all = 0;
  qp_init.comp_mask = IBV_QP_INIT_ATTR_PD;
  qp_init.pd = pd_;

  qp_ = ibv.create_qp_ex(context_, &qp_init);
  XIO_CHECK_NNULL(qp_, "ibv_create_qp_ex");

  fprintf(stderr, "rdma_ep: Created QP num=%u, SQ depth=%d, CQ depth=%d\n",
          qp_->qp_num, config_.sq_depth, ncqes);
}

void Backend::setup_qp_loopback() {
  DestInfo loopback;
  loopback.lid = port_attr_.lid;
  loopback.qpn = qp_->qp_num;
  loopback.psn = 0;
  loopback.gid = local_gid_;

  modify_qp_reset_to_init();
  modify_qp_init_to_rtr(loopback);
  modify_qp_rtr_to_rts();

  fprintf(stderr, "rdma_ep: QP connected in loopback mode (QPN=%u)\n",
          qp_->qp_num);
}

void Backend::modify_qp_reset_to_init() {
  struct ibv_qp_attr attr;
  memset(&attr, 0, sizeof(attr));

  attr.qp_state = IBV_QPS_INIT;
  attr.pkey_index = 0;
  attr.port_num = port_;
  attr.qp_access_flags = IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_LOCAL_WRITE |
                         IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_ATOMIC;

  int attr_mask = IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT |
                  IBV_QP_ACCESS_FLAGS;

  int err;
#if defined(GDA_BNXT)
  if (provider_ == Provider::BNXT)
    err = bnxt_dv_modify_qp(qp_, &attr, attr_mask);
  else
#endif
#if defined(GDA_ERNIC)
  if (provider_ == Provider::ROCM_ERNIC)
    err = ernic_dv_modify_qp(qp_, &attr, attr_mask);
  else
#endif
    err = ibv.modify_qp(qp_, &attr, attr_mask);
  XIO_CHECK_ZERO(err, "modify_qp (RESET->INIT)");
}

void Backend::modify_qp_init_to_rtr(const DestInfo &remote) {
  struct ibv_qp_attr attr;
  memset(&attr, 0, sizeof(attr));

  attr.qp_state = IBV_QPS_RTR;
  attr.path_mtu = port_attr_.active_mtu;
  attr.min_rnr_timer = 12;
  attr.ah_attr.port_num = port_;
  attr.rq_psn = remote.psn;
  attr.dest_qp_num = remote.qpn;

  if (provider_ == Provider::IONIC) {
    attr.max_dest_rd_atomic = 15;
  } else {
    attr.max_dest_rd_atomic = 1;
  }

  if (port_attr_.link_layer == IBV_LINK_LAYER_ETHERNET) {
    attr.ah_attr.grh.sgid_index = gid_index_;
    attr.ah_attr.is_global = 1;
    attr.ah_attr.grh.hop_limit = 1;
    attr.ah_attr.sl = 1;
    attr.ah_attr.grh.traffic_class = config_.traffic_class;
    memcpy(&attr.ah_attr.grh.dgid, &remote.gid, 16);
  } else {
    attr.ah_attr.dlid = remote.lid;
  }

  int attr_mask = IBV_QP_STATE | IBV_QP_PATH_MTU | IBV_QP_RQ_PSN |
                  IBV_QP_DEST_QPN | IBV_QP_AV | IBV_QP_MAX_DEST_RD_ATOMIC |
                  IBV_QP_MIN_RNR_TIMER;

  int err;
#if defined(GDA_BNXT)
  if (provider_ == Provider::BNXT)
    err = bnxt_dv_modify_qp(qp_, &attr, attr_mask);
  else
#endif
#if defined(GDA_ERNIC)
  if (provider_ == Provider::ROCM_ERNIC)
    err = ernic_dv_modify_qp(qp_, &attr, attr_mask);
  else
#endif
    err = ibv.modify_qp(qp_, &attr, attr_mask);
  XIO_CHECK_ZERO(err, "modify_qp (INIT->RTR)");
}

void Backend::modify_qp_rtr_to_rts() {
  struct ibv_qp_attr attr;
  memset(&attr, 0, sizeof(attr));

  attr.qp_state = IBV_QPS_RTS;
  attr.sq_psn = 0;
  attr.timeout = 14;
  attr.retry_cnt = 7;
  attr.rnr_retry = 7;

  if (provider_ == Provider::IONIC) {
    attr.max_rd_atomic = 15;
  } else {
    attr.max_rd_atomic = 1;
  }

  int attr_mask = IBV_QP_STATE | IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC |
                  IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY;

  int err;
#if defined(GDA_BNXT)
  if (provider_ == Provider::BNXT)
    err = bnxt_dv_modify_qp(qp_, &attr, attr_mask);
  else
#endif
#if defined(GDA_ERNIC)
  if (provider_ == Provider::ROCM_ERNIC)
    err = ernic_dv_modify_qp(qp_, &attr, attr_mask);
  else
#endif
    err = ibv.modify_qp(qp_, &attr, attr_mask);
  XIO_CHECK_ZERO(err, "modify_qp (RTR->RTS)");
}

int Backend::ibv_mtu_to_int(enum ibv_mtu mtu) {
  switch (mtu) {
  case IBV_MTU_256:
    return 256;
  case IBV_MTU_512:
    return 512;
  case IBV_MTU_1024:
    return 1024;
  case IBV_MTU_2048:
    return 2048;
  case IBV_MTU_4096:
    return 4096;
  default:
    return -1;
  }
}

void *Backend::pd_alloc_device_uncached(struct ibv_pd *pd, void *pd_context,
                                        size_t size, size_t alignment,
                                        uint64_t resource_type) {
  (void)pd;
  (void)pd_context;
  (void)alignment;
  (void)resource_type;
  void *dev_ptr = nullptr;
  hipError_t err = hipExtMallocWithFlags(&dev_ptr, size, hipDeviceMallocUncached);
  if (err != hipSuccess) {
    fprintf(stderr, "rdma_ep: hipExtMallocWithFlags failed: %s\n",
            hipGetErrorString(err));
    return nullptr;
  }
  memset(dev_ptr, 0, size);
  return dev_ptr;
}

void Backend::pd_release(struct ibv_pd *pd, void *pd_context, void *ptr,
                         uint64_t resource_type) {
  (void)pd;
  (void)pd_context;
  (void)resource_type;
  (void)hipFree(ptr);
}

void Backend::create_parent_domain() {
  struct ibv_parent_domain_init_attr pattr;
  memset(&pattr, 0, sizeof(pattr));
  pattr.pd = pd_;
  pattr.td = nullptr;
  pattr.comp_mask = IBV_PARENT_DOMAIN_INIT_ATTR_ALLOCATORS;
  pattr.free = Backend::pd_release;
  pattr.pd_context = nullptr;

  if (provider_ == Provider::IONIC) {
    pattr.alloc = Backend::pd_alloc_device_uncached;
  } else {
    // MLX5 uses host allocation
    pattr.alloc = [](ibv_pd *, void *, size_t size, size_t, uint64_t) -> void * {
      void *ptr = nullptr;
      hipError_t err = hipHostMalloc(&ptr, size, hipHostMallocDefault);
      if (err != hipSuccess)
        return nullptr;
      memset(ptr, 0, size);
      return ptr;
    };
  }

  pd_parent_ = ibv.alloc_parent_domain(context_, &pattr);
  XIO_CHECK_NNULL(pd_parent_, "ibv_alloc_parent_domain");
}

void Backend::setup_gpu_qp() {
  size_t qp_size = sizeof(QueuePair);

  host_qp_ = static_cast<QueuePair *>(malloc(qp_size));
  if (!host_qp_) {
    fprintf(stderr, "rdma_ep: malloc failed for host QueuePair\n");
    return;
  }

  new (host_qp_) QueuePair(pd_, provider_);

  hipError_t err = hipMalloc(&gpu_qp_, qp_size);
  if (err != hipSuccess) {
    fprintf(stderr, "rdma_ep: hipMalloc failed for GPU QueuePair: %s\n",
            hipGetErrorString(err));
    free(host_qp_);
    host_qp_ = nullptr;
    return;
  }

  initialize_gpu_qp();

  err = hipMemcpy(gpu_qp_, host_qp_, qp_size, hipMemcpyDefault);
  if (err != hipSuccess) {
    fprintf(stderr, "rdma_ep: hipMemcpy failed for GPU QueuePair: %s\n",
            hipGetErrorString(err));
    (void)hipFree(gpu_qp_);
    gpu_qp_ = nullptr;
  }

  fprintf(stderr, "rdma_ep: GPU QueuePair initialized (provider=%s)\n",
          provider_name(provider_));
}

int Backend::connect_to_peer(const DestInfo &remote) {
  if (!qp_) {
    fprintf(stderr, "rdma_ep: connect_to_peer: no QP\n");
    return -1;
  }

  modify_qp_reset_to_init();
  modify_qp_init_to_rtr(remote);
  modify_qp_rtr_to_rts();

  fprintf(stderr, "rdma_ep: Connected to peer (QPN=%u, GID=%02x%02x:...:%02x%02x)\n",
          remote.qpn,
          remote.gid.raw[0], remote.gid.raw[1],
          remote.gid.raw[14], remote.gid.raw[15]);
  return 0;
}

DestInfo Backend::get_local_dest_info() const {
  DestInfo info{};
  info.lid = port_attr_.lid;
  info.qpn = qp_ ? qp_->qp_num : 0;
  info.psn = 0;
  info.gid = local_gid_;
  return info;
}

int Backend::set_remote_rkey(uint32_t remote_rkey) {
  if (!host_qp_ || !gpu_qp_) return -1;
  host_qp_->rkey_ = remote_rkey;
  hipError_t err = hipMemcpy(gpu_qp_, host_qp_, sizeof(QueuePair), hipMemcpyDefault);
  if (err != hipSuccess) {
    fprintf(stderr, "rdma_ep: set_remote_rkey hipMemcpy failed\n");
    return -1;
  }
  fprintf(stderr, "rdma_ep: Remote rkey set to 0x%x\n", remote_rkey);
  return 0;
}

int Backend::register_data_buffer(void *buf, size_t size) {
  if (!buf || size == 0 || !host_qp_ || !gpu_qp_) {
    fprintf(stderr, "rdma_ep: register_data_buffer: invalid args\n");
    return -1;
  }

  int access = IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE |
               IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_ATOMIC;
  if (config_.pcie_relaxed_ordering)
    access |= IBV_ACCESS_RELAXED_ORDERING;

  if (heap_mr_) {
    ibv.dereg_mr(heap_mr_);
    heap_mr_ = nullptr;
  }

  heap_mr_ = ibv.reg_mr_host(pd_, buf, size, access);
  if (!heap_mr_) {
    fprintf(stderr, "rdma_ep: ibv_reg_mr failed for data buffer\n");
    return -1;
  }

  host_qp_->lkey_ = heap_mr_->lkey;
  host_qp_->rkey_ = heap_mr_->rkey;
  rkey_ = heap_mr_->rkey;
  lkey_ = heap_mr_->lkey;

  hipError_t err = hipMemcpy(gpu_qp_, host_qp_, sizeof(QueuePair),
                             hipMemcpyDefault);
  if (err != hipSuccess) {
    fprintf(stderr, "rdma_ep: hipMemcpy failed to re-sync GPU QP: %s\n",
            hipGetErrorString(err));
    return -1;
  }

  fprintf(stderr, "rdma_ep: Registered data buffer: addr=%p, size=%zu, "
                  "lkey=0x%x, rkey=0x%x\n",
          buf, size, heap_mr_->lkey, heap_mr_->rkey);
  return 0;
}

void Backend::cleanup_gpu_qp() {
  if (host_qp_) {
    free(host_qp_);
    host_qp_ = nullptr;
  }
  if (gpu_qp_) {
    (void)hipFree(gpu_qp_);
    gpu_qp_ = nullptr;
  }
}

void Backend::initialize_gpu_qp() {
  if (!host_qp_)
    return;

#if defined(GDA_BNXT)
  if (provider_ == Provider::BNXT) {
    bnxt_initialize_gpu_qp();
    return;
  }
#endif

#if defined(GDA_ERNIC)
  if (provider_ == Provider::ROCM_ERNIC) {
    ernic_initialize_gpu_qp();
    return;
  }
#endif
}

#undef XIO_CHECK_ZERO
#undef XIO_CHECK_NNULL

} // namespace rdma_ep
