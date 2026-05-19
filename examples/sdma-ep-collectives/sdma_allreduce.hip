/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * AllReduce collective using SDMA with validation
 */

#include "sdma_common.hpp"
#include <xio.h>
#include "endpoints/sdma-ep/sdma-ep.h"
#include "endpoints/sdma-ep/sdma-host-queue.h"
#include "endpoints/sdma-ep/sdma_device.hpp"

#include <cstdio>
#include <vector>

using namespace xio;

// Kernel arguments for AllReduce
struct AllreduceArgs {
  sdma_ep::SdmaQueueHandle* queues[MAX_GPUS];
  int* remoteBufs[MAX_GPUS];       // Peer input buffers for local reduction
  int* remoteDst[MAX_GPUS];        // Peer result buffers for allgather
  uint64_t** remoteBarrierSignals; // [nBlocks*nPeer] pointers to remote barrier slots
  uint64_t** remoteSdmaSignals;    // [nBlocks*nPeer] pointers to remote SDMA slots
  uint64_t* localBarrierSignals;   // Local barrier signals: nBlocks*nPeer slots
  uint64_t* localSdmaSignals;      // Local SDMA signals: nBlocks*nPeer slots
  uint32_t* triggerFlags;          // Trigger flags for device-triggered mode
  int* localInput;                 // This rank's input buffer
  int* localReduced;               // This rank's reduced result buffer
  size_t nelemsPerRank;            // Number of int32 elements per rank
  int myrank;
  int nranks;
};

// Device function: Cross-GPU barrier (copied from current implementation)
__device__ void crossGpuBarrierAllreduce(AllreduceArgs& args, int nPeer,
                                         uint64_t* myBarrierSignals,
                                         uint64_t expectedSignal) {
  if (threadIdx.x < static_cast<uint32_t>(nPeer)) {
    int slotIdx = blockIdx.x * nPeer + threadIdx.x;
    __atomic_store_n(args.remoteBarrierSignals[slotIdx], expectedSignal,
                     __ATOMIC_RELAXED);
    while (__atomic_load_n(&myBarrierSignals[threadIdx.x], __ATOMIC_RELAXED) <
           expectedSignal) {
    }
  }
  __syncthreads();
}

// Kernel: Device-initiated AllReduce
// Processes data in chunks, overlapping reduction with SDMA transfers
__global__ void sdmaAllreduceKernel(AllreduceArgs args, int nBlocks,
                                    uint64_t expectedSignal) {
  const int rank = args.myrank;
  const int nranks = args.nranks;
  const size_t nelemsPerRank = args.nelemsPerRank;
  const int laneId = threadIdx.x % WARP_SIZE;
  const int warpId = threadIdx.x / WARP_SIZE;
  const int nPeer = nranks - 1;

  // Get base pointers for this block's signal section
  uint64_t* myBarrierSignals = args.localBarrierSignals + blockIdx.x * nPeer;
  uint64_t* mySdmaSignals = args.localSdmaSignals + blockIdx.x * nPeer;

  // Work in int4 units for vectorization
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

  // Initial cross-GPU synchronization
  crossGpuBarrierAllreduce(args, nPeer, myBarrierSignals, expectedSignal);

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

    offsetInt4 += chunkInt4s;
  }

  // Signal completion and wait for peers
  if (laneId == 0 && warpId < nPeer) {
    int peer = (warpId < rank) ? warpId : warpId + 1;
    int slotIdx = blockIdx.x * nPeer + warpId;

    sdma_ep::signal(*args.queues[peer], args.remoteSdmaSignals[slotIdx]);
    sdma_ep::waitSignal(&mySdmaSignals[warpId], expectedSignal);
    sdma_ep::quiet(*args.queues[peer]);
  }
}

