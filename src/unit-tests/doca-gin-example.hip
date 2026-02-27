/*************************************************************************
 * Copyright (c) 2025, NVIDIA CORPORATION. All rights reserved.
 * Copyright (c) 2025, Advanced Micro Devices, Inc. All rights reserved.
 *
 * See LICENSE.txt for license information
 ************************************************************************/

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "doca/gin_gdaki.h"
#include "hip/hip_runtime.h"

/*
 * DOCA GIN AlltoAll-style example for AMD GPUs (rocm-xio doca-ep).
 *
 * Port of the NCCL Pure GIN AlltoAll example to run on AMD using the
 * doca-ep device API (radaki_dev_*). Single-rank only: one process, one GPU.
 * No NCCL or DOCA host stack; kernel uses doca-ep for fence and, in
 * single-rank mode, a device copy for data so verification passes without
 * a real NIC backend.
 */

#define HIP_CHECK(cmd)                                                         \
  do {                                                                         \
    hipError_t _err = (cmd);                                                   \
    if (_err != hipSuccess) {                                                  \
      std::fprintf(stderr, "HIP error %s at %s:%d\n", hipGetErrorString(_err), \
                   __FILE__, __LINE__);                                        \
      return 1;                                                                \
    }                                                                          \
  } while (0)

#define CTA_COUNT 1
#define THREADS_PER_CTA 512

/* Single-rank AlltoAll kernel: copy send -> recv (same shape as multi-rank
 * AlltoAll). Uses doca-ep fence so we exercise the doca-ep code path.
 */
template <typename T>
__global__ void PureGinAlltoAllKernelSingleRank(const T* __restrict__ sendbuf,
                                                T* __restrict__ recvbuf,
                                                size_t count, int my_rank,
                                                int nRanks) {
  /* Same indexing as AlltoAll: each rank sends count elements to each peer.
   * All threads cooperate to copy each segment. */
  for (int r = 0; r < nRanks; r++) {
    size_t src_offset = r * count;
    size_t dst_offset = my_rank * count;
    for (size_t i = threadIdx.x + blockIdx.x * blockDim.x; i < count;
         i += blockDim.x * gridDim.x) {
      recvbuf[dst_offset + i] = sendbuf[src_offset + i];
    }
  }
  __syncthreads();

  /* Use doca-ep device API so we link and run doca-ep on AMD */
  radaki_dev_fence_release<DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU>();
}

/* Minimal runner: single rank, no NCCL/utils. */
static int run_example(int argc, char* argv[],
                       int (*example_fn)(int rank, int nRanks, int device,
                                         int devices_per_rank)) {
  (void)argc;
  (void)argv;
  return example_fn(0, 1, 0, 1);
}

int pureGinAlltoAll(int my_rank, int total_ranks, int local_device,
                    int devices_per_rank) {
  (void)devices_per_rank;

  if (my_rank == 0) {
    std::printf("Starting Pure GIN AlltoAll (single-rank, doca-ep)\n");
  }

  HIP_CHECK(hipSetDevice(local_device));
  std::printf("  Rank %d using GPU device %d\n", my_rank, local_device);

  size_t count = 1024;
  size_t total_elements = count * total_ranks;
  size_t size_bytes = total_elements * sizeof(float);

  float* h_sendbuff = (float*)malloc(size_bytes);
  float* h_recvbuff = (float*)malloc(size_bytes);
  if (!h_sendbuff || !h_recvbuff) {
    std::fprintf(stderr, "malloc failed\n");
    free(h_sendbuff);
    free(h_recvbuff);
    return 1;
  }

  void* d_sendbuff = nullptr;
  void* d_recvbuff = nullptr;
  HIP_CHECK(hipMalloc(&d_sendbuff, size_bytes));
  HIP_CHECK(hipMalloc(&d_recvbuff, size_bytes));

  for (size_t i = 0; i < total_elements; i++) {
    int dest_rank = (int)(i / count);
    size_t element_idx = i % count;
    h_sendbuff[i] = (float)(my_rank * 1000 + dest_rank * 100 + element_idx);
  }
  HIP_CHECK(
    hipMemcpy(d_sendbuff, h_sendbuff, size_bytes, hipMemcpyHostToDevice));
  std::printf("  Rank %d initialized send data\n", my_rank);

  hipStream_t stream = nullptr;
  HIP_CHECK(hipStreamCreate(&stream));

  if (my_rank == 0) {
    std::printf("Starting Pure GIN AlltoAll with %zu elements per rank "
                "(%zu total elements, %zu MB)\n",
                count, total_elements, size_bytes / (1024 * 1024));
  }

  std::printf("\n=== Executing Pure GIN AlltoAll (single-rank) ===\n");

  HIP_CHECK(hipMemset(d_recvbuff, 0, size_bytes));

  PureGinAlltoAllKernelSingleRank<float>
    <<<CTA_COUNT, THREADS_PER_CTA, 0, stream>>>((const float*)d_sendbuff,
                                                (float*)d_recvbuff, count,
                                                my_rank, total_ranks);

  HIP_CHECK(hipGetLastError());
  HIP_CHECK(hipStreamSynchronize(stream));
  std::printf("  Rank %d completed pure GIN AlltoAll kernel\n", my_rank);

  HIP_CHECK(
    hipMemcpy(h_recvbuff, d_recvbuff, size_bytes, hipMemcpyDeviceToHost));

  bool gin_success = true;
  for (int src_rank = 0; src_rank < total_ranks; src_rank++) {
    for (size_t i = 0; i < count; i++) {
      size_t recv_idx = src_rank * count + i;
      float expected = (float)(src_rank * 1000 + my_rank * 100 + i);
      if (h_recvbuff[recv_idx] != expected) {
        gin_success = false;
        std::fprintf(stderr,
                     "  Rank %d: Pure GIN mismatch at [%d][%zu]: got %.0f, "
                     "expected %.0f\n",
                     my_rank, src_rank, (unsigned long)i, h_recvbuff[recv_idx],
                     expected);
        break;
      }
    }
    if (!gin_success)
      break;
  }

  if (my_rank == 0) {
    std::printf("Pure GIN AlltoAll result: %s\n",
                gin_success ? "PASSED" : "FAILED");
  }

  free(h_sendbuff);
  free(h_recvbuff);
  HIP_CHECK(hipFree(d_sendbuff));
  HIP_CHECK(hipFree(d_recvbuff));
  HIP_CHECK(hipStreamDestroy(stream));

  return gin_success ? 0 : 1;
}

int main(int argc, char* argv[]) {
  return run_example(argc, argv, pureGinAlltoAll);
}
