/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * ROCm ERNIC loopback data path test.
 * Creates a real QP connected to itself on the
 * local ERNIC device, registers a data buffer,
 * posts an RDMA WRITE from GPU device code via
 * ernic::Ops::post_wqe_rma_single, waits for CQE
 * completion via ernic::Ops::quiet_single, and
 * verifies the data with LFSR pattern.
 *
 * This test validates the full GDA device code
 * path:
 *   GPU kernel -> WQE construction ->
 *   doorbell ring -> NIC DMA -> CQE
 *
 * Requires: ROCm ERNIC device, GDA_ERNIC=ON build.
 */

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <hip/hip_runtime.h>

#include "gda-backend.hpp"
#include "queue-pair.hpp"
#include "vendor-ops.hpp"
#include "xio-data-pattern.hpp"
#include "xio.h"

#if !defined(GDA_ERNIC)
int main() {
  printf("SKIPPED: GDA_ERNIC not enabled.\n");
  return 0;
}
#else

using namespace rdma_ep;

static constexpr uint32_t DEFAULT_XFER_SIZE = 256;
static constexpr uint32_t DEFAULT_LFSR_SEED = 1;

static void print_usage(const char *prog) {
  fprintf(stderr,
          "Usage: %s [OPTIONS]\n"
          "  --size  N   Transfer size in bytes "
          "(default %u)\n"
          "  --seed  N   LFSR seed "
          "(default %u)\n",
          prog, DEFAULT_XFER_SIZE,
          DEFAULT_LFSR_SEED);
}

__global__ void loopback_write_kernel(
    QueuePair *qp, void *src_ptr,
    void *dst_ptr, uint32_t length,
    int *result,
    unsigned long long *elapsed) {
  if (threadIdx.x != 0)
    return;

  unsigned long long t0 = wall_clock64();

  qp->put_nbi_single(dst_ptr, src_ptr,
                      length, true);
  qp->quiet_single();

  *elapsed = wall_clock64() - t0;
  *result = 0;
}

