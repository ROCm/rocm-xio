/*
 * SPDX-License-Identifier: GPL-2.0
 *
 * rocm-xio fio engine — HIP/C++ translation unit
 *
 * Include ordering note
 * ---------------------
 * xio.h → xio-endpoint-includes-gen.h → nvme-ep.h creates a circular
 * dependency before xioBufferInfo/XioEndpointConfig are defined.
 * Workaround: pre-define NVME_EP_H to skip the auto-include, then
 * include nvme-ep.h explicitly after xio.h has fully expanded.
 */

#include <hip/hip_runtime.h>

#include "rocm-xio-hip.h"

#ifndef __HIP_DEVICE_COMPILE__

#include <cerrno>
#include <cstdlib>
#include <cstring>

#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>

#define NVME_EP_H
#if __has_include(<rocm-xio/xio.h>)
#include <rocm-xio/xio.h>
#else
#include <xio.h>
#endif
#undef NVME_EP_H
#if __has_include(<rocm-xio/nvme-ep.h>)
#include <rocm-xio/nvme-ep.h>
#else
#include <nvme-ep.h>
#endif

/* ------------------------------------------------------------------ */
/* Shared BAR0 cache — avoids re-mapping the same physical region     */
/* from multiple fio threads for the same NVMe controller.            */
/* ------------------------------------------------------------------ */

#define RXIO_BAR0_CACHE_MAX 8
static struct {
  pthread_mutex_t lock;
  struct {
    uint32_t bdf;
    void* bar0_cpu;
    void* bar0_gpu;
    int ref;
  } entries[RXIO_BAR0_CACHE_MAX];
} s_bar0_cache = {PTHREAD_MUTEX_INITIALIZER};

static int bar0_get(uint32_t bdf, void** cpu_out, void** gpu_out) {
  pthread_mutex_lock(&s_bar0_cache.lock);
  for (int i = 0; i < RXIO_BAR0_CACHE_MAX; i++) {
    auto& e = s_bar0_cache.entries[i];
    if (e.ref > 0 && e.bdf == bdf) {
      *cpu_out = e.bar0_cpu;
      *gpu_out = e.bar0_gpu;
      e.ref++;
      pthread_mutex_unlock(&s_bar0_cache.lock);
      return 0;
    }
  }
  /* Not cached — map it */
  void *cpu = nullptr, *gpu = nullptr;
  int rc = xio::mapPciBar(bdf, 0, &cpu, &gpu, 8192);
  if (rc < 0) {
    pthread_mutex_unlock(&s_bar0_cache.lock);
    return rc;
  }
  for (int i = 0; i < RXIO_BAR0_CACHE_MAX; i++) {
    auto& e = s_bar0_cache.entries[i];
    if (e.ref == 0) {
      e.bdf = bdf;
      e.bar0_cpu = cpu;
      e.bar0_gpu = gpu;
      e.ref = 1;
      break;
    }
  }
  *cpu_out = cpu;
  *gpu_out = gpu;
  pthread_mutex_unlock(&s_bar0_cache.lock);
  return 0;
}

static void bar0_put(uint32_t bdf) {
  pthread_mutex_lock(&s_bar0_cache.lock);
  for (int i = 0; i < RXIO_BAR0_CACHE_MAX; i++) {
    auto& e = s_bar0_cache.entries[i];
    if (e.ref > 0 && e.bdf == bdf) {
      e.ref--;
      break;
    }
  }
  pthread_mutex_unlock(&s_bar0_cache.lock);
}

/* ------------------------------------------------------------------ */
/* Per-queue context                                                   */
/* ------------------------------------------------------------------ */

struct rxio_queue_ctx {
  char controller[256];
  uint32_t nvme_bdf;
  uint32_t nsid;
  unsigned lba_size;
  uint64_t ns_capacity_lbas;
  uint16_t queue_id;
  uint16_t queue_size;
  int kmod_fd;
  int nvme_fd;

  struct nvme_queue_info qi;

  /* GPU data buffer — batch_cap slots of single_buf_size each */
  xio::xioBufferInfo data_buf;
  size_t single_buf_size;
  int batch_cap;

