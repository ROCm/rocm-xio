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
 * and only needs mlx5dv_init_obj to extract queue
 * buffer pointers for GPU-side WQE posting.
 */

#include <cstdio>
#include <cstring>

#include <dlfcn.h>

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

mlx5dv_funcs_t mlx5_dv{};

} // anonymous namespace

#if defined(GDA_MLX5)

void* Backend::mlx5_dv_dlopen() {
  void* handle = nullptr;
#ifdef RDMA_CORE_LIB_DIR
  handle = dlopen(RDMA_CORE_LIB_DIR "/libmlx5.so", RTLD_LAZY);
#endif
  if (!handle)
    handle = dlopen("libmlx5.so", RTLD_LAZY);
  if (!handle)
    handle = dlopen("/usr/lib/x86_64-linux-gnu/libmlx5.so", RTLD_LAZY);
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

  return 0;
}

void Backend::mlx5_initialize_gpu_qp() {
  if (!host_qp_ || !qp_ || !cq_)
    return;

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

  host_qp_->mlx5_cq_ = gda_mlx5_device_cq(static_cast<mlx5_cqe64*>(dv_cq.buf),
                                          dv_cq.dbrec);

  host_qp_->mlx5_sq_ =
    gda_mlx5_device_sq(static_cast<gda_mlx5_wqe*>(dv_qp.sq.buf), dv_qp.dbrec,
                       static_cast<gda_mlx5_doorbell*>(dv_qp.bf.reg),
                       static_cast<uint16_t>(dv_qp.sq.wqe_cnt));

  host_qp_->lkey_ = 0;
  host_qp_->rkey_ = 0;
  host_qp_->qp_num_ = qp_->qp_num;
  host_qp_->inline_threshold_ = config_.inline_threshold;

  fprintf(stderr,
          "rdma_ep::mlx5: GPU QP initialized "
          "(CQ buf=%p, SQ buf=%p, "
          "SQ depth=%u, BF=%p)\n",
          (void*)dv_cq.buf, dv_qp.sq.buf, dv_qp.sq.wqe_cnt, dv_qp.bf.reg);
}

#endif // defined(GDA_MLX5)

} // namespace rdma_ep