int main(int argc, char **argv) {
  uint32_t xfer_size = DEFAULT_XFER_SIZE;
  uint32_t lfsr_seed = DEFAULT_LFSR_SEED;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--size") == 0 &&
        i + 1 < argc) {
      xfer_size =
          static_cast<uint32_t>(atoi(argv[++i]));
    } else if (strcmp(argv[i], "--seed") == 0 &&
               i + 1 < argc) {
      lfsr_seed =
          static_cast<uint32_t>(atoi(argv[++i]));
    } else {
      print_usage(argv[0]);
      return 1;
    }
  }

  printf("=== ERNIC Loopback Data Path Test ===\n");
  printf("  size=%u  seed=%u\n\n",
         xfer_size, lfsr_seed);

  hipError_t herr = hipInit(0);
  if (herr != hipSuccess) {
    fprintf(stderr, "hipInit failed: %s\n",
            hipGetErrorString(herr));
    return 1;
  }

  int device_count = 0;
  (void)hipGetDeviceCount(&device_count);
  if (device_count == 0) {
    fprintf(stderr, "No HIP devices found.\n");
    return 1;
  }
  (void)hipSetDevice(0);

  BackendConfig cfg;
  cfg.provider = Provider::ROCM_ERNIC;
  cfg.gpu_device_id = 0;
  cfg.sq_depth = 256;
  cfg.cq_depth = 256;
  cfg.inline_threshold = 28;
  cfg.loopback = true;

  Backend backend(cfg);
  int ret = backend.init();
  if (ret != 0) {
    fprintf(stderr, "Backend init failed.\n");
    return 1;
  }
  printf("Backend initialized.\n");

  QueuePair *gpu_qp = backend.get_gpu_qp();
  if (!gpu_qp) {
    fprintf(stderr,
            "No GPU QueuePair available.\n");
    return 1;
  }
  printf("GPU QueuePair ready.\n");

  size_t buf_size = xfer_size * 2;
  void *buf = nullptr;
  herr = hipHostMalloc(&buf, buf_size,
                       hipHostMallocMapped);
  if (herr != hipSuccess) {
    fprintf(stderr,
            "hipHostMalloc failed: %s\n",
            hipGetErrorString(herr));
    return 1;
  }

  uint8_t *src = static_cast<uint8_t *>(buf);
  uint8_t *dst = src + xfer_size;

  xio::DataPatternParams fill_p{
      src, xfer_size, 0,
      xfer_size, lfsr_seed, nullptr};
  xio::dataPattern(false, fill_p);
  memset(dst, 0x00, xfer_size);

  printf("Data buffer allocated: "
         "src=%p, dst=%p, size=%u\n",
         (void *)src, (void *)dst, xfer_size);

  ret = backend.register_data_buffer(
      buf, buf_size);
  if (ret != 0) {
    fprintf(stderr,
            "register_data_buffer failed.\n");
    (void)hipHostFree(buf);
    return 1;
  }
  printf("Buffer registered: "
         "lkey=0x%x, rkey=0x%x\n",
         backend.get_lkey(),
         backend.get_rkey());

  void *buf_gpu = nullptr;
  herr = hipHostGetDevicePointer(
      &buf_gpu, buf, 0);
  if (herr != hipSuccess) {
    fprintf(stderr,
            "hipHostGetDevicePointer "
            "failed: %s\n",
            hipGetErrorString(herr));
    (void)hipHostFree(buf);
    return 1;
  }

  printf("Addresses: src=%p, dst=%p "
         "(GPU: %p)\n",
         (void *)src, (void *)dst, buf_gpu);

  int *d_result = nullptr;
  unsigned long long *d_elapsed = nullptr;
  herr = hipMalloc(&d_result, sizeof(int));
  if (herr != hipSuccess) {
    fprintf(stderr,
            "hipMalloc(result) failed.\n");
    (void)hipHostFree(buf);
    return 1;
  }
  herr = hipMalloc(&d_elapsed,
                   sizeof(unsigned long long));
  if (herr != hipSuccess) {
    fprintf(stderr,
            "hipMalloc(elapsed) failed.\n");
    (void)hipFree(d_result);
    (void)hipHostFree(buf);
    return 1;
  }
  int h_result = -1;
  unsigned long long h_elapsed = 0;
  (void)hipMemcpy(d_result, &h_result,
                  sizeof(int),
                  hipMemcpyHostToDevice);
  (void)hipMemcpy(d_elapsed, &h_elapsed,
                  sizeof(h_elapsed),
                  hipMemcpyHostToDevice);

  printf("Pre-check: src[0]=0x%02x, "
         "dst[0]=0x%02x\n", src[0], dst[0]);
  xio::DataPatternParams pre_p{
      src, xfer_size, 0,
      xfer_size, lfsr_seed, nullptr};
  assert(xio::dataPattern(true, pre_p));
  assert(dst[0] == 0x00);

  printf("Launching RDMA WRITE kernel...\n");
  hipLaunchKernelGGL(
      loopback_write_kernel,
      dim3(1), dim3(1), 0, 0,
      gpu_qp, (void *)src,
      (void *)dst, xfer_size,
      d_result, d_elapsed);

  herr = hipGetLastError();
  if (herr != hipSuccess) {
    fprintf(stderr,
            "Kernel launch failed: %s\n",
            hipGetErrorString(herr));
    (void)hipFree(d_elapsed);
    (void)hipFree(d_result);
    (void)hipHostFree(buf);
    return 1;
  }

  herr = hipDeviceSynchronize();
  if (herr != hipSuccess) {
    fprintf(stderr,
            "Kernel sync failed: %s\n",
            hipGetErrorString(herr));
    (void)hipFree(d_elapsed);
    (void)hipFree(d_result);
    (void)hipHostFree(buf);
    return 1;
  }

  (void)hipMemcpy(&h_result, d_result,
                  sizeof(int),
                  hipMemcpyDeviceToHost);
  (void)hipMemcpy(&h_elapsed, d_elapsed,
                  sizeof(h_elapsed),
                  hipMemcpyDeviceToHost);
  (void)hipFree(d_elapsed);
  (void)hipFree(d_result);

  if (h_result != 0) {
    fprintf(stderr,
            "Kernel reported error: %d\n",
            h_result);
    (void)hipHostFree(buf);
    return 1;
  }

  int wall_clk_rate = 0;
  (void)hipDeviceGetAttribute(
      &wall_clk_rate,
      hipDeviceAttributeWallClockRate, 0);
  double freq_khz =
      static_cast<double>(wall_clk_rate);
  double total_us =
      (static_cast<double>(h_elapsed) /
       freq_khz) * 1000.0;
  printf("Kernel completed: %.1f us "
         "(RDMA WRITE + CQE wait).\n",
         total_us);

  printf("Post-check: dst[0]=0x%02x, "
         "dst[%u]=0x%02x\n",
         dst[0], xfer_size - 1,
         dst[xfer_size - 1]);

  size_t err_offset = 0;
  xio::DataPatternParams vfy_p{
      dst, xfer_size, 0,
      xfer_size, lfsr_seed, &err_offset};
  bool ok = xio::dataPattern(true, vfy_p);

  if (!ok) {
    fprintf(stderr,
            "\nFAILED: LFSR mismatch at offset "
            "%zu (got 0x%02x).\n",
            err_offset, dst[err_offset]);
    (void)hipHostFree(buf);
    backend.shutdown();
    return 1;
  }

  (void)hipHostFree(buf);
  backend.shutdown();

  printf("\nPASSED: All %u bytes LFSR-verified "
         "via RDMA WRITE loopback.\n",
         xfer_size);
  return 0;
}

#endif // GDA_ERNIC
