/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * BNXT loopback data path test.
 * Creates a real QP connected to itself on the local Thor 2 NIC,
 * registers a data buffer, posts an RDMA WRITE from GPU device code
 * via bnxt::Ops::post_wqe_rma_single, waits for CQE completion via
 * bnxt::Ops::quiet_single, and verifies the data was transferred.
 *
 * This test validates the full GDA device code path:
 *   GPU kernel -> WQE construction -> doorbell ring -> NIC DMA -> CQE
 *
 * Requires: BNXT NIC (Thor 2), GDA_BNXT=ON build.
 */

#include <cassert>
#include <cstdio>
#include <cstring>

#include <hip/hip_runtime.h>

#include "gda-backend.hpp"
#include "queue-pair.hpp"
#include "vendor-ops.hpp"
#include "xio.h"

#if !defined(GDA_BNXT)
int main() {
  printf("SKIPPED: GDA_BNXT not enabled.\n");
  return 0;
}
#else

using namespace rdma_ep;

static constexpr uint32_t TRANSFER_SIZE = 256;
static constexpr uint8_t DATA_PATTERN = 0xA5;

__global__ void loopback_write_kernel(QueuePair *qp,
                                      void *src_ptr,
                                      void *dst_ptr,
                                      uint32_t length,
                                      int *result) {
  if (threadIdx.x != 0)
    return;

  qp->put_nbi_single(dst_ptr, src_ptr, length, true);

  qp->quiet_single();

  *result = 0;
}

int main() {
  printf("=== BNXT Loopback Data Path Test ===\n\n");

  // --- Init HIP ---
  hipError_t herr = hipInit(0);
  if (herr != hipSuccess) {
    fprintf(stderr, "hipInit failed: %s\n", hipGetErrorString(herr));
    return 1;
  }

  int device_count = 0;
  (void)hipGetDeviceCount(&device_count);
  if (device_count == 0) {
    fprintf(stderr, "No HIP devices found.\n");
    return 1;
  }
  (void)hipSetDevice(0);

  // --- Create Backend ---
  BackendConfig cfg;
  cfg.provider = Provider::BNXT;
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
    fprintf(stderr, "No GPU QueuePair available.\n");
    return 1;
  }
  printf("GPU QueuePair ready.\n");

  // --- Allocate data buffer (host-pinned, GPU + NIC accessible) ---
  size_t buf_size = TRANSFER_SIZE * 2;
  void *buf = nullptr;
  herr = hipHostMalloc(&buf, buf_size, hipHostMallocMapped);
  if (herr != hipSuccess) {
    fprintf(stderr, "hipHostMalloc failed: %s\n", hipGetErrorString(herr));
    return 1;
  }

  uint8_t *src = static_cast<uint8_t *>(buf);
  uint8_t *dst = src + TRANSFER_SIZE;

  memset(src, DATA_PATTERN, TRANSFER_SIZE);
  memset(dst, 0x00, TRANSFER_SIZE);

  printf("Data buffer allocated: src=%p, dst=%p, size=%u\n",
         (void *)src, (void *)dst, TRANSFER_SIZE);

  // --- Register buffer with IB ---
  ret = backend.register_data_buffer(buf, buf_size);
  if (ret != 0) {
    fprintf(stderr, "register_data_buffer failed.\n");
    (void)hipHostFree(buf);
    return 1;
  }
  printf("Buffer registered: lkey=0x%x, rkey=0x%x\n",
         backend.get_lkey(), backend.get_rkey());

  // --- Get GPU-accessible pointer for the data buffer ---
  void *buf_gpu = nullptr;
  herr = hipHostGetDevicePointer(&buf_gpu, buf, 0);
  if (herr != hipSuccess) {
    fprintf(stderr, "hipHostGetDevicePointer failed: %s\n",
            hipGetErrorString(herr));
    (void)hipHostFree(buf);
    return 1;
  }

  printf("Addresses: src=%p, dst=%p (GPU: %p)\n",
         (void *)src, (void *)dst, buf_gpu);

  // --- Allocate kernel result on GPU ---
  int *d_result = nullptr;
  herr = hipMalloc(&d_result, sizeof(int));
  if (herr != hipSuccess) {
    fprintf(stderr, "hipMalloc(result) failed.\n");
    (void)hipHostFree(buf);
    return 1;
  }
  int h_result = -1;
  (void)hipMemcpy(d_result, &h_result, sizeof(int), hipMemcpyHostToDevice);

  // --- Verify source data before RDMA ---
  printf("Pre-check: src[0]=0x%02x, dst[0]=0x%02x\n", src[0], dst[0]);
  assert(src[0] == DATA_PATTERN);
  assert(dst[0] == 0x00);

  // --- Launch GPU kernel: RDMA WRITE src -> dst ---
  printf("Launching RDMA WRITE kernel...\n");
  hipLaunchKernelGGL(loopback_write_kernel, dim3(1), dim3(1), 0, 0,
                     gpu_qp, (void *)src, (void *)dst, TRANSFER_SIZE, d_result);

  herr = hipGetLastError();
  if (herr != hipSuccess) {
    fprintf(stderr, "Kernel launch failed: %s\n", hipGetErrorString(herr));
    (void)hipFree(d_result);
    (void)hipHostFree(buf);
    return 1;
  }

  herr = hipDeviceSynchronize();
  if (herr != hipSuccess) {
    fprintf(stderr, "Kernel sync failed: %s\n", hipGetErrorString(herr));
    (void)hipFree(d_result);
    (void)hipHostFree(buf);
    return 1;
  }

  // --- Check kernel result ---
  (void)hipMemcpy(&h_result, d_result, sizeof(int), hipMemcpyDeviceToHost);
  (void)hipFree(d_result);

  if (h_result != 0) {
    fprintf(stderr, "Kernel reported error: %d\n", h_result);
    (void)hipHostFree(buf);
    return 1;
  }
  printf("Kernel completed successfully.\n");

  // --- Verify data ---
  printf("Post-check: dst[0]=0x%02x, dst[%u]=0x%02x\n",
         dst[0], TRANSFER_SIZE - 1, dst[TRANSFER_SIZE - 1]);

  int errors = 0;
  for (uint32_t i = 0; i < TRANSFER_SIZE; i++) {
    if (dst[i] != DATA_PATTERN) {
      if (errors < 10) {
        fprintf(stderr, "  MISMATCH at offset %u: expected 0x%02x, got 0x%02x\n",
                i, DATA_PATTERN, dst[i]);
      }
      errors++;
    }
  }

  (void)hipHostFree(buf);
  backend.shutdown();

  if (errors > 0) {
    fprintf(stderr, "\nFAILED: %d/%u bytes mismatched.\n", errors, TRANSFER_SIZE);
    return 1;
  }

  printf("\nPASSED: All %u bytes transferred correctly via RDMA WRITE loopback.\n",
         TRANSFER_SIZE);
  return 0;
}

#endif // GDA_BNXT
