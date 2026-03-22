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
#include "xio.h"

namespace rdma_ep {

#define XIO_CHECK_ZERO(expr, msg)                                              \
  do {                                                                         \
    int _err = (expr);                                                         \
    if (_err != 0) {                                                           \
      fprintf(stderr,                                                          \
              "rdma_ep::ernic: %s failed: "                                    \
              "%d at %s:%d\n",                                                 \
              (msg), _err, __FILE__, __LINE__);                                \
      return;                                                                  \
    }                                                                          \
  } while (0)

#define XIO_CHECK_NNULL(expr, msg)                                             \
  do {                                                                         \
    if (!(expr)) {                                                             \
      fprintf(stderr,                                                          \
              "rdma_ep::ernic: %s returned "                                   \
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
            "rdma_ep::ernic: dlsym failed for "
            "%s: %s\n",
            name, dlerror());
    return -1;
  }
  return 0;
}

ernicdv_funcs_t ernic_dv{};
void* ernicdv_handle_ = nullptr;

} // anonymous namespace

#if defined(GDA_ERNIC)

void* Backend::ernic_dv_dlopen() {
  constexpr int flags = RTLD_LAZY | RTLD_DEEPBIND;
  void* handle = nullptr;
#ifdef RDMA_CORE_LIB_DIR
  handle = dlopen(RDMA_CORE_LIB_DIR "/librocm_ernic.so", flags);
#endif
  if (!handle)
    handle = dlopen("librocm_ernic.so", flags);
  if (!handle)
    handle = dlopen("/usr/local/lib/librocm_ernic.so", flags);
  if (!handle)
    fprintf(stderr,
            "rdma_ep::ernic: Could not open "
            "librocm_ernic.so: %s\n",
            dlerror());
  return handle;
}

