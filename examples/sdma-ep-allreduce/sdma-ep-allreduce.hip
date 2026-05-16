/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Benchmark: MPI allreduce via local reduction + SDMA allgather.
 *
 * Each MPI rank owns one GPU. The kernel performs:
 *   1. Local reduction: sum input data from all peers using P2P memory reads
 *   2. AllGather via SDMA: distribute the reduced chunk to all peers
 *
 * This is equivalent to the allreduce9 kernel pattern: reduce-scatter
 * followed by SDMA-based allgather.
 *
 * Prerequisites:
 *   - N AMD GPUs with XGMI / Infinity Fabric P2P
 *   - MPI (OpenMPI, MPICH, etc.)
 *   - Root access (hsakmt requires /dev/kfd)
 *
 * Usage:
 *   mpirun -np <N> sudo ./sdma-ep-allreduce [-w warmup] [-n iters]
 * [--device-triggered]
 *
 * Options:
 *   -w <warmup>  : Number of warmup iterations (default: 5)
 *   -n <iters>   : Number of measured iterations (default: 20)
 *   --device-triggered : Use wait_flag_then_put (GPU triggers SDMA)
 *
 * Modes:
 *   device-initiated (default): GPU kernel calls SDMA functions directly
 *   device-triggered: Host pre-programs SDMA with wait_flag_then_put,
 *                     GPU sets flag to trigger transfers
 */

#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include <hip/hip_ext.h>
#include <hip/hip_runtime.h>

#include <mpi.h>

#include "endpoints/sdma-ep/sdma-ep.h"
#include "endpoints/sdma-ep/sdma-host-queue.h"
#include "endpoints/sdma-ep/sdma_device.hpp"
#include "xio.h"

using namespace xio;

static int g_myrank = 0;

static constexpr int MAX_GPUS = 8;
static constexpr size_t CHUNK_SIZE_KB = 256; // Chunk size for pipelined
                                             // transfers
static constexpr int WARP_SIZE = 64;

struct AllreduceArgs {
  sdma_ep::SdmaQueueHandle* queues[MAX_GPUS];
  int* remoteBufs[MAX_GPUS];       // Peer input buffers for local reduction
  int* remoteDst[MAX_GPUS];        // Peer result buffers for allgather
  uint64_t** remoteBarrierSignals; // Array of nBlocks*nPeer pointers to remote
                                   // barrier signal slots
  uint64_t** remoteSdmaSignals;    // Array of nBlocks*nPeer pointers to remote
                                   // SDMA signal slots
  uint64_t* localBarrierSignals;   // Local barrier signals: nBlocks*nPeer slots
  uint64_t* localSdmaSignals;      // Local SDMA signals: nBlocks*nPeer slots
  uint32_t* triggerFlags; // Array of flags (one per block) to trigger SDMA
                          // transfers (uint32_t for wait_flag_then_put)
  int* localInput;        // This rank's input buffer
  int* localReduced;      // This rank's reduced result buffer
  size_t nelemsPerRank;   // Number of int32 elements per rank
  int myrank;
  int nranks;
};

