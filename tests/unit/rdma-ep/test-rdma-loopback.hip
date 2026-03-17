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
 * Supports both BNXT and IONIC providers via CLI.
 *
 * Requires: GDA_BNXT=ON or GDA_IONIC=ON build.
 */

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <hip/hip_runtime.h>

#include <dirent.h>
#include <unistd.h>

#include "gda-backend.hpp"
#include "queue-pair.hpp"
#include "vendor-ops.hpp"
#include "xio-data-pattern.hpp"
#include "xio.h"

#if !defined(GDA_BNXT) && !defined(GDA_IONIC)
int main() {
  printf("SKIP: no GDA vendor enabled.\n");
  return 77;
}
#else

using namespace rdma_ep;

static constexpr uint32_t DEFAULT_XFER_SIZE = 256;
static constexpr uint32_t DEFAULT_LFSR_SEED = 1;

static bool detect_pci_vendor(uint16_t vendor_id) {
  DIR* d = opendir("/sys/class/infiniband");
  if (!d)
    return false;
  struct dirent* ent;
  while ((ent = readdir(d)) != nullptr) {
    if (ent->d_name[0] == '.')
      continue;
    char path[512];
    snprintf(path, sizeof(path),
             "/sys/class/infiniband/%s"
             "/device/vendor",
             ent->d_name);
    FILE* f = fopen(path, "r");
    if (!f)
      continue;
    unsigned int vid = 0;
    if (fscanf(f, "%x", &vid) == 1 && vid == vendor_id) {
      fclose(f);
      closedir(d);
      return true;
    }
    fclose(f);
  }
  closedir(d);
  return false;
}

static void print_usage(const char* prog) {
  fprintf(stderr,
          "Usage: %s [OPTIONS]\n"
          "  --provider P  bnxt|ionic|auto"
          " (default auto)\n"
          "  --device DEV  RDMA device name\n"
          "  --size   N    Transfer size"
          " (default %u)\n"
          "  --seed   N    LFSR seed"
          " (default %u)\n",
          prog, DEFAULT_XFER_SIZE, DEFAULT_LFSR_SEED);
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
                                      int* result,
                                      unsigned long long* elapsed) {
  if (threadIdx.x != 0)
    return;

  unsigned long long t0 = wall_clock64();

  qp->put_nbi_single(dst_ptr, src_ptr, length, true);
  qp->quiet_single();

  *elapsed = wall_clock64() - t0;
  *result = 0;
}

