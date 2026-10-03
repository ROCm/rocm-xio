/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * nvme-multi-bench: drive N NVMe queues (across multiple controllers) from a
 * single gpuKernelMultiQueuePersistent launch and measure aggregate IOPS.
 *
 * Usage:
 *   sudo ./nvme-multi-bench [options] /dev/nvme1 /dev/nvme2 ...
 *
 * Options:
 *   --queue-id  Q   NVMe I/O queue ID to create on each controller
 *               (default: 32)
 *   --depth     D   iodepth / batch_depth per queue (default: 8)
 *   --runtime   S   measurement duration in seconds (default: 30)
 *   --gpu       G   GPU device index (default: 0)
 *   --bs        B   block size in bytes (default: 4096)
 *   --write         issue writes instead of reads
 */

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <hip/hip_runtime.h>

#include <fcntl.h>
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

using namespace xio::nvme_ep;
using xio::XioEndpointConfig;

/* ------------------------------------------------------------------ */
/* Per-queue host-side context                                         */
/* ------------------------------------------------------------------ */

struct QueueCtx {
  std::string controller;
  int kmod_fd = -1;
  int nvme_fd = -1;
  uint16_t queue_id = 0;
  uint32_t nsid = 1;
  unsigned lba_size = 512;
  uint64_t ns_capacity_lbas = 0;
  uint32_t nvme_bdf = 0;

  nvme_queue_info qi = {};
  xio::xioBufferInfo data_buf = {};
  size_t buf_size = 0;

  void* bar0_cpu = nullptr;
  void* bar0_gpu = nullptr;

  /* CPU-side copies of GPU param structs (will be uploaded to device) */
  XioEndpointConfig ep_cfg = {};
  nvmeIoParams io_params = {};
  nvmeDoorbellParams doorbell = {};
  nvmeBufferParams buf_params = {};

  char ns_path[256] = {};
  bool quiesced = false;
};

/* ------------------------------------------------------------------ */
/* Helpers                                                            */
/* ------------------------------------------------------------------ */

#undef HIP_CHECK
#define HIP_CHECK(call)                                                        \
  do {                                                                         \
    hipError_t _e = (call);                                                    \
    if (_e != hipSuccess) {                                                    \
      fprintf(stderr, "HIP error %s:%d: %s\n", __FILE__, __LINE__,             \
              hipGetErrorString(_e));                                          \
      return -1;                                                               \
    }                                                                          \
  } while (0)

