/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unified loopback data path test.
 * Creates a real QP connected to itself on a local
 * NIC, registers a data buffer, posts an RDMA WRITE
 * from GPU device code, waits for CQE completion,
 * and verifies the data with LFSR pattern.
 *
 * Supports BNXT, MLX5, and IONIC providers via CLI.
 *
 * Requires: GDA_BNXT=ON, GDA_MLX5=ON, or
 *           GDA_IONIC=ON build.
 */

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <hip/hip_runtime.h>

#include <unistd.h>

#if defined(GDA_IONIC)
#ifndef INFINIBAND_VERBS_H
extern "C" {
#include <infiniband/verbs.h>
}
#endif
#endif

#include "detect-pci-vendor.hpp"
#include "gda-backend.hpp"
#include "queue-pair.hpp"
#include "vendor-ops.hpp"
#include "xio-data-pattern.hpp"
#include "xio.h"

#if !defined(GDA_BNXT) && !defined(GDA_MLX5) && !defined(GDA_IONIC)
int main() {
  printf("SKIP: no GDA vendor enabled.\n");
  return 77;
}
#else

using namespace rdma_ep;

static constexpr uint32_t DEFAULT_XFER_SIZE = 256;
static constexpr uint32_t DEFAULT_LFSR_SEED = 1;
static constexpr unsigned DEFAULT_ITERATIONS = 1;

static void print_usage(const char* prog) {
  fprintf(stderr,
          "Usage: %s [OPTIONS]\n"
          "  --provider P    bnxt|mlx5|ionic|auto"
          " (default auto)\n"
          "  --device DEV    RDMA device name\n"
          "  --size   N      Transfer size"
          " (default %u)\n"
          "  --seed   N      LFSR seed"
          " (default %u)\n"
          "  -n N            Iterations"
          " (default %u)\n"
          "  --write-imm     Use RDMA WRITE"
          " with immediate data\n"
          "  --queue-mem M   host|vram"
          " (default host)\n",
          prog, DEFAULT_XFER_SIZE, DEFAULT_LFSR_SEED, DEFAULT_ITERATIONS);
}

__global__ void loopback_db_diag_kernel(QueuePair* qp, void* src_ptr,
                                        void* dst_ptr, uint32_t length,
                                        int* result,
                                        unsigned long long* elapsed) {
  if (threadIdx.x != 0)
    return;

#if defined(GDA_IONIC)
  if (qp->provider_ == Provider::IONIC) {
    printf("DIAG: sq_buf=%p cq_buf=%p "
           "sq_dbreg=%p\n",
           (void*)qp->ionic_sq_buf_, (void*)qp->ionic_cq_buf_,
           (void*)qp->sq_dbreg_);
    printf("DIAG: sq_dbval=0x%lx "
           "sq_mask=0x%lx "
           "sq_prod=%u lkey=0x%x "
           "rkey=0x%x\n",
           (unsigned long)qp->sq_dbval_, (unsigned long)qp->sq_mask_,
           qp->sq_prod_, qp->lkey_, qp->rkey_);
    printf("DIAG: cq_dbval=0x%lx "
           "cq_mask=0x%lx\n",
           (unsigned long)qp->cq_dbval_, (unsigned long)qp->cq_mask_);

    qp->put_nbi_single(dst_ptr, src_ptr, length, true);
    __threadfence_system();

    volatile uint32_t* sq32 = reinterpret_cast<volatile uint32_t*>(
      qp->ionic_sq_buf_);
    printf("DIAG: WQE[0..31]: "
           "%08x %08x %08x %08x "
           "%08x %08x %08x %08x\n",
           sq32[0], sq32[1], sq32[2], sq32[3], sq32[4], sq32[5], sq32[6],
           sq32[7]);
    printf("DIAG: WQE[32..63]: "
           "%08x %08x %08x %08x "
           "%08x %08x %08x %08x\n",
           sq32[8], sq32[9], sq32[10], sq32[11], sq32[12], sq32[13], sq32[14],
           sq32[15]);

    for (int i = 0; i < 100000; i++)
      __builtin_amdgcn_s_sleep(10);

    volatile struct ionic_v1_cqe* cqe = &qp->ionic_cq_buf_[0];
    uint32_t qtf = cqe->qid_type_flags;
    uint32_t msn_raw = cqe->send.msg_msn;
    uint32_t st_len = cqe->status_length;
    printf("DIAG: after DB: cqe[0] "
           "qtf=0x%x msn_raw=0x%x "
           "st_len=0x%x sq_prod=%u\n",
           qtf, msn_raw, st_len, qp->sq_prod_);

    *result = 0;
    *elapsed = 0;
    return;
  }
#endif

  unsigned long long t0 = wall_clock64();
  qp->put_nbi_single(dst_ptr, src_ptr, length, true);
  qp->quiet_single();
  *elapsed = wall_clock64() - t0;
  *result = 0;
}

