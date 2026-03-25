/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * MLX5 (Mellanox ConnectX) Direct Verbs backend
 * for rdma-ep. Uses the system mlx5dv API from
 * libibverbs-dev (no custom rdma-core patches).
 *
 * Unlike BNXT/IONIC/ERNIC which dlopen custom DV
 * libraries, MLX5 dlopens the upstream libmlx5.so
 * and uses mlx5dv_init_obj to extract queue buffer
 * pointers for GPU-side WQE posting. Queue buffers
 * are registered with hipHostRegister for GPU
 * accessibility.
 */

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <hip/hip_runtime.h>

#include <dlfcn.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <unistd.h>

#include "gda-backend.hpp"
#include "ibv-wrapper.hpp"
#include "mlx5/mlx5-provider.hpp"
#include "queue-pair.hpp"

namespace rdma_ep {

namespace {

template <typename FuncPtr>
int dlsym_load(FuncPtr& out, void* handle, const char* name) {
  out = reinterpret_cast<FuncPtr>(dlsym(handle, name));
  if (!out) {
    fprintf(stderr,
            "rdma_ep::mlx5: dlsym failed for "
            "%s: %s\n",
            name, dlerror());
    return -1;
  }
  return 0;
}

template <typename FuncPtr>
int dlsym_load_optional(FuncPtr& out, void* handle, const char* name) {
  out = reinterpret_cast<FuncPtr>(dlsym(handle, name));
  return out ? 0 : -1;
}

void* page_align(void* ptr) {
  long page_size = sysconf(_SC_PAGESIZE);
  uintptr_t addr = reinterpret_cast<uintptr_t>(ptr);
  addr &= ~(static_cast<uintptr_t>(page_size) - 1);
  return reinterpret_cast<void*>(addr);
}

mlx5dv_funcs_t mlx5_dv{};

} // anonymous namespace

#if defined(GDA_MLX5)

void* Backend::mlx5_dv_dlopen() {
  constexpr int flags = RTLD_LAZY | RTLD_DEEPBIND;
  void* handle = nullptr;
#ifdef RDMA_CORE_LIB_DIR
  handle = dlopen(RDMA_CORE_LIB_DIR "/libmlx5.so", flags);
#endif
  if (!handle)
    handle = dlopen("libmlx5.so", flags);
  if (!handle)
    handle = dlopen("/usr/lib/x86_64-linux-gnu/libmlx5.so", flags);
  if (!handle)
    handle = dlopen("/usr/lib/aarch64-linux-gnu/libmlx5.so", flags);
  if (!handle)
    handle = dlopen("/usr/lib64/libmlx5.so", flags);
  if (!handle)
    fprintf(stderr,
            "rdma_ep::mlx5: Could not open "
            "libmlx5.so: %s\n",
            dlerror());
  return handle;
}

int Backend::mlx5_dv_dl_init() {
  mlx5dv_handle_ = mlx5_dv_dlopen();
  if (!mlx5dv_handle_)
    return -1;

  if (dlsym_load(mlx5_dv.init_obj, mlx5dv_handle_, "mlx5dv_init_obj") != 0)
    return -1;

  dlsym_load_optional(mlx5_dv.is_supported, mlx5dv_handle_,
                      "mlx5dv_is_supported");
  dlsym_load_optional(mlx5_dv.query_device, mlx5dv_handle_,
                      "mlx5dv_query_device");

  return 0;
}

void Backend::mlx5_initialize_gpu_qp() {
  if (!host_qp_ || !qp_ || !cq_)
    return;

  if (mlx5_dv.is_supported && !mlx5_dv.is_supported(device_)) {
    fprintf(stderr, "rdma_ep::mlx5: device is not an "
                    "MLX5 device\n");
    return;
  }

  if (mlx5_dv.query_device) {
    struct mlx5dv_context dv_ctx {};
    dv_ctx.comp_mask = MLX5DV_CONTEXT_MASK_CQE_COMPRESION |
                       MLX5DV_CONTEXT_MASK_DYN_BFREGS;
    int qrc = mlx5_dv.query_device(context_, &dv_ctx);
    if (qrc == 0) {
#ifdef MLX5DV_CONTEXT_FLAGS_BLUEFLAME
      bool has_bf = (dv_ctx.flags & MLX5DV_CONTEXT_FLAGS_BLUEFLAME) != 0;
      fprintf(stderr,
              "rdma_ep::mlx5: caps: "
              "BlueFlame=%s, "
              "max_dynamic_bfregs=%u\n",
              has_bf ? "yes" : "no", dv_ctx.max_dynamic_bfregs);
#else
      fprintf(stderr,
              "rdma_ep::mlx5: caps: "
              "max_dynamic_bfregs=%u\n",
              dv_ctx.max_dynamic_bfregs);
#endif
    }
  }

  struct mlx5dv_obj obj {};
  struct mlx5dv_qp dv_qp {};
  struct mlx5dv_cq dv_cq {};

  obj.qp.in = qp_;
  obj.qp.out = &dv_qp;
  obj.cq.in = cq_;
  obj.cq.out = &dv_cq;

  int ret = mlx5_dv.init_obj(&obj, MLX5DV_OBJ_QP | MLX5DV_OBJ_CQ);
  if (ret != 0) {
    fprintf(stderr,
            "rdma_ep::mlx5: "
            "mlx5dv_init_obj failed: %d\n",
            ret);
    return;
  }

  long page_size = sysconf(_SC_PAGESIZE);
  hipError_t herr;

  size_t sq_size = dv_qp.sq.wqe_cnt * dv_qp.sq.stride;
  herr = hipHostRegister(dv_qp.sq.buf, sq_size, hipHostRegisterDefault);
  if (herr != hipSuccess) {
    fprintf(stderr,
            "rdma_ep::mlx5: hipHostRegister "
            "SQ failed: %s\n",
            hipGetErrorString(herr));
    return;
  }
  mlx5_registered_sq_ = dv_qp.sq.buf;

  size_t cq_size = dv_cq.cqe_cnt * dv_cq.cqe_size;
  herr = hipHostRegister(dv_cq.buf, cq_size, hipHostRegisterDefault);
  if (herr != hipSuccess) {
    fprintf(stderr,
            "rdma_ep::mlx5: hipHostRegister "
            "CQ failed: %s\n",
            hipGetErrorString(herr));
    return;
  }
  mlx5_registered_cq_ = dv_cq.buf;

  void* sq_dbr_page = page_align(dv_qp.dbrec);
  herr = hipHostRegister(sq_dbr_page, page_size, hipHostRegisterDefault);
  if (herr != hipSuccess) {
    fprintf(stderr,
            "rdma_ep::mlx5: hipHostRegister "
            "SQ dbrec page failed: %s\n",
            hipGetErrorString(herr));
    return;
  }
  mlx5_registered_sq_dbr_page_ = sq_dbr_page;

  void* cq_dbr_page = page_align(dv_cq.dbrec);
  if (cq_dbr_page != sq_dbr_page) {
    herr = hipHostRegister(cq_dbr_page, page_size, hipHostRegisterDefault);
    if (herr != hipSuccess) {
      fprintf(stderr,
              "rdma_ep::mlx5: hipHostRegister "
              "CQ dbrec page failed: %s\n",
              hipGetErrorString(herr));
      return;
    }
    mlx5_registered_cq_dbr_page_ = cq_dbr_page;
  }

  hsa_status_t hsa_st = hsa_init();
  if (hsa_st != HSA_STATUS_SUCCESS &&
      hsa_st != static_cast<hsa_status_t>(0x1001)) {
    fprintf(stderr,
            "rdma_ep::mlx5: hsa_init "
            "failed: %d\n",
            hsa_st);
    return;
  }

  hsa_agent_t gpu_agent = {0};
  hsa_amd_memory_pool_t cpu_pool = {0};

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
            if (seg == HSA_AMD_SEGMENT_GLOBAL) {
              *static_cast<hsa_amd_memory_pool_t*>(d) = pool;
            }
            return HSA_STATUS_SUCCESS;
          },
          data);
        return HSA_STATUS_INFO_BREAK;
      }
      return HSA_STATUS_SUCCESS;
    },
    &cpu_pool);

  void* gpu_bf_ptr = nullptr;
  size_t bf_lock_size = dv_qp.bf.size * 2;
  hsa_st = hsa_amd_memory_lock_to_pool(dv_qp.bf.reg, bf_lock_size, &gpu_agent,
                                       1, cpu_pool, 0, &gpu_bf_ptr);
  if (hsa_st != HSA_STATUS_SUCCESS) {
    fprintf(stderr,
            "rdma_ep::mlx5: "
            "hsa_amd_memory_lock_to_pool "
            "BF/UAR failed: %d\n",
            hsa_st);
    return;
  }
  mlx5_registered_bf_ = dv_qp.bf.reg;

  fprintf(stderr,
          "rdma_ep::mlx5: BF/UAR locked "
          "via hsa_amd_memory_lock_to_pool "
          "(host=%p gpu=%p size=%zu)\n",
          dv_qp.bf.reg, gpu_bf_ptr, bf_lock_size);

  uint32_t initial_cq_ci = endian::from_be(dv_cq.dbrec[0]);

  mlx5_cqe64* cq_buf = static_cast<mlx5_cqe64*>(dv_cq.buf);
  for (uint32_t i = 0; i < dv_cq.cqe_cnt; i++)
    cq_buf[i].op_own = 0xFF;

  host_qp_->mlx5_cq_ = gda_mlx5_device_cq(cq_buf, dv_cq.dbrec,
                                          static_cast<uint32_t>(dv_cq.cqe_cnt),
                                          static_cast<uint32_t>(
                                            dv_cq.cqe_size));
  host_qp_->mlx5_cq_.cons_index = initial_cq_ci;

  uint16_t initial_sq_pi = static_cast<uint16_t>(
    endian::from_be(dv_qp.dbrec[1]) & 0xffff);

  host_qp_->mlx5_sq_ = gda_mlx5_device_sq(
    static_cast<gda_mlx5_wqe*>(dv_qp.sq.buf), &dv_qp.dbrec[1],
    static_cast<gda_mlx5_doorbell*>(gpu_bf_ptr),
    static_cast<uint16_t>(dv_qp.sq.wqe_cnt));
  host_qp_->mlx5_sq_.tail = initial_sq_pi;
  host_qp_->mlx5_sq_.post = initial_sq_pi;

  host_qp_->lkey_ = 0;
  host_qp_->rkey_ = 0;
  host_qp_->qp_num_ = qp_->qp_num;
  host_qp_->inline_threshold_ = config_.inline_threshold;

  fprintf(stderr,
          "rdma_ep::mlx5: GPU QP initialized "
          "(CQ buf=%p depth=%u cqe_size=%u "
          "ci=%u, "
          "SQ buf=%p depth=%u pi=%u, "
          "BF host=%p gpu=%p)\n",
          (void*)dv_cq.buf, dv_cq.cqe_cnt, dv_cq.cqe_size, initial_cq_ci,
          dv_qp.sq.buf, dv_qp.sq.wqe_cnt, initial_sq_pi, dv_qp.bf.reg,
          gpu_bf_ptr);
}