static int setup_queue(QueueCtx& q, int queue_id, size_t bs,
                       unsigned memory_mode, int gpu_id) {
  q.queue_id = (uint16_t)queue_id;

  if (xio::detectBdfFromDevice(q.controller.c_str(), &q.nvme_bdf) < 0)
    return -1;
  if (queryLbaSize(q.controller.c_str(), q.nsid, &q.lba_size) < 0)
    return -1;
  if (queryNamespaceCapacity(q.controller.c_str(), q.nsid,
                             &q.ns_capacity_lbas) < 0)
    return -1;

  q.kmod_fd = open(ROCM_XIO_DEVICE_PATH, O_RDWR | O_CLOEXEC);
  if (q.kmod_fd < 0) {
    perror("open /dev/rocm-xio");
    return -1;
  }

  void *bar0_cpu = nullptr, *bar0_gpu = nullptr;
  if (xio::mapPciBar(q.nvme_bdf, 0, &bar0_cpu, &bar0_gpu, 8192) < 0)
    return -1;
  q.bar0_cpu = bar0_cpu;
  q.bar0_gpu = bar0_gpu;

  if (createQueue(q.controller.c_str(), ROCM_XIO_DEVICE_PATH, q.queue_id, 1024,
                  q.nvme_bdf, memory_mode, &q.qi) < 0)
    return -1;

  q.nvme_fd = open(q.controller.c_str(), O_RDWR | O_CLOEXEC);
  if (q.nvme_fd < 0)
    return -1;

  xio::NvmeDevicePath nvme_path;
  if (!xio::resolveNvmeDevicePath(q.controller.c_str(), q.nsid, &nvme_path) &&
      !nvme_path.namespacePath.empty()) {
    strncpy(q.ns_path, nvme_path.namespacePath.c_str(), sizeof(q.ns_path) - 1);
    if (!xio::xioQuiesceNvmeNamespace(q.kmod_fd, q.ns_path, q.queue_id))
      q.quiesced = true;
  }

  q.buf_size = bs;
  HIP_CHECK(xio::allocateGpuAccessibleBuffer(bs, memory_mode, q.nvme_bdf,
                                             q.controller.c_str(),
                                             &q.data_buf));

  /* Doorbell */
  q.doorbell = {};
  q.doorbell.usePciMmioBridge = false;
  q.doorbell.nvmeBar0Gpu = q.bar0_gpu;
  q.doorbell.nvmeTargetBdf = q.nvme_bdf;
  q.doorbell.doorbellOffset = doorbellBase + (q.queue_id * 2) * doorBellStride;

  /* Buffer params */
  q.buf_params = {};
  q.buf_params.readBuffer = (uint8_t*)q.data_buf.gpuPtr;
  q.buf_params.writeBuffer = (uint8_t*)q.data_buf.gpuPtr;
  q.buf_params.bufferSize = bs;
  q.buf_params.readBufferDma = q.data_buf.dmaAddr;
  q.buf_params.writeBufferDma = q.data_buf.dmaAddr;
  if (q.data_buf.pagePhysAddrs) {
    q.buf_params.readPagePhysAddrs = q.data_buf.pagePhysAddrs;
    q.buf_params.writePagePhysAddrs = q.data_buf.pagePhysAddrs;
    q.buf_params.readNumPages = q.data_buf.numPages;
    q.buf_params.writeNumPages = q.data_buf.numPages;
  }

  /* Endpoint config */
  void* sq_ptr = q.qi.sq_gpu ? q.qi.sq_gpu : q.qi.sq_virt;
  void* cq_ptr = q.qi.cq_gpu ? q.qi.cq_gpu : q.qi.cq_virt;
  q.ep_cfg = {};
  q.ep_cfg.submissionQueue = sq_ptr;
  q.ep_cfg.completionQueue = cq_ptr;
  q.ep_cfg.memoryMode = memory_mode;
  q.ep_cfg.iterations = 1;
  q.ep_cfg.numThreads = 1;

  /* I/O params */
  q.io_params = {};
  q.io_params.lbaSize = q.lba_size;
  q.io_params.lbasPerIo = (uint32_t)(bs / q.lba_size);
  q.io_params.nsid = q.nsid;
  q.io_params.queueSize = 1024;
  q.io_params.readIo = 1;
  q.io_params.writeIo = 0;

  return 0;
}

static void teardown_queue(QueueCtx& q) {
  if (q.data_buf.gpuPtr || q.data_buf.hostPtr)
    xio::freeGpuAccessibleBuffer(&q.data_buf);
  if (q.quiesced && q.kmod_fd >= 0 && q.ns_path[0])
    xio::xioUnquiesceNvmeNamespace(q.kmod_fd, q.ns_path, q.queue_id);
  if (q.nvme_fd >= 0) {
    deleteQueue(q.nvme_fd, q.queue_id);
    close(q.nvme_fd);
  }
  if (q.kmod_fd >= 0)
    close(q.kmod_fd);
}

/* ------------------------------------------------------------------ */
/* main                                                               */
/* ------------------------------------------------------------------ */