// Kernel: Device-triggered AllReduce
// Reduces data and sets trigger flags; host pre-programs SDMA queue
__global__ void reduceAndTriggerKernel(AllreduceArgs args, int nBlocks,
                                       uint64_t expectedSignal) {
  const int rank = args.myrank;
  const int nranks = args.nranks;
  const size_t nelemsPerRank = args.nelemsPerRank;
  const int laneId = threadIdx.x % WARP_SIZE;
  const int warpId = threadIdx.x / WARP_SIZE;
  const int nPeer = nranks - 1;

  uint64_t* mySdmaSignals = args.localSdmaSignals + blockIdx.x * nPeer;
  uint64_t* myBarrierSignals = args.localBarrierSignals + blockIdx.x * nPeer;

  constexpr size_t nInt4PerChunk = (CHUNK_SIZE_KB * 1024) / sizeof(int4);
  const size_t nInt4PerRank = nelemsPerRank / 4;

  const size_t int4PerBlock = (nInt4PerRank + nBlocks - 1) / nBlocks;
  const size_t blockStartInt4 = blockIdx.x * int4PerBlock;
  const size_t blockInt4s = (blockIdx.x == nBlocks - 1)
                              ? (nInt4PerRank - blockStartInt4)
                              : int4PerBlock;

  if (blockStartInt4 >= nInt4PerRank)
    return;

  const size_t nChunks = (blockInt4s + nInt4PerChunk - 1) / nInt4PerChunk;
  size_t offsetInt4 = (rank * nInt4PerRank) + blockStartInt4;

  // Cross-GPU barrier synchronization
  crossGpuBarrierAllreduce(args, nPeer, myBarrierSignals, expectedSignal);

  int4* localInput4 = reinterpret_cast<int4*>(args.localInput);
  int4* localReduced4 = reinterpret_cast<int4*>(args.localReduced);

  // Process each chunk: reduce, then trigger
  for (size_t chunkIdx = 0; chunkIdx < nChunks; ++chunkIdx) {
    size_t chunkInt4s = (chunkIdx == nChunks - 1)
                          ? (blockInt4s - chunkIdx * nInt4PerChunk)
                          : nInt4PerChunk;

    // Reduce this chunk from all peers
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

    // Ensure chunk reduction is complete before trigger
    __builtin_amdgcn_s_waitcnt(0);
    __builtin_amdgcn_s_barrier();
    __atomic_signal_fence(__ATOMIC_SEQ_CST);

    // Set trigger for this chunk (all blocks increment the same chunk flag)
    if (threadIdx.x == 0) {
      __atomic_fetch_add(&args.triggerFlags[chunkIdx], 1, __ATOMIC_RELAXED);
    }

    offsetInt4 += chunkInt4s;
  }

  // Wait for peer SDMA operations to complete
  if (laneId == 0 && warpId < nPeer) {
    sdma_ep::waitSignal(&mySdmaSignals[warpId], expectedSignal);
  }

}