int Backend::mlx5_cpu_loopback_smoke_test() {
  if (!qp_ || !cq_ || !pd_)
    return -1;

  const size_t test_size = 64;
  const size_t buf_size = test_size * 2;
  void* buf = nullptr;
  if (posix_memalign(&buf, 4096, buf_size)) {
    fprintf(stderr, "rdma_ep::mlx5: smoke test: "
                    "posix_memalign failed\n");
    return -1;
  }

  uint8_t* src = static_cast<uint8_t*>(buf);
  uint8_t* dst = src + test_size;
  memset(src, 0xAB, test_size);
  memset(dst, 0x00, test_size);

  int access = IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE |
               IBV_ACCESS_REMOTE_READ;
  struct ibv_mr* mr = ibv.reg_mr_host(pd_, buf, buf_size, access);
  if (!mr) {
    fprintf(stderr, "rdma_ep::mlx5: smoke test: "
                    "ibv_reg_mr failed\n");
    free(buf);
    return -1;
  }

  struct ibv_sge sge {};
  sge.addr = reinterpret_cast<uint64_t>(src);
  sge.length = test_size;
  sge.lkey = mr->lkey;

  struct ibv_send_wr wr {};
  wr.wr_id = 1;
  wr.sg_list = &sge;
  wr.num_sge = 1;
  wr.opcode = IBV_WR_RDMA_WRITE;
  wr.send_flags = IBV_SEND_SIGNALED;
  wr.wr.rdma.remote_addr = reinterpret_cast<uint64_t>(dst);
  wr.wr.rdma.rkey = mr->rkey;

  struct ibv_send_wr* bad_wr = nullptr;
  int ret = ibv_post_send(qp_, &wr, &bad_wr);
  if (ret != 0) {
    fprintf(stderr,
            "rdma_ep::mlx5: smoke test: "
            "ibv_post_send failed: %d\n",
            ret);
    ibv.dereg_mr(mr);
    free(buf);
    return -1;
  }

  struct ibv_wc wc {};
  int polls = 0;
  const int max_polls = 1000000;
  int ne = 0;
  while (polls < max_polls) {
    ne = ibv_poll_cq(cq_, 1, &wc);
    if (ne > 0)
      break;
    if (ne < 0) {
      fprintf(stderr,
              "rdma_ep::mlx5: smoke test: "
              "ibv_poll_cq error: %d\n",
              ne);
      ibv.dereg_mr(mr);
      free(buf);
      return -1;
    }
    polls++;
  }

  if (ne == 0) {
    fprintf(stderr,
            "rdma_ep::mlx5: smoke test: "
            "CQE timeout after %d polls\n",
            max_polls);
    ibv.dereg_mr(mr);
    free(buf);
    return -1;
  }

  if (wc.status != IBV_WC_SUCCESS) {
    fprintf(stderr,
            "rdma_ep::mlx5: smoke test: "
            "WC error status=%d\n",
            wc.status);
    ibv.dereg_mr(mr);
    free(buf);
    return -1;
  }

  bool data_ok = (memcmp(src, dst, test_size) == 0);
  ibv.dereg_mr(mr);
  free(buf);

  if (!data_ok) {
    fprintf(stderr, "rdma_ep::mlx5: smoke test: "
                    "data mismatch\n");
    return -1;
  }

  fprintf(stderr,
          "rdma_ep::mlx5: CPU loopback "
          "smoke test PASSED "
          "(%zu bytes, %d polls)\n",
          test_size, polls);
  return 0;
}

void Backend::mlx5_cleanup() {
  if (mlx5_registered_bf_) {
    (void)hsa_amd_memory_unlock(mlx5_registered_bf_);
    mlx5_registered_bf_ = nullptr;
  }
  if (mlx5_registered_cq_dbr_page_) {
    (void)hipHostUnregister(mlx5_registered_cq_dbr_page_);
    mlx5_registered_cq_dbr_page_ = nullptr;
  }
  if (mlx5_registered_sq_dbr_page_) {
    (void)hipHostUnregister(mlx5_registered_sq_dbr_page_);
    mlx5_registered_sq_dbr_page_ = nullptr;
  }
  if (mlx5_registered_cq_) {
    (void)hipHostUnregister(mlx5_registered_cq_);
    mlx5_registered_cq_ = nullptr;
  }
  if (mlx5_registered_sq_) {
    (void)hipHostUnregister(mlx5_registered_sq_);
    mlx5_registered_sq_ = nullptr;
  }
}

#endif // defined(GDA_MLX5)

} // namespace rdma_ep
