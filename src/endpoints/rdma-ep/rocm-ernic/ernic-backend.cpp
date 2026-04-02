/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * ROCm ERNIC Direct Verbs backend for rdma-ep.
 * Implements DV library loading, CQ/QP creation,
 * and GPU QP initialization for the rocm_ernic
 * RDMA provider.
 *
 * Modeled after bnxt/bnxt-backend.cpp.
 */

#include <cstdio>
#include <cstring>

#include <hip/hip_runtime.h>

#include <dlfcn.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <unistd.h>

#include "gda-backend.hpp"
#include "ibv-wrapper.hpp"
#include "queue-pair.hpp"
#include "rocm-ernic/ernic-provider.hpp"
#include "xio-rdma-check.h"
#include "xio.h"

namespace rdma_ep {

#define XIO_CHECK_ZERO(expr, msg)                                              \
  _XIO_CHECK_ZERO("rdma_ep::ernic", (expr), (msg), return)
#define XIO_CHECK_NNULL(expr, msg)                                             \
  _XIO_CHECK_NNULL("rdma_ep::ernic", (expr), (msg), return)

namespace {

using xio_rdma::dlsym_load;

ernicdv_funcs_t ernic_dv{};
void* ernicdv_handle_ = nullptr;

} // anonymous namespace

#if defined(GDA_ERNIC)

void* Backend::ernic_dv_dlopen() {
  return xio_rdma::dv_dlopen("librocm_ernic.so", "rdma_ep::ernic");
}

int Backend::ernic_dv_dl_init() {
  ernicdv_handle_ = ernic_dv_dlopen();
  if (!ernicdv_handle_)
    return -1;

#define LOAD(field, name)                                                      \
  if (dlsym_load(ernic_dv.field, ernicdv_handle_, name, "rdma_ep::ernic") !=   \
      0)                                                                       \
    return -1;

  LOAD(create_qp, "rocm_ernic_dv_create_qp");
  LOAD(destroy_qp, "rocm_ernic_dv_destroy_qp");
  LOAD(modify_qp, "rocm_ernic_dv_modify_qp");
  LOAD(create_cq, "rocm_ernic_dv_create_cq");
  LOAD(destroy_cq, "rocm_ernic_dv_destroy_cq");
  LOAD(umem_reg, "rocm_ernic_dv_umem_reg");
  LOAD(umem_dereg, "rocm_ernic_dv_umem_dereg");
  LOAD(get_cq_id, "rocm_ernic_dv_get_cq_id");
  LOAD(get_qp_attr, "rocm_ernic_dv_get_qp_attr");

#undef LOAD
  return 0;
}

static void create_one_cq(ernic_host_cq* hcq, struct ibv_context* ctx,
                          ernicdv_funcs_t& dv, int ncqe, int dmabuf_enabled,
                          const char* label) {
  hcq->cqe_size = 64;
  hcq->depth = static_cast<uint32_t>(ncqe);
  hcq->length = hcq->depth * hcq->cqe_size;

  /*
   * Allocate CQ buffer in system memory so the
   * emulated device server can DMA-map it.
   * GPU VRAM CQs (hipExtMallocWithFlags) would
   * require vfio-user DMA proxy support for GPU
   * BAR regions -- tracked for future work.
   */
  size_t pgsz = static_cast<size_t>(sysconf(_SC_PAGESIZE));
  size_t alloc_len = (hcq->length + pgsz - 1) & ~(pgsz - 1);
  if (alloc_len < pgsz)
    alloc_len = pgsz;

  void* buf_ptr = nullptr;
  hipError_t herr = xio::allocHostMemory(alloc_len, &buf_ptr, label,
                                         XIO_HOST_MEM_PINNED);
  if (herr != hipSuccess) {
    fprintf(stderr,
            "rdma_ep::ernic: "
            "allocHostMemory %s failed\n",
            label);
    return;
  }
  hcq->buf = buf_ptr;

  struct rocm_ernic_dv_umem_attr ua {};
  ua.addr = hcq->buf;
  ua.size = alloc_len;
  ua.access_flags = IBV_ACCESS_LOCAL_WRITE;
  ua.dmabuf_fd = -1;
  (void)dmabuf_enabled;

  hcq->umem = dv.umem_reg(ctx, &ua);
  if (!hcq->umem) {
    fprintf(stderr,
            "rdma_ep::ernic: umem_reg %s "
            "failed\n",
            label);
    return;
  }

  struct rocm_ernic_dv_cq_init_attr ca {};
  ca.umem_handle = hcq->umem;
  ca.ncqe = hcq->depth;

  hcq->cq = dv.create_cq(ctx, &ca);
  if (!hcq->cq) {
    fprintf(stderr,
            "rdma_ep::ernic: create_cq %s "
            "failed\n",
            label);
  }
}

void Backend::ernic_create_cqs(int cqe) {
  int dmabuf = ibv.is_dmabuf_supported();

  (void)xio::allocHostMemory(sizeof(ernic_host_cq), (void**)&ernic_scq_,
                             "ERNIC SCQ", XIO_HOST_MEM_PLAIN);
  XIO_CHECK_NNULL(ernic_scq_, "allocHostMemory (ERNIC SCQ)");
  (void)xio::allocHostMemory(sizeof(ernic_host_cq), (void**)&ernic_rcq_,
                             "ERNIC RCQ", XIO_HOST_MEM_PLAIN);
  XIO_CHECK_NNULL(ernic_rcq_, "allocHostMemory (ERNIC RCQ)");

  create_one_cq(ernic_scq_, context_, ernic_dv, cqe, dmabuf, "SCQ");
  XIO_CHECK_NNULL(ernic_scq_->cq, "ernic_dv_create_cq (SCQ)");

  create_one_cq(ernic_rcq_, context_, ernic_dv, cqe, dmabuf, "RCQ");
  XIO_CHECK_NNULL(ernic_rcq_->cq, "ernic_dv_create_cq (RCQ)");

  if (cq_) {
    ibv.destroy_cq(cq_);
    cq_ = nullptr;
  }
  cq_ = ernic_scq_->cq;

  fprintf(stderr,
          "rdma_ep::ernic: Created CQs "
          "(SCQ depth=%u, RCQ depth=%u)\n",
          ernic_scq_->depth, ernic_rcq_->depth);
}

void Backend::ernic_create_qps(int sq_length) {
  (void)xio::allocHostMemory(sizeof(ernic_host_qp), (void**)&ernic_qp_,
                             "ERNIC QP", XIO_HOST_MEM_PLAIN);
  XIO_CHECK_NNULL(ernic_qp_, "allocHostMemory (ERNIC QP)");

  uint32_t max_swr = static_cast<uint32_t>(sq_length);
  uint32_t max_ssge = 1;
  uint32_t max_ils = config_.inline_threshold;
  uint32_t max_rwr = 0;
  uint32_t max_rsge = 0;

  size_t pgsz = static_cast<size_t>(sysconf(_SC_PAGESIZE));
  uint32_t sq_wqe_sz = 128;
  ernic_qp_->sq_depth = max_swr;
  ernic_qp_->sq_wqe_size = sq_wqe_sz;
  ernic_qp_->sq_len = max_swr * sq_wqe_sz;
  if (ernic_qp_->sq_len < pgsz)
    ernic_qp_->sq_len = static_cast<uint32_t>(pgsz);
  ernic_qp_->sq_len += static_cast<uint32_t>(pgsz);

  uint32_t rq_wqe_sz = 64;
  ernic_qp_->rq_depth = max_rwr ? max_rwr : 1;
  ernic_qp_->rq_wqe_size = rq_wqe_sz;
  ernic_qp_->rq_len = ernic_qp_->rq_depth * rq_wqe_sz;
  if (ernic_qp_->rq_len < pgsz)
    ernic_qp_->rq_len = static_cast<uint32_t>(pgsz);

  void* sq_ptr = nullptr;
  hipError_t herr = xio::allocHostMemory(ernic_qp_->sq_len, &sq_ptr, "ERNIC SQ",
                                         XIO_HOST_MEM_PINNED);
  if (herr != hipSuccess) {
    fprintf(stderr, "rdma_ep::ernic: "
                    "allocHostMemory SQ failed\n");
    return;
  }
  ernic_qp_->sq_buf = sq_ptr;

  struct rocm_ernic_dv_umem_attr sq_ua {};
  sq_ua.addr = sq_ptr;
  sq_ua.size = ernic_qp_->sq_len;
  sq_ua.access_flags = IBV_ACCESS_LOCAL_WRITE;
  sq_ua.dmabuf_fd = -1;

  auto* sq_umem = ernic_dv.umem_reg(context_, &sq_ua);
  XIO_CHECK_NNULL(sq_umem, "ernic_dv_umem_reg (SQ)");

  void* rq_ptr = nullptr;
  herr = xio::allocHostMemory(ernic_qp_->rq_len, &rq_ptr, "ERNIC RQ",
                              XIO_HOST_MEM_PINNED);
  if (herr != hipSuccess) {
    fprintf(stderr, "rdma_ep::ernic: "
                    "allocHostMemory RQ failed\n");
    return;
  }
  ernic_qp_->rq_buf = rq_ptr;

  struct rocm_ernic_dv_umem_attr rq_ua {};
  rq_ua.addr = rq_ptr;
  rq_ua.size = ernic_qp_->rq_len;
  rq_ua.access_flags = IBV_ACCESS_LOCAL_WRITE;
  rq_ua.dmabuf_fd = -1;

  auto* rq_umem = ernic_dv.umem_reg(context_, &rq_ua);
  XIO_CHECK_NNULL(rq_umem, "ernic_dv_umem_reg (RQ)");

  memset(&ernic_qp_->attr, 0, sizeof(ernic_qp_->attr));
  ernic_qp_->attr.send_cq = ernic_scq_->cq;
  ernic_qp_->attr.recv_cq = ernic_rcq_->cq;
  ernic_qp_->attr.max_send_wr = max_swr;
  ernic_qp_->attr.max_recv_wr = max_rwr;
  ernic_qp_->attr.max_send_sge = max_ssge;
  ernic_qp_->attr.max_recv_sge = max_rsge;
  ernic_qp_->attr.max_inline_data = max_ils;
  ernic_qp_->attr.qp_type = IBV_QPT_RC;
  ernic_qp_->attr.sq_umem_handle = sq_umem;
  ernic_qp_->attr.sq_len = ernic_qp_->sq_len;
  ernic_qp_->attr.sq_wqe_size = ernic_qp_->sq_wqe_size;
  ernic_qp_->attr.rq_umem_handle = rq_umem;
  ernic_qp_->attr.rq_len = ernic_qp_->rq_len;
  ernic_qp_->attr.rq_wqe_size = ernic_qp_->rq_wqe_size;

  if (qp_) {
    ibv.destroy_qp(qp_);
    qp_ = nullptr;
  }
  qp_ = ernic_dv.create_qp(pd_, &ernic_qp_->attr);
  XIO_CHECK_NNULL(qp_, "ernic_dv_create_qp");

  struct rocm_ernic_dv_qp_attr qp_attr {};
  ernic_dv.get_qp_attr(qp_, &qp_attr);
  ernic_qp_->uar_ptr = qp_attr.uar_ptr;
  ernic_qp_->uar_mmap_offset = qp_attr.uar_mmap_offset;
  ernic_qp_->uar_qp_offset = qp_attr.uar_qp_offset;
  ernic_qp_->uar_cq_offset = qp_attr.uar_cq_offset;
  ernic_qp_->qp_handle = qp_attr.qp_handle;

  fprintf(stderr,
          "rdma_ep::ernic: Created QP via DV "
          "(QPN=%u, SQ depth=%u, "
          "SQ len=%u)\n",
          qp_->qp_num, ernic_qp_->sq_depth, ernic_qp_->sq_len);
}

void Backend::ernic_initialize_gpu_qp() {
  if (!host_qp_ || !ernic_qp_ || !ernic_scq_)
    return;

  (void)ernic_dv.get_cq_id(ernic_scq_->cq);

  memset(&host_qp_->ernic_cq_, 0, sizeof(ernic_device_cq));
  host_qp_->ernic_cq_.buf = ernic_scq_->buf;
  host_qp_->ernic_cq_.depth = ernic_scq_->depth;
  host_qp_->ernic_cq_.cqe_size = ernic_scq_->cqe_size;

  memset(&host_qp_->ernic_sq_, 0, sizeof(ernic_device_sq));
  host_qp_->ernic_sq_.buf = (char*)ernic_qp_->sq_buf + sysconf(_SC_PAGESIZE);
  host_qp_->ernic_sq_.sq_ring_prod_tail = (volatile int32_t*)ernic_qp_->sq_buf;

  {
    char res_path[256];
    snprintf(res_path, sizeof(res_path),
             "/sys/class/infiniband/%s/device/resource",
             ibv.get_device_name(device_));
    FILE* rf = fopen(res_path, "r");
    unsigned long bar2_base = 0;
    if (rf) {
      unsigned long s, e, f;
      fscanf(rf, "%lx %lx %lx", &s, &e, &f);
      fscanf(rf, "%lx %lx %lx", &s, &e, &f);
      fscanf(rf, "%lx %lx %lx", &bar2_base, &e, &f);
      fclose(rf);
    }
    if (bar2_base && ernic_qp_->uar_mmap_offset >= bar2_base) {
      uint64_t bar_off64 = (ernic_qp_->uar_mmap_offset - bar2_base) +
                           ernic_qp_->uar_qp_offset;
      if (bar_off64 > UINT32_MAX) {
        fprintf(stderr,
                "rdma_ep::ernic: UAR BAR2 offset "
                "0x%lx exceeds 32-bit range, "
                "MMIO bridge disabled\n",
                (unsigned long)bar_off64);
      } else {
        host_qp_->ernic_sq_.uar_bar_offset = (uint32_t)bar_off64;
        fprintf(stderr,
                "rdma_ep::ernic: UAR BAR2 offset=0x%x "
                "(mmap=0x%lx, bar2=0x%lx, qp_off=0x%x)\n",
                host_qp_->ernic_sq_.uar_bar_offset,
                (unsigned long)ernic_qp_->uar_mmap_offset, bar2_base,
                ernic_qp_->uar_qp_offset);
      }
    }
  }
  host_qp_->ernic_sq_.depth = ernic_qp_->sq_depth;
  host_qp_->ernic_sq_.wqe_size = ernic_qp_->sq_wqe_size;
  host_qp_->ernic_sq_.qpn = qp_->qp_num;
  host_qp_->ernic_sq_.qp_handle = ernic_qp_->qp_handle;
  host_qp_->ernic_sq_.mtu = ibv_mtu_to_int(port_attr_.active_mtu);

  if (ernic_qp_->uar_ptr) {
    hipError_t herr = hipHostRegister(ernic_qp_->uar_ptr, getpagesize(),
                                      hipHostRegisterDefault);
    if (herr != hipSuccess) {
      fprintf(stderr,
              "rdma_ep::ernic: "
              "hipHostRegister(uar) "
              "failed: %s\n",
              hipGetErrorString(herr));
      return;
    }
    void* dev_uar = nullptr;
    herr = hipHostGetDevicePointer(&dev_uar, ernic_qp_->uar_ptr, 0);
    if (herr != hipSuccess) {
      fprintf(stderr,
              "rdma_ep::ernic: "
              "hipHostGetDevicePointer(uar) "
              "failed: %s\n",
              hipGetErrorString(herr));
      return;
    }
    host_qp_->ernic_sq_.uar_ptr = static_cast<volatile uint32_t*>(dev_uar);
    host_qp_->ernic_sq_.uar_qp_offset = ernic_qp_->uar_qp_offset;
  }

  if (config_.pci_mmio_bridge) {
    uint16_t bridge_bdf = 0;
    int bret = xio::detectPciMmioBridgeBdf(&bridge_bdf);
    if (bret != 0) {
      fprintf(stderr,
              "rdma_ep::ernic: "
              "xio::detectPciMmioBridgeBdf failed: %d\n",
              bret);
    } else {
      void* shadow_cpu = nullptr;
      bret = xio::mapMmioBridgeShadowBuffer(bridge_bdf, &shadow_cpu);
      if (bret != 0 || !shadow_cpu) {
        fprintf(stderr,
                "rdma_ep::ernic: "
                "xio::mapMmioBridgeShadowBuffer failed: %d\n",
                bret);
      } else {
        const size_t shadow_size = 8192;
        void* shadow_gpu = nullptr;
        int rreg = xio::registerMmioBridgeShadowBufferForGpu(shadow_cpu,
                                                             shadow_size,
                                                             &shadow_gpu);
        if (rreg != 0 || !shadow_gpu) {
          fprintf(stderr,
                  "rdma_ep::ernic: "
                  "registerMmioBridgeShadowBufferForGpu "
                  "failed: %d\n",
                  rreg);
        } else {
          char sysfs_link[256];
          snprintf(sysfs_link, sizeof(sysfs_link),
                   "/sys/class/infiniband/%s/device",
                   ibv.get_device_name(device_));
          char link_buf[256];
          ssize_t llen = readlink(sysfs_link, link_buf, sizeof(link_buf) - 1);
          uint16_t ernic_bdf = 0;
          if (llen > 0) {
            link_buf[llen] = '\0';
            const char* p = strrchr(link_buf, '/');
            if (p)
              p++;
            else
              p = link_buf;
            unsigned b = 0, d = 0, f = 0;
            if (sscanf(p, "%*x:%x:%x.%x", &b, &d, &f) == 3)
              ernic_bdf = (uint16_t)((b << 8) | (d << 3) | f);
          }

          if (ernic_bdf == 0 || host_qp_->ernic_sq_.uar_bar_offset == 0) {
            fprintf(stderr,
                    "rdma_ep::ernic: pci-mmio-bridge "
                    "cannot enable: ernic_bdf=0x%04x, "
                    "uar_bar_offset=0x%x "
                    "(sysfs resolution failed)\n",
                    ernic_bdf, host_qp_->ernic_sq_.uar_bar_offset);
          } else {
            host_qp_->ernic_sq_.use_mmio_bridge = true;
            host_qp_->ernic_sq_.mmio_bridge_shadow = shadow_gpu;
            host_qp_->ernic_sq_.ernic_target_bdf = ernic_bdf;
            fprintf(stderr,
                    "rdma_ep::ernic: pci-mmio-bridge "
                    "enabled (bridge=0x%04x, "
                    "ernic=0x%04x, shadow=%p)\n",
                    bridge_bdf, ernic_bdf, shadow_gpu);
          }
        }
      }
    }
  }

  host_qp_->lkey_ = 0;
  host_qp_->rkey_ = 0;
  host_qp_->qp_num_ = qp_->qp_num;
  host_qp_->inline_threshold_ = config_.inline_threshold;

  fprintf(stderr,
          "rdma_ep::ernic: GPU QP initialized "
          "(CQ depth=%u, SQ depth=%u, "
          "SQ buf=%p, UAR=%p)\n",
          host_qp_->ernic_cq_.depth, host_qp_->ernic_sq_.depth,
          host_qp_->ernic_sq_.buf, (void*)host_qp_->ernic_sq_.uar_ptr);
}

int ernic_dv_modify_qp(struct ibv_qp* qp, struct ibv_qp_attr* attr,
                       int attr_mask) {
  if (!ernic_dv.modify_qp)
    return -1;
  return ernic_dv.modify_qp(qp, attr, attr_mask);
}

#endif // defined(GDA_ERNIC)

#undef XIO_CHECK_ZERO
#undef XIO_CHECK_NNULL

} // namespace rdma_ep