  /* PRP pool — one 4KB page per slot */
  void* prp_pool_cpu;
  void* prp_pool_gpu;
  size_t prp_pool_bytes;
  uint64_t prp_pool_dma;

  void* bar0_cpu;
  void* bar0_gpu;

  xio::nvme_ep::nvmeDoorbellParams doorbell;
  xio::nvme_ep::nvmeBufferParams buf_params_template;
  xio::XioEndpointConfig ep_cfg;

  hipStream_t stream;

  /*
   * Persistent NVMe queue state (shared by stateful and persistent paths).
   * state[0] = sq_tail(lo16) | cq_head(hi16); state[1] = expected_phase.
   */
  volatile uint32_t* queue_state_cpu;
  volatile uint32_t* queue_state_gpu;

  /* Persistent-kernel work ring (CPU→GPU) */
  xio::nvme_ep::nvmeWorkItem* work_ring_cpu;
  xio::nvme_ep::nvmeWorkItem* work_ring_gpu;
  volatile uint32_t* stop_flag_cpu;
  volatile uint32_t* stop_flag_gpu;
  uint32_t ring_depth;
  uint32_t prod_idx; /* CPU producer monotonic index */
  uint32_t cons_idx; /* CPU consumer (reap) index */
  bool persistent;

  char ns_path[256];
  bool quiesced;
};

/* ------------------------------------------------------------------ */
/* Lifecycle                                                           */
/* ------------------------------------------------------------------ */

extern "C" struct rxio_queue_ctx* rxio_ctx_alloc(void) {
  struct rxio_queue_ctx* ctx = (struct rxio_queue_ctx*)calloc(1, sizeof(*ctx));
  if (ctx)
    ctx->kmod_fd = -1;
  return ctx;
}

extern "C" void rxio_ctx_free(struct rxio_queue_ctx* ctx) {
  free(ctx);
}

/* ------------------------------------------------------------------ */
/* rxio_setup                                                          */
/* ------------------------------------------------------------------ */

