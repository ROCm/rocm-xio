/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * MLX5 queues in GPU device memory, created through DevX.
 *
 * ibv_create_qp cannot place a QP's buffers in device memory, so with
 * QueueMemMode::DEVICE_VRAM the QP and CQ are created from one registered slab
 * of GPU memory (the same flow rocm-xio's bnxt backend uses with its DV calls):
 *
 *   1. one slab (send queue, completion queue, doorbell records) from HIP's
 * virtual memory API: uncached, device read/write, plus host read/write so the
 * CPU can reach it through the large BAR;
 *   2. mlx5dv_devx_umem_reg_ex(dmabuf) of the slab;
 *   3. CQ and QP objects created with raw device commands
 * (mlx5dv_devx_obj_create) that name the umem, then moved RESET->INIT->RTR->RTS
 * with raw modify commands;
 *   4. a dedicated non-cached UAR for the doorbell, reachable from the GPU.
 *
 * Command layouts: mlx5-devx-prm.h.
 */

#include "gda-backend.hpp"

#if defined(GDA_MLX5)

#include <cerrno>
#include <cstdio>
#include <cstring>

#include <hip/hip_runtime.h>
#include <hip/hip_version.h>

#include <dlfcn.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <unistd.h>

extern "C" {
#include <infiniband/mlx5dv.h>
}

#include "ibv-wrapper.hpp"
#include "mlx5-devx-prm.h"
#include "mlx5-provider.hpp"
#include "queue-pair.hpp"
#include "rdma-common.h"

namespace xio {
namespace rdma_ep {

namespace {

constexpr size_t kPage = 4096;
constexpr size_t kWqebb = 64;
constexpr size_t kCqe = 64;
// Doorbell records: the QP's (rcv, snd) pair and the CQ's (ci, arm) pair, 128
// bytes apart
constexpr size_t kQpDbrecOff = 0;
constexpr size_t kCqDbrecOff = 128;

struct DevxFns {
  struct mlx5dv_devx_umem* (*umem_reg_ex)(struct ibv_context*,
                                          struct mlx5dv_devx_umem_in*);
  int (*umem_dereg)(struct mlx5dv_devx_umem*);
  struct mlx5dv_devx_obj* (*obj_create)(struct ibv_context*, const void*,
                                        size_t, void*, size_t);
  int (*obj_modify)(struct mlx5dv_devx_obj*, const void*, size_t, void*,
                    size_t);
  int (*obj_destroy)(struct mlx5dv_devx_obj*);
  struct mlx5dv_devx_uar* (*alloc_uar)(struct ibv_context*, uint32_t);
  void (*free_uar)(struct mlx5dv_devx_uar*);
  int (*query_eqn)(struct ibv_context*, uint32_t, uint32_t*);
  int (*init_obj)(struct mlx5dv_obj*, uint64_t);
};

template <typename F>
bool load(F& fn, void* handle, const char* name) {
  fn = reinterpret_cast<F>(dlsym(handle, name));
  if (!fn)
    fprintf(stderr, "rdma_ep::mlx5: devx: libmlx5 lacks %s\n", name);
  return fn != nullptr;
}

size_t align_up(size_t v, size_t a) {
  return (v + a - 1) / a * a;
}

uint32_t log2_ceil(size_t v) {
  uint32_t l = 0;
  while ((size_t(1) << l) < v)
    l++;
  return l;
}

} // namespace

/** Everything the DevX path owns. Lives for the Backend's lifetime. */
struct Mlx5DevxState {
  DevxFns fn{};

  // The slab
  void* slab = nullptr;
  size_t slab_size = 0;
  hipMemGenericAllocationHandle_t handle{};
  bool mapped = false;
  bool host_access = false;
  struct mlx5dv_devx_umem* umem = nullptr;

  // Layout inside the slab
  size_t sq_off = 0, cq_off = 0, dbr_off = 0;
  uint32_t sq_wqe_cnt = 0, cq_cqe_cnt = 0;

  struct mlx5dv_devx_uar* uar = nullptr;
  void* gpu_doorbell = nullptr; // GPU-visible alias of the UAR doorbell pair
  void* locked_uar_ptr = nullptr;

  struct mlx5dv_devx_obj* cq_obj = nullptr;
  struct mlx5dv_devx_obj* qp_obj = nullptr;
  uint32_t pdn = 0, eqn = 0, cqn = 0, qpn = 0;
};

namespace {

hipError_t alloc_slab(Mlx5DevxState& s, size_t size, int device) {
#if HIP_VERSION >= 70000000
  hipMemAllocationProp prop = {};
  prop.type = hipMemAllocationTypeUncached;
  prop.location.type = hipMemLocationTypeDevice;
  prop.location.id = device;
  prop.requestedHandleTypes = hipMemHandleTypePosixFileDescriptor;

  size_t gran = 0;
  hipError_t err = hipMemGetAllocationGranularity(
    &gran, &prop, hipMemAllocationGranularityMinimum);
  if (err != hipSuccess)
    return err;
  s.slab_size = align_up(size, gran);

  err = hipMemCreate(&s.handle, s.slab_size, &prop, 0);
  if (err != hipSuccess)
    return err;
  err = hipMemAddressReserve(&s.slab, s.slab_size, 0, 0, 0);
  if (err != hipSuccess)
    return err;
  err = hipMemMap(s.slab, s.slab_size, 0, s.handle, 0);
  if (err != hipSuccess)
    return err;
  s.mapped = true;

  hipMemAccessDesc access[2] = {};
  access[0].location.type = hipMemLocationTypeDevice;
  access[0].location.id = device;
  access[0].flags = hipMemAccessFlagsProtReadWrite;
  access[1].location.type = hipMemLocationTypeHost;
  access[1].location.id = 0;
  access[1].flags = hipMemAccessFlagsProtReadWrite;
  err = hipMemSetAccess(s.slab, s.slab_size, access, 2);
  if (err == hipSuccess) {
    s.host_access = true;
  } else {
    // No CPU mapping (no large BAR?): the GPU can still use the queues
    fprintf(stderr,
            "rdma_ep::mlx5: devx: host access to the queue slab failed (%s); "
            "device access only\n",
            hipGetErrorString(err));
    err = hipMemSetAccess(s.slab, s.slab_size, access, 1);
  }
  return err;
#else
  (void)s;
  (void)size;
  (void)device;
  return hipErrorNotSupported;
#endif
}

void free_slab(Mlx5DevxState& s) {
#if HIP_VERSION >= 70000000
  if (s.mapped)
    (void)hipMemUnmap(s.slab, s.slab_size);
  if (s.slab)
    (void)hipMemAddressFree(s.slab, s.slab_size);
  if (s.handle)
    (void)hipMemRelease(s.handle);
#endif
  s.slab = nullptr;
  s.mapped = false;
  s.handle = {};
}

} // namespace

int Backend::mlx5_devx_create_queues() {
  auto* s = new Mlx5DevxState();
  devx_ = s;

  if (!mlx5dv_handle_) {
    fprintf(stderr, "rdma_ep::mlx5: devx: libmlx5 not loaded\n");
    return -1;
  }
  bool ok = load(s->fn.umem_reg_ex, mlx5dv_handle_,
                 "mlx5dv_devx_umem_reg_ex") &&
            load(s->fn.umem_dereg, mlx5dv_handle_, "mlx5dv_devx_umem_dereg") &&
            load(s->fn.obj_create, mlx5dv_handle_, "mlx5dv_devx_obj_create") &&
            load(s->fn.obj_modify, mlx5dv_handle_, "mlx5dv_devx_obj_modify") &&
            load(s->fn.obj_destroy, mlx5dv_handle_,
                 "mlx5dv_devx_obj_destroy") &&
            load(s->fn.alloc_uar, mlx5dv_handle_, "mlx5dv_devx_alloc_uar") &&
            load(s->fn.free_uar, mlx5dv_handle_, "mlx5dv_devx_free_uar") &&
            load(s->fn.query_eqn, mlx5dv_handle_, "mlx5dv_devx_query_eqn") &&
            load(s->fn.init_obj, mlx5dv_handle_, "mlx5dv_init_obj");
  if (!ok)
    return -1;

  // --- sizes and layout
  s->sq_wqe_cnt = 1u << log2_ceil(size_t(config_.sq_depth) * 4);
  s->cq_cqe_cnt = 1u << log2_ceil(size_t(config_.cq_depth) + 1);
  size_t sq_bytes = size_t(s->sq_wqe_cnt) * kWqebb;
  size_t cq_bytes = size_t(s->cq_cqe_cnt) * kCqe;
  s->sq_off = 0;
  s->cq_off = align_up(sq_bytes, kPage);
  s->dbr_off = align_up(s->cq_off + cq_bytes, kPage);
  size_t total = s->dbr_off + kPage;

  hipError_t herr = hipSetDevice(config_.gpu_device_id);
  if (herr == hipSuccess)
    herr = alloc_slab(*s, total, config_.gpu_device_id);
  if (herr != hipSuccess) {
    fprintf(stderr, "rdma_ep::mlx5: devx: queue slab allocation failed: %s\n",
            hipGetErrorString(herr));
    return -1;
  }
  (void)hipMemset(s->slab, 0, s->slab_size);
  // CQEs start invalid and hardware-owned
  (void)hipMemset(static_cast<char*>(s->slab) + s->cq_off, 0xFF, cq_bytes);
  (void)hipDeviceSynchronize();

  // --- register the slab with the NIC (dmabuf)
  int fd = -1;
  herr = hipMemExportToShareableHandle(&fd, s->handle,
                                       hipMemHandleTypePosixFileDescriptor, 0);
  if (herr != hipSuccess || fd < 0) {
    fprintf(stderr, "rdma_ep::mlx5: devx: dmabuf export failed: %s\n",
            hipGetErrorString(herr));
    return -1;
  }
  struct mlx5dv_devx_umem_in uin {};
  uin.addr = nullptr; // offset into the dmabuf
  uin.size = s->slab_size;
  uin.access = IBV_ACCESS_LOCAL_WRITE;
  uin.pgsz_bitmap = ~(uint64_t(kPage) - 1);
  uin.comp_mask = MLX5DV_UMEM_MASK_DMABUF;
  uin.dmabuf_fd = fd;
  errno = 0;
  s->umem = s->fn.umem_reg_ex(context_, &uin);
  int umem_errno = errno;
  close(fd); // the umem keeps its own reference
  if (!s->umem) {
    fprintf(stderr,
            "rdma_ep::mlx5: devx: mlx5dv_devx_umem_reg_ex failed (%s)\n",
            strerror(umem_errno));
    return -1;
  }

  // --- protection domain number, event queue number, doorbell page
  struct mlx5dv_pd dv_pd {};
  struct mlx5dv_obj obj {};
  obj.pd.in = pd_;
  obj.pd.out = &dv_pd;
  if (s->fn.init_obj(&obj, MLX5DV_OBJ_PD) != 0) {
    fprintf(stderr, "rdma_ep::mlx5: devx: mlx5dv_init_obj(PD) failed\n");
    return -1;
  }
  s->pdn = dv_pd.pdn;
  if (s->fn.query_eqn(context_, 0, &s->eqn) != 0) {
    fprintf(stderr, "rdma_ep::mlx5: devx: mlx5dv_devx_query_eqn failed\n");
    return -1;
  }
  errno = 0;
  s->uar = s->fn.alloc_uar(context_, MLX5DV_UAR_ALLOC_TYPE_NC_DEDICATED);
  if (!s->uar && errno == EOPNOTSUPP) {
    fprintf(stderr, "rdma_ep::mlx5: devx: no dedicated NC UAR, using BF\n");
    s->uar = s->fn.alloc_uar(context_, MLX5DV_UAR_ALLOC_TYPE_BF);
  }
  if (!s->uar) {
    fprintf(stderr, "rdma_ep::mlx5: devx: mlx5dv_devx_alloc_uar failed (%s)\n",
            strerror(errno));
    return -1;
  }

  // --- CQ
  {
    constexpr size_t in_sz = DEVX_ST_SZ_BYTES(create_cq_in);
    constexpr size_t out_sz = DEVX_ST_SZ_BYTES(create_cq_out);
    uint8_t in[in_sz] = {};
    uint8_t out[out_sz] = {};
    DEVX_SET(create_cq_in, in, opcode, XIO_MLX5_CMD_OP_CREATE_CQ);
    uint8_t* cqc = DEVX_ADDR_OF(create_cq_in, in, cq_context);
    DEVX_SET(cqc, cqc, cqe_sz, 0); // 64-byte CQEs
    DEVX_SET(cqc, cqc, log_cq_size, log2_ceil(s->cq_cqe_cnt));
    DEVX_SET(cqc, cqc, uar_page, s->uar->page_id);
    DEVX_SET(cqc, cqc, c_eqn_or_apu_element, s->eqn);
    DEVX_SET(cqc, cqc, log_page_size, 0);
    DEVX_SET(cqc, cqc, dbr_umem_valid, 1);
    DEVX_SET(cqc, cqc, dbr_umem_id, s->umem->umem_id);
    DEVX_SET64(cqc, cqc, dbr_addr, s->dbr_off + kCqDbrecOff);
    DEVX_SET64(create_cq_in, in, cq_umem_offset, s->cq_off);
    DEVX_SET(create_cq_in, in, cq_umem_id, s->umem->umem_id);
    DEVX_SET(create_cq_in, in, cq_umem_valid, 1);
    s->cq_obj = s->fn.obj_create(context_, in, sizeof(in), out, sizeof(out));
    if (!s->cq_obj) {
      fprintf(stderr,
              "rdma_ep::mlx5: devx: create CQ failed (%s, status=0x%x "
              "syndrome=0x%x)\n",
              strerror(errno), DEVX_GET(create_cq_out, out, status),
              DEVX_GET(create_cq_out, out, syndrome));
      return -1;
    }
    s->cqn = DEVX_GET(create_cq_out, out, cqn);
  }

  // --- QP (zero-length receive queue; the send queue is the whole work queue)
  {
    constexpr size_t in_sz = DEVX_ST_SZ_BYTES(create_qp_in);
    constexpr size_t out_sz = DEVX_ST_SZ_BYTES(create_qp_out);
    uint8_t in[in_sz] = {};
    uint8_t out[out_sz] = {};
    DEVX_SET(create_qp_in, in, opcode, XIO_MLX5_CMD_OP_CREATE_QP);
    uint8_t* qpc = DEVX_ADDR_OF(create_qp_in, in, qpc);
    DEVX_SET(qpc, qpc, st, XIO_MLX5_QPC_ST_RC);
    DEVX_SET(qpc, qpc, pm_state, XIO_MLX5_QPC_PM_STATE_MIGRATED);
    DEVX_SET(qpc, qpc, pd, s->pdn);
    DEVX_SET(qpc, qpc, uar_page, s->uar->page_id);
    DEVX_SET(qpc, qpc, cqn_snd, s->cqn);
    DEVX_SET(qpc, qpc, cqn_rcv, s->cqn);
    DEVX_SET(qpc, qpc, log_sq_size, log2_ceil(s->sq_wqe_cnt));
    DEVX_SET(qpc, qpc, log_rq_size, 0);
    DEVX_SET(qpc, qpc, rq_type, XIO_MLX5_QPC_RQ_TYPE_ZERO_LEN_RQ);
    DEVX_SET(qpc, qpc, log_msg_max, 30);
    DEVX_SET(qpc, qpc, log_page_size, 0);
    DEVX_SET(qpc, qpc, dbr_umem_valid, 1);
    DEVX_SET(qpc, qpc, dbr_umem_id, s->umem->umem_id);
    DEVX_SET64(qpc, qpc, dbr_addr, s->dbr_off + kQpDbrecOff);
    DEVX_SET64(create_qp_in, in, wq_umem_offset, s->sq_off);
    DEVX_SET(create_qp_in, in, wq_umem_id, s->umem->umem_id);
    DEVX_SET(create_qp_in, in, wq_umem_valid, 1);
    s->qp_obj = s->fn.obj_create(context_, in, sizeof(in), out, sizeof(out));
    if (!s->qp_obj) {
      fprintf(stderr,
              "rdma_ep::mlx5: devx: create QP failed (%s, status=0x%x "
              "syndrome=0x%x)\n",
              strerror(errno), DEVX_GET(create_qp_out, out, status),
              DEVX_GET(create_qp_out, out, syndrome));
      return -1;
    }
    s->qpn = DEVX_GET(create_qp_out, out, qpn);
  }

  // RESET -> INIT now; the rest needs the peer
  {
    constexpr size_t in_sz = DEVX_ST_SZ_BYTES(rst2init_qp_in);
    constexpr size_t out_sz = DEVX_ST_SZ_BYTES(rst2init_qp_out);
    uint8_t in[in_sz] = {};
    uint8_t out[out_sz] = {};
    DEVX_SET(rst2init_qp_in, in, opcode, XIO_MLX5_CMD_OP_RST2INIT_QP);
    DEVX_SET(rst2init_qp_in, in, qpn, s->qpn);
    uint8_t* qpc = DEVX_ADDR_OF(rst2init_qp_in, in, qpc);
    DEVX_SET(qpc, qpc, pm_state, XIO_MLX5_QPC_PM_STATE_MIGRATED);
    DEVX_SET(qpc, qpc, primary_address_path.vhca_port_num, port_);
    DEVX_SET(qpc, qpc, primary_address_path.pkey_index, 0);
    DEVX_SET(qpc, qpc, atomic_mode, XIO_MLX5_QPC_ATOMIC_MODE_UP_TO_8B);
    DEVX_SET(qpc, qpc, rre, 1);
    DEVX_SET(qpc, qpc, rwe, 1);
    DEVX_SET(qpc, qpc, rae, 1);
    if (s->fn.obj_modify(s->qp_obj, in, sizeof(in), out, sizeof(out)) != 0) {
      fprintf(stderr,
              "rdma_ep::mlx5: devx: RST2INIT failed (%s, status=0x%x "
              "syndrome=0x%x)\n",
              strerror(errno), DEVX_GET(rst2init_qp_out, out, status),
              DEVX_GET(rst2init_qp_out, out, syndrome));
      return -1;
    }
  }

  fprintf(stderr,
          "rdma_ep::mlx5: devx: QP num=%u CQ num=%u in GPU memory "
          "(slab %p, %zu bytes, host access %s), SQ %u WQEBBs, CQ %u CQEs\n",
          s->qpn, s->cqn, s->slab, s->slab_size, s->host_access ? "yes" : "no",
          s->sq_wqe_cnt, s->cq_cqe_cnt);
  return 0;
}

uint32_t Backend::mlx5_devx_qpn() const {
  return devx_ ? devx_->qpn : 0;
}

int Backend::mlx5_devx_connect(const DestInfo& remote) {
  Mlx5DevxState* s = devx_;
  if (!s || !s->qp_obj)
    return -1;

  // INIT -> RTR
  {
    constexpr size_t in_sz = DEVX_ST_SZ_BYTES(init2rtr_qp_in);
    constexpr size_t out_sz = DEVX_ST_SZ_BYTES(init2rtr_qp_out);
    uint8_t in[in_sz] = {};
    uint8_t out[out_sz] = {};
    DEVX_SET(init2rtr_qp_in, in, opcode, XIO_MLX5_CMD_OP_INIT2RTR_QP);
    DEVX_SET(init2rtr_qp_in, in, qpn, s->qpn);
    uint8_t* qpc = DEVX_ADDR_OF(init2rtr_qp_in, in, qpc);
    DEVX_SET(qpc, qpc, mtu, static_cast<uint32_t>(port_attr_.active_mtu));
    DEVX_SET(qpc, qpc, log_msg_max, 30);
    DEVX_SET(qpc, qpc, remote_qpn, remote.qpn);
    DEVX_SET(qpc, qpc, next_rcv_psn, remote.psn);
    DEVX_SET(qpc, qpc, log_rra_max,
             log2_ceil(rd_atomic_cap(provider_, device_attr_)));
    DEVX_SET(qpc, qpc, min_rnr_nak, 12);
    DEVX_SET(qpc, qpc, primary_address_path.vhca_port_num, port_);
    DEVX_SET(qpc, qpc, primary_address_path.pkey_index, 0);
    // Same addressing the verbs path uses: GRH with the peer's GID, plus the
    // LID on InfiniBand
    DEVX_SET(qpc, qpc, primary_address_path.grh, 1);
    DEVX_SET(qpc, qpc, primary_address_path.src_addr_index, gid_index_);
    DEVX_SET(qpc, qpc, primary_address_path.hop_limit, 1);
    DEVX_SET(qpc, qpc, primary_address_path.tclass, config_.traffic_class);
    uint8_t* gid = DEVX_ADDR_OF(qpc, qpc, primary_address_path.rgid_rip);
    memcpy(gid, remote.gid.raw, 16);
    if (port_attr_.link_layer == IBV_LINK_LAYER_ETHERNET) {
      // RoCE also needs the peer's MAC and a UDP source port: not wired up here
      fprintf(stderr,
              "rdma_ep::mlx5: devx: RoCE addressing is not implemented; use an "
              "InfiniBand port\n");
      return -1;
    }
    DEVX_SET(qpc, qpc, primary_address_path.rlid, remote.lid);
    DEVX_SET(qpc, qpc, primary_address_path.sl, 0);
    if (s->fn.obj_modify(s->qp_obj, in, sizeof(in), out, sizeof(out)) != 0) {
      fprintf(stderr,
              "rdma_ep::mlx5: devx: INIT2RTR failed (%s, status=0x%x "
              "syndrome=0x%x)\n",
              strerror(errno), DEVX_GET(init2rtr_qp_out, out, status),
              DEVX_GET(init2rtr_qp_out, out, syndrome));
      return -1;
    }
  }

  // RTR -> RTS
  {
    constexpr size_t in_sz = DEVX_ST_SZ_BYTES(rtr2rts_qp_in);
    constexpr size_t out_sz = DEVX_ST_SZ_BYTES(rtr2rts_qp_out);
    uint8_t in[in_sz] = {};
    uint8_t out[out_sz] = {};
    DEVX_SET(rtr2rts_qp_in, in, opcode, XIO_MLX5_CMD_OP_RTR2RTS_QP);
    DEVX_SET(rtr2rts_qp_in, in, qpn, s->qpn);
    uint8_t* qpc = DEVX_ADDR_OF(rtr2rts_qp_in, in, qpc);
    DEVX_SET(qpc, qpc, next_send_psn, 0);
    DEVX_SET(qpc, qpc, log_sra_max,
             log2_ceil(rd_atomic_cap(provider_, device_attr_)));
    DEVX_SET(qpc, qpc, retry_count, 7);
    DEVX_SET(qpc, qpc, rnr_retry, 7);
    DEVX_SET(qpc, qpc, primary_address_path.ack_timeout, 14);
    if (s->fn.obj_modify(s->qp_obj, in, sizeof(in), out, sizeof(out)) != 0) {
      fprintf(stderr,
              "rdma_ep::mlx5: devx: RTR2RTS failed (%s, status=0x%x "
              "syndrome=0x%x)\n",
              strerror(errno), DEVX_GET(rtr2rts_qp_out, out, status),
              DEVX_GET(rtr2rts_qp_out, out, syndrome));
      return -1;
    }
  }
  return 0;
}

void Backend::mlx5_devx_initialize_gpu_qp() {
  Mlx5DevxState* s = devx_;
  if (!host_qp_ || !s || !s->qp_obj)
    return;

  // GPU-visible alias of the doorbell pair, as the verbs path does for its
  // BlueFlame registers
  hsa_agent_t gpu_agent{};
  hsa_amd_memory_pool_t cpu_pool{};
  hsa_iterate_agents(
    [](hsa_agent_t agent, void* data) -> hsa_status_t {
      hsa_device_type_t dt;
      if (hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &dt) ==
            HSA_STATUS_SUCCESS &&
          dt == HSA_DEVICE_TYPE_GPU) {
        *static_cast<hsa_agent_t*>(data) = agent;
        return HSA_STATUS_INFO_BREAK;
      }
      return HSA_STATUS_SUCCESS;
    },
    &gpu_agent);
  hsa_iterate_agents(
    [](hsa_agent_t agent, void* data) -> hsa_status_t {
      hsa_device_type_t dt;
      if (hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &dt) ==
            HSA_STATUS_SUCCESS &&
          dt == HSA_DEVICE_TYPE_CPU) {
        hsa_amd_agent_iterate_memory_pools(
          agent,
          [](hsa_amd_memory_pool_t pool, void* d) -> hsa_status_t {
            hsa_amd_segment_t seg;
            hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_SEGMENT,
                                         &seg);
            if (seg == HSA_AMD_SEGMENT_GLOBAL)
              *static_cast<hsa_amd_memory_pool_t*>(d) = pool;
            return HSA_STATUS_SUCCESS;
          },
          data);
        return HSA_STATUS_INFO_BREAK;
      }
      return HSA_STATUS_SUCCESS;
    },
    &cpu_pool);

  void* gpu_bf = nullptr;
  hsa_status_t st = hsa_amd_memory_lock_to_pool(s->uar->reg_addr, 2 * 256,
                                                &gpu_agent, 1, cpu_pool, 0,
                                                &gpu_bf);
  if (st != HSA_STATUS_SUCCESS) {
    fprintf(stderr, "rdma_ep::mlx5: devx: locking the doorbell failed: %d\n",
            st);
    return;
  }
  s->locked_uar_ptr = s->uar->reg_addr;
  s->gpu_doorbell = gpu_bf;

  char* slab = static_cast<char*>(s->slab);
  auto* cq_buf = reinterpret_cast<mlx5_cqe64*>(slab + s->cq_off);
  auto* cq_dbrec = reinterpret_cast<__be32*>(slab + s->dbr_off + kCqDbrecOff);
  auto* qp_dbrec = reinterpret_cast<__be32*>(slab + s->dbr_off + kQpDbrecOff);

  host_qp_->mlx5_cq_ = gda_mlx5_device_cq(cq_buf, cq_dbrec, s->cq_cqe_cnt,
                                          static_cast<uint32_t>(kCqe));
  host_qp_->mlx5_cq_.cons_index = 0;
  host_qp_->mlx5_sq_ =
    gda_mlx5_device_sq(reinterpret_cast<gda_mlx5_wqe*>(slab + s->sq_off),
                       &qp_dbrec[1], static_cast<gda_mlx5_doorbell*>(gpu_bf),
                       static_cast<uint16_t>(s->sq_wqe_cnt));
  host_qp_->mlx5_sq_.tail = 0;
  host_qp_->mlx5_sq_.post = 0;
  host_qp_->lkey_ = 0;
  host_qp_->rkey_ = 0;
  host_qp_->qp_num_ = s->qpn;
  host_qp_->inline_threshold_ = config_.inline_threshold;

  fprintf(stderr,
          "rdma_ep::mlx5: devx: GPU QP initialized (CQ buf=%p depth=%u, "
          "SQ buf=%p depth=%u, doorbell host=%p gpu=%p)\n",
          static_cast<void*>(cq_buf), s->cq_cqe_cnt,
          static_cast<void*>(slab + s->sq_off), s->sq_wqe_cnt, s->uar->reg_addr,
          gpu_bf);
}

void Backend::mlx5_devx_cleanup() {
  Mlx5DevxState* s = devx_;
  if (!s)
    return;
  if (s->qp_obj)
    (void)s->fn.obj_destroy(s->qp_obj);
  if (s->cq_obj)
    (void)s->fn.obj_destroy(s->cq_obj);
  if (s->locked_uar_ptr)
    (void)hsa_amd_memory_unlock(s->locked_uar_ptr);
  if (s->uar)
    s->fn.free_uar(s->uar);
  if (s->umem)
    (void)s->fn.umem_dereg(s->umem);
  free_slab(*s);
  delete s;
  devx_ = nullptr;
}

} // namespace rdma_ep
} // namespace xio

#endif // defined(GDA_MLX5)