int main(int argc, char** argv) {
  int queue_id = 32;
  int depth = 8;
  int runtime_s = 30;
  int gpu_id = 0;
  size_t bs = 4096;
  bool do_write = false;
  std::vector<std::string> controllers;

  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--queue-id") && i + 1 < argc)
      queue_id = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--depth") && i + 1 < argc)
      depth = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--runtime") && i + 1 < argc)
      runtime_s = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--gpu") && i + 1 < argc)
      gpu_id = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--bs") && i + 1 < argc)
      bs = (size_t)atol(argv[++i]);
    else if (!strcmp(argv[i], "--write"))
      do_write = true;
    else if (argv[i][0] == '/')
      controllers.push_back(argv[i]);
    else {
      fprintf(stderr, "Unknown arg: %s\n", argv[i]);
      return 1;
    }
  }

  if (controllers.empty()) {
    fprintf(stderr,
            "Usage: %s [--queue-id Q] [--depth D] [--runtime S] "
            "[--gpu G] [--bs B] [--write] /dev/nvme1 [/dev/nvme2 ...]\n",
            argv[0]);
    return 1;
  }

  uint32_t n = (uint32_t)controllers.size();
  printf("nvme-multi-bench: %u queue(s), bs=%zu, depth=%d, runtime=%ds, "
         "%s\n",
         n, bs, depth, runtime_s, do_write ? "write" : "read");

  hipError_t herr = hipSetDevice(gpu_id);
  if (herr != hipSuccess) {
    fprintf(stderr, "hipSetDevice(%d): %s\n", gpu_id, hipGetErrorString(herr));
    return 1;
  }

  /* Set up each queue */
  std::vector<QueueCtx> queues(n);
  for (uint32_t i = 0; i < n; i++) {
    queues[i].controller = controllers[i];
    /* Use queue_id - i so multiple queues on same controller don't collide */
    if (setup_queue(queues[i], queue_id - (int)i, bs, 0 /*host coherent*/,
                    gpu_id) < 0) {
      fprintf(stderr, "setup_queue failed for %s\n", controllers[i].c_str());
      return 1;
    }
    printf("  Queue %u: %s qid=%u lba_size=%u ns_cap=%lluGiB\n", i,
           controllers[i].c_str(), queues[i].queue_id, queues[i].lba_size,
           (unsigned long long)(queues[i].ns_capacity_lbas *
                                queues[i].lba_size / (1024 * 1024 * 1024)));
  }

  /* ── Upload per-queue GPU params to device memory ── */
  std::vector<XioEndpointConfig> h_configs(n);
  std::vector<nvmeIoParams> h_io(n);
  std::vector<nvmeDoorbellParams> h_door(n);
  std::vector<nvmeBufferParams> h_buf(n);

  for (uint32_t i = 0; i < n; i++) {
    h_configs[i] = queues[i].ep_cfg;
    h_io[i] = queues[i].io_params;
    if (do_write) {
      h_io[i].readIo = 0;
      h_io[i].writeIo = 1;
    }
    h_door[i] = queues[i].doorbell;
    h_buf[i] = queues[i].buf_params;
  }

  XioEndpointConfig* d_configs = nullptr;
  nvmeIoParams* d_io = nullptr;
  nvmeDoorbellParams* d_door = nullptr;
  nvmeBufferParams* d_buf = nullptr;

  hipMalloc(&d_configs, n * sizeof(XioEndpointConfig));
  hipMalloc(&d_io, n * sizeof(nvmeIoParams));
  hipMalloc(&d_door, n * sizeof(nvmeDoorbellParams));
  hipMalloc(&d_buf, n * sizeof(nvmeBufferParams));

  hipMemcpy(d_configs, h_configs.data(), n * sizeof(XioEndpointConfig),
            hipMemcpyHostToDevice);
  hipMemcpy(d_io, h_io.data(), n * sizeof(nvmeIoParams), hipMemcpyHostToDevice);
  hipMemcpy(d_door, h_door.data(), n * sizeof(nvmeDoorbellParams),
            hipMemcpyHostToDevice);
  hipMemcpy(d_buf, h_buf.data(), n * sizeof(nvmeBufferParams),
            hipMemcpyHostToDevice);

  /* ── Pinned host memory: queue states + work ring ── */
  uint32_t ring_depth = (uint32_t)depth;

  void* qs_raw = nullptr;
  hipHostMalloc(&qs_raw, n * 2 * sizeof(uint32_t), hipHostMallocDefault);
  memset(qs_raw, 0, n * 2 * sizeof(uint32_t));
  volatile uint32_t* queue_states_cpu = (volatile uint32_t*)qs_raw;
  void* qs_gpu = nullptr;
  hipHostGetDevicePointer(&qs_gpu, qs_raw, 0);
  volatile uint32_t* queue_states_gpu = (volatile uint32_t*)qs_gpu;

  void* ring_raw = nullptr;
  size_t ring_bytes = (size_t)n * ring_depth * sizeof(nvmeWorkItem);
  hipHostMalloc(&ring_raw, ring_bytes, hipHostMallocDefault);
  memset(ring_raw, 0, ring_bytes);
  volatile nvmeWorkItem* work_ring_cpu = (volatile nvmeWorkItem*)ring_raw;
  void* ring_gpu = nullptr;
  hipHostGetDevicePointer(&ring_gpu, ring_raw, 0);
  volatile nvmeWorkItem* work_ring_gpu = (volatile nvmeWorkItem*)ring_gpu;

  void* sf_raw = nullptr;
  hipHostMalloc(&sf_raw, sizeof(uint32_t), hipHostMallocDefault);
  *(uint32_t*)sf_raw = 0;
  volatile uint32_t* stop_flag_cpu = (volatile uint32_t*)sf_raw;
  void* sf_gpu = nullptr;
  hipHostGetDevicePointer(&sf_gpu, sf_raw, 0);
  volatile uint32_t* stop_flag_gpu = (volatile uint32_t*)sf_gpu;

  /* ── Launch multi-queue kernel ── */
  hipStream_t stream;
  hipStreamCreate(&stream);
  hipGetLastError();

  hipLaunchKernelGGL(xio::nvme_ep::gpuKernelMultiQueuePersistent, dim3(n),
                     dim3(1), 0, stream, d_configs, d_io, d_door, d_buf,
                     queue_states_gpu, work_ring_gpu, ring_depth, stop_flag_gpu,
                     (uint32_t)depth);

  hipError_t launch_err = hipGetLastError();
  if (launch_err != hipSuccess) {
    fprintf(stderr, "kernel launch failed: %s\n",
            hipGetErrorString(launch_err));
    return 1;
  }
  printf("Kernel launched: %u blocks (1 per queue)\n", n);

  /* ── CPU work loop: post ops as fast as possible ── */
  std::vector<uint64_t> prod_idx(n, 0);
  std::vector<uint64_t> cons_idx(n, 0);
  std::atomic<uint64_t> total_completed(0);

  auto t_start = std::chrono::steady_clock::now();
  auto t_end = t_start + std::chrono::seconds(runtime_s);

  while (std::chrono::steady_clock::now() < t_end) {
    for (uint32_t q = 0; q < n; q++) {
      volatile nvmeWorkItem* my_ring = work_ring_cpu + (uint64_t)q * ring_depth;

      /* Reap completions */
      while (cons_idx[q] < prod_idx[q]) {
        uint64_t idx = cons_idx[q];
        uint32_t pos = (uint32_t)(idx % ring_depth);
        if (my_ring[pos].seq == (uint32_t)(idx * 2 + 2)) {
          my_ring[pos].seq = 0;
          cons_idx[q]++;
          total_completed.fetch_add(1, std::memory_order_relaxed);
        } else {
          break;
        }
      }

      /* Post new work */
      while (prod_idx[q] - cons_idx[q] < ring_depth) {
        uint64_t idx = prod_idx[q];
        uint32_t pos = (uint32_t)(idx % ring_depth);
        if (my_ring[pos].seq != 0)
          break;

        uint64_t cap = queues[q].ns_capacity_lbas;
        uint32_t lbas = (uint32_t)(bs / queues[q].lba_size);
        uint64_t lba = (cap > lbas) ? ((idx * lbas) % (cap - lbas)) : 0;

        my_ring[pos].lba = lba;
        my_ring[pos].lbas = lbas;
        my_ring[pos].slot = 0;
        my_ring[pos].is_write = do_write ? 1 : 0;
        my_ring[pos]._pad = 0;
        my_ring[pos].seq = (uint32_t)(idx * 2 + 1);
        prod_idx[q]++;
      }
    }
  }

  /* Stop kernel */
  *stop_flag_cpu = 1;
  hipStreamSynchronize(stream);

  auto elapsed = std::chrono::duration<double>(
                   std::chrono::steady_clock::now() - t_start)
                   .count();
  uint64_t ops = total_completed.load();
  double iops = (double)ops / elapsed;
  double bw_mbs = iops * (double)bs / (1024.0 * 1024.0);

  printf("\n=== Results (%u queue(s), depth=%d, bs=%zu) ===\n", n, depth, bs);
  printf("  Total ops:    %llu\n", (unsigned long long)ops);
  printf("  Elapsed:      %.2f s\n", elapsed);
  printf("  Aggregate:    %.0f IOPS  %.1f MB/s\n", iops, bw_mbs);
  printf("  Per-queue:    %.0f IOPS\n", iops / n);

  /* Cleanup */
  hipStreamDestroy(stream);
  hipHostFree(sf_raw);
  hipHostFree(ring_raw);
  hipHostFree(qs_raw);
  hipFree(d_configs);
  hipFree(d_io);
  hipFree(d_door);
  hipFree(d_buf);

  for (auto& q : queues)
    teardown_queue(q);

  return 0;
}