extern "C" int rxio_setup(struct rxio_queue_ctx* ctx, const char* controller,
                          uint16_t queue_id, uint16_t queue_size,
                          size_t buf_size, size_t single_size, int batch_cap,
                          unsigned memory_mode, int gpu_id, int job_index) {
  int rc;

  if (!ctx || !controller)
    return -EINVAL;

  strncpy(ctx->controller, controller, sizeof(ctx->controller) - 1);
  ctx->queue_id = queue_id;
  ctx->queue_size = queue_size;
  ctx->nsid = 1;
  ctx->batch_cap = (batch_cap < 1) ? 1 : batch_cap;

  ctx->single_buf_size = (single_size + 4095) & ~(size_t)4095;
  if (!ctx->single_buf_size)
    ctx->single_buf_size = 4096;

  hipError_t herr = hipSetDevice(gpu_id);
  if (herr != hipSuccess) {
    fprintf(stderr, "rxio: hipSetDevice(%d): %s\n", gpu_id,
            hipGetErrorString(herr));
    return -EIO;
  }

  rc = xio::detectBdfFromDevice(controller, &ctx->nvme_bdf);
  if (rc < 0) {
    fprintf(stderr, "rxio: detectBdf: %d\n", rc);
    return rc;
  }

  rc = xio::nvme_ep::queryLbaSize(controller, ctx->nsid, &ctx->lba_size);
  if (rc < 0 || !ctx->lba_size) {
    fprintf(stderr, "rxio: queryLbaSize: %d\n", rc);
    return rc < 0 ? rc : -EIO;
  }

  rc = xio::nvme_ep::queryNamespaceCapacity(controller, ctx->nsid,
                                            &ctx->ns_capacity_lbas);
  if (rc < 0) {
    fprintf(stderr, "rxio: queryNsCap: %d\n", rc);
    return rc;
  }

  if (!queue_id) {
    uint16_t max_qid = 0;
    rc = xio::nvme_ep::queryMaxQueueId(controller, &max_qid);
    if (rc < 0) {
      fprintf(stderr, "rxio: queryMaxQid: %d\n", rc);
      return rc;
    }
    if (job_index < 0)
      job_index = 0;
    if ((uint16_t)job_index >= max_qid) {
      fprintf(stderr, "rxio: job_index %d >= max_qid %u\n", job_index, max_qid);
      return -ERANGE;
    }
    ctx->queue_id = max_qid - (uint16_t)job_index;
  }

  ctx->kmod_fd = open(ROCM_XIO_DEVICE_PATH, O_RDWR | O_CLOEXEC);
  if (ctx->kmod_fd < 0)
    return -errno;

  rc = bar0_get(ctx->nvme_bdf, &ctx->bar0_cpu, &ctx->bar0_gpu);
  if (rc < 0) {
    fprintf(stderr, "rxio: bar0_get: %d\n", rc);
    return rc;
  }

  rc = xio::nvme_ep::createQueue(controller, ROCM_XIO_DEVICE_PATH,
                                 ctx->queue_id, ctx->queue_size, ctx->nvme_bdf,
                                 memory_mode, &ctx->qi);
  if (rc < 0) {
    fprintf(stderr, "rxio: createQueue: %d\n", rc);
    return rc;
  }

  ctx->nvme_fd = open(controller, O_RDWR | O_CLOEXEC);
  if (ctx->nvme_fd < 0)
    return -errno;

  xio::NvmeDevicePath nvme_path;
  if (!xio::resolveNvmeDevicePath(controller, ctx->nsid, &nvme_path) &&
      !nvme_path.namespacePath.empty()) {
    strncpy(ctx->ns_path, nvme_path.namespacePath.c_str(),
            sizeof(ctx->ns_path) - 1);
    if (!xio::xioQuiesceNvmeNamespace(ctx->kmod_fd, ctx->ns_path,
                                      ctx->queue_id))
      ctx->quiesced = true;
  }

  herr = xio::allocateGpuAccessibleBuffer(buf_size, memory_mode, ctx->nvme_bdf,
                                          controller, &ctx->data_buf);
  if (herr != hipSuccess) {
    fprintf(stderr, "rxio: allocGpuBuf %zu: %s\n", buf_size,
            hipGetErrorString(herr));
    return -ENOMEM;
  }

  /* PRP pool: one 4KB page per slot */
  uint64_t xfer_pages = (ctx->single_buf_size + NVME_PAGE_SIZE - 1) /
                        NVME_PAGE_SIZE;
  if (xfer_pages > 1) {
    constexpr uint32_t prp_pp = NVME_PAGE_SIZE / sizeof(uint64_t);
    size_t prp_entries = (size_t)prp_pp * (size_t)ctx->batch_cap;
    long sp = sysconf(_SC_PAGESIZE);
    size_t hp = (sp > 0) ? (size_t)sp : 4096;
    ctx->prp_pool_bytes = (prp_entries * sizeof(uint64_t) + hp - 1) & ~(hp - 1);

    void* ph = nullptr;
    herr = hipHostMalloc(&ph, ctx->prp_pool_bytes, hipHostMallocDefault);
    if (herr != hipSuccess)
      return -ENOMEM;
    memset(ph, 0, ctx->prp_pool_bytes);
    ctx->prp_pool_cpu = ph;

    herr = hipHostGetDevicePointer(&ctx->prp_pool_gpu, ph, 0);
    if (herr != hipSuccess)
      return -EIO;

    ctx->prp_pool_dma = xio::getPhysAddr(ph);
    if (!ctx->prp_pool_dma) {
      fprintf(stderr, "rxio: getPhysAddr PRP pool failed\n");
      return -EIO;
    }
  }

  /* Persistent queue state for stateful kernel (2 × uint32_t) */
  {
    void* qs = nullptr;
    herr = hipHostMalloc(&qs, 2 * sizeof(uint32_t), hipHostMallocDefault);
    if (herr != hipSuccess)
      return -ENOMEM;
    memset(qs, 0, 2 * sizeof(uint32_t));

    ctx->queue_state_cpu = (volatile uint32_t*)qs;
    void* qs_gpu = nullptr;
    herr = hipHostGetDevicePointer(&qs_gpu, qs, 0);
    if (herr != hipSuccess)
      return -EIO;
    ctx->queue_state_gpu = (volatile uint32_t*)qs_gpu;
  }

  /* Doorbell */
  ctx->doorbell = {};
  ctx->doorbell.usePciMmioBridge = false;
  ctx->doorbell.nvmeBar0Gpu = ctx->bar0_gpu;
  ctx->doorbell.nvmeTargetBdf = ctx->nvme_bdf;
  ctx->doorbell.doorbellOffset = xio::nvme_ep::doorbellBase +
                                 (ctx->queue_id * 2) *
                                   xio::nvme_ep::doorBellStride;

  /* Buffer params template (per-slot pointers computed at submit time) */
  ctx->buf_params_template = {};
  ctx->buf_params_template.readBuffer = (uint8_t*)ctx->data_buf.gpuPtr;
  ctx->buf_params_template.writeBuffer = (uint8_t*)ctx->data_buf.gpuPtr;
  ctx->buf_params_template.bufferSize = buf_size;
  ctx->buf_params_template.readBufferDma = ctx->data_buf.dmaAddr;
  ctx->buf_params_template.writeBufferDma = ctx->data_buf.dmaAddr;
  if (ctx->data_buf.pagePhysAddrs) {
    ctx->buf_params_template.readPagePhysAddrs = ctx->data_buf.pagePhysAddrs;
    ctx->buf_params_template.writePagePhysAddrs = ctx->data_buf.pagePhysAddrs;
    ctx->buf_params_template.readNumPages = ctx->data_buf.numPages;
    ctx->buf_params_template.writeNumPages = ctx->data_buf.numPages;
  }
  if (xfer_pages > 1 && ctx->prp_pool_gpu) {
    ctx->buf_params_template.prpListPool = (uint64_t*)ctx->prp_pool_gpu;
    ctx->buf_params_template.prpListPoolDma = ctx->prp_pool_dma;
    ctx->buf_params_template.prpEntriesPerCmd =
      xio::nvme_ep::prpListEntriesPerPage();
    ctx->buf_params_template.prpSlotsPerBatch = 1;
  }

  void* sq_ptr = ctx->qi.sq_gpu ? ctx->qi.sq_gpu : ctx->qi.sq_virt;
  void* cq_ptr = ctx->qi.cq_gpu ? ctx->qi.cq_gpu : ctx->qi.cq_virt;
  ctx->ep_cfg = {};
  ctx->ep_cfg.submissionQueue = sq_ptr;
  ctx->ep_cfg.completionQueue = cq_ptr;
  ctx->ep_cfg.memoryMode = memory_mode;
  ctx->ep_cfg.iterations = 1;
  ctx->ep_cfg.numThreads = 1;

  herr = hipStreamCreate(&ctx->stream);
  if (herr != hipSuccess) {
    fprintf(stderr, "rxio: hipStreamCreate: %s\n", hipGetErrorString(herr));
    return -EIO;
  }

  return 0;
}