// Kernel: Chunked local reduction + SDMA AllGather
// Similar to allreduce9: process in chunks to overlap computation with
// transfers Each block synchronizes with same blockIdx on peer GPUs using
// per-block signals
__global__ void sdmaAllreduceKernel(AllreduceArgs args, int nBlocks,
                                    uint64_t expectedSignal) {
  const int rank = args.myrank;
  const int nranks = args.nranks;
  const size_t nelemsPerRank = args.nelemsPerRank;
  const int laneId = threadIdx.x % WARP_SIZE;
  const int warpId = threadIdx.x / WARP_SIZE;
  const int nPeer = nranks - 1;

  // sdma_ep::SdmaQueueHandle handle = *args.queues[warpId % MAX_GPUS];

  size_t startIdx = rank * nelemsPerRank;

  // Get base pointers for this block's signal section (nBlocks * nPeer signals
  // total) Each block gets its own nPeer-sized section
  uint64_t* myBarrierSignals = args.localBarrierSignals + blockIdx.x * nPeer;
  uint64_t* mySdmaSignals = args.localSdmaSignals + blockIdx.x * nPeer;

  // Work in int4 units like allreduce9
  constexpr size_t nInt4PerChunk = (CHUNK_SIZE_KB * 1024) / sizeof(int4);
  const size_t nInt4PerRank = nelemsPerRank / 4;

  // Distribute work across blocks
  const size_t int4PerBlock = (nInt4PerRank + nBlocks - 1) / nBlocks;
  const size_t blockStartInt4 = blockIdx.x * int4PerBlock;
  const size_t blockInt4s = (blockIdx.x == nBlocks - 1)
                              ? (nInt4PerRank - blockStartInt4)
                              : int4PerBlock;

  if (blockStartInt4 >= nInt4PerRank)
    return; // Block has no work

  const size_t nChunks = (blockInt4s + nInt4PerChunk - 1) / nInt4PerChunk;
  size_t offsetInt4 = (rank * nInt4PerRank) + blockStartInt4;

  // Initial cross-GPU synchronization via memory stores/loads
  if (threadIdx.x < static_cast<uint32_t>(nPeer)) {
    int slotIdx = blockIdx.x * nPeer + threadIdx.x;

    // Signal to peer that we've entered the kernel
    // __threadfence_system();
    __atomic_store_n(args.remoteBarrierSignals[slotIdx], expectedSignal,
                     __ATOMIC_RELAXED);

    // Wait for peer to enter
    while (__atomic_load_n(&myBarrierSignals[threadIdx.x], __ATOMIC_RELAXED) <
           expectedSignal) {
    }
  }
  __syncthreads();

  int4* localInput4 = reinterpret_cast<int4*>(args.localInput);
  int4* localReduced4 = reinterpret_cast<int4*>(args.localReduced);

  // Process each chunk: reduce, then DMA
  for (size_t chunkIdx = 0; chunkIdx < nChunks; ++chunkIdx) {
    size_t chunkInt4s = (chunkIdx == nChunks - 1)
                          ? (blockInt4s - chunkIdx * nInt4PerChunk)
                          : nInt4PerChunk;

    // Step 1: Reduce this chunk from all peers (vectorized loads)
    for (size_t idx = threadIdx.x; idx < chunkInt4s; idx += blockDim.x) {
      int4 data = localInput4[offsetInt4 + idx];

#pragma unroll
      for (size_t peerIdx = 0; peerIdx < MAX_GPUS - 1; ++peerIdx) {
        size_t peer = (peerIdx < rank) ? peerIdx : peerIdx + 1;
        int4 val = reinterpret_cast<int4*>(
          args.remoteBufs[peer])[offsetInt4 + idx];
        data.x += val.x;
        data.y += val.y;
        data.z += val.z;
        data.w += val.w;
      }

      localReduced4[offsetInt4 + idx] = data;
    }

    // Ensure chunk reduction is complete before DMA
    __builtin_amdgcn_s_waitcnt(0);
    __builtin_amdgcn_s_barrier();
    __atomic_signal_fence(__ATOMIC_SEQ_CST);

    // Step 2: DMA this chunk to all peers (one warp lane per peer)
    if (laneId == 0 && warpId < nPeer) {
      int peer = (warpId < rank) ? warpId : warpId + 1;

      char* dst = reinterpret_cast<char*>(args.remoteDst[peer]) +
                  offsetInt4 * sizeof(int4);
      char* src = reinterpret_cast<char*>(args.localReduced) +
                  offsetInt4 * sizeof(int4);
      size_t bytes = chunkInt4s * sizeof(int4);

      if (chunkInt4s != 0) {
        sdma_ep::put(*args.queues[peer], dst, src, bytes);
      }
    }

    // Ensure all SDMA operations for this chunk are submitted before next chunk
    // __syncthreads();

    offsetInt4 += chunkInt4s;
  }

  // Signal completion and wait for peers (one warp per peer, using SDMA signal
  // buffer)
  if (laneId == 0 && warpId < nPeer) {
    int peer = (warpId < rank) ? warpId : warpId + 1;
    int slotIdx = blockIdx.x * nPeer + warpId;

    // Signal to peer that we've completed our SDMA operations
    sdma_ep::signal(*args.queues[peer], args.remoteSdmaSignals[slotIdx]);

    // Wait for peer to complete their SDMA operations
    sdma_ep::waitSignal(&mySdmaSignals[warpId], expectedSignal);

    sdma_ep::quiet(*args.queues[peer]);
  }
  // __syncthreads();
}