__global__ void loopback_write_kernel(QueuePair* qp, void* src_ptr,
                                      void* dst_ptr, uint32_t length,
                                      int* result, unsigned long long* elapsed,
                                      unsigned iterations) {
  if (threadIdx.x != 0)
    return;

  unsigned long long t0 = wall_clock64();

  for (unsigned i = 0; i < iterations; i++) {
    qp->put_nbi_single(dst_ptr, src_ptr, length, true);
    qp->quiet_single();
  }

  *elapsed = wall_clock64() - t0;
  *result = 0;
}

__global__ void loopback_post_one_kernel(QueuePair* qp, void* src_ptr,
                                         void* dst_ptr, uint32_t length,
                                         volatile int* done) {
  if (threadIdx.x != 0)
    return;
  qp->put_nbi_single(dst_ptr, src_ptr, length, true);
  __threadfence_system();
  *done = 1;
}

__global__ void loopback_write_imm_kernel(QueuePair* qp, void* src_ptr,
                                          void* dst_ptr, uint32_t length,
                                          int* result,
                                          unsigned long long* elapsed,
                                          unsigned iterations) {
  if (threadIdx.x != 0)
    return;

  unsigned long long t0 = wall_clock64();

  for (unsigned i = 0; i < iterations; i++) {
    uint32_t imm = i + 1;

#if defined(GDA_IONIC)
    if (qp->provider_ == Provider::IONIC) {
      volatile struct ionic_v1_cqe* cqe = &qp->ionic_cq_buf_[0];
      __hip_atomic_store((uint32_t*)&cqe->send.msg_msn, 0u, __ATOMIC_RELEASE,
                         __HIP_MEMORY_SCOPE_SYSTEM);
      __hip_atomic_store((uint32_t*)&cqe->qid_type_flags, 0u, __ATOMIC_RELEASE,
                         __HIP_MEMORY_SCOPE_SYSTEM);
      __threadfence_system();

      qp->put_nbi_imm_single(dst_ptr, src_ptr, length, imm, true);

      uint32_t timeout = 0;
      uint32_t cons = qp->sq_prod_;
      uint32_t qtf_be = __hip_atomic_load((uint32_t*)&cqe->qid_type_flags,
                                          __ATOMIC_ACQUIRE,
                                          __HIP_MEMORY_SCOPE_SYSTEM);
      uint32_t msn = byteswap<uint32_t>(
        __hip_atomic_load((uint32_t*)&cqe->send.msg_msn, __ATOMIC_ACQUIRE,
                          __HIP_MEMORY_SCOPE_SYSTEM));

      while ((msn - cons) & 0x800000) {
        if (++timeout > 5000000) {
          uint32_t st_len = __hip_atomic_load((uint32_t*)&cqe->status_length,
                                              __ATOMIC_ACQUIRE,
                                              __HIP_MEMORY_SCOPE_SYSTEM);
          printf("WRITE_IMM TIMEOUT: "
                 "qtf=0x%08x msn=%u "
                 "cons=%u st_len=0x%08x "
                 "sq_prod=%u iter=%u\n",
                 qtf_be, msn, cons, st_len, qp->sq_prod_, i);
          *result = -2;
          *elapsed = wall_clock64() - t0;
          return;
        }
        qtf_be = __hip_atomic_load((uint32_t*)&cqe->qid_type_flags,
                                   __ATOMIC_ACQUIRE, __HIP_MEMORY_SCOPE_SYSTEM);
        msn = byteswap<uint32_t>(
          __hip_atomic_load((uint32_t*)&cqe->send.msg_msn, __ATOMIC_ACQUIRE,
                            __HIP_MEMORY_SCOPE_SYSTEM));
      }

      if (qtf_be & byteswap<uint32_t>(IONIC_V1_CQE_ERROR)) {
        uint32_t st_len = __hip_atomic_load((uint32_t*)&cqe->status_length,
                                            __ATOMIC_ACQUIRE,
                                            __HIP_MEMORY_SCOPE_SYSTEM);
        printf("WRITE_IMM CQE ERROR: "
               "qtf=0x%08x msn=%u "
               "st_len=0x%08x iter=%u\n",
               qtf_be, msn, st_len, i);
        *result = -3;
        *elapsed = wall_clock64() - t0;
        return;
      }
      continue;
    }
#endif
    qp->put_nbi_imm_single(dst_ptr, src_ptr, length, imm, true);
    qp->quiet_single();
  }

  *elapsed = wall_clock64() - t0;
  *result = 0;
}