/* ------------------------------------------------------------------ */
/* rxio_submit — launch one gpuKernelStateful (async on stream)       */
/* ------------------------------------------------------------------ */

extern "C" int rxio_submit(struct rxio_queue_ctx* ctx, uint64_t lba,
                           uint32_t lbas, int is_write, int slot, int n_ops) {
  if (n_ops < 1)
    n_ops = 1;

  xio::nvme_ep::nvmeIoParams io = {};
  io.lbaSize = ctx->lba_size;
  io.baseLba = lba;
  io.lbaRangeLbas = 0;
  io.useRandomAccess = false;
  io.lfsrSeed = 0;
  io.nsid = ctx->nsid;
  io.lbasPerIo = lbas;
  io.queueSize = ctx->queue_size;
  io.infiniteMode = false;
  io.batchSize = 1;
  io.wavefrontSize = 32;
  io.readIo = is_write ? 0 : n_ops;
  io.writeIo = is_write ? n_ops : 0;

  /* Per-slot buffer params */
  xio::nvme_ep::nvmeBufferParams bp = ctx->buf_params_template;
  size_t off = (size_t)slot * ctx->single_buf_size;
  uint8_t* base = (uint8_t*)ctx->data_buf.gpuPtr;
  bp.readBuffer = base + off;
  bp.writeBuffer = base + off;
  bp.bufferSize = ctx->single_buf_size;
  if (!ctx->data_buf.isDeviceMemory) {
    bp.readBufferDma = ctx->data_buf.dmaAddr + off;
    bp.writeBufferDma = ctx->data_buf.dmaAddr + off;
  }
  if (ctx->prp_pool_gpu && ctx->buf_params_template.prpListPool) {
    uint32_t prp_pp = xio::nvme_ep::prpListEntriesPerPage();
    bp.prpListPool = (uint64_t*)ctx->prp_pool_gpu + (size_t)slot * prp_pp;
    bp.prpListPoolDma = ctx->prp_pool_dma + (uint64_t)slot * NVME_PAGE_SIZE;
  }

  (void)xio::clearHipLaunchError("rocm-xio-fio", "gpuKernelStateful",
                                 ctx->queue_id);

  hipLaunchKernelGGL(xio::nvme_ep::gpuKernelStateful, dim3(1), dim3(1), 0,
                     ctx->stream, ctx->ep_cfg, io, ctx->doorbell, bp,
                     ctx->queue_state_gpu);

  hipError_t lerr = xio::checkHipLaunchError("rocm-xio-fio",
                                             "gpuKernelStateful", ctx->queue_id,
                                             1, 1, 0, ctx->stream);
  if (lerr != hipSuccess) {
    fprintf(stderr, "rxio: gpuKernelStateful launch: %s\n",
            hipGetErrorString(lerr));
    return -EIO;
  }

  return 0;
}