// Kernel: Chunked local reduction with per-chunk triggers
// Used with device-triggered mode where host sets up wait_flag_then_put per
// chunk
__global__ void reduceAndTriggerKernel(AllreduceArgs args, int nBlocks,
                                       uint64_t expectedSignal,
                                       uint32_t baseTrigger) {
  const int rank = args.myrank;
  const int nranks = args.nranks;
  const size_t nelemsPerRank = args.nelemsPerRank;
  const int laneId = threadIdx.x % WARP_SIZE;
  const int warpId = threadIdx.x / WARP_SIZE;
  const int nPeer = nranks - 1;

  // Get base pointers for this block's signal section
  uint64_t* mySdmaSignals = args.localSdmaSignals + blockIdx.x * nPeer;

  // Work in int4 units for vectorization (same as device-initiated mode)
  constexpr size_t nInt4PerChunk = (CHUNK_SIZE_KB * 1024) / sizeof(int4);
  const size_t nInt4PerRank = nelemsPerRank / 4;

  // Distribute work across blocks
  const size_t int4PerBlock = (nInt4PerRank + nBlocks - 1) / nBlocks;
  const size_t blockStartInt4 = blockIdx.x * int4PerBlock;
  const size_t blockInt4s = (blockIdx.x == nBlocks - 1)
                              ? (nInt4PerRank - blockStartInt4)
                              : int4PerBlock;

  if (blockStartInt4 >= nInt4PerRank)
    return; // Block has no work

  const size_t nChunks = (blockInt4s + nInt4PerChunk - 1) / nInt4PerChunk;
  size_t offsetInt4 = (rank * nInt4PerRank) + blockStartInt4;

  int4* localInput4 = reinterpret_cast<int4*>(args.localInput);
  int4* localReduced4 = reinterpret_cast<int4*>(args.localReduced);

  // Process each chunk: reduce, then trigger
  for (size_t chunkIdx = 0; chunkIdx < nChunks; ++chunkIdx) {
    size_t chunkInt4s = (chunkIdx == nChunks - 1)
                          ? (blockInt4s - chunkIdx * nInt4PerChunk)
                          : nInt4PerChunk;

    // Reduce this chunk from all peers (vectorized loads)
    for (size_t idx = threadIdx.x; idx < chunkInt4s; idx += blockDim.x) {
      int4 data = localInput4[offsetInt4 + idx];

      for (int peer = 0; peer < nranks; ++peer) {
        if (peer == rank)
          continue;
        int4 val = reinterpret_cast<int4*>(
          args.remoteBufs[peer])[offsetInt4 + idx];
        data.x += val.x;
        data.y += val.y;
        data.z += val.z;
        data.w += val.w;
      }

      localReduced4[offsetInt4 + idx] = data;
    }

    // Ensure chunk reduction is complete before trigger
    __builtin_amdgcn_s_waitcnt(0);
    __builtin_amdgcn_s_barrier();
    __atomic_signal_fence(__ATOMIC_SEQ_CST);

    // Set trigger for this chunk (absolute value = baseTrigger + chunkIdx + 1)
    if (threadIdx.x == 0) {
      __atomic_store_n(&args.triggerFlags[blockIdx.x],
                       baseTrigger + static_cast<uint32_t>(chunkIdx + 1),
                       __ATOMIC_RELEASE);
    }

    offsetInt4 += chunkInt4s;
  }

  // Wait for peer SDMA operations to complete (one warp lane per peer)
  if (laneId == 0 && warpId < nPeer) {
    sdma_ep::waitSignal(&mySdmaSignals[warpId], expectedSignal);
  }
}