// Host helper: Program chunked transfers for device-triggered mode
// Chunk-major ordering: for each chunk, transfer from all blocks
size_t programChunkedTransfers(
  AllreduceArgs& args, sdma_ep::SdmaQueueHostHandle* hostHandles,
  const SdmaTestConfig& config, int myrank, int nranks, int nBlocks,
  uint32_t* chunkExpected, const uint32_t* chunkContributors,
  size_t maxChunksPerBlockInput) {

  size_t nInt4PerRank = args.nelemsPerRank / 4;
  constexpr size_t nInt4PerChunk = (CHUNK_SIZE_KB * 1024) / sizeof(int4);
  int nPeer = nranks - 1;
  const size_t rankBaseInt4 = static_cast<size_t>(myrank) * nInt4PerRank;

  // Calculate chunks per block
  size_t int4PerBlock = (nInt4PerRank + nBlocks - 1) / nBlocks;
  size_t maxChunksPerBlock =
    (int4PerBlock + nInt4PerChunk - 1) / nInt4PerChunk;
  if (maxChunksPerBlockInput != 0 &&
      maxChunksPerBlockInput < maxChunksPerBlock) {
    maxChunksPerBlock = maxChunksPerBlockInput;
  }

  // Chunk-major ordering: for each chunk, transfer from all blocks
  for (size_t chunkIdx = 0; chunkIdx < maxChunksPerBlock; ++chunkIdx) {
    uint32_t contributors = config.nBlocks;
    if (chunkContributors && chunkIdx < maxChunksPerBlockInput) {
      contributors = chunkContributors[chunkIdx];
    }
    if (contributors == 0) {
      continue;
    }

    uint32_t expectedCount = contributors;
    if (chunkExpected && chunkIdx < maxChunksPerBlockInput) {
      expectedCount = chunkExpected[chunkIdx] + contributors;
    }

    for (int peer = 0; peer < nranks; ++peer) {
      if (peer == myrank) continue;

      bool firstPut = true;

      for (int b = 0; b < nBlocks; ++b) {
        size_t blockStartInt4 = b * int4PerBlock;
        size_t blockInt4s = (b == nBlocks - 1)
                            ? (nInt4PerRank - blockStartInt4)
                            : int4PerBlock;

        if (blockStartInt4 >= nInt4PerRank) continue;

        size_t nChunks = (blockInt4s + nInt4PerChunk - 1) / nInt4PerChunk;
        if (chunkIdx >= nChunks) continue;

        size_t chunkStartInt4 = blockStartInt4 + chunkIdx * nInt4PerChunk;
        size_t chunkInt4s = (chunkIdx == nChunks - 1)
                            ? (blockInt4s - chunkIdx * nInt4PerChunk)
                            : nInt4PerChunk;

        size_t chunkOffsetInt4 = rankBaseInt4 + chunkStartInt4;

        void* dst = reinterpret_cast<char*>(args.remoteDst[peer]) +
                    chunkOffsetInt4 * sizeof(int4);
        void* src = reinterpret_cast<char*>(args.localReduced) +
                    chunkOffsetInt4 * sizeof(int4);
        size_t bytes = chunkInt4s * sizeof(int4);

        if (firstPut) {
          // Wait for all blocks to complete this chunk
          hostHandles[peer].wait_flag_then_put(
            &args.triggerFlags[chunkIdx],
            expectedCount,
            src, dst, bytes);
          firstPut = false;
        } else {
          // Just transfer
          hostHandles[peer].put(src, dst, bytes);
        }
      }
    }

    if (chunkExpected && chunkIdx < maxChunksPerBlockInput) {
      chunkExpected[chunkIdx] = expectedCount;
    }
  }

  // Signal completion after all chunks so device-triggered kernels observe
  // queue completion when they spin on SDMA signal slots.
  for (int b = 0; b < nBlocks; ++b) {
    for (int peer = 0; peer < nranks; ++peer) {
      if (peer == myrank) {
        continue;
      }

      int peerIdxOnMe = (peer < myrank) ? peer : peer - 1;
      int slotIdx = b * nPeer + peerIdxOnMe;
      hostHandles[peer].signal(args.remoteSdmaSignals[slotIdx],
                               static_cast<uint64_t>(1));
    }
  }

  return maxChunksPerBlock;
}

// AllReduce collective implementation
class SdmaAllreduceTestColl : public SdmaTestColl {
public:
  void initData(int rank, int nranks, void* inputBuf,
               void* expectedBuf, size_t nelemsPerRank) override {
    // Fill input with rank ID
    size_t totalElems = nelemsPerRank * nranks;
    std::vector<int> hostData(totalElems, rank);
    HIP_CHECK(hipMemcpy(inputBuf, hostData.data(), totalElems * sizeof(int),
                        hipMemcpyHostToDevice));

    // Expected: sum of all ranks = nranks*(nranks-1)/2
    int expectedValue = nranks * (nranks - 1) / 2;
    std::fill((int*)expectedBuf, (int*)expectedBuf + totalElems, expectedValue);
  }

  void setupCollTest(size_t size) override {
    currentSize_ = size;
    currentElemsPerRank_ = size / sizeof(int) / nranks_;
    currentSignal_ = 1;
    recomputeChunkMetadata();
    markKernelArgsDirty();
  }

  // Pre-program SDMA queue for all iterations (called before benchmarking)
  void preprogramIterations(int iters) override {
    if (!config_.deviceTriggered) return;

    refreshKernelArgs();
    AllreduceArgs& args = kernelArgs_;
    for (int i = 0; i < iters; ++i) {
      uint32_t* expectedPtr =
        chunkTriggerExpected_.empty() ? nullptr : chunkTriggerExpected_.data();
      const uint32_t* contributorPtr =
        chunkContributors_.empty() ? nullptr : chunkContributors_.data();
      programChunkedTransfers(args, hostHandles_, config_, rank_, nranks_,
                              config_.nBlocks, expectedPtr, contributorPtr,
                              maxChunksPerBlock_);
    }
  }