int main(int argc, char** argv) {
  uint32_t xfer_size = DEFAULT_XFER_SIZE;
  uint32_t lfsr_seed = DEFAULT_LFSR_SEED;
  unsigned iterations = DEFAULT_ITERATIONS;
  const char* provider_str = "auto";
  const char* device_name = nullptr;
  bool diag_mode = false;
  bool write_imm = false;
  bool cpu_poll = false;
  QueueMemMode queue_mem = QueueMemMode::HOST_COHERENT;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--provider") == 0 && i + 1 < argc) {
      provider_str = argv[++i];
    } else if (strcmp(argv[i], "--device") == 0 && i + 1 < argc) {
      device_name = argv[++i];
    } else if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) {
      xfer_size = static_cast<uint32_t>(atoi(argv[++i]));
    } else if (strcmp(argv[i], "--seed") == 0 && i + 1 < argc) {
      lfsr_seed = static_cast<uint32_t>(atoi(argv[++i]));
    } else if ((strcmp(argv[i], "-n") == 0 ||
                strcmp(argv[i], "--iterations") == 0) &&
               i + 1 < argc) {
      iterations = static_cast<unsigned>(atoi(argv[++i]));
    } else if (strcmp(argv[i], "--diag") == 0) {
      diag_mode = true;
    } else if (strcmp(argv[i], "--write-imm") == 0) {
      write_imm = true;
    } else if (strcmp(argv[i], "--cpu-poll") == 0) {
      cpu_poll = true;
    } else if (strcmp(argv[i], "--queue-mem") == 0 && i + 1 < argc) {
      const char* m = argv[++i];
      if (strcmp(m, "vram") == 0)
        queue_mem = QueueMemMode::DEVICE_VRAM;
      else if (strcmp(m, "host") == 0)
        queue_mem = QueueMemMode::HOST_COHERENT;
      else {
        fprintf(stderr,
                "Unknown --queue-mem: %s"
                " (use host or vram)\n",
                m);
        return 1;
      }
    } else {
      print_usage(argv[0]);
      return 1;
    }
  }

  Provider prov;
  if (strcmp(provider_str, "bnxt") == 0) {
#if defined(GDA_BNXT)
    prov = Provider::BNXT;
#else
    fprintf(stderr, "GDA_BNXT not enabled in build.\n");
    return 1;
#endif
  } else if (strcmp(provider_str, "mlx5") == 0) {
#if defined(GDA_MLX5)
    prov = Provider::MLX5;
#else
    fprintf(stderr, "GDA_MLX5 not enabled in build.\n");
    return 1;
#endif
  } else if (strcmp(provider_str, "ionic") == 0) {
#if defined(GDA_IONIC)
    prov = Provider::IONIC;
#else
    fprintf(stderr, "GDA_IONIC not enabled in build.\n");
    return 1;
#endif
  } else if (strcmp(provider_str, "auto") == 0) {
#if defined(GDA_IONIC)
    if (detect_pci_vendor(VENDOR_ID_PENSANDO)) {
      prov = Provider::IONIC;
      printf("Auto-detected: ionic (0x%04x)\n", VENDOR_ID_PENSANDO);
    } else
#endif
#if defined(GDA_MLX5)
      if (detect_pci_vendor(VENDOR_ID_MELLANOX)) {
      prov = Provider::MLX5;
      printf("Auto-detected: mlx5 (0x%04x)\n", VENDOR_ID_MELLANOX);
    } else
#endif
#if defined(GDA_BNXT)
      if (detect_pci_vendor(VENDOR_ID_BROADCOM)) {
      prov = Provider::BNXT;
      printf("Auto-detected: bnxt (0x%04x)\n", VENDOR_ID_BROADCOM);
    } else
#endif
    {
      printf("SKIP: no supported NIC detected.\n");
      return 77;
    }
  } else {
    fprintf(stderr, "Unknown provider: %s\n", provider_str);
    print_usage(argv[0]);
    return 1;
  }

  const char* prov_name = provider_name(prov);

  const char* qmem_name = queue_mem == QueueMemMode::DEVICE_VRAM ? "vram"
                                                                 : "host";
  printf("=== %s Loopback Data Path Test ===\n", prov_name);
  printf("  provider=%s  size=%u  seed=%u"
         "  iterations=%u  queue-mem=%s\n\n",
         prov_name, xfer_size, lfsr_seed, iterations, qmem_name);

  hipError_t herr = hipInit(0);
  if (herr != hipSuccess) {
    fprintf(stderr, "hipInit failed: %s\n", hipGetErrorString(herr));
    return 1;
  }

  int device_count = 0;
  (void)hipGetDeviceCount(&device_count);
  if (device_count == 0) {
    printf("SKIP: no HIP devices found.\n");
    return 77;
  }
  (void)hipSetDevice(0);

  BackendConfig cfg;
  cfg.provider = prov;
  cfg.gpu_device_id = 0;
  cfg.sq_depth = 256;
  cfg.cq_depth = 256;
  cfg.inline_threshold = 28;
  cfg.loopback = true;
  cfg.queue_mem = queue_mem;
  if (device_name)
    cfg.hca_list = device_name;

  Backend backend(cfg);
  int ret = backend.init();
  if (ret != 0) {
    fprintf(stderr, "Backend init failed.\n");
    return 1;
  }
  printf("Backend initialized.\n");

  QueuePair* gpu_qp = backend.get_gpu_qp();
  if (!gpu_qp) {
    fprintf(stderr, "No GPU QueuePair available.\n");
    return 1;
  }
  printf("GPU QueuePair ready.\n");

  size_t buf_size = xfer_size > 0 ? xfer_size * 2 : 4096;
  void* buf = nullptr;
  herr = xio::allocHostMemory(buf_size, &buf, "loopback data",
                              XIO_HOST_MEM_PINNED);
  if (herr != hipSuccess) {
    fprintf(stderr, "allocHostMemory failed\n");
    return 1;
  }

  uint8_t* src = static_cast<uint8_t*>(buf);
  uint8_t* dst = xfer_size > 0 ? src + xfer_size : src;

  if (xfer_size > 0) {
    xio::DataPatternParams fill_p{src,       xfer_size, 0,
                                  xfer_size, lfsr_seed, nullptr};
    xio::dataPattern(false, fill_p);
    memset(dst, 0x00, xfer_size);
  }

  printf("Data buffer allocated: "
         "src=%p, dst=%p, size=%u\n",
         (void*)src, (void*)dst, xfer_size);

  ret = backend.register_data_buffer(buf, buf_size);
  if (ret != 0) {
    fprintf(stderr, "register_data_buffer failed.\n");
    xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);
    return 1;
  }
  printf("Buffer registered: lkey=0x%x,"
         " rkey=0x%x\n",
         backend.get_lkey(), backend.get_rkey());

  printf("Addresses: src=%p, dst=%p\n", (void*)src, (void*)dst);

  int* d_result = nullptr;
  unsigned long long* d_elapsed = nullptr;
  hsa_status_t hsa_ret = xio::allocDeviceMemory(sizeof(int), (void**)&d_result,
                                                "loopback result",
                                                XIO_DEVICE_MEM_HIP);
  if (hsa_ret != HSA_STATUS_SUCCESS) {
    fprintf(stderr, "allocDeviceMemory(result) failed.\n");
    backend.shutdown();
    xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);
    return 1;
  }
  hsa_ret = xio::allocDeviceMemory(sizeof(unsigned long long),
                                   (void**)&d_elapsed, "loopback elapsed",
                                   XIO_DEVICE_MEM_HIP);
  if (hsa_ret != HSA_STATUS_SUCCESS) {
    fprintf(stderr, "allocDeviceMemory(elapsed) failed.\n");
    xio::freeDeviceMemory(d_result, XIO_DEVICE_MEM_HIP);
    backend.shutdown();
    xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);
    return 1;
  }
  int h_result = -1;
  unsigned long long h_elapsed = 0;
  (void)hipMemcpy(d_result, &h_result, sizeof(int), hipMemcpyHostToDevice);
  (void)hipMemcpy(d_elapsed, &h_elapsed, sizeof(h_elapsed),
                  hipMemcpyHostToDevice);

  if (xfer_size > 0) {
    printf("Pre-check: src[0]=0x%02x,"
           " dst[0]=0x%02x\n",
           src[0], dst[0]);
    xio::DataPatternParams pre_p{src,       xfer_size, 0,
                                 xfer_size, lfsr_seed, nullptr};
    bool src_ok = xio::dataPattern(true, pre_p);
    if (!src_ok) {
      fprintf(stderr, "Pre-check LFSR failed"
                      " on source buffer.\n");
      backend.shutdown();
      xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);
      return 1;
    }
    if (dst[0] != 0x00) {
      fprintf(stderr, "Pre-check dst not zeroed.\n");
      backend.shutdown();
      xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);
      return 1;
    }
  }

  if (write_imm) {
#if defined(GDA_IONIC)
    if (prov == Provider::IONIC) {
      QueuePair* hqp = backend.get_host_qp();
      if (hqp && hqp->ionic_cq_buf_) {
        memset(hqp->ionic_cq_buf_, 0, sizeof(struct ionic_v1_cqe));
        __sync_synchronize();
        fprintf(stderr,
                "DBG: zeroed CQ buf[0] at %p"
                " from CPU\n",
                (void*)hqp->ionic_cq_buf_);
      }
    }
#endif
#if defined(GDA_IONIC)
    if (prov == Provider::IONIC) {
      struct ibv_recv_wr recv_wr = {};
      recv_wr.wr_id = 0;
      recv_wr.next = nullptr;

      if (xfer_size == 0) {
        recv_wr.sg_list = nullptr;
        recv_wr.num_sge = 0;
      } else {
        static struct ibv_sge recv_sge = {};
        recv_sge.addr = reinterpret_cast<uint64_t>(dst);
        recv_sge.length = xfer_size;
        recv_sge.lkey = backend.get_lkey();
        recv_wr.sg_list = &recv_sge;
        recv_wr.num_sge = 1;
      }

      struct ibv_recv_wr* bad_wr = nullptr;
      int rrc = ibv_post_recv(backend.get_ibv_qp(), &recv_wr, &bad_wr);
      if (rrc != 0) {
        fprintf(stderr, "ibv_post_recv failed: %d\n", rrc);
        backend.shutdown();
        xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);
        return 1;
      }
      printf("Posted receive WQE for"
             " WRITE_IMM.\n");
    } else