/* ------------------------------------------------------------------ */
/* rxio_sync / rxio_poll                                              */
/* ------------------------------------------------------------------ */

extern "C" int rxio_sync(struct rxio_queue_ctx* ctx) {
  hipError_t st = xio::syncHipKernel("rocm-xio-fio", "gpuKernelStateful",
                                     ctx->queue_id, ctx->stream);
  if (st != hipSuccess) {
    fprintf(stderr, "rxio: sync failed: %s\n", hipGetErrorString(st));
    return -EIO;
  }
  return 0;
}

extern "C" int rxio_poll(struct rxio_queue_ctx* ctx) {
  hipError_t st = hipStreamQuery(ctx->stream);
  if (st == hipSuccess)
    return 1;
  if (st == hipErrorNotReady)
    return 0;
  fprintf(stderr, "rxio: hipStreamQuery: %s\n", hipGetErrorString(st));
  return -EIO;
}

/* ------------------------------------------------------------------ */
/* D2H / H2D copies                                                   */
/* ------------------------------------------------------------------ */

extern "C" int rxio_copy_from_gpu(struct rxio_queue_ctx* ctx, void* dst,
                                  size_t len, int slot) {
  size_t off = (size_t)slot * ctx->single_buf_size;
  hipError_t herr = hipMemcpy(dst, (uint8_t*)ctx->data_buf.gpuPtr + off, len,
                              hipMemcpyDeviceToHost);
  if (herr != hipSuccess) {
    fprintf(stderr, "rxio: D2H: %s\n", hipGetErrorString(herr));
    return -EIO;
  }
  return 0;
}

extern "C" int rxio_copy_to_gpu(struct rxio_queue_ctx* ctx, const void* src,
                                size_t len, int slot) {
  size_t off = (size_t)slot * ctx->single_buf_size;
  hipError_t herr = hipMemcpy((uint8_t*)ctx->data_buf.gpuPtr + off, src, len,
                              hipMemcpyHostToDevice);
  if (herr != hipSuccess) {
    fprintf(stderr, "rxio: H2D: %s\n", hipGetErrorString(herr));
    return -EIO;
  }
  return 0;
}