  void runColl(const SdmaTestConfig& config, int rank, int nranks,
              hipStream_t stream) override {
    refreshKernelArgs();
    AllreduceArgs& args = kernelArgs_;

    if (config.deviceTriggered) {
      reduceAndTriggerKernel<<<config.nBlocks, config.nThreadsPerBlock,
                              0, stream>>>(args, config.nBlocks, currentSignal_);
    } else {
      sdmaAllreduceKernel<<<config.nBlocks, config.nThreadsPerBlock,
                           0, stream>>>(args, config.nBlocks, currentSignal_);
    }
    currentSignal_++;
  }

  void getBw(double deltaSec, double& algBw, double& busBw) override {
    // Algorithmic BW
    algBw = (currentSize_ / (1024.0 * 1024.0 * 1024.0)) / deltaSec;

    // Bus BW (allreduce: 2*(N-1)/N factor)
    size_t totalBusBytes = 2 * (nranks_ - 1) * currentSize_ / nranks_;
    busBw = (totalBusBytes / (1024.0 * 1024.0 * 1024.0)) / deltaSec;
  }

  size_t getInputBufferSize(size_t nelemsPerRank, int nranks) const override {
    return nelemsPerRank * nranks * sizeof(int);
  }

  size_t getResultBufferSize(size_t nelemsPerRank, int nranks) const override {
    return nelemsPerRank * nranks * sizeof(int);
  }

  size_t getExpectedBufferSize(size_t nelemsPerRank, int nranks) const override {
    return nelemsPerRank * nranks * sizeof(int);
  }

  void setBuffers(int* input, int* result,
                 uint64_t* barrierSigs, uint64_t* sdmaSigs,
                 uint32_t* triggerFlags) override {
    inputBuf_ = input;
    resultBuf_ = result;
    barrierSignals_ = barrierSigs;
    sdmaSignals_ = sdmaSigs;
    triggerFlags_ = triggerFlags;
    markKernelArgsDirty();
  }

  void setQueues(sdma_ep::SdmaQueueInfo* queues,
                sdma_ep::SdmaQueueHostHandle* hostHandles) override {
    queues_ = queues;
    hostHandles_ = hostHandles;
    markKernelArgsDirty();
  }

  void setIpcHandles(int** remoteBufs, int** remoteDst,
                    uint64_t** remoteBarrierSignals,
                    uint64_t** remoteSdmaSignals) override {
    remoteBufs_ = remoteBufs;
    remoteDst_ = remoteDst;
    remoteBarrierSignals_ = remoteBarrierSignals;
    remoteSdmaSignals_ = remoteSdmaSignals;
    markKernelArgsDirty();
  }

  void setRankInfo(int rank, int nranks, const SdmaTestConfig& config) {
    rank_ = rank;
    nranks_ = nranks;
    config_ = config;
    recomputeChunkMetadata();
    markKernelArgsDirty();
  }

private:
  void recomputeChunkMetadata() {
    if (config_.nBlocks <= 0) {
      maxChunksPerBlock_ = 0;
      chunkTriggerExpected_.clear();
      chunkContributors_.clear();
      return;
    }
    constexpr size_t nInt4PerChunk = (CHUNK_SIZE_KB * 1024) / sizeof(int4);
    size_t nInt4PerRank =
      (currentElemsPerRank_ >= 4) ? (currentElemsPerRank_ / 4) : 0;
    size_t int4PerBlock = (nInt4PerRank + config_.nBlocks - 1) /
                          (config_.nBlocks == 0 ? 1 : config_.nBlocks);
    maxChunksPerBlock_ =
      (int4PerBlock + nInt4PerChunk - 1) / nInt4PerChunk;

    if (nInt4PerRank == 0) {
      maxChunksPerBlock_ = 0;
    }

    chunkTriggerExpected_.assign(maxChunksPerBlock_, 0);
    chunkContributors_.assign(maxChunksPerBlock_, 0);

    for (size_t chunkIdx = 0; chunkIdx < maxChunksPerBlock_; ++chunkIdx) {
      uint32_t contributors = 0;
      for (int b = 0; b < config_.nBlocks; ++b) {
        size_t blockStartInt4 = static_cast<size_t>(b) * int4PerBlock;
        size_t blockInt4s = (b == config_.nBlocks - 1)
                              ? (nInt4PerRank > blockStartInt4
                                   ? (nInt4PerRank - blockStartInt4)
                                   : 0)
                              : int4PerBlock;

        if (blockStartInt4 >= nInt4PerRank) {
          continue;
        }

        size_t nChunks = (blockInt4s + nInt4PerChunk - 1) / nInt4PerChunk;
        if (chunkIdx < nChunks) {
          contributors++;
        }
      }
      chunkContributors_[chunkIdx] = contributors;
    }
  }