#endif
    {
      fprintf(stderr, "SKIP: WRITE_IMM not supported"
                      " for this provider (no"
                      " ibv_post_recv support).\n");
      backend.shutdown();
      xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);
      return 77;
    }
  }

  if (cpu_poll) {
#ifdef INFINIBAND_VERBS_H
    printf("CPU-poll mode: GPU posts 1 WQE,"
           " CPU polls ibv_poll_cq,"
           " repeat %u times...\n",
           iterations);
    struct ibv_cq* ibcq = backend.get_ibv_cq();
    if (!ibcq) {
      fprintf(stderr, "No ibv CQ available\n");
      backend.shutdown();
      xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);
      return 1;
    }
    printf("ibv CQ cqe=%d\n", ibcq->cqe);

    volatile int* h_done = nullptr;
    hipError_t ha = hipHostMalloc((void**)&h_done, sizeof(int),
                                  hipHostMallocMapped);
    if (ha != hipSuccess || !h_done) {
      fprintf(stderr, "hipHostMalloc h_done failed\n");
      backend.shutdown();
      xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);
      return 1;
    }

    int failed = 0;
    for (unsigned i = 0; i < iterations; i++) {
      *h_done = 0;
      hipLaunchKernelGGL(loopback_post_one_kernel, dim3(1), dim3(1), 0, 0,
                         gpu_qp, (void*)src, (void*)dst, xfer_size, h_done);
      while (!*h_done) {
        __builtin_ia32_pause();
      }
      (void)hipDeviceSynchronize();

      struct ibv_wc wc;
      int polls = 0;
      while (1) {
        int ne = ibv_poll_cq(ibcq, 1, &wc);
        if (ne < 0) {
          fprintf(stderr, "poll_cq error iter %u\n", i);
          failed = 1;
          break;
        }
        if (ne > 0) {
          if (wc.status != IBV_WC_SUCCESS) {
            fprintf(stderr, "WC error iter %u: %d\n", i, wc.status);
            failed = 1;
          }
          break;
        }
        if (++polls > 100000000) {
          fprintf(stderr, "poll timeout iter %u\n", i);
          failed = 1;
          break;
        }
      }
      if (failed)
        break;
      if ((i + 1) % 1000 == 0)
        printf("  %u iterations OK\n", i + 1);
    }

    if (!failed)
      printf("\nPASSED: %u CPU-poll iters"
             " (CQ wrapped %u times)\n",
             iterations, iterations / ibcq->cqe);
    else
      printf("\nFAILED\n");

    (void)hipHostFree((void*)h_done);
    xio::freeDeviceMemory(d_elapsed, XIO_DEVICE_MEM_HIP);
    xio::freeDeviceMemory(d_result, XIO_DEVICE_MEM_HIP);
    backend.shutdown();
    xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);
    return failed ? 1 : 0;