// Helper function to program SDMA wait_flag_then_put operations for all chunks
// Returns the number of chunks processed (for incrementing expectedTrigger)
size_t programChunkedTransfers(
  AllreduceArgs& args, std::vector<sdma_ep::SdmaQueueHostHandle>& hostHandles,
  int myrank, int nranks, int nBlocks, uint64_t expectedSignal,
  uint32_t baseTrigger) {
  size_t nInt4PerRank = args.nelemsPerRank / 4;
  constexpr size_t nInt4PerChunk = (CHUNK_SIZE_KB * 1024) / sizeof(int4);
  int nPeer = nranks - 1;
  size_t maxChunks = 0;

  // For each block, program wait_flag_then_put for each chunk, then signal
  for (int b = 0; b < nBlocks; ++b) {
    size_t int4PerBlock = (nInt4PerRank + nBlocks - 1) / nBlocks;
    size_t blockStartInt4 = b * int4PerBlock;
    size_t blockInt4s = (b == nBlocks - 1) ? (nInt4PerRank - blockStartInt4)
                                           : int4PerBlock;
    size_t nChunks = (blockInt4s + nInt4PerChunk - 1) / nInt4PerChunk;
    maxChunks = (nChunks > maxChunks) ? nChunks : maxChunks;

    // For each peer, program all chunks then add a signal
    for (int peer = 0; peer < nranks; ++peer) {
      if (peer == myrank)
        continue;

      // Program all chunk transfers for this peer
      for (size_t chunkIdx = 0; chunkIdx < nChunks; ++chunkIdx) {
        size_t chunkStartInt4 = blockStartInt4 + chunkIdx * nInt4PerChunk;
        size_t chunkInt4s = (chunkIdx == nChunks - 1)
                              ? (blockInt4s - chunkIdx * nInt4PerChunk)
                              : nInt4PerChunk;

        void* dst = reinterpret_cast<char*>(args.remoteDst[peer]) +
                    chunkStartInt4 * sizeof(int4);
        void* src = reinterpret_cast<char*>(args.localReduced) +
                    chunkStartInt4 * sizeof(int4);
        size_t bytes = chunkInt4s * sizeof(int4);

        // Block b's flag, waiting for chunk completion (baseTrigger + chunkIdx + 1)
        hostHandles[peer].wait_flag_then_put(
          &args.triggerFlags[b],
          baseTrigger + static_cast<uint32_t>(chunkIdx + 1), src, dst, bytes);
      }

      // After all chunks complete, signal peer that we're done
      int peerIdxOnMe = (peer < myrank) ? peer : peer - 1;
      int slotIdx = b * nPeer + peerIdxOnMe;
      hostHandles[peer].signal(args.remoteSdmaSignals[slotIdx], expectedSignal);
    }
  }

  return maxChunks;
}

