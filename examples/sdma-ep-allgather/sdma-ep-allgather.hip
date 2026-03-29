/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Example: MPI allgather via shader-initiated SDMA.
 *
 * Each MPI rank owns one GPU.  The GPU kernel uses the
 * rocm-xio sdma_ep device-side API to DMA its local
 * input buffer into the correct slot of every other
 * rank's output buffer -- implementing a GPU-initiated
 * allgather collective without CPU involvement in the
 * data path.
 *
 * Prerequisites:
 *   - N AMD GPUs with XGMI / Infinity Fabric P2P
 *   - MPI (OpenMPI, MPICH, etc.)
 *   - Root access (hsakmt requires /dev/kfd)
 *
 * Usage:
 *   mpirun -np <N> sudo ./sdma-ep-allgather [chunk]
 *
 * The optional [chunk] argument is the per-rank
 * transfer size in integers (default: 1024 = 4 KiB).
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <hip/hip_ext.h>
#include <hip/hip_runtime.h>
#include <mpi.h>

#include "sdma-ep.h"

#define HIP_CHECK(expr)                                                        \
  do {                                                                         \
    hipError_t _err = (expr);                                                  \
    if (_err != hipSuccess) {                                                  \
      fprintf(stderr, "[rank %d] HIP error %d (%s) at %s:%d\n", g_myrank,     \
              _err, hipGetErrorString(_err), __FILE__, __LINE__);              \
      MPI_Abort(MPI_COMM_WORLD, 1);                                           \
    }                                                                          \
  } while (0)

static int g_myrank = 0;

static constexpr int MAX_GPUS = 8;
static constexpr int DEFAULT_CHUNK_INTS = 1024;

struct AllgatherArgs {
  sdma_ep::SdmaQueueHandle* queues[MAX_GPUS];
  void* remoteDst[MAX_GPUS];
  uint64_t* remoteSignals[MAX_GPUS];
  uint64_t* localSignals;
  void* localInput;
  size_t chunkBytes;
  int myrank;
  int nranks;
};

__global__ void sdmaAllgatherKernel(AllgatherArgs args) {
  for (int peer = 0; peer < args.nranks; ++peer) {
    if (peer == args.myrank)
      continue;

    char* dst =
      static_cast<char*>(args.remoteDst[peer]) +
      static_cast<size_t>(args.myrank) * args.chunkBytes;

    sdma_ep::putSignal(*args.queues[peer], dst, args.localInput,
                       args.chunkBytes,
                       args.remoteSignals[peer] + args.myrank);
  }

  for (int peer = 0; peer < args.nranks; ++peer) {
    if (peer == args.myrank)
      continue;
    sdma_ep::quiet(*args.queues[peer]);
  }

  for (int peer = 0; peer < args.nranks; ++peer) {
    if (peer == args.myrank)
      continue;
    sdma_ep::waitSignal(args.localSignals + peer, 1);
  }
}