/* ------------------------------------------------------------------ */
/* Persistent-kernel API                                               */
/* ------------------------------------------------------------------ */

extern "C" int rxio_start_persistent(struct rxio_queue_ctx* ctx,
                                     int ring_depth) {
  if (ring_depth < 1)
    ring_depth = 1;
  ctx->ring_depth = (uint32_t)ring_depth;
  ctx->prod_idx = 0;
  ctx->cons_idx = 0;
  ctx->persistent = false;

  /* Allocate work ring in pinned host memory (GPU-accessible via PCIe) */
  size_t ring_bytes = (size_t)ring_depth * sizeof(xio::nvme_ep::nvmeWorkItem);
  void* rh = nullptr;
  hipError_t herr = hipHostMalloc(&rh, ring_bytes, hipHostMallocDefault);
  if (herr != hipSuccess)
    return -ENOMEM;
  memset(rh, 0, ring_bytes);
  ctx->work_ring_cpu = (xio::nvme_ep::nvmeWorkItem*)rh;
  void* rg = nullptr;
  herr = hipHostGetDevicePointer(&rg, rh, 0);
  if (herr != hipSuccess)
    return -EIO;
  ctx->work_ring_gpu = (xio::nvme_ep::nvmeWorkItem*)rg;

  /* Stop flag in pinned host memory */
  void* sf = nullptr;
  herr = hipHostMalloc(&sf, sizeof(uint32_t), hipHostMallocDefault);
  if (herr != hipSuccess)
    return -ENOMEM;
  *(uint32_t*)sf = 0;
  ctx->stop_flag_cpu = (volatile uint32_t*)sf;
  void* sfg = nullptr;
  herr = hipHostGetDevicePointer(&sfg, sf, 0);
  if (herr != hipSuccess)
    return -EIO;
  ctx->stop_flag_gpu = (volatile uint32_t*)sfg;

  /* Build ioParams template (lbas set per-op in work item; lbaSize needed) */
  xio::nvme_ep::nvmeIoParams io = {};
  io.lbaSize = ctx->lba_size;
  io.lbasPerIo = 1; /* overridden per-op via lbas in work item */
  io.nsid = ctx->nsid;
  io.queueSize = ctx->queue_size;
  io.infiniteMode = false;
  io.batchSize = 1;
  io.wavefrontSize = 32;
  io.readIo = 1; /* kernel uses work_item.is_write to select dir */
  io.writeIo = 0;

  /* Flush any stale device-side error before launching the persistent kernel */
  (void)hipDeviceSynchronize();
  hipGetLastError();

  (void)xio::clearHipLaunchError("rocm-xio-fio", "gpuKernelPersistent",
                                 ctx->queue_id);
  hipLaunchKernelGGL(xio::nvme_ep::gpuKernelPersistent, dim3(1), dim3(1), 0,
                     ctx->stream, ctx->ep_cfg, io, ctx->doorbell,
                     ctx->buf_params_template, ctx->queue_state_gpu,
                     ctx->work_ring_gpu, ctx->ring_depth, ctx->stop_flag_gpu,
                     ctx->ring_depth);

  hipError_t lerr = hipGetLastError();
  if (lerr != hipSuccess) {
    fprintf(stderr, "rxio: gpuKernelPersistent launch failed: %s\n",
            hipGetErrorString(lerr));
    return -EIO;
  }
  ctx->persistent = true;
  return 0;
}

extern "C" int rxio_post_work(struct rxio_queue_ctx* ctx, uint64_t lba,
                              uint32_t lbas, int is_write, int slot) {
  uint32_t idx = ctx->prod_idx;
  uint32_t pos = idx % ctx->ring_depth;
  volatile xio::nvme_ep::nvmeWorkItem* item = &ctx->work_ring_cpu[pos];

  /* Ring full if GPU hasn't finished and CPU hasn't reaped this slot.
   * Slot is free when seq==0 (initial or zeroed after reap). */
  if (item->seq != 0)
    return -ENOSPC;

  item->lba = lba;
  item->lbas = lbas;
  item->slot = (uint32_t)slot;
  item->is_write = (uint32_t)is_write;
  item->_pad = 0;

  /* Publish: odd seq = new work (volatile write visible to GPU via PCIe) */
  item->seq = idx * 2 + 1;

  ctx->prod_idx++;
  return 0;
}