void runBenchmark(AllreduceArgs& args, bool deviceTriggered,
                  std::vector<sdma_ep::SdmaQueueHostHandle>& hostHandles,
                  int warmup, int iters, int myrank, int nranks, int nBlocks) {
  size_t totalElems = args.nelemsPerRank * nranks;
  size_t startIdx = myrank * args.nelemsPerRank;

  hipEvent_t start, stop;
  HIP_CHECK(hipEventCreate(&start));
  HIP_CHECK(hipEventCreate(&stop));

  int nThreadsPerBlock = 512;

  // Initialize signal buffers to 0
  int nPeer = nranks - 1;
  HIP_CHECK(
    hipMemset(args.localBarrierSignals, 0, nBlocks * nPeer * sizeof(uint64_t)));
  HIP_CHECK(
    hipMemset(args.localSdmaSignals, 0, nBlocks * nPeer * sizeof(uint64_t)));
  HIP_CHECK(hipMemset(args.triggerFlags, 0, nBlocks * sizeof(uint32_t)));

  uint64_t expectedSignal = 1;
  uint32_t expectedTrigger = 0;

  HIP_CHECK(hipMemset(args.localReduced, 0, totalElems * sizeof(int)));

  MPI_Barrier(MPI_COMM_WORLD);
  // Warmup
  for (int i = 0; i < warmup; ++i) {
    if (deviceTriggered) {
      // Device-triggered: host programs wait_flag_then_put for each chunk, GPU triggers
      size_t nChunks = programChunkedTransfers(args, hostHandles, myrank, nranks, nBlocks,
                                               expectedSignal, expectedTrigger);
      reduceAndTriggerKernel<<<nBlocks, nThreadsPerBlock>>>(args, nBlocks,
                                                            expectedSignal, expectedTrigger);
      expectedTrigger += nChunks;
    } else {
      // Device-initiated: GPU kernel does everything
      sdmaAllreduceKernel<<<nBlocks, nThreadsPerBlock>>>(args, nBlocks,
                                                         expectedSignal);
    }

    expectedSignal++;
  }
  HIP_CHECK(hipDeviceSynchronize());

  MPI_Barrier(MPI_COMM_WORLD);

  // Timed iterations
  HIP_CHECK(hipEventRecord(start));

  for (int i = 0; i < iters; ++i) {
    if (deviceTriggered) {
      // Device-triggered: host programs wait_flag_then_put for each chunk, GPU triggers
      size_t nChunks = programChunkedTransfers(args, hostHandles, myrank, nranks, nBlocks,
                                               expectedSignal, expectedTrigger);
      reduceAndTriggerKernel<<<nBlocks, nThreadsPerBlock>>>(args, nBlocks,
                                                            expectedSignal, expectedTrigger);
      expectedTrigger += nChunks;
    } else {
      sdmaAllreduceKernel<<<nBlocks, nThreadsPerBlock>>>(args, nBlocks,
                                                         expectedSignal);
    }

    expectedSignal++;
  }

  HIP_CHECK(hipEventRecord(stop));
  HIP_CHECK(hipEventSynchronize(stop));

  float milliseconds = 0;
  HIP_CHECK(hipEventElapsedTime(&milliseconds, start, stop));

  HIP_CHECK(hipEventDestroy(start));
  HIP_CHECK(hipEventDestroy(stop));

  // Gather timing to rank 0
  float allTimes[MAX_GPUS];
  MPI_Gather(&milliseconds, 1, MPI_FLOAT, allTimes, 1, MPI_FLOAT, 0,
             MPI_COMM_WORLD);

  if (myrank == 0) {
    // Use max time across all ranks
    float maxTime = allTimes[0];
    for (int i = 1; i < nranks; ++i) {
      if (allTimes[i] > maxTime)
        maxTime = allTimes[i];
    }

    float avgTimeMs = maxTime / iters;
    size_t totalBytes = totalElems * sizeof(int);

    // Bus bandwidth: each rank sends nelemsPerRank to (nranks-1) peers
    // Total data movement = nranks * nelemsPerRank * (nranks-1)
    size_t totalBusBytes = 2 * (nranks - 1) * totalBytes / nranks;
    double busBW = (totalBusBytes / (1024.0 * 1024.0 * 1024.0)) /
                   (avgTimeMs / 1000.0);

    // Algbw: total data size / time
    double algBW = (totalBytes / (1024.0 * 1024.0 * 1024.0)) /
                   (avgTimeMs / 1000.0);

    printf("%10zu  %10.2f  %10.2f  %10.2f\n", totalBytes / 1024,
           avgTimeMs * 1000, busBW, algBW);
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
      fprintf(stderr, "allreduce requires at least 2 ranks\n");
    MPI_Finalize();
    return 1;
  }
  if (nranks > MAX_GPUS) {
    if (myrank == 0)
      fprintf(stderr, "Max supported ranks: %d\n", MAX_GPUS);
    MPI_Finalize();
    return 1;
  }

  // Parse arguments
  int warmup = 5;
  int iters = 20;
  bool deviceTriggered = false;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-w") == 0 && i + 1 < argc) {
      warmup = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-n") == 0 && i + 1 < argc) {
      iters = atoi(argv[++i]);
    } else if (strcmp(argv[i], "--device-triggered") == 0) {
      deviceTriggered = true;
    }
  }

  if (myrank == 0) {
    printf("# SDMA AllReduce Benchmark\n");
    printf("# Ranks: %d, Mode: %s\n", nranks,
           deviceTriggered ? "device-triggered" : "device-initiated");
    printf("# Warmup: %d, Iterations: %d\n", warmup, iters);
    printf("#\n");
    printf("# %8s  %10s  %10s  %10s\n", "Size(KB)", "Time(us)", "BusBW(GB/s)",
           "AlgBW(GB/s)");
    printf("#--------------------------------------------------\n");
  }

  // Set HIP device
  HIP_CHECK(hipSetDevice(myrank));

  // Initialize XIO
  int rc = sdma_ep::initEndpoint();
  if (rc != 0) {
    fprintf(stderr, "[rank %d] sdma_ep::initEndpoint failed (%d)\n", myrank,
            rc);
    MPI_Abort(MPI_COMM_WORLD, 1);
  }

  // Allocate maximum size buffers (16 MB per rank)
  size_t maxElemsPerRank = (256 * 1024 * 1024) / sizeof(int);
  size_t maxTotalElems = maxElemsPerRank * nranks;

  int* inputBuf;
  int* resultBuf;
  uint64_t* barrierSignalBuf;
  uint64_t* sdmaSignalBuf;
  uint32_t* triggerFlags;

  constexpr int nBlocks = 8;
  int nPeer = nranks - 1;

  HIP_CHECK(hipExtMallocWithFlags((void**)&inputBuf,
                                  maxTotalElems * sizeof(int),
                                  hipDeviceMallocUncached));
  HIP_CHECK(hipExtMallocWithFlags((void**)&resultBuf,
                                  maxTotalElems * sizeof(int),
                                  hipDeviceMallocUncached));
  HIP_CHECK(hipExtMallocWithFlags((void**)&barrierSignalBuf,
                                  nBlocks * nPeer * sizeof(uint64_t),
                                  hipDeviceMallocUncached));
  HIP_CHECK(hipExtMallocWithFlags((void**)&sdmaSignalBuf,
                                  nBlocks * nPeer * sizeof(uint64_t),
                                  hipDeviceMallocUncached));
  HIP_CHECK(hipExtMallocWithFlags((void**)&triggerFlags,
                                  nBlocks * sizeof(uint32_t),
                                  hipDeviceMallocUncached));

  // Initialize input
  int* hostInput = new int[maxTotalElems];
  for (size_t i = 0; i < maxTotalElems; ++i) {
    hostInput[i] = myrank;
  }
  HIP_CHECK(hipMemcpy(inputBuf, hostInput, maxTotalElems * sizeof(int),
                      hipMemcpyHostToDevice));

  // Exchange IPC handles
  hipIpcMemHandle_t inputHandle, resultHandle, barrierSignalHandle,
    sdmaSignalHandle;
  HIP_CHECK(hipIpcGetMemHandle(&inputHandle, inputBuf));
  HIP_CHECK(hipIpcGetMemHandle(&resultHandle, resultBuf));
  HIP_CHECK(hipIpcGetMemHandle(&barrierSignalHandle, barrierSignalBuf));
  HIP_CHECK(hipIpcGetMemHandle(&sdmaSignalHandle, sdmaSignalBuf));

  hipIpcMemHandle_t* allInputHandles = new hipIpcMemHandle_t[nranks];
  hipIpcMemHandle_t* allResultHandles = new hipIpcMemHandle_t[nranks];
  hipIpcMemHandle_t* allBarrierSignalHandles = new hipIpcMemHandle_t[nranks];
  hipIpcMemHandle_t* allSdmaSignalHandles = new hipIpcMemHandle_t[nranks];

  MPI_Allgather(&inputHandle, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                allInputHandles, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                MPI_COMM_WORLD);
  MPI_Allgather(&resultHandle, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                allResultHandles, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                MPI_COMM_WORLD);
  MPI_Allgather(&barrierSignalHandle, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                allBarrierSignalHandles, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                MPI_COMM_WORLD);
  MPI_Allgather(&sdmaSignalHandle, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                allSdmaSignalHandles, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                MPI_COMM_WORLD);

  // Create SDMA queues
  sdma_ep::SdmaQueueInfo queueInfos[MAX_GPUS] = {};
  std::vector<sdma_ep::SdmaQueueHostHandle> hostHandles;
  if (deviceTriggered) {
    hostHandles.reserve(nranks);
  }

  // Allocate pointer arrays for remote signals (nBlocks * nPeer pointers)
  uint64_t** remoteBarrierSignalPtrs;
  uint64_t** remoteSdmaSignalPtrs;
  uint64_t** hostBarrierPtrs = new uint64_t*[nBlocks * nPeer];
  uint64_t** hostSdmaPtrs = new uint64_t*[nBlocks * nPeer];

  // Initialize to nullptr
  for (int i = 0; i < nBlocks * nPeer; ++i) {
    hostBarrierPtrs[i] = nullptr;
    hostSdmaPtrs[i] = nullptr;
  }

  HIP_CHECK(
    hipMalloc(&remoteBarrierSignalPtrs, nBlocks * nPeer * sizeof(uint64_t*)));
  HIP_CHECK(
    hipMalloc(&remoteSdmaSignalPtrs, nBlocks * nPeer * sizeof(uint64_t*)));

  AllreduceArgs args = {};
  args.localInput = inputBuf;
  args.localReduced = resultBuf;
  args.localBarrierSignals = barrierSignalBuf;
  args.localSdmaSignals = sdmaSignalBuf;
  args.remoteBarrierSignals = remoteBarrierSignalPtrs;
  args.remoteSdmaSignals = remoteSdmaSignalPtrs;
  args.triggerFlags = triggerFlags;
  args.myrank = myrank;
  args.nranks = nranks;

  for (int peer = 0; peer < nranks; ++peer) {
    if (peer == myrank) {
      if (deviceTriggered) {
        hostHandles.push_back(sdma_ep::SdmaQueueHostHandle(nullptr));
      }
      continue;
    }

    xio::enablePeerAccess(myrank, peer);

    if (deviceTriggered) {
      rc = sdma_ep::createHostQueue(myrank, peer, &queueInfos[peer]);
      if (rc != 0) {
        fprintf(stderr, "[rank %d] createHostQueue(%d->%d) failed (%d)\n",
                myrank, myrank, peer, rc);
        MPI_Abort(MPI_COMM_WORLD, 1);
      }
      hostHandles.push_back(sdma_ep::getHostHandle(myrank, peer, 0));
    } else {
      rc = sdma_ep::createQueue(myrank, peer, &queueInfos[peer]);
      if (rc != 0) {
        fprintf(stderr, "[rank %d] createQueue(%d->%d) failed (%d)\n", myrank,
                myrank, peer, rc);
        MPI_Abort(MPI_COMM_WORLD, 1);
      }
      args.queues[peer] = static_cast<sdma_ep::SdmaQueueHandle*>(
        queueInfos[peer].deviceHandle);

      if (args.queues[peer] == nullptr) {
        fprintf(stderr,
                "[rank %d] ERROR: queue deviceHandle for peer %d is nullptr!\n",
                myrank, peer);
        MPI_Abort(MPI_COMM_WORLD, 1);
      }
      // fprintf(stderr, "[rank %d] Created queue to peer %d, handle=%p\n",
      //         myrank, peer, args.queues[peer]);
    }

    HIP_CHECK(
      hipIpcOpenMemHandle(reinterpret_cast<void**>(&args.remoteBufs[peer]),
                          allInputHandles[peer],
                          hipIpcMemLazyEnablePeerAccess));
    HIP_CHECK(
      hipIpcOpenMemHandle(reinterpret_cast<void**>(&args.remoteDst[peer]),
                          allResultHandles[peer],
                          hipIpcMemLazyEnablePeerAccess));

    // Open peer's signal buffers
    uint64_t* peerBarrierSignals;
    uint64_t* peerSdmaSignals;
    HIP_CHECK(hipIpcOpenMemHandle(reinterpret_cast<void**>(&peerBarrierSignals),
                                  allBarrierSignalHandles[peer],
                                  hipIpcMemLazyEnablePeerAccess));
    HIP_CHECK(hipIpcOpenMemHandle(reinterpret_cast<void**>(&peerSdmaSignals),
                                  allSdmaSignalHandles[peer],
                                  hipIpcMemLazyEnablePeerAccess));

    // Populate host pointer arrays
    // On this GPU, threadIdx i handles peer (i < myrank ? i : i+1)
    // On peer GPU, we are at position (myrank < peer ? myrank : myrank-1)
    int myIdxOnPeer = (myrank < peer) ? myrank : myrank - 1;
    int peerIdxOnMe = (peer < myrank) ? peer : peer - 1;

    for (int b = 0; b < nBlocks; ++b) {
      int slotIdx = b * nPeer + peerIdxOnMe;
      hostBarrierPtrs[slotIdx] = peerBarrierSignals + b * nPeer + myIdxOnPeer;
      hostSdmaPtrs[slotIdx] = peerSdmaSignals + b * nPeer + myIdxOnPeer;
    }
  }

  // Copy pointer arrays to device
  HIP_CHECK(hipMemcpy(remoteBarrierSignalPtrs, hostBarrierPtrs,
                      nBlocks * nPeer * sizeof(uint64_t*),
                      hipMemcpyHostToDevice));
  HIP_CHECK(hipMemcpy(remoteSdmaSignalPtrs, hostSdmaPtrs,
                      nBlocks * nPeer * sizeof(uint64_t*),
                      hipMemcpyHostToDevice));

  delete[] allInputHandles;
  delete[] allResultHandles;
  delete[] allBarrierSignalHandles;
  delete[] allSdmaSignalHandles;
  delete[] hostBarrierPtrs;
  delete[] hostSdmaPtrs;

  // Sweep power-of-2 sizes from 4 KB to 16 MB
  for (size_t sizeBytes = 256 * 1024 * 1024; sizeBytes <= 256 * 1024 * 1024;
       sizeBytes *= 2) {
    size_t totalElems = sizeBytes / sizeof(int);
    size_t nelemsPerRank = totalElems / nranks;

    args.nelemsPerRank = nelemsPerRank;

    runBenchmark(args, deviceTriggered, hostHandles, warmup, iters, myrank,
                 nranks, nBlocks);

    MPI_Barrier(MPI_COMM_WORLD);
  }

  // Cleanup
  for (int peer = 0; peer < nranks; ++peer) {
    if (peer == myrank)
      continue;
    HIP_CHECK(hipIpcCloseMemHandle(args.remoteBufs[peer]));
    HIP_CHECK(hipIpcCloseMemHandle(args.remoteDst[peer]));
    // Note: We opened peer signal buffers but stored pointers in arrays,
    // cleanup handled by hipFree below
    if (!deviceTriggered) {
      sdma_ep::destroyQueue(&queueInfos[peer]);
    }
  }

  sdma_ep::shutdownEndpoint();
  HIP_CHECK(hipFree(inputBuf));
  HIP_CHECK(hipFree(resultBuf));
  HIP_CHECK(hipFree(barrierSignalBuf));
  HIP_CHECK(hipFree(sdmaSignalBuf));
  HIP_CHECK(hipFree(remoteBarrierSignalPtrs));
  HIP_CHECK(hipFree(remoteSdmaSignalPtrs));
  HIP_CHECK(hipFree(triggerFlags));
  delete[] hostInput;

  MPI_Finalize();
  return 0;
}