  void markKernelArgsDirty() { kernelArgsDirty_ = true; }

  void refreshKernelArgs() {
    if (!kernelArgsDirty_) {
      return;
    }

    kernelArgs_ = {};
    kernelArgs_.localInput = inputBuf_;
    kernelArgs_.localReduced = resultBuf_;
    kernelArgs_.localBarrierSignals = barrierSignals_;
    kernelArgs_.localSdmaSignals = sdmaSignals_;
    kernelArgs_.remoteBarrierSignals = remoteBarrierSignals_;
    kernelArgs_.remoteSdmaSignals = remoteSdmaSignals_;
    kernelArgs_.triggerFlags = triggerFlags_;
    kernelArgs_.myrank = rank_;
    kernelArgs_.nranks = nranks_;
    kernelArgs_.nelemsPerRank = currentElemsPerRank_;

    for (int i = 0; i < MAX_GPUS; ++i) {
      if (remoteBufs_) kernelArgs_.remoteBufs[i] = remoteBufs_[i];
      if (remoteDst_) kernelArgs_.remoteDst[i] = remoteDst_[i];
    }

    if (!config_.deviceTriggered && queues_) {
      for (int peer = 0; peer < nranks_; ++peer) {
        if (peer == rank_) continue;
        kernelArgs_.queues[peer] = static_cast<sdma_ep::SdmaQueueHandle*>(
          queues_[peer].deviceHandle);
      }
    }

    kernelArgsDirty_ = false;
  }

  // Test state
  size_t currentSize_ = 0;
  size_t currentElemsPerRank_ = 0;
  int rank_ = 0;
  int nranks_ = 0;
  SdmaTestConfig config_;

  uint64_t currentSignal_ = 1;

  // Pointers to engine-managed resources
  int* inputBuf_ = nullptr;
  int* resultBuf_ = nullptr;
  uint64_t* barrierSignals_ = nullptr;
  uint64_t* sdmaSignals_ = nullptr;
  uint32_t* triggerFlags_ = nullptr;
  sdma_ep::SdmaQueueInfo* queues_ = nullptr;
  sdma_ep::SdmaQueueHostHandle* hostHandles_ = nullptr;
  int** remoteBufs_ = nullptr;
  int** remoteDst_ = nullptr;
  uint64_t** remoteBarrierSignals_ = nullptr;
  uint64_t** remoteSdmaSignals_ = nullptr;

  AllreduceArgs kernelArgs_{};
  bool kernelArgsDirty_ = true;
  std::vector<uint32_t> chunkTriggerExpected_;
  std::vector<uint32_t> chunkContributors_;
  size_t maxChunksPerBlock_ = 0;
};

// Main entry point
int main(int argc, char** argv) {
  SdmaAllreduceTestColl coll;
  SdmaTestEngine engine(argc, argv, &coll);

  engine.initialize();

  // Set rank info in collective (get config from engine after arg parsing)
  coll.setRankInfo(engine.getRank(), engine.getNranks(), engine.getConfig());

  engine.allocateBuffers();
  engine.setupQueues();
  engine.runBenchmark();
  engine.cleanup();

  return 0;
}