#else
    printf("SKIP: --cpu-poll requires"
           " infiniband/verbs.h\n");
    xio::freeDeviceMemory(d_elapsed, XIO_DEVICE_MEM_HIP);
    xio::freeDeviceMemory(d_result, XIO_DEVICE_MEM_HIP);
    backend.shutdown();
    xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);
    return 77;
#endif
  } else if (diag_mode) {
    printf("Launching DIAG kernel...\n");
    hipLaunchKernelGGL(loopback_db_diag_kernel, dim3(1), dim3(1), 0, 0, gpu_qp,
                       (void*)src, (void*)dst, xfer_size, d_result, d_elapsed);
  } else if (write_imm) {
    printf("Launching RDMA WRITE_IMM kernel"
           " (%u iterations, size=%u,"
           " imm=1..%u)...\n",
           iterations, xfer_size, iterations);
    hipLaunchKernelGGL(loopback_write_imm_kernel, dim3(1), dim3(1), 0, 0,
                       gpu_qp, (void*)src, (void*)dst, xfer_size, d_result,
                       d_elapsed, iterations);
  } else {
    printf("Launching RDMA WRITE kernel"
           " (%u iterations)...\n",
           iterations);
    hipLaunchKernelGGL(loopback_write_kernel, dim3(1), dim3(1), 0, 0, gpu_qp,
                       (void*)src, (void*)dst, xfer_size, d_result, d_elapsed,
                       iterations);
  }

  herr = hipGetLastError();
  if (herr != hipSuccess) {
    fprintf(stderr, "Kernel launch failed: %s\n", hipGetErrorString(herr));
    xio::freeDeviceMemory(d_elapsed, XIO_DEVICE_MEM_HIP);
    xio::freeDeviceMemory(d_result, XIO_DEVICE_MEM_HIP);
    backend.shutdown();
    xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);
    return 1;
  }

  herr = hipDeviceSynchronize();
  if (herr != hipSuccess) {
    fprintf(stderr, "Kernel sync failed: %s\n", hipGetErrorString(herr));
    xio::freeDeviceMemory(d_elapsed, XIO_DEVICE_MEM_HIP);
    xio::freeDeviceMemory(d_result, XIO_DEVICE_MEM_HIP);
    backend.shutdown();
    xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);
    return 1;
  }

