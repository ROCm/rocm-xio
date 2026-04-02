/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM
 *   src/gda/bnxt/backend_gda_bnxt.cpp,
 * adapted for rocm-xio.
 * Simplified from array-based (num_pes) to
 * single-endpoint (1 SCQ, 1 RCQ, 1 QP).
 * Implements dmabuf-based QP creation for Broadcom
 * Thor 2 NICs.
 *
 * Updated for the v11 Direct Verbs API from the
 * sbasavapatna/rdma-core dv-upstream fork.
 */

#include <cmath>
#include <cstdio>
#include <cstring>

#include <hip/hip_runtime.h>

#include <dlfcn.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <unistd.h>

#include "bnxt/bnxt-dv-sizing.hpp"
#include "bnxt/bnxt-provider.hpp"
#include "gda-backend.hpp"
#include "ibv-wrapper.hpp"
#include "queue-pair.hpp"
#include "xio-rdma-check.h"
#include "xio.h"

namespace rdma_ep {

#define XIO_CHECK_ZERO(expr, msg)                                              \
  _XIO_CHECK_ZERO("rdma_ep::bnxt", (expr), (msg), return)
#define XIO_CHECK_NNULL(expr, msg)                                             \
  _XIO_CHECK_NNULL("rdma_ep::bnxt", (expr), (msg), return)

namespace {

using xio_rdma::dlsym_load;

bnxtdv_funcs_t bnxt_re_dv{};
void* bnxtdv_handle_ = nullptr;

} // anonymous namespace

#if defined(GDA_BNXT)

void* Backend::bnxt_dv_dlopen() {
  return xio_rdma::dv_dlopen("libbnxt_re.so", "rdma_ep::bnxt");
}

int Backend::bnxt_dv_dl_init() {
  bnxtdv_handle_ = bnxt_dv_dlopen();
  if (!bnxtdv_handle_)
    return -1;

#define LOAD(field, name)                                                      \
  if (dlsym_load(bnxt_re_dv.field, bnxtdv_handle_, name, "rdma_ep::bnxt") !=   \
      0)                                                                       \
    return -1;

  LOAD(create_qp, "bnxt_re_dv_create_qp");
  LOAD(destroy_qp, "bnxt_re_dv_destroy_qp");
  LOAD(modify_qp, "bnxt_re_dv_modify_qp");
  LOAD(create_cq, "bnxt_re_dv_create_cq");
  LOAD(destroy_cq, "bnxt_re_dv_destroy_cq");
  LOAD(umem_reg, "bnxt_re_dv_umem_reg");
  LOAD(umem_dereg, "bnxt_re_dv_umem_dereg");
  LOAD(alloc_db_region, "bnxt_re_dv_alloc_db_region");
  LOAD(free_db_region, "bnxt_re_dv_free_db_region");
  LOAD(get_default_db_region, "bnxt_re_dv_get_default_db_region");
  LOAD(get_cq_id, "bnxt_re_dv_get_cq_id");

#undef LOAD
  return 0;
}

/*
 * Helper: allocate a CQ buffer on GPU, register
 * it as a UMEM, and create a DV CQ.
 */
static void create_one_cq(bnxt_host_cq* hcq, struct ibv_context* ctx,
                          bnxtdv_funcs_t& dv, int ncqe, int dmabuf_enabled,
                          const char* label) {
  hcq->cqe_size = bnxt_sizing::cqe_size();
  hcq->depth = static_cast<uint32_t>(ncqe);
  hcq->length = hcq->depth * hcq->cqe_size;

  void* buf_ptr = nullptr;
  hsa_status_t ds = xio::allocDeviceMemory(hcq->length, &buf_ptr, label,
                                           XIO_DEVICE_MEM_UNCACHED);
  if (ds != HSA_STATUS_SUCCESS) {
    fprintf(stderr,
            "rdma_ep::bnxt: "
            "allocDeviceMemory %s "
            "failed\n",
            label);
    return;
  }
  hcq->buf = buf_ptr;
  (void)hipMemset(hcq->buf, 0, hcq->length);

  if (dmabuf_enabled) {
    int fd = -1;
    uint64_t offset = 0;
    hsa_status_t ds = xio::exportDmabuf(hcq->buf, hcq->length, &fd, &offset);
    if (ds != HSA_STATUS_SUCCESS || fd < 0) {
      fprintf(stderr,
              "rdma_ep::bnxt: exportDmabuf %s "
              "failed (status=%d), falling back "
              "to non-dmabuf path\n",
              label, ds);
      dmabuf_enabled = 0;
    } else {
      hcq->dmabuf_fd = fd;
      hcq->dmabuf_offset = offset;
    }
  }

  struct bnxt_re_dv_umem_reg_attr ua {};
  ua.size = hcq->length;
  ua.access_flags = IBV_ACCESS_LOCAL_WRITE;
  if (dmabuf_enabled) {
    ua.addr = reinterpret_cast<void*>(
      static_cast<uintptr_t>(hcq->dmabuf_offset));
    ua.comp_mask = BNXT_RE_DV_UMEM_FLAGS_DMABUF;
    ua.dmabuf_fd = hcq->dmabuf_fd;
  } else {
    ua.addr = hcq->buf;
  }

  hcq->umem = dv.umem_reg(ctx, &ua);
  if (!hcq->umem) {
    fprintf(stderr,
            "rdma_ep::bnxt: umem_reg %s "
            "failed\n",
            label);
    return;
  }

  struct bnxt_re_dv_cq_init_attr ca {};
  ca.umem_handle = hcq->umem;
  ca.cq_umem_offset = 0;
  ca.ncqe = hcq->depth;

  hcq->cq = dv.create_cq(ctx, &ca);
  if (!hcq->cq) {
    fprintf(stderr,
            "rdma_ep::bnxt: create_cq %s "
            "failed\n",
            label);
  }
}

void Backend::bnxt_create_cqs(int cqe) {
  int dmabuf = ibv.is_dmabuf_supported();

  cqe = 1; // CQE compression: 1 entry

  (void)xio::allocHostMemory(sizeof(bnxt_host_cq), (void**)&bnxt_scq_,
                             "BNXT SCQ", XIO_HOST_MEM_PLAIN);
  XIO_CHECK_NNULL(bnxt_scq_, "allocHostMemory (BNXT SCQ)");
  (void)xio::allocHostMemory(sizeof(bnxt_host_cq), (void**)&bnxt_rcq_,
                             "BNXT RCQ", XIO_HOST_MEM_PLAIN);
  XIO_CHECK_NNULL(bnxt_rcq_, "allocHostMemory (BNXT RCQ)");

  create_one_cq(bnxt_scq_, context_, bnxt_re_dv, cqe, dmabuf, "SCQ");
  XIO_CHECK_NNULL(bnxt_scq_->cq, "bnxt_re_dv_create_cq (SCQ)");

  create_one_cq(bnxt_rcq_, context_, bnxt_re_dv, cqe, dmabuf, "RCQ");
  XIO_CHECK_NNULL(bnxt_rcq_->cq, "bnxt_re_dv_create_cq (RCQ)");

  if (cq_) {
    ibv.destroy_cq(cq_);
    cq_ = nullptr;
  }
  cq_ = bnxt_scq_->cq;

  fprintf(stderr,
          "rdma_ep::bnxt: Created CQs "
          "(SCQ depth=%u, RCQ depth=%u)\n",
          bnxt_scq_->depth, bnxt_rcq_->depth);
}

void Backend::bnxt_create_qps(int sq_length) {
  struct bnxt_re_dv_umem_reg_attr umem_attr;

  (void)xio::allocHostMemory(sizeof(bnxt_host_qp), (void**)&bnxt_qp_, "BNXT QP",
                             XIO_HOST_MEM_PLAIN);
  XIO_CHECK_NNULL(bnxt_qp_, "allocHostMemory (BNXT QP)");

  uint32_t max_swr = static_cast<uint32_t>(sq_length);
  uint32_t max_ssge = 1;
  uint32_t max_ils = config_.inline_threshold;
  uint32_t max_rwr = 0;
  uint32_t max_rsge = 0;

  auto sq = bnxt_sizing::compute_sq(max_swr, max_ssge, max_ils);
  auto rq = bnxt_sizing::compute_rq(max_rwr, max_rsge);

  bnxt_qp_->sq_len = sq.len;
  bnxt_qp_->sq_slots = sq.slots;
  bnxt_qp_->sq_wqe_sz = sq.wqe_sz;
  bnxt_qp_->sq_psn_sz = sq.psn_sz;
  bnxt_qp_->sq_npsn = sq.npsn;
  bnxt_qp_->rq_len = rq.len;
  bnxt_qp_->rq_slots = rq.slots;
  bnxt_qp_->rq_wqe_sz = rq.wqe_sz;

  // --- SQ buffer: CPU-pinnable + GPU-accessible.
  //     Kernel QP path uses ib_umem_get which
  //     needs regular CPU pages (no VM_PFNMAP).
  //     hipHostMalloc uses device-file mmap which
  //     ib_umem_get can't pin.  Use posix_memalign
  //     + hipHostRegister instead. ---
  void* sq_ptr = nullptr;
  hipError_t herr = xio::allocHostMemory(bnxt_qp_->sq_len, &sq_ptr, "BNXT SQ",
                                         XIO_HOST_MEM_PINNED);
  if (herr != hipSuccess) {
    fprintf(stderr, "rdma_ep::bnxt: "
                    "allocHostMemory SQ failed\n");
    return;
  }
  bnxt_qp_->sq_buf = sq_ptr;

  // MSN table at end of SQ buffer
  uint64_t msn_bytes = (uint64_t)bnxt_qp_->sq_psn_sz * bnxt_qp_->sq_npsn;
  uint64_t msn_off = bnxt_qp_->sq_len - msn_bytes;
  bnxt_qp_->msntbl = (void*)((char*)sq_ptr + msn_off);
  bnxt_qp_->msn_tbl_sz = bnxt_qp_->sq_npsn;

  // Register SQ UMEM -- use GPU VA (not dmabuf)
  // because the kernel's QP creation path uses
  // the traditional VA-based ib_umem_get.
  memset(&umem_attr, 0, sizeof(umem_attr));
  umem_attr.addr = sq_ptr;
  umem_attr.size = bnxt_qp_->sq_len;
  umem_attr.access_flags = IBV_ACCESS_LOCAL_WRITE;

  auto* sq_umem = bnxt_re_dv.umem_reg(context_, &umem_attr);
  XIO_CHECK_NNULL(sq_umem, "bnxt_re_dv_umem_reg (SQ)");

  // --- RQ buffer: same approach as SQ. ---
  uint32_t rq_alloc = bnxt_qp_->rq_len;
  if (rq_alloc == 0) {
    long pgsz_long = sysconf(_SC_PAGESIZE);
    rq_alloc = (pgsz_long > 0) ? static_cast<uint32_t>(pgsz_long) : 4096;
    bnxt_qp_->rq_len = rq_alloc;
  }

  void* rq_ptr = nullptr;
  herr = xio::allocHostMemory(rq_alloc, &rq_ptr, "BNXT RQ",
                              XIO_HOST_MEM_PINNED);
  if (herr != hipSuccess) {
    fprintf(stderr, "rdma_ep::bnxt: "
                    "allocHostMemory RQ failed\n");
    return;
  }
  bnxt_qp_->rq_buf = rq_ptr;

  // Register RQ UMEM -- same VA approach as SQ.
  memset(&umem_attr, 0, sizeof(umem_attr));
  umem_attr.addr = rq_ptr;
  umem_attr.size = rq_alloc;
  umem_attr.access_flags = IBV_ACCESS_LOCAL_WRITE;

  auto* rq_umem = bnxt_re_dv.umem_reg(context_, &umem_attr);
  XIO_CHECK_NNULL(rq_umem, "bnxt_re_dv_umem_reg (RQ)");

  // Doorbell region -- try default first, then alloc
  (void)xio::allocHostMemory(sizeof(bnxt_re_dv_db_region_attr),
                             (void**)&bnxt_qp_->db_region_attr,
                             "BNXT DB region", XIO_HOST_MEM_PLAIN);
  XIO_CHECK_NNULL(bnxt_qp_->db_region_attr, "alloc db_region_attr");
  int dbr_rc = bnxt_re_dv.get_default_db_region(context_,
                                                bnxt_qp_->db_region_attr);
  if (dbr_rc != 0) {
    xio::freeHostMemory(bnxt_qp_->db_region_attr, XIO_HOST_MEM_PLAIN);
    bnxt_qp_->db_region_attr = bnxt_re_dv.alloc_db_region(context_);
    XIO_CHECK_NNULL(bnxt_qp_->db_region_attr, "bnxt_re_dv_alloc_db_region");
  }

  // Fill DV QP init attr
  memset(&bnxt_qp_->attr, 0, sizeof(bnxt_re_dv_qp_init_attr));
  bnxt_qp_->attr.send_cq = bnxt_scq_->cq;
  bnxt_qp_->attr.recv_cq = bnxt_rcq_->cq;
  bnxt_qp_->attr.max_send_wr = max_swr;
  bnxt_qp_->attr.max_recv_wr = max_rwr;
  bnxt_qp_->attr.max_send_sge = max_ssge;
  bnxt_qp_->attr.max_recv_sge = max_rsge;
  bnxt_qp_->attr.max_inline_data = max_ils;
  bnxt_qp_->attr.qp_type = IBV_QPT_RC;

  bnxt_qp_->attr.dbr_handle = bnxt_qp_->db_region_attr;
  bnxt_qp_->attr.sq_umem_handle = sq_umem;
  bnxt_qp_->attr.sq_umem_offset = 0;
  bnxt_qp_->attr.sq_len = bnxt_qp_->sq_len;
  bnxt_qp_->attr.sq_slots = bnxt_qp_->sq_slots;
  bnxt_qp_->attr.sq_wqe_sz = bnxt_qp_->sq_wqe_sz;
  bnxt_qp_->attr.sq_psn_sz = bnxt_qp_->sq_psn_sz;
  bnxt_qp_->attr.sq_npsn = bnxt_qp_->sq_npsn;
  bnxt_qp_->attr.rq_umem_handle = rq_umem;
  bnxt_qp_->attr.rq_umem_offset = 0;
  bnxt_qp_->attr.rq_len = bnxt_qp_->rq_len;
  bnxt_qp_->attr.rq_slots = bnxt_qp_->rq_slots;
  bnxt_qp_->attr.rq_wqe_sz = bnxt_qp_->rq_wqe_sz;

  if (qp_) {
    ibv.destroy_qp(qp_);
    qp_ = nullptr;
  }
  qp_ = bnxt_re_dv.create_qp(pd_, &bnxt_qp_->attr);
  XIO_CHECK_NNULL(qp_, "bnxt_re_dv_create_qp");

  fprintf(stderr,
          "rdma_ep::bnxt: Created QP via DV "
          "(QPN=%u, SQ slots=%u, SQ len=%u, "
          "MSN tbl sz=%u)\n",
          qp_->qp_num, bnxt_qp_->sq_slots, bnxt_qp_->sq_len,
          bnxt_qp_->msn_tbl_sz);
}

void Backend::bnxt_initialize_gpu_qp() {
  if (!host_qp_ || !bnxt_qp_ || !bnxt_scq_)
    return;

  uint32_t scq_id = bnxt_re_dv.get_cq_id(bnxt_scq_->cq);

  memset(&host_qp_->bnxt_cq_, 0, sizeof(bnxt_device_cq));
  host_qp_->bnxt_cq_.buf = bnxt_scq_->buf;
  host_qp_->bnxt_cq_.depth = bnxt_scq_->depth;
  host_qp_->bnxt_cq_.id = scq_id;

  memset(&host_qp_->bnxt_sq_, 0, sizeof(bnxt_device_sq));
  host_qp_->bnxt_sq_.buf = bnxt_qp_->sq_buf;
  host_qp_->bnxt_sq_.depth = bnxt_qp_->sq_slots;
  host_qp_->bnxt_sq_.id = qp_->qp_num;
  host_qp_->bnxt_sq_.msntbl = bnxt_qp_->msntbl;
  host_qp_->bnxt_sq_.msn_tbl_sz = bnxt_qp_->msn_tbl_sz;
  host_qp_->bnxt_sq_.psn_sz_log2 = static_cast<uint32_t>(
    std::log2(bnxt_qp_->sq_psn_sz));
  host_qp_->bnxt_sq_.mtu = ibv_mtu_to_int(port_attr_.active_mtu);

  hipError_t herr = hipHostRegister(bnxt_qp_->db_region_attr->dbr,
                                    getpagesize(), hipHostRegisterDefault);
  if (herr != hipSuccess) {
    fprintf(stderr,
            "rdma_ep::bnxt: "
            "hipHostRegister(dbr) failed: "
            "%s\n",
            hipGetErrorString(herr));
    return;
  }
  herr = hipHostGetDevicePointer((void**)&host_qp_->bnxt_dbr_,
                                 bnxt_qp_->db_region_attr->dbr, 0);
  if (herr != hipSuccess) {
    fprintf(stderr,
            "rdma_ep::bnxt: "
            "hipHostGetDevicePointer(dbr) "
            "failed: %s\n",
            hipGetErrorString(herr));
    return;
  }

  host_qp_->lkey_ = 0;
  host_qp_->rkey_ = 0;
  host_qp_->qp_num_ = qp_->qp_num;
  host_qp_->inline_threshold_ = config_.inline_threshold;

  fprintf(stderr,
          "rdma_ep::bnxt: GPU QP initialized "
          "(CQ id=%u, SQ depth=%u, "
          "SQ buf=%p, DB=%p, MTU=%lu)\n",
          host_qp_->bnxt_cq_.id, host_qp_->bnxt_sq_.depth,
          host_qp_->bnxt_sq_.buf, (void*)host_qp_->bnxt_dbr_,
          host_qp_->bnxt_sq_.mtu);
}

void Backend::bnxt_cleanup() {
  if (qp_ && bnxt_re_dv.destroy_qp) {
    bnxt_re_dv.destroy_qp(qp_);
    qp_ = nullptr;
  }

  if (bnxt_scq_ && bnxt_scq_->cq && bnxt_re_dv.destroy_cq) {
    if (cq_ == bnxt_scq_->cq)
      cq_ = nullptr;
    bnxt_re_dv.destroy_cq(bnxt_scq_->cq);
    bnxt_scq_->cq = nullptr;
  }
  if (bnxt_rcq_ && bnxt_rcq_->cq && bnxt_re_dv.destroy_cq) {
    bnxt_re_dv.destroy_cq(bnxt_rcq_->cq);
    bnxt_rcq_->cq = nullptr;
  }

  if (bnxt_re_dv.umem_dereg) {
    if (bnxt_qp_) {
      auto* sq_u = static_cast<bnxt_re_dv_umem*>(bnxt_qp_->attr.sq_umem_handle);
      auto* rq_u = static_cast<bnxt_re_dv_umem*>(bnxt_qp_->attr.rq_umem_handle);
      if (sq_u) {
        bnxt_re_dv.umem_dereg(sq_u);
        bnxt_qp_->attr.sq_umem_handle = nullptr;
      }
      if (rq_u) {
        bnxt_re_dv.umem_dereg(rq_u);
        bnxt_qp_->attr.rq_umem_handle = nullptr;
      }
    }
    if (bnxt_scq_ && bnxt_scq_->umem) {
      bnxt_re_dv.umem_dereg(bnxt_scq_->umem);
      bnxt_scq_->umem = nullptr;
    }
    if (bnxt_rcq_ && bnxt_rcq_->umem) {
      bnxt_re_dv.umem_dereg(bnxt_rcq_->umem);
      bnxt_rcq_->umem = nullptr;
    }
  }

  if (bnxt_qp_) {
    if (bnxt_qp_->db_region_attr) {
      if (bnxt_qp_->db_region_attr->dbr)
        (void)hipHostUnregister(bnxt_qp_->db_region_attr->dbr);
      xio::freeHostMemory(bnxt_qp_->db_region_attr, XIO_HOST_MEM_PLAIN);
      bnxt_qp_->db_region_attr = nullptr;
    }
    if (bnxt_qp_->sq_buf) {
      xio::freeHostMemory(bnxt_qp_->sq_buf, XIO_HOST_MEM_PINNED);
      bnxt_qp_->sq_buf = nullptr;
    }
    if (bnxt_qp_->rq_buf) {
      xio::freeHostMemory(bnxt_qp_->rq_buf, XIO_HOST_MEM_PINNED);
      bnxt_qp_->rq_buf = nullptr;
    }
    xio::freeHostMemory(bnxt_qp_, XIO_HOST_MEM_PLAIN);
    bnxt_qp_ = nullptr;
  }

  if (bnxt_scq_) {
    if (bnxt_scq_->buf)
      xio::freeDeviceMemory(bnxt_scq_->buf, XIO_DEVICE_MEM_UNCACHED);
    xio::freeHostMemory(bnxt_scq_, XIO_HOST_MEM_PLAIN);
    bnxt_scq_ = nullptr;
  }
  if (bnxt_rcq_) {
    if (bnxt_rcq_->buf)
      xio::freeDeviceMemory(bnxt_rcq_->buf, XIO_DEVICE_MEM_UNCACHED);
    xio::freeHostMemory(bnxt_rcq_, XIO_HOST_MEM_PLAIN);
    bnxt_rcq_ = nullptr;
  }
}

#endif // defined(GDA_BNXT)

int bnxt_dv_modify_qp(struct ibv_qp* qp, struct ibv_qp_attr* attr,
                      int attr_mask) {
  if (!bnxt_re_dv.modify_qp)
    return -1;
  return bnxt_re_dv.modify_qp(qp, attr, attr_mask);
}

#undef XIO_CHECK_ZERO
#undef XIO_CHECK_NNULL

} // namespace rdma_ep
