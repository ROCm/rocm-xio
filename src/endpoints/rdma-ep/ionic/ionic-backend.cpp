/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * IONIC (Pensando) Direct Verbs backend for
 * rdma-ep. Implements DV library loading, CQ/QP
 * creation via parent domain, and GPU QueuePair
 * initialization for the ionic RDMA provider.
 *
 * Uses host-pinned memory (hipHostMalloc) for
 * parent domain allocations. When kernel-side
 * ib_umem_get_dmabuf support lands for ionic,
 * switch to pd_alloc_device_uncached to use GPU
 * device memory directly.
 */

#include <cstdio>
#include <cstring>

#include <hip/hip_runtime.h>

#include <dlfcn.h>
#include <unistd.h>

#include "gda-backend.hpp"
#include "ibv-wrapper.hpp"
#include "ionic/ionic-provider.hpp"
#include "queue-pair.hpp"

namespace rdma_ep {

#define XIO_CHECK_ZERO(expr, msg)                                              \
  do {                                                                         \
    int _err = (expr);                                                         \
    if (_err != 0) {                                                           \
      fprintf(stderr,                                                          \
              "rdma_ep::ionic: %s failed: "                                    \
              "%d at %s:%d\n",                                                 \
              (msg), _err, __FILE__, __LINE__);                                \
      return;                                                                  \
    }                                                                          \
  } while (0)

#define XIO_CHECK_NNULL(expr, msg)                                             \
  do {                                                                         \
    if (!(expr)) {                                                             \
      fprintf(stderr,                                                          \
              "rdma_ep::ionic: %s returned "                                   \
              "null at %s:%d\n",                                               \
              (msg), __FILE__, __LINE__);                                      \
      return;                                                                  \
    }                                                                          \
  } while (0)

namespace {

template <typename FuncPtr>
int dlsym_load(FuncPtr& out, void* handle, const char* name) {
  out = reinterpret_cast<FuncPtr>(dlsym(handle, name));
  if (!out) {
    fprintf(stderr,
            "rdma_ep::ionic: dlsym failed for "
            "%s: %s\n",
            name, dlerror());
    return -1;
  }
  return 0;
}

ionicdv_funcs_t ionic_dv{};
void* ionicdv_lib_handle_ = nullptr;

using qp_set_gda_fn = int (*)(struct ibv_qp*, bool, bool);
qp_set_gda_fn ionic_qp_set_gda_ = nullptr;

} // anonymous namespace

#if defined(GDA_IONIC)

void* Backend::ionic_dv_dlopen() {
  constexpr int flags = RTLD_LAZY | RTLD_DEEPBIND;
  void* handle = nullptr;
#ifdef RDMA_CORE_LIB_DIR
  handle = dlopen(RDMA_CORE_LIB_DIR "/libionic.so", flags);
#endif
  if (!handle)
    handle = dlopen("libionic.so", flags);
  if (!handle)
    handle = dlopen("/usr/local/lib/libionic.so", flags);
  if (!handle)
    fprintf(stderr,
            "rdma_ep::ionic: Could not open "
            "libionic.so: %s\n",
            dlerror());
  return handle;
}

int Backend::ionic_dv_dl_init() {
  ionicdv_lib_handle_ = ionic_dv_dlopen();
  if (!ionicdv_lib_handle_)
    return -1;

#define LOAD(field, name)                                                      \
  if (dlsym_load(ionic_dv.field, ionicdv_lib_handle_, name) != 0)              \
    return -1;

  LOAD(get_ctx, "ionic_dv_get_ctx");
  LOAD(qp_get_udma_idx, "ionic_dv_qp_get_udma_idx");
  LOAD(get_cq, "ionic_dv_get_cq");
  LOAD(get_qp, "ionic_dv_get_qp");
  LOAD(pd_set_sqcmb, "ionic_dv_pd_set_sqcmb");
  LOAD(pd_set_rqcmb, "ionic_dv_pd_set_rqcmb");
  LOAD(pd_set_udma_mask, "ionic_dv_pd_set_udma_mask");
  LOAD(create_cq_ex, "ionic_dv_create_cq_ex");

#undef LOAD

  if (dlsym_load(ionic_qp_set_gda_, ionicdv_lib_handle_,
                 "ionic_dv_qp_set_gda") != 0)
    return -1;

  ionicdv_handle_ = ionicdv_lib_handle_;
  return 0;
}

void Backend::ionic_setup_parent_domain(
  struct ibv_parent_domain_init_attr* pattr) {
  memset(pattr, 0, sizeof(*pattr));
  pattr->pd = pd_;
  pattr->td = nullptr;
  pattr->comp_mask = IBV_PARENT_DOMAIN_INIT_ATTR_ALLOCATORS;
  if (config_.queue_mem == QueueMemMode::DEVICE_VRAM) {
    pattr->alloc = Backend::pd_alloc_device_uncached;
    pattr->free = Backend::pd_release;
  } else {
    pattr->alloc = Backend::pd_alloc_host_pinned;
    pattr->free = Backend::pd_release_host;
  }
  pattr->pd_context = nullptr;
}

void Backend::ionic_create_cqs(int ncqes) {
  struct ibv_parent_domain_init_attr pattr;
  ionic_setup_parent_domain(&pattr);

  pd_parent_ = ibv.alloc_parent_domain(context_, &pattr);
  XIO_CHECK_NNULL(pd_parent_, "ibv_alloc_parent_domain");

  ionic_dv.pd_set_udma_mask(pd_parent_, IONIC_UDMA_MASK_LOW);

  int cmb_rc = ionic_dv.pd_set_sqcmb(pd_parent_, false, false, false);
  if (cmb_rc != 0) {
    fprintf(stderr,
            "rdma_ep::ionic: "
            "pd_set_sqcmb(off) failed: %d "
            "(non-fatal)\n",
            cmb_rc);
  }
  cmb_rc = ionic_dv.pd_set_rqcmb(pd_parent_, false, false, false);
  if (cmb_rc != 0) {
    fprintf(stderr,
            "rdma_ep::ionic: "
            "pd_set_rqcmb(off) failed: %d "
            "(non-fatal)\n",
            cmb_rc);
  }

  struct ibv_cq_init_attr_ex cq_attr;
  memset(&cq_attr, 0, sizeof(cq_attr));
  cq_attr.cqe = ncqes;
  cq_attr.channel = nullptr;
  cq_attr.comp_vector = 0;
  cq_attr.wc_flags = 0;
  cq_attr.comp_mask = IBV_CQ_INIT_ATTR_MASK_PD;
  cq_attr.parent_domain = pd_parent_;

  struct ionic_cq_init_attr_ex ionic_cq_attr;
  memset(&ionic_cq_attr, 0, sizeof(ionic_cq_attr));
  ionic_cq_attr.comp_mask = IONIC_CQ_INIT_ATTR_MASK_FLAGS;
  ionic_cq_attr.flags = IONIC_CQ_INIT_ATTR_CCQE;

  errno = 0;
  struct ibv_cq_ex* cq_ex = ionic_dv.create_cq_ex(context_, &cq_attr,
                                                  &ionic_cq_attr);
  if (!cq_ex) {
    fprintf(stderr,
            "rdma_ep::ionic: "
            "ionic_dv_create_cq_ex returned "
            "null (errno=%d: %s) at %s:%d\n",
            errno, strerror(errno), __FILE__, __LINE__);
    return;
  }

  if (cq_) {
    ibv.destroy_cq(cq_);
    cq_ = nullptr;
  }
  cq_ = ibv_cq_ex_to_cq(cq_ex);

  fprintf(stderr,
          "rdma_ep::ionic: Created CQ "
          "(depth=%d, CCQE mode)\n",
          ncqes);
}

void Backend::ionic_initialize_gpu_qp() {
  if (!host_qp_ || !cq_ || !qp_)
    return;

  struct ionic_dv_ctx dvctx;
  memset(&dvctx, 0, sizeof(dvctx));
  int rc = ionic_dv.get_ctx(&dvctx, context_);
  if (rc != 0) {
    fprintf(stderr,
            "rdma_ep::ionic: "
            "ionic_dv_get_ctx failed: %d\n",
            rc);
    return;
  }

  gpu_db_page_ = dvctx.db_page;

  uintptr_t db_page_va = reinterpret_cast<uintptr_t>(dvctx.db_page);
  uintptr_t db_ptr_va = reinterpret_cast<uintptr_t>(dvctx.db_ptr);
  size_t db_offset = db_ptr_va - db_page_va;

  fprintf(stderr,
          "rdma_ep::ionic: DB page=%p, "
          "DB ptr=%p, offset=%zu\n",
          dvctx.db_page, (void*)dvctx.db_ptr, db_offset);

  rc = ionic_qp_set_gda_(qp_, true, false);
  if (rc != 0) {
    fprintf(stderr,
            "rdma_ep::ionic: "
            "ionic_dv_qp_set_gda failed: "
            "%d\n",
            rc);
    return;
  }

  uint8_t udma_idx = ionic_dv.qp_get_udma_idx(qp_);

  struct ionic_dv_cq dvcq;
  memset(&dvcq, 0, sizeof(dvcq));
  rc = ionic_dv.get_cq(&dvcq, cq_, udma_idx);
  if (rc != 0) {
    fprintf(stderr,
            "rdma_ep::ionic: "
            "ionic_dv_get_cq failed: %d\n",
            rc);
    return;
  }

  struct ionic_dv_qp dvqp;
  memset(&dvqp, 0, sizeof(dvqp));
  rc = ionic_dv.get_qp(&dvqp, qp_);
  if (rc != 0) {
    fprintf(stderr,
            "rdma_ep::ionic: "
            "ionic_dv_get_qp failed: %d\n",
            rc);
    return;
  }

  host_qp_->ionic_cq_buf_ = static_cast<struct ionic_v1_cqe*>(dvcq.q.ptr);
  host_qp_->cq_mask_ = dvcq.q.mask;
  host_qp_->cq_dbval_ = dvcq.q.db_val;
  host_qp_->cq_pos_ = 0;
  host_qp_->cq_dbpos_ = 0;
  host_qp_->cq_lock_ = 0;

  host_qp_->ionic_sq_buf_ = static_cast<struct ionic_v1_wqe*>(dvqp.sq.ptr);
  host_qp_->sq_mask_ = dvqp.sq.mask;
  host_qp_->sq_dbval_ = dvqp.sq.db_val;
  host_qp_->sq_prod_ = 0;
  host_qp_->sq_dbprod_ = 0;
  host_qp_->sq_msn_ = 0;
  host_qp_->sq_lock_ = 0;

  fprintf(stderr,
          "rdma_ep::ionic: SQ db_val=0x%lx "
          "stride_log2=%u depth_log2=%u, "
          "CQ db_val=0x%lx "
          "stride_log2=%u depth_log2=%u\n",
          (unsigned long)dvqp.sq.db_val, dvqp.sq.stride_log2,
          dvqp.sq.depth_log2, (unsigned long)dvcq.q.db_val, dvcq.q.stride_log2,
          dvcq.q.depth_log2);

  hipError_t herr = hipHostRegister(dvctx.db_page, getpagesize(),
                                    hipHostRegisterIoMemory);
  if (herr != hipSuccess) {
    fprintf(stderr,
            "rdma_ep::ionic: "
            "hipHostRegister(db_page, IO) "
            "failed: %s\n",
            hipGetErrorString(herr));
    return;
  }
  void* gpu_db_base = nullptr;
  herr = hipHostGetDevicePointer(&gpu_db_base, dvctx.db_page, 0);
  if (herr != hipSuccess) {
    fprintf(stderr,
            "rdma_ep::ionic: "
            "hipHostGetDevicePointer"
            "(db_page) failed: %s\n",
            hipGetErrorString(herr));
    return;
  }

  uint64_t* gpu_db = reinterpret_cast<uint64_t*>(
    reinterpret_cast<uintptr_t>(gpu_db_base) + db_offset);

  host_qp_->sq_dbreg_ = &gpu_db[dvctx.sq_qtype];
  host_qp_->cq_dbreg_ = &gpu_db[dvctx.cq_qtype];

  fprintf(stderr,
          "rdma_ep::ionic: sq_qtype=%u "
          "cq_qtype=%u, "
          "sq_dbreg=%p cq_dbreg=%p\n",
          dvctx.sq_qtype, dvctx.cq_qtype, (void*)host_qp_->sq_dbreg_,
          (void*)host_qp_->cq_dbreg_);

  host_qp_->lkey_ = 0;
  host_qp_->rkey_ = 0;
  host_qp_->qp_num_ = qp_->qp_num;
  host_qp_->inline_threshold_ = config_.inline_threshold;

  fprintf(stderr,
          "rdma_ep::ionic: GPU QP initialized "
          "(CQ mask=0x%lx, SQ mask=0x%lx, "
          "CQ buf=%p, SQ buf=%p, "
          "DB page=%p, DB gpu=%p)\n",
          (unsigned long)host_qp_->cq_mask_, (unsigned long)host_qp_->sq_mask_,
          (void*)host_qp_->ionic_cq_buf_, (void*)host_qp_->ionic_sq_buf_,
          dvctx.db_page, (void*)gpu_db);
}

#endif // defined(GDA_IONIC)

#undef XIO_CHECK_ZERO
#undef XIO_CHECK_NNULL

} // namespace rdma_ep