#if defined(GDA_IONIC)
  if (diag_mode && prov == Provider::IONIC) {
    printf("DIAG: GPU kernel done. "
           "Trying CPU DB to correct "
           "qtype offset...\n");
    volatile uint64_t* cpu_db_page = static_cast<volatile uint64_t*>(
      backend.get_db_page());
    uint64_t sq_db_val = backend.get_host_qp()->sq_dbval_;
    uint16_t sq_mask = backend.get_host_qp()->sq_mask_;
    uint32_t sq_prod = backend.get_host_qp()->sq_prod_;
    uint8_t sq_qtype = 3;
    uint64_t db_write = sq_db_val | (sq_mask & 1u);
    printf("DIAG: CPU writing 0x%lx to "
           "dbpage[%u] (%p) "
           "(sq_prod_host=%u)\n",
           (unsigned long)db_write, sq_qtype, (void*)&cpu_db_page[sq_qtype],
           sq_prod);
    cpu_db_page[sq_qtype] = db_write;
    __sync_synchronize();
    usleep(500000);
    printf("DIAG: After CPU DB: "
           "dst[0]=0x%02x\n",
           dst[0]);
  }
#endif

  (void)hipMemcpy(&h_result, d_result, sizeof(int), hipMemcpyDeviceToHost);
  (void)hipMemcpy(&h_elapsed, d_elapsed, sizeof(h_elapsed),
                  hipMemcpyDeviceToHost);
  xio::freeDeviceMemory(d_elapsed, XIO_DEVICE_MEM_HIP);
  xio::freeDeviceMemory(d_result, XIO_DEVICE_MEM_HIP);

  if (h_result != 0) {
    if (h_result == -2) {
      fprintf(stderr, "Kernel timed out waiting"
                      " for CQE.\n");
#if defined(GDA_IONIC)
      if (prov == Provider::IONIC) {
        QueuePair* hqp = backend.get_host_qp();
        volatile struct ionic_v1_cqe* cpu_cqe = hqp->ionic_cq_buf_;
        uint32_t cpu_qtf = cpu_cqe->qid_type_flags;
        uint32_t cpu_msn = cpu_cqe->send.msg_msn;
        uint32_t cpu_st = cpu_cqe->status_length;
        fprintf(stderr,
                "CPU CQE[0]: qtf=0x%08x"
                " msn_raw=0x%08x"
                " st_len=0x%08x\n",
                cpu_qtf, cpu_msn, cpu_st);
      }
#endif
    } else if (h_result == -3)
      fprintf(stderr, "Kernel got CQE error"
                      " (see GPU printf above).\n");
    else
      fprintf(stderr,
              "Kernel reported error:"
              " %d\n",
              h_result);
    backend.shutdown();
    xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);
    return 1;
  }

  int wall_clk_rate = 0;
  (void)hipDeviceGetAttribute(&wall_clk_rate, hipDeviceAttributeWallClockRate,
                              0);
  double freq_khz = static_cast<double>(wall_clk_rate);
  double total_us = (static_cast<double>(h_elapsed) / freq_khz) * 1000.0;
  printf("Kernel completed: %.1f us "
         "(RDMA %s + CQE wait).\n",
         total_us, write_imm ? "WRITE_IMM" : "WRITE");

  if (xfer_size > 0) {
    printf("Post-check: dst[0]=0x%02x,"
           " dst[%u]=0x%02x\n",
           dst[0], xfer_size - 1, dst[xfer_size - 1]);

    size_t err_offset = 0;
    xio::DataPatternParams vfy_p{dst,       xfer_size, 0,
                                 xfer_size, lfsr_seed, &err_offset};
    bool ok = xio::dataPattern(true, vfy_p);

    if (!ok) {
      fprintf(stderr,
              "\nFAILED: LFSR mismatch at "
              "offset %zu (got 0x%02x).\n",
              err_offset, dst[err_offset]);
      backend.shutdown();
      xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);
      return 1;
    }
  }

  backend.shutdown();
  xio::freeHostMemory(buf, XIO_HOST_MEM_PINNED);

  if (write_imm && xfer_size == 0) {
    printf("\nPASSED: %u zero-length WRITE_IMM"
           " (imm=1..%u) completed"
           " via %s loopback.\n",
           iterations, iterations, prov_name);
  } else {
    printf("\nPASSED: All %u bytes LFSR-verified"
           " via %s RDMA %s loopback"
           " (%u iterations).\n",
           xfer_size, prov_name, write_imm ? "WRITE_IMM" : "WRITE", iterations);
  }
  return 0;
}

#endif // GDA_BNXT || GDA_MLX5 || GDA_IONIC