extern "C" int rxio_reap(struct rxio_queue_ctx* ctx) {
  uint32_t idx = ctx->cons_idx;
  if (idx >= ctx->prod_idx)
    return 0; /* nothing outstanding */

  uint32_t pos = idx % ctx->ring_depth;
  volatile xio::nvme_ep::nvmeWorkItem* item = &ctx->work_ring_cpu[pos];
  uint32_t done_seq = idx * 2 + 2;

  if (item->seq != done_seq)
    return 0; /* GPU not done yet */

  /* Zero the seq to mark this slot as free for rxio_post_work */
  item->seq = 0;
  ctx->cons_idx++;
  return 1;
}

extern "C" void rxio_stop_persistent(struct rxio_queue_ctx* ctx) {
  if (!ctx->persistent)
    return;
  *ctx->stop_flag_cpu = 1;
  /* Wait for kernel to see the flag and exit */
  (void)hipStreamSynchronize(ctx->stream);
  ctx->persistent = false;

  if (ctx->work_ring_cpu) {
    (void)hipHostFree(ctx->work_ring_cpu);
    ctx->work_ring_cpu = nullptr;
    ctx->work_ring_gpu = nullptr;
  }
  if (ctx->stop_flag_cpu) {
    (void)hipHostFree((void*)ctx->stop_flag_cpu);
    ctx->stop_flag_cpu = nullptr;
    ctx->stop_flag_gpu = nullptr;
  }
}

/* ------------------------------------------------------------------ */
/* rxio_teardown                                                       */
/* ------------------------------------------------------------------ */

extern "C" void rxio_teardown(struct rxio_queue_ctx* ctx) {
  if (!ctx || !ctx->controller[0])
    return;
  ctx->controller[0] = '\0';

  /* Stop persistent kernel before destroying stream */
  if (ctx->persistent)
    rxio_stop_persistent(ctx);

  if (ctx->stream) {
    (void)hipStreamSynchronize(ctx->stream);
    (void)hipStreamDestroy(ctx->stream);
    ctx->stream = nullptr;
  }

  if (ctx->queue_state_cpu) {
    (void)hipHostFree((void*)ctx->queue_state_cpu);
    ctx->queue_state_cpu = nullptr;
  }

  bar0_put(ctx->nvme_bdf);

  if (ctx->quiesced && ctx->kmod_fd >= 0 && ctx->ns_path[0])
    xio::xioUnquiesceNvmeNamespace(ctx->kmod_fd, ctx->ns_path, ctx->queue_id);

  if (ctx->nvme_fd >= 0) {
    xio::nvme_ep::deleteQueue(ctx->nvme_fd, ctx->queue_id);
    close(ctx->nvme_fd);
    ctx->nvme_fd = -1;
  }

  if (ctx->data_buf.gpuPtr || ctx->data_buf.hostPtr)
    xio::freeGpuAccessibleBuffer(&ctx->data_buf);

  if (ctx->prp_pool_cpu) {
    (void)hipHostFree(ctx->prp_pool_cpu);
    ctx->prp_pool_cpu = nullptr;
  }

  if (ctx->kmod_fd >= 0) {
    close(ctx->kmod_fd);
    ctx->kmod_fd = -1;
  }
}

/* ------------------------------------------------------------------ */
/* Metadata                                                            */
/* ------------------------------------------------------------------ */

extern "C" unsigned rxio_lba_size(struct rxio_queue_ctx* ctx) {
  return ctx ? ctx->lba_size : 512;
}

extern "C" uint64_t rxio_ns_capacity_lbas(struct rxio_queue_ctx* ctx) {
  return ctx ? ctx->ns_capacity_lbas : 0;
}

#endif /* !__HIP_DEVICE_COMPILE__ */