int Backend::ernic_dv_dl_init() {
  ernicdv_handle_ = ernic_dv_dlopen();
  if (!ernicdv_handle_)
    return -1;

#define LOAD(field, name)                                                      \
  if (dlsym_load(ernic_dv.field, ernicdv_handle_, name) != 0)                  \
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

  void* buf_ptr = nullptr;
  hipError_t herr = hipExtMallocWithFlags(&buf_ptr, hcq->length,
                                          hipDeviceMallocUncached);
  if (herr != hipSuccess) {
    fprintf(stderr,
            "rdma_ep::ernic: "
            "hipExtMallocWithFlags %s "
            "failed: %s\n",
            label, hipGetErrorString(herr));
    return;
  }
  hcq->buf = buf_ptr;
  (void)hipMemset(hcq->buf, 0, hcq->length);

  struct rocm_ernic_dv_umem_attr ua {};
  ua.addr = hcq->buf;
  ua.size = hcq->length;
  ua.access_flags = IBV_ACCESS_LOCAL_WRITE;
  ua.dmabuf_fd = -1;

  if (dmabuf_enabled) {
    uint64_t offset = 0;
    int fd = -1;
    hsa_amd_portable_export_dmabuf(hcq->buf, hcq->length, &fd, &offset);
    hcq->dmabuf_fd = fd;
    ua.dmabuf_fd = fd;
    ua.addr = reinterpret_cast<void*>(static_cast<uintptr_t>(offset));
    ua.comp_mask = ROCM_ERNIC_DV_UMEM_FLAGS_DMABUF;
  }

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

  ernic_scq_ = static_cast<ernic_host_cq*>(calloc(1, sizeof(ernic_host_cq)));
  ernic_rcq_ = static_cast<ernic_host_cq*>(calloc(1, sizeof(ernic_host_cq)));

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
  ernic_qp_ = static_cast<ernic_host_qp*>(calloc(1, sizeof(ernic_host_qp)));

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

  uint32_t rq_wqe_sz = 64;
  ernic_qp_->rq_depth = max_rwr ? max_rwr : 1;
  ernic_qp_->rq_wqe_size = rq_wqe_sz;
  ernic_qp_->rq_len = ernic_qp_->rq_depth * rq_wqe_sz;
  if (ernic_qp_->rq_len < pgsz)
    ernic_qp_->rq_len = static_cast<uint32_t>(pgsz);

  void* sq_ptr = nullptr;
  if (posix_memalign(&sq_ptr, pgsz, ernic_qp_->sq_len)) {
    fprintf(stderr, "rdma_ep::ernic: "
                    "posix_memalign SQ failed\n");
    return;
  }
  memset(sq_ptr, 0, ernic_qp_->sq_len);
  hipError_t herr = hipHostRegister(sq_ptr, ernic_qp_->sq_len,
                                    hipHostRegisterDefault);
  if (herr != hipSuccess) {
    fprintf(stderr,
            "rdma_ep::ernic: "
            "hipHostRegister SQ failed: %s\n",
            hipGetErrorString(herr));
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
  if (posix_memalign(&rq_ptr, pgsz, ernic_qp_->rq_len)) {
    fprintf(stderr, "rdma_ep::ernic: "
                    "posix_memalign RQ failed\n");
    return;
  }
  memset(rq_ptr, 0, ernic_qp_->rq_len);
  herr = hipHostRegister(rq_ptr, ernic_qp_->rq_len, hipHostRegisterDefault);
  if (herr != hipSuccess) {
    fprintf(stderr,
            "rdma_ep::ernic: "
            "hipHostRegister RQ failed: %s\n",
            hipGetErrorString(herr));
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
  ernic_qp_->uar_qp_offset = qp_attr.uar_qp_offset;
  ernic_qp_->uar_cq_offset = qp_attr.uar_cq_offset;

  fprintf(stderr,
          "rdma_ep::ernic: Created QP via DV "
          "(QPN=%u, SQ depth=%u, "
          "SQ len=%u)\n",
          qp_->qp_num, ernic_qp_->sq_depth, ernic_qp_->sq_len);
}

int Backend::ernic_init_mmio_bridge() {
  if (!config_.pci_mmio_bridge)
    return 0;

  uint16_t bdf = 0;
  int ret = xio::detectPciMmioBridgeBdf(&bdf);
  if (ret != 0) {
    fprintf(stderr,
            "rdma_ep::ernic: "
            "detectPciMmioBridgeBdf failed\n");
    return -1;
  }
  mmio_bridge_bdf_ = bdf;

  void* shadow_virt = nullptr;
  ret = xio::mapMmioBridgeShadowBuffer(
      bdf, &shadow_virt);
  if (ret != 0) {
    fprintf(stderr,
            "rdma_ep::ernic: "
            "mapMmioBridgeShadowBuffer failed\n");
    return -1;
  }

  void* shadow_gpu = nullptr;
  ret = xio::registerMmioBridgeShadowBufferForGpu(
      shadow_virt, 4096, &shadow_gpu);
  if (ret != 0) {
    fprintf(stderr,
            "rdma_ep::ernic: "
            "registerMmioBridgeShadowBufferForGpu"
            " failed\n");
    return -1;
  }
  mmio_shadow_gpu_ = shadow_gpu;

  fprintf(stderr,
          "rdma_ep::ernic: MMIO bridge ready "
          "(BDF=0x%04x, shadow=%p)\n",
          mmio_bridge_bdf_,
          mmio_shadow_gpu_);
  return 0;
}

void Backend::ernic_initialize_gpu_qp() {
  if (!host_qp_ || !ernic_qp_ || !ernic_scq_)
    return;

  (void)ernic_dv.get_cq_id(ernic_scq_->cq);

  memset(&host_qp_->ernic_cq_, 0,
         sizeof(ernic_device_cq));
  host_qp_->ernic_cq_.buf = ernic_scq_->buf;
  host_qp_->ernic_cq_.depth = ernic_scq_->depth;
  host_qp_->ernic_cq_.cqe_size =
      ernic_scq_->cqe_size;

  memset(&host_qp_->ernic_sq_, 0,
         sizeof(ernic_device_sq));
  host_qp_->ernic_sq_.buf = ernic_qp_->sq_buf;
  host_qp_->ernic_sq_.depth = ernic_qp_->sq_depth;
  host_qp_->ernic_sq_.wqe_size =
      ernic_qp_->sq_wqe_size;
  host_qp_->ernic_sq_.qpn = qp_->qp_num;
  host_qp_->ernic_sq_.mtu =
      ibv_mtu_to_int(port_attr_.active_mtu);

  host_qp_->ernic_sq_.use_mmio_bridge =
      config_.pci_mmio_bridge && mmio_shadow_gpu_;
  host_qp_->ernic_sq_.mmio_shadow_buf =
      mmio_shadow_gpu_;
  host_qp_->ernic_sq_.uar_bar_index = 2;

  if (host_qp_->ernic_sq_.use_mmio_bridge) {
    uint16_t ernic_bdf = 0;
    const char* ib_name =
        ibv.get_device_name(device_);
    char link[512];
    char resolved[512];
    snprintf(link, sizeof(link),
             "/sys/class/infiniband/%s/device",
             ib_name);
    ssize_t len = readlink(link, resolved,
                           sizeof(resolved) - 1);
    if (len > 0) {
      resolved[len] = '\0';
      const char* base = strrchr(resolved, '/');
      if (base)
        base++;
      else
        base = resolved;
      unsigned bus = 0, dev = 0, func = 0;
      if (sscanf(base, "%*x:%x:%x.%x",
                 &bus, &dev, &func) == 3) {
        ernic_bdf =
            (static_cast<uint16_t>(bus) << 8) |
            (static_cast<uint16_t>(dev) << 3) |
            static_cast<uint16_t>(func);
        host_qp_->ernic_sq_.ernic_target_bdf =
            ernic_bdf;
        fprintf(stderr,
                "rdma_ep::ernic: ERNIC PCI "
                "BDF=0x%04x (%s)\n",
                ernic_bdf, base);
      } else {
        fprintf(stderr,
                "rdma_ep::ernic: "
                "BDF parse failed: %s\n",
                base);
        host_qp_->ernic_sq_.use_mmio_bridge =
            false;
      }
    } else {
      fprintf(stderr,
              "rdma_ep::ernic: "
              "readlink failed for %s\n",
              link);
      host_qp_->ernic_sq_.use_mmio_bridge = false;
    }
  }

  if (!host_qp_->ernic_sq_.use_mmio_bridge &&
      ernic_qp_->uar_ptr) {
    hipError_t herr = hipHostRegister(
        ernic_qp_->uar_ptr, getpagesize(),
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
    herr = hipHostGetDevicePointer(
        &dev_uar, ernic_qp_->uar_ptr, 0);
    if (herr != hipSuccess) {
      fprintf(stderr,
              "rdma_ep::ernic: "
              "hipHostGetDevicePointer(uar) "
              "failed: %s\n",
              hipGetErrorString(herr));
      return;
    }
    host_qp_->ernic_sq_.uar_ptr =
        static_cast<volatile uint32_t*>(dev_uar);
    host_qp_->ernic_sq_.uar_qp_offset =
        ernic_qp_->uar_qp_offset;
  }

  host_qp_->lkey_ = 0;
  host_qp_->rkey_ = 0;
  host_qp_->qp_num_ = qp_->qp_num;
  host_qp_->inline_threshold_ =
      config_.inline_threshold;

  fprintf(stderr,
          "rdma_ep::ernic: GPU QP initialized "
          "(CQ depth=%u, SQ depth=%u, "
          "SQ buf=%p, UAR=%p, "
          "mmio_bridge=%s)\n",
          host_qp_->ernic_cq_.depth,
          host_qp_->ernic_sq_.depth,
          host_qp_->ernic_sq_.buf,
          (void*)host_qp_->ernic_sq_.uar_ptr,
          host_qp_->ernic_sq_.use_mmio_bridge
              ? "yes"
              : "no");
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