int main(int argc, char* argv[]) {
  MPI_Init(&argc, &argv);

  int nranks, myrank;
  MPI_Comm_size(MPI_COMM_WORLD, &nranks);
  MPI_Comm_rank(MPI_COMM_WORLD, &myrank);
  g_myrank = myrank;

  if (nranks < 2) {
    if (myrank == 0)
      fprintf(stderr, "ERROR: need >= 2 MPI ranks\n");
    MPI_Finalize();
    return 1;
  }
  if (nranks > MAX_GPUS) {
    if (myrank == 0)
      fprintf(stderr, "ERROR: max %d ranks supported\n", MAX_GPUS);
    MPI_Finalize();
    return 1;
  }

  int chunkInts = DEFAULT_CHUNK_INTS;
  if (argc > 1)
    chunkInts = atoi(argv[1]);
  size_t chunkBytes = static_cast<size_t>(chunkInts) * sizeof(int);

  if (myrank == 0) {
    printf("sdma-ep allgather: %d ranks, %d ints "
           "(%zu bytes) per rank\n",
           nranks, chunkInts, chunkBytes);
  }

  HIP_CHECK(hipSetDevice(myrank));
  hipDeviceProp_t prop;
  HIP_CHECK(hipGetDeviceProperties(&prop, myrank));
  printf("[rank %d] GPU %d: %s\n", myrank, myrank, prop.name);

  int rc = sdma_ep::initEndpoint();
  if (rc != 0) {
    fprintf(stderr, "[rank %d] initEndpoint failed (%d)\n", myrank, rc);
    MPI_Abort(MPI_COMM_WORLD, 1);
  }

  AllgatherArgs args = {};
  args.myrank = myrank;
  args.nranks = nranks;
  args.chunkBytes = chunkBytes;

  sdma_ep::SdmaQueueInfo queueInfos[MAX_GPUS] = {};
  for (int peer = 0; peer < nranks; ++peer) {
    if (peer == myrank)
      continue;

    sdma_ep::SdmaConnectionInfo connInfo = {};
    rc = sdma_ep::createConnection(myrank, peer, &connInfo);
    if (rc != 0) {
      fprintf(stderr, "[rank %d] createConnection(%d->%d) "
                      "failed (%d)\n",
              myrank, myrank, peer, rc);
      MPI_Abort(MPI_COMM_WORLD, 1);
    }

    rc = sdma_ep::createQueue(myrank, peer, &queueInfos[peer]);
    if (rc != 0) {
      fprintf(stderr, "[rank %d] createQueue(%d->%d) "
                      "failed (%d)\n",
              myrank, myrank, peer, rc);
      MPI_Abort(MPI_COMM_WORLD, 1);
    }
    args.queues[peer] = static_cast<sdma_ep::SdmaQueueHandle*>(
      queueInfos[peer].deviceHandle);
  }

  int* inputBuf = nullptr;
  int* outputBuf = nullptr;
  HIP_CHECK(hipMalloc(&inputBuf, chunkBytes));
  HIP_CHECK(hipMalloc(&outputBuf, chunkBytes * nranks));
  HIP_CHECK(hipMemset(outputBuf, 0, chunkBytes * nranks));

  int* hostPattern = static_cast<int*>(malloc(chunkBytes));
  for (int i = 0; i < chunkInts; ++i)
    hostPattern[i] = myrank + 1;
  HIP_CHECK(
    hipMemcpy(inputBuf, hostPattern, chunkBytes, hipMemcpyHostToDevice));
  HIP_CHECK(hipMemcpy(static_cast<char*>(static_cast<void*>(outputBuf)) +
                         static_cast<size_t>(myrank) * chunkBytes,
                       hostPattern, chunkBytes, hipMemcpyHostToDevice));
  free(hostPattern);
  args.localInput = inputBuf;

  uint64_t* signalBuf = nullptr;
  HIP_CHECK(hipExtMallocWithFlags(reinterpret_cast<void**>(&signalBuf),
                                  nranks * sizeof(uint64_t),
                                  hipDeviceMallocUncached));
  HIP_CHECK(hipMemset(signalBuf, 0, nranks * sizeof(uint64_t)));
  args.localSignals = signalBuf;

  hipIpcMemHandle_t outHandle, sigHandle;
  HIP_CHECK(hipIpcGetMemHandle(&outHandle, outputBuf));
  HIP_CHECK(hipIpcGetMemHandle(&sigHandle, signalBuf));

  hipIpcMemHandle_t* allOutHandles = static_cast<hipIpcMemHandle_t*>(
    malloc(nranks * sizeof(hipIpcMemHandle_t)));
  hipIpcMemHandle_t* allSigHandles = static_cast<hipIpcMemHandle_t*>(
    malloc(nranks * sizeof(hipIpcMemHandle_t)));

  MPI_Allgather(&outHandle, sizeof(hipIpcMemHandle_t), MPI_BYTE, allOutHandles,
                sizeof(hipIpcMemHandle_t), MPI_BYTE, MPI_COMM_WORLD);
  MPI_Allgather(&sigHandle, sizeof(hipIpcMemHandle_t), MPI_BYTE, allSigHandles,
                sizeof(hipIpcMemHandle_t), MPI_BYTE, MPI_COMM_WORLD);

  for (int peer = 0; peer < nranks; ++peer) {
    if (peer == myrank) {
      args.remoteDst[peer] = nullptr;
      args.remoteSignals[peer] = nullptr;
      continue;
    }
    void* remoteOut = nullptr;
    void* remoteSig = nullptr;
    HIP_CHECK(hipIpcOpenMemHandle(&remoteOut, allOutHandles[peer],
                                  hipIpcMemLazyEnablePeerAccess));
    HIP_CHECK(hipIpcOpenMemHandle(&remoteSig, allSigHandles[peer],
                                  hipIpcMemLazyEnablePeerAccess));
    args.remoteDst[peer] = remoteOut;
    args.remoteSignals[peer] = static_cast<uint64_t*>(remoteSig);
  }
  free(allOutHandles);
  free(allSigHandles);

  MPI_Barrier(MPI_COMM_WORLD);

  if (myrank == 0)
    printf("\nLaunching allgather kernel...\n");

  hipLaunchKernelGGL(sdmaAllgatherKernel, dim3(1), dim3(1), 0, nullptr, args);
  HIP_CHECK(hipDeviceSynchronize());

  MPI_Barrier(MPI_COMM_WORLD);

  int* hostOutput = static_cast<int*>(malloc(chunkBytes * nranks));
  HIP_CHECK(hipMemcpy(hostOutput, outputBuf, chunkBytes * nranks,
                       hipMemcpyDeviceToHost));

  bool pass = true;
  for (int r = 0; r < nranks; ++r) {
    int expected = r + 1;
    for (int i = 0; i < chunkInts; ++i) {
      int idx = r * chunkInts + i;
      if (hostOutput[idx] != expected) {
        fprintf(stderr, "[rank %d] FAIL: output[%d][%d] = "
                        "%d (expected %d)\n",
                myrank, r, i, hostOutput[idx], expected);
        pass = false;
        break;
      }
    }
    if (!pass)
      break;
  }
  free(hostOutput);

  if (pass)
    printf("[rank %d] PASS: allgather verified.\n", myrank);

  for (int peer = 0; peer < nranks; ++peer) {
    if (peer == myrank)
      continue;
    hipIpcCloseMemHandle(args.remoteDst[peer]);
    hipIpcCloseMemHandle(args.remoteSignals[peer]);
    sdma_ep::destroyQueue(&queueInfos[peer]);
  }

  sdma_ep::shutdownEndpoint();
  HIP_CHECK(hipFree(inputBuf));
  HIP_CHECK(hipFree(outputBuf));
  HIP_CHECK(hipFree(signalBuf));

  MPI_Finalize();
  return pass ? 0 : 1;
}