int main(int argc, char** argv) {
  uint32_t xfer_size = DEFAULT_XFER_SIZE;
  uint32_t lfsr_seed = DEFAULT_LFSR_SEED;
  const char* provider_str = "auto";
  const char* device_name = nullptr;
  bool diag_mode = false;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--provider") == 0 && i + 1 < argc) {
      provider_str = argv[++i];
    } else if (strcmp(argv[i], "--device") == 0 && i + 1 < argc) {
      device_name = argv[++i];
    } else if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) {
      xfer_size = static_cast<uint32_t>(atoi(argv[++i]));
    } else if (strcmp(argv[i], "--seed") == 0 && i + 1 < argc) {
      lfsr_seed = static_cast<uint32_t>(atoi(argv[++i]));
    } else if (strcmp(argv[i], "--diag") == 0) {
      diag_mode = true;
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
  } else if (strcmp(provider_str, "ionic") == 0) {
#if defined(GDA_IONIC)
    prov = Provider::IONIC;
#else
    fprintf(stderr, "GDA_IONIC not enabled in build.\n");
    return 1;
#endif
  } else if (strcmp(provider_str, "auto") == 0) {
#if defined(GDA_IONIC)
    if (detect_pci_vendor(0x1dd8)) {
      prov = Provider::IONIC;
      printf("Auto-detected: ionic (0x1dd8)\n");
    } else
#endif
#if defined(GDA_BNXT)
      if (detect_pci_vendor(0x14e4)) {
      prov = Provider::BNXT;
      printf("Auto-detected: bnxt (0x14e4)\n");
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

  const char* prov_name = (prov == Provider::BNXT) ? "BNXT" : "IONIC";

  printf("=== %s Loopback Data Path Test ===\n", prov_name);
  printf("  provider=%s  size=%u  seed=%u\n\n", prov_name, xfer_size,
         lfsr_seed);

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

  size_t buf_size = xfer_size * 2;
  void* buf = nullptr;
  if (posix_memalign(&buf, 4096, buf_size)) {
    fprintf(stderr, "posix_memalign failed\n");
    return 1;
  }

  uint8_t* src = static_cast<uint8_t*>(buf);
  uint8_t* dst = src + xfer_size;

  xio::DataPatternParams fill_p{src,       xfer_size, 0,
                                xfer_size, lfsr_seed, nullptr};
  xio::dataPattern(false, fill_p);
  memset(dst, 0x00, xfer_size);

  printf("Data buffer allocated: "
         "src=%p, dst=%p, size=%u\n",
         (void*)src, (void*)dst, xfer_size);

  ret = backend.register_data_buffer(buf, buf_size);
  if (ret != 0) {
    fprintf(stderr, "register_data_buffer failed.\n");
    free(buf);
    return 1;
  }
  printf("Buffer registered: lkey=0x%x,"
         " rkey=0x%x\n",
         backend.get_lkey(), backend.get_rkey());

  printf("Addresses: src=%p, dst=%p\n", (void*)src, (void*)dst);

  int* d_result = nullptr;
  unsigned long long* d_elapsed = nullptr;
  herr = hipMalloc(&d_result, sizeof(int));
  if (herr != hipSuccess) {
    fprintf(stderr, "hipMalloc(result) failed.\n");
    free(buf);
    return 1;
  }
  herr = hipMalloc(&d_elapsed, sizeof(unsigned long long));
  if (herr != hipSuccess) {
    fprintf(stderr, "hipMalloc(elapsed) failed.\n");
    (void)hipFree(d_result);
    free(buf);
    return 1;
  }
  int h_result = -1;
  unsigned long long h_elapsed = 0;
  (void)hipMemcpy(d_result, &h_result, sizeof(int), hipMemcpyHostToDevice);
  (void)hipMemcpy(d_elapsed, &h_elapsed, sizeof(h_elapsed),
                  hipMemcpyHostToDevice);

  printf("Pre-check: src[0]=0x%02x,"
         " dst[0]=0x%02x\n",
         src[0], dst[0]);
  {
    xio::DataPatternParams pre_p{src,       xfer_size, 0,
                                 xfer_size, lfsr_seed, nullptr};
    bool src_ok = xio::dataPattern(true, pre_p);
    if (!src_ok) {
      fprintf(stderr, "Pre-check LFSR failed"
                      " on source buffer.\n");
      free(buf);
      return 1;
    }
  }
  if (dst[0] != 0x00) {
    fprintf(stderr, "Pre-check dst not zeroed.\n");
    free(buf);
    return 1;
  }

  if (diag_mode) {
    printf("Launching DIAG kernel...\n");
    hipLaunchKernelGGL(loopback_db_diag_kernel, dim3(1), dim3(1), 0, 0, gpu_qp,
                       (void*)src, (void*)dst, xfer_size, d_result, d_elapsed);
  } else {
    printf("Launching RDMA WRITE kernel...\n");
    hipLaunchKernelGGL(loopback_write_kernel, dim3(1), dim3(1), 0, 0, gpu_qp,
                       (void*)src, (void*)dst, xfer_size, d_result, d_elapsed);
  }

  herr = hipGetLastError();
  if (herr != hipSuccess) {
    fprintf(stderr, "Kernel launch failed: %s\n", hipGetErrorString(herr));
    (void)hipFree(d_elapsed);
    (void)hipFree(d_result);
    free(buf);
    return 1;
  }

  herr = hipDeviceSynchronize();
  if (herr != hipSuccess) {
    fprintf(stderr, "Kernel sync failed: %s\n", hipGetErrorString(herr));
    (void)hipFree(d_elapsed);
    (void)hipFree(d_result);
    free(buf);
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
  (void)hipFree(d_elapsed);
  (void)hipFree(d_result);

  if (h_result != 0) {
    fprintf(stderr, "Kernel reported error: %d\n", h_result);
    free(buf);
    return 1;
  }

  int wall_clk_rate = 0;
  (void)hipDeviceGetAttribute(&wall_clk_rate, hipDeviceAttributeWallClockRate,
                              0);
  double freq_khz = static_cast<double>(wall_clk_rate);
  double total_us = (static_cast<double>(h_elapsed) / freq_khz) * 1000.0;
  printf("Kernel completed: %.1f us "
         "(RDMA WRITE + CQE wait).\n",
         total_us);

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
    free(buf);
    backend.shutdown();
    return 1;
  }

  free(buf);
  backend.shutdown();

  printf("\nPASSED: All %u bytes LFSR-verified"
         " via %s RDMA WRITE loopback.\n",
         xfer_size, prov_name);
  return 0;
}

#endif // GDA_BNXT || GDA_IONIC
