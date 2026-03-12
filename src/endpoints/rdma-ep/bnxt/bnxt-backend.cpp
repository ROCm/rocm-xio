/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/bnxt/backend_gda_bnxt.cpp, adapted for rocm-xio.
 * Simplified from array-based (num_pes) to single-endpoint (1 SCQ, 1 RCQ, 1 QP).
 * Implements dmabuf-based QP creation for Broadcom Thor 2 NICs.
 */

#include "gda-backend.hpp"
#include "queue-pair.hpp"
#include "bnxt/bnxt-provider.hpp"
#include "ibv-wrapper.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <unistd.h>

#include <hip/hip_runtime.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>

namespace rdma_ep {

#define XIO_CHECK_ZERO(expr, msg)                                              \
  do {                                                                         \
    int _err = (expr);                                                         \
    if (_err != 0) {                                                           \
      fprintf(stderr, "rdma_ep::bnxt: %s failed: %d at %s:%d\n", (msg),       \
              _err, __FILE__, __LINE__);                                       \
      return;                                                                  \
    }                                                                          \
  } while (0)

#define XIO_CHECK_NNULL(expr, msg)                                             \
  do {                                                                         \
    if (!(expr)) {                                                             \
      fprintf(stderr, "rdma_ep::bnxt: %s returned null at %s:%d\n", (msg),     \
              __FILE__, __LINE__);                                             \
      return;                                                                  \
    }                                                                          \
  } while (0)

namespace {

template <typename FuncPtr>
int dlsym_load(FuncPtr &out, void *handle, const char *name) {
  out = reinterpret_cast<FuncPtr>(dlsym(handle, name));
  if (!out) {
    fprintf(stderr, "rdma_ep::bnxt: dlsym failed for %s: %s\n", name,
            dlerror());
    return -1;
  }
  return 0;
}

bnxtdv_funcs_t bnxt_re_dv{};
void *bnxtdv_handle_ = nullptr;

} // anonymous namespace

#if defined(GDA_BNXT)

void *Backend::bnxt_dv_dlopen() {
  void *handle = dlopen("libbnxt_re-rdmav34.so", RTLD_LAZY);
  if (!handle)
    handle = dlopen("libbnxt_re.so", RTLD_LAZY);
  if (!handle)
    handle = dlopen("/usr/local/lib/libbnxt_re.so", RTLD_LAZY);
  if (!handle)
    fprintf(stderr, "rdma_ep::bnxt: Could not open libbnxt_re.so\n");
  return handle;
}

int Backend::bnxt_dv_dl_init() {
  bnxtdv_handle_ = bnxt_dv_dlopen();
  if (!bnxtdv_handle_)
    return -1;

#define LOAD(field, name)                                                      \
  if (dlsym_load(bnxt_re_dv.field, bnxtdv_handle_, name) != 0)                \
    return -1;

  LOAD(init_obj, "bnxt_re_dv_init_obj");
  LOAD(create_qp, "bnxt_re_dv_create_qp");
  LOAD(destroy_qp, "bnxt_re_dv_destroy_qp");
  LOAD(modify_qp, "bnxt_re_dv_modify_qp");
  LOAD(qp_mem_alloc, "bnxt_re_dv_qp_mem_alloc");
  LOAD(create_cq, "bnxt_re_dv_create_cq");
  LOAD(destroy_cq, "bnxt_re_dv_destroy_cq");
  LOAD(cq_mem_alloc, "bnxt_re_dv_cq_mem_alloc");
  LOAD(umem_reg, "bnxt_re_dv_umem_reg");
  LOAD(umem_dereg, "bnxt_re_dv_umem_dereg");
  LOAD(alloc_db_region, "bnxt_re_dv_alloc_db_region");
  LOAD(free_db_region, "bnxt_re_dv_free_db_region");

#undef LOAD
  return 0;
}

void Backend::bnxt_create_cqs(int cqe) {
  struct bnxt_re_dv_cq_attr cq_attr;
  struct bnxt_re_dv_cq_init_attr cq_init_attr;
  struct bnxt_re_dv_umem_reg_attr umem_attr;

  int dmabuf_enabled = ibv.is_dmabuf_supported();

  cqe = 1; // CQE compression: only need 1 entry

  // Allocate host structures
  bnxt_scq_ = static_cast<bnxt_host_cq *>(calloc(1, sizeof(bnxt_host_cq)));
  bnxt_rcq_ = static_cast<bnxt_host_cq *>(calloc(1, sizeof(bnxt_host_cq)));

  // --- Create SCQ ---
  memset(&cq_attr, 0, sizeof(cq_attr));
  bnxt_scq_->handle = bnxt_re_dv.cq_mem_alloc(context_, cqe, &cq_attr);
  XIO_CHECK_NNULL(bnxt_scq_->handle, "bnxt_re_dv_cq_mem_alloc (SCQ)");

  cq_attr.ncqe = cqe;
  bnxt_scq_->length = cq_attr.ncqe * cq_attr.cqe_size;
  bnxt_scq_->depth = cq_attr.ncqe;

  hipError_t herr =
    hipExtMallocWithFlags(&bnxt_scq_->buf, bnxt_scq_->length,
                          hipDeviceMallocUncached);
  if (herr != hipSuccess) {
    fprintf(stderr, "rdma_ep::bnxt: hipExtMallocWithFlags SCQ failed: %s\n",
            hipGetErrorString(herr));
    return;
  }
  (void)hipMemset(bnxt_scq_->buf, 0, bnxt_scq_->length);

  if (dmabuf_enabled) {
    hsa_amd_portable_export_dmabuf(bnxt_scq_->buf, bnxt_scq_->length,
                                   &bnxt_scq_->dmabuf_fd,
                                   &bnxt_scq_->dmabuf_offset);
  }

  memset(&umem_attr, 0, sizeof(umem_attr));
  umem_attr.addr = bnxt_scq_->buf;
  umem_attr.size = bnxt_scq_->length;
  umem_attr.access_flags = IBV_ACCESS_LOCAL_WRITE;
  umem_attr.dmabuf_fd = dmabuf_enabled ? bnxt_scq_->dmabuf_fd : 0;

  bnxt_scq_->umem_handle = bnxt_re_dv.umem_reg(context_, &umem_attr);
  XIO_CHECK_NNULL(bnxt_scq_->umem_handle, "bnxt_re_dv_umem_reg (SCQ)");

  memset(&cq_init_attr, 0, sizeof(cq_init_attr));
  cq_init_attr.cq_handle = (uint64_t)bnxt_scq_->handle;
  cq_init_attr.umem_handle = bnxt_scq_->umem_handle;
  cq_init_attr.ncqe = cq_attr.ncqe;

  bnxt_scq_->cq = bnxt_re_dv.create_cq(context_, &cq_init_attr);
  XIO_CHECK_NNULL(bnxt_scq_->cq, "bnxt_re_dv_create_cq (SCQ)");

  // --- Create RCQ ---
  memset(&cq_attr, 0, sizeof(cq_attr));
  bnxt_rcq_->handle = bnxt_re_dv.cq_mem_alloc(context_, cqe, &cq_attr);
  XIO_CHECK_NNULL(bnxt_rcq_->handle, "bnxt_re_dv_cq_mem_alloc (RCQ)");

  bnxt_rcq_->length = cq_attr.ncqe * cq_attr.cqe_size;
  bnxt_rcq_->depth = cq_attr.ncqe;

  herr = hipExtMallocWithFlags(&bnxt_rcq_->buf, bnxt_rcq_->length,
                               hipDeviceMallocUncached);
  if (herr != hipSuccess) {
    fprintf(stderr, "rdma_ep::bnxt: hipExtMallocWithFlags RCQ failed: %s\n",
            hipGetErrorString(herr));
    return;
  }
  (void)hipMemset(bnxt_rcq_->buf, 0, bnxt_rcq_->length);

  if (dmabuf_enabled) {
    hsa_amd_portable_export_dmabuf(bnxt_rcq_->buf, bnxt_rcq_->length,
                                   &bnxt_rcq_->dmabuf_fd,
                                   &bnxt_rcq_->dmabuf_offset);
  }

  memset(&umem_attr, 0, sizeof(umem_attr));
  umem_attr.addr = bnxt_rcq_->buf;
  umem_attr.size = bnxt_rcq_->length;
  umem_attr.access_flags = IBV_ACCESS_LOCAL_WRITE;
  umem_attr.dmabuf_fd = dmabuf_enabled ? bnxt_rcq_->dmabuf_fd : 0;

  bnxt_rcq_->umem_handle = bnxt_re_dv.umem_reg(context_, &umem_attr);
  XIO_CHECK_NNULL(bnxt_rcq_->umem_handle, "bnxt_re_dv_umem_reg (RCQ)");

  memset(&cq_init_attr, 0, sizeof(cq_init_attr));
  cq_init_attr.cq_handle = (uint64_t)bnxt_rcq_->handle;
  cq_init_attr.umem_handle = bnxt_rcq_->umem_handle;
  cq_init_attr.ncqe = cq_attr.ncqe;

  bnxt_rcq_->cq = bnxt_re_dv.create_cq(context_, &cq_init_attr);
  XIO_CHECK_NNULL(bnxt_rcq_->cq, "bnxt_re_dv_create_cq (RCQ)");

  // Override the cq_ in backend with the SCQ
  if (cq_) {
    ibv.destroy_cq(cq_);
    cq_ = nullptr;
  }
  cq_ = bnxt_scq_->cq;

  fprintf(stderr, "rdma_ep::bnxt: Created CQs (SCQ depth=%u, RCQ depth=%u)\n",
          bnxt_scq_->depth, bnxt_rcq_->depth);
}

void Backend::bnxt_create_qps(int sq_length) {
  struct ibv_qp_init_attr ib_qp_attr;
  struct bnxt_re_dv_umem_reg_attr umem_attr;
  int dmabuf_enabled = ibv.is_dmabuf_supported();

  bnxt_qp_ = static_cast<bnxt_host_qp *>(calloc(1, sizeof(bnxt_host_qp)));

  // IB QP Init Attr
  memset(&ib_qp_attr, 0, sizeof(ib_qp_attr));
  ib_qp_attr.send_cq = bnxt_scq_->cq;
  ib_qp_attr.recv_cq = bnxt_rcq_->cq;
  ib_qp_attr.cap.max_send_wr = sq_length;
  ib_qp_attr.cap.max_recv_wr = 0;
  ib_qp_attr.cap.max_send_sge = 1;
  ib_qp_attr.cap.max_recv_sge = 0;
  ib_qp_attr.cap.max_inline_data = config_.inline_threshold;
  ib_qp_attr.qp_type = IBV_QPT_RC;
  ib_qp_attr.sq_sig_all = 0;

  // Alloc qp_mem_info
  memset(&bnxt_qp_->mem_info, 0, sizeof(bnxt_re_dv_qp_mem_info));
  int err =
    bnxt_re_dv.qp_mem_alloc(pd_, &ib_qp_attr, &bnxt_qp_->mem_info);
  XIO_CHECK_ZERO(err, "bnxt_re_dv_qp_mem_alloc");

  // Alloc SQ buffer on GPU
  void *sq_ptr = nullptr;
  hipError_t herr = hipExtMallocWithFlags(&sq_ptr,
                                          bnxt_qp_->mem_info.sq_len,
                                          hipDeviceMallocUncached);
  if (herr != hipSuccess) {
    fprintf(stderr, "rdma_ep::bnxt: hipExtMallocWithFlags SQ failed: %s\n",
            hipGetErrorString(herr));
    return;
  }
  (void)hipMemset(sq_ptr, 0, bnxt_qp_->mem_info.sq_len);
  bnxt_qp_->mem_info.sq_va = (uint64_t)sq_ptr;
  bnxt_qp_->sq_buf = sq_ptr;

  if (dmabuf_enabled) {
    hsa_amd_portable_export_dmabuf(sq_ptr, bnxt_qp_->mem_info.sq_len,
                                   &bnxt_qp_->sq_dmabuf_fd,
                                   &bnxt_qp_->sq_dmabuf_offset);
  }

  // MSN Table pointer (at end of SQ buffer)
  uint64_t msntbl_len =
    bnxt_qp_->mem_info.sq_psn_sz * bnxt_qp_->mem_info.sq_npsn;
  uint64_t msntbl_offset = bnxt_qp_->mem_info.sq_len - msntbl_len;
  bnxt_qp_->msntbl = (void *)((char *)bnxt_qp_->sq_buf + msntbl_offset);
  bnxt_qp_->msn_tbl_sz = bnxt_qp_->mem_info.sq_npsn;

  // Register SQ UMEM
  memset(&umem_attr, 0, sizeof(umem_attr));
  umem_attr.addr = (void *)bnxt_qp_->mem_info.sq_va;
  umem_attr.size = bnxt_qp_->mem_info.sq_len;
  umem_attr.access_flags = IBV_ACCESS_LOCAL_WRITE;
  umem_attr.dmabuf_fd = dmabuf_enabled ? bnxt_qp_->sq_dmabuf_fd : 0;

  void *sq_umem = bnxt_re_dv.umem_reg(context_, &umem_attr);
  XIO_CHECK_NNULL(sq_umem, "bnxt_re_dv_umem_reg (SQ)");

  // Alloc RQ buffer on GPU
  void *rq_ptr = nullptr;
  herr = hipExtMallocWithFlags(&rq_ptr, bnxt_qp_->mem_info.rq_len,
                               hipDeviceMallocUncached);
  if (herr != hipSuccess) {
    fprintf(stderr, "rdma_ep::bnxt: hipExtMallocWithFlags RQ failed: %s\n",
            hipGetErrorString(herr));
    return;
  }
  (void)hipMemset(rq_ptr, 0, bnxt_qp_->mem_info.rq_len);
  bnxt_qp_->mem_info.rq_va = (uint64_t)rq_ptr;
  bnxt_qp_->rq_buf = rq_ptr;

  if (dmabuf_enabled) {
    hsa_amd_portable_export_dmabuf(rq_ptr, bnxt_qp_->mem_info.rq_len,
                                   &bnxt_qp_->rq_dmabuf_fd,
                                   &bnxt_qp_->rq_dmabuf_offset);
  }

  // Register RQ UMEM
  memset(&umem_attr, 0, sizeof(umem_attr));
  umem_attr.addr = (void *)bnxt_qp_->mem_info.rq_va;
  umem_attr.size = bnxt_qp_->mem_info.rq_len;
  umem_attr.access_flags = IBV_ACCESS_LOCAL_WRITE;
  umem_attr.dmabuf_fd = dmabuf_enabled ? bnxt_qp_->rq_dmabuf_fd : 0;

  void *rq_umem = bnxt_re_dv.umem_reg(context_, &umem_attr);
  XIO_CHECK_NNULL(rq_umem, "bnxt_re_dv_umem_reg (RQ)");

  // Alloc doorbell region
  bnxt_qp_->db_region_attr = bnxt_re_dv.alloc_db_region(context_);
  XIO_CHECK_NNULL(bnxt_qp_->db_region_attr, "bnxt_re_dv_alloc_db_region");

  // Fill DV QP init attr
  memset(&bnxt_qp_->attr, 0, sizeof(bnxt_re_dv_qp_init_attr));
  bnxt_qp_->attr.send_cq = ib_qp_attr.send_cq;
  bnxt_qp_->attr.recv_cq = ib_qp_attr.recv_cq;
  bnxt_qp_->attr.max_send_wr = ib_qp_attr.cap.max_send_wr;
  bnxt_qp_->attr.max_recv_wr = ib_qp_attr.cap.max_recv_wr;
  bnxt_qp_->attr.max_send_sge = ib_qp_attr.cap.max_send_sge;
  bnxt_qp_->attr.max_recv_sge = ib_qp_attr.cap.max_recv_sge;
  bnxt_qp_->attr.max_inline_data = ib_qp_attr.cap.max_inline_data;
  bnxt_qp_->attr.qp_type = ib_qp_attr.qp_type;
  bnxt_qp_->attr.qp_handle = bnxt_qp_->mem_info.qp_handle;
  bnxt_qp_->attr.dbr_handle = bnxt_qp_->db_region_attr;
  bnxt_qp_->attr.sq_umem_handle = sq_umem;
  bnxt_qp_->attr.sq_len = bnxt_qp_->mem_info.sq_len;
  bnxt_qp_->attr.sq_slots = bnxt_qp_->mem_info.sq_slots;
  bnxt_qp_->attr.sq_wqe_sz = bnxt_qp_->mem_info.sq_wqe_sz;
  bnxt_qp_->attr.sq_psn_sz = bnxt_qp_->mem_info.sq_psn_sz;
  bnxt_qp_->attr.sq_npsn = bnxt_qp_->mem_info.sq_npsn;
  bnxt_qp_->attr.rq_umem_handle = rq_umem;
  bnxt_qp_->attr.rq_len = bnxt_qp_->mem_info.rq_len;
  bnxt_qp_->attr.rq_slots = bnxt_qp_->mem_info.rq_slots;
  bnxt_qp_->attr.rq_wqe_sz = bnxt_qp_->mem_info.rq_wqe_sz;
  bnxt_qp_->attr.comp_mask = bnxt_qp_->mem_info.comp_mask;

  // Create QP via BNXT DV
  if (qp_) {
    ibv.destroy_qp(qp_);
    qp_ = nullptr;
  }
  qp_ = bnxt_re_dv.create_qp(pd_, &bnxt_qp_->attr);
  XIO_CHECK_NNULL(qp_, "bnxt_re_dv_create_qp");

  fprintf(stderr,
          "rdma_ep::bnxt: Created QP via DV (QPN=%u, SQ slots=%u, "
          "SQ len=%u, MSN tbl sz=%u)\n",
          qp_->qp_num, bnxt_qp_->mem_info.sq_slots,
          bnxt_qp_->mem_info.sq_len, bnxt_qp_->msn_tbl_sz);
}

void Backend::bnxt_initialize_gpu_qp() {
  if (!host_qp_ || !bnxt_qp_ || !bnxt_scq_)
    return;

  struct bnxt_re_dv_obj dv_obj;
  struct bnxt_re_dv_cq dv_cq;
  int err;

  // Export SCQ via DV
  memset(&dv_obj, 0, sizeof(dv_obj));
  dv_obj.cq.in = bnxt_scq_->cq;
  dv_obj.cq.out = &dv_cq;
  err = bnxt_re_dv.init_obj(&dv_obj, BNXT_RE_DV_OBJ_CQ);
  if (err != 0) {
    fprintf(stderr, "rdma_ep::bnxt: init_obj(CQ) failed: %d\n", err);
    return;
  }

  memset(&host_qp_->bnxt_cq_, 0, sizeof(bnxt_device_cq));
  host_qp_->bnxt_cq_.buf = bnxt_scq_->buf;
  host_qp_->bnxt_cq_.depth = bnxt_scq_->depth;
  host_qp_->bnxt_cq_.id = dv_cq.cqn;

  // Export QP via DV
  struct bnxt_re_dv_qp dv_qp;
  memset(&dv_obj, 0, sizeof(dv_obj));
  dv_obj.qp.in = qp_;
  dv_obj.qp.out = &dv_qp;
  err = bnxt_re_dv.init_obj(&dv_obj, BNXT_RE_DV_OBJ_QP);
  if (err != 0) {
    fprintf(stderr, "rdma_ep::bnxt: init_obj(QP) failed: %d\n", err);
    return;
  }

  memset(&host_qp_->bnxt_sq_, 0, sizeof(bnxt_device_sq));
  host_qp_->bnxt_sq_.buf = bnxt_qp_->sq_buf;
  host_qp_->bnxt_sq_.depth = bnxt_qp_->mem_info.sq_slots;
  host_qp_->bnxt_sq_.id = qp_->qp_num;
  host_qp_->bnxt_sq_.msntbl = bnxt_qp_->msntbl;
  host_qp_->bnxt_sq_.msn_tbl_sz = bnxt_qp_->msn_tbl_sz;
  host_qp_->bnxt_sq_.psn_sz_log2 =
    static_cast<uint32_t>(std::log2(bnxt_qp_->mem_info.sq_psn_sz));
  host_qp_->bnxt_sq_.mtu = ibv_mtu_to_int(port_attr_.active_mtu);

  // Export doorbell register for GPU access
  hipError_t herr = hipHostRegister(bnxt_qp_->db_region_attr->dbr,
                                    getpagesize(), hipHostRegisterDefault);
  if (herr != hipSuccess) {
    fprintf(stderr, "rdma_ep::bnxt: hipHostRegister(dbr) failed: %s\n",
            hipGetErrorString(herr));
    return;
  }
  herr = hipHostGetDevicePointer((void **)&host_qp_->bnxt_dbr_,
                                 bnxt_qp_->db_region_attr->dbr, 0);
  if (herr != hipSuccess) {
    fprintf(stderr, "rdma_ep::bnxt: hipHostGetDevicePointer(dbr) failed: %s\n",
            hipGetErrorString(herr));
    return;
  }

  // Set memory keys and inline threshold
  host_qp_->lkey_ = 0;  // Will be set when heap MR is registered
  host_qp_->rkey_ = 0;  // Will be set for remote peer
  host_qp_->qp_num_ = qp_->qp_num;
  host_qp_->inline_threshold_ = config_.inline_threshold;

  fprintf(stderr,
          "rdma_ep::bnxt: GPU QP initialized (CQ id=%u, SQ depth=%u, "
          "SQ buf=%p, DB=%p, MTU=%lu)\n",
          host_qp_->bnxt_cq_.id, host_qp_->bnxt_sq_.depth,
          host_qp_->bnxt_sq_.buf, (void *)host_qp_->bnxt_dbr_,
          host_qp_->bnxt_sq_.mtu);
}

#endif // defined(GDA_BNXT)

int bnxt_dv_modify_qp(struct ibv_qp *qp, struct ibv_qp_attr *attr,
                      int attr_mask) {
  if (!bnxt_re_dv.modify_qp)
    return -1;
  return bnxt_re_dv.modify_qp(qp, attr, attr_mask, 0, 0);
}

#undef XIO_CHECK_ZERO
#undef XIO_CHECK_NNULL

} // namespace rdma_ep
