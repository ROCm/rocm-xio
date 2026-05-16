/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * AllToAll collective using SDMA with validation
 */

#include <cstdio>
#include <vector>

#include <xio.h>

#include "endpoints/sdma-ep/sdma-ep.h"
#include "endpoints/sdma-ep/sdma-host-queue.h"
#include "endpoints/sdma-ep/sdma_device.hpp"
#include "sdma_common.hpp"

using namespace xio;

// Kernel arguments for AllToAll
struct AlltoallArgs {
  sdma_ep::SdmaQueueHandle* queues[MAX_GPUS]; // SDMA queue handles
  int* remoteDst[MAX_GPUS];                   // Peer result buffers
  uint64_t** remoteBarrierSignals;            // Cross-GPU barrier pointers
  uint64_t** remoteSdmaSignals;               // SDMA completion signals
  uint64_t* localBarrierSignals;
  uint64_t* localSdmaSignals;
  uint64_t* localCounters; // Per-warp completion counters
  uint32_t* triggerFlags;  // Device-triggered mode
  int* localInput;         // This rank's input (full array)
  int* localResult;        // This rank's result (full array)
  size_t nelemsPerRank;
  int myrank;
  int nranks;
};

// Kernel: Device-initiated AllToAll
// In-place operation: data already in localResult buffer at correct offset
// Single block with 7 warps (448 threads), each warp handles one peer
// Uses counter-based synchronization for efficient completion tracking
__global__ void sdmaAlltoallKernel(AlltoallArgs args, int nBlocks,
                                   uint64_t expectedSignal) {
  const int rank = args.myrank;
  const int nranks = args.nranks;
  const size_t nelemsPerRank = args.nelemsPerRank;
  const int laneId = threadIdx.x % WARP_SIZE;
  const int warpId = threadIdx.x / WARP_SIZE;
  const int nPeer = nranks - 1;

  // Only use warpId < nPeer (7 warps for 8 ranks)
  if (warpId >= nranks)
    return;

  // Map warpId to peer rank
  int peer = (warpId < rank) ? warpId : warpId + 1;

  // This rank's data segment (already in buffer at rank*nelemsPerRank)
  size_t bytes = nelemsPerRank * sizeof(int);

  // Each warp does put+signal+counter to its assigned peer
  if (laneId == 0 && warpId < nPeer) {
    // Source: this rank's data in local buffer
    void* src = &args.localInput[peer * nelemsPerRank];
    // Destination: same offset in peer's buffer
    void* dst = &args.remoteDst[peer][rank * nelemsPerRank];
    // Put data, increment signal, and increment counter
    sdma_ep::putSignalCounter(*args.queues[peer], dst, src, bytes,
                              args.remoteSdmaSignals[warpId],
                              &args.localCounters[peer]);

    // Wait for peer's data to arrive
    sdma_ep::waitSignal(&args.localSdmaSignals[warpId], expectedSignal);

    // Wait for our counter to reach expected value (operation complete)
    sdma_ep::waitCounter(&args.localCounters[peer], expectedSignal);
  }
  if (laneId == 0 && warpId == nPeer) {
    // Source: this rank's data in local buffer
    void* src = &args.localInput[rank * nelemsPerRank];
    void* dst = &args.localResult[rank * nelemsPerRank];
    // Put data, increment signal, and increment counter
    sdma_ep::putCounter(*args.queues[rank], dst, src, bytes,
                        &args.localCounters[rank]);
    // Wait for our counter to reach expected value (operation complete)
    sdma_ep::waitCounter(&args.localCounters[rank], expectedSignal);
  }
}

// Kernel: Device-triggered AllToAll
// Single warp (64 threads), one thread increments trigger to release SDMA ops
// Host pre-programs SDMA queue with wait_flag_then_put
__global__ void alltoallTriggerKernel(AlltoallArgs args, int nBlocks,
                                      uint64_t expectedSignal) {
  const int nPeer = args.nranks - 1;
  const int tid = threadIdx.x;

  // Single thread increments the trigger flag to signal host-programmed SDMA
  if (tid == 0) {
    // Atomically increment trigger to release this iteration's SDMA operations
    __hip_atomic_fetch_add(&args.triggerFlags[0], 1, __ATOMIC_RELAXED,
                           __HIP_MEMORY_SCOPE_AGENT);
  }

  if (tid < nPeer) {
    // Wait for all peer SDMA operations to complete
    sdma_ep::waitSignal(&args.localSdmaSignals[tid], expectedSignal);
  }
  if (tid < args.nranks) {
    // Wait for our counter to reach expected value (operation complete)
    sdma_ep::waitCounter(&args.localCounters[tid], expectedSignal);
  }
}

// AllToAll collective implementation
class SdmaAlltoallTestColl : public SdmaTestColl {
public:
  SdmaAlltoallTestColl() = default;

  ~SdmaAlltoallTestColl() {
    if (counters_) {
      HIP_CHECK(hipFree(counters_));
      counters_ = nullptr;
    }
  }

  void initData(int rank, int nranks, void* inputBuf, void* expectedBuf,
                size_t nelemsPerRank) override {
    size_t totalElems = nelemsPerRank * nranks;
    std::vector<int> hostData(totalElems, 0);

    // Fill data destined for each peer rank
    for (int r = 0; r < nranks; ++r) {
      for (size_t i = 0; i < nelemsPerRank; ++i) {
        hostData[r * nelemsPerRank + i] = rank + r * nranks + i;
      }
    }

    // Copy to result buffer (in-place buffer)
    HIP_CHECK(hipMemcpy(inputBuf, hostData.data(), totalElems * sizeof(int),
                        hipMemcpyHostToDevice));

    int* expected = static_cast<int*>(expectedBuf);
    for (int r = 0; r < nranks; ++r) {
      for (size_t i = 0; i < nelemsPerRank; ++i) {
        expected[r * nelemsPerRank + i] = r + rank * nranks + i;
      }
    }
  }

  void setupCollTest(size_t size) override {
    currentSize_ = size;
    currentElemsPerRank_ = size / sizeof(int) / nranks_;
    markKernelArgsDirty();
  }

  // Pre-program SDMA queue for all iterations (called before benchmarking)
  void preprogramIterations(int iters) override {
    if (!config_.deviceTriggered)
      return;

    refreshKernelArgs();
    AlltoallArgs& args = kernelArgs_;
    int nPeer = nranks_ - 1;

    // Program SDMA operations for all iterations
    // Each iteration waits for trigger to reach a different value (increments)
    for (int i = 0; i < iters; ++i) {
      uint64_t signalValue = 1;
      uint32_t expectedTrigger = currentTriggerBase_ + i +
                                 1; // +1 because kernel increments

      // For each peer, program: wait_flag_then_put + signal + counter_increment
      for (int peer = 0; peer < nranks_; ++peer) {
        size_t srcOffset = peer * currentElemsPerRank_;
        size_t dstOffset = rank_ * currentElemsPerRank_;
        void* src = &args.localInput[srcOffset];
        void* dst = &args.remoteDst[peer][dstOffset];
        if (peer == rank_) {
          dst = &args.localResult[dstOffset];
        }
        size_t bytes = currentElemsPerRank_ * sizeof(int);

        int peerIdx = (peer < rank_) ? peer : peer - 1;

        // Wait for trigger to reach expected value, then transfer data
        hostHandles_[peer].wait_flag_then_put(&args.triggerFlags[0],
                                              expectedTrigger, src, dst, bytes);

        // Signal completion to peer
        if (peer != rank_) {
          hostHandles_[peer].signal(args.remoteSdmaSignals[peerIdx],
                                    signalValue);
        }

        // Increment local counter (use signal to write the value)
        hostHandles_[peer].signal(&args.localCounters[peer], signalValue);
      }
    }

    // Update trigger base for next preprogramming call
    currentTriggerBase_ += iters;
  }

  void runColl(const SdmaTestConfig& config, int rank, int nranks,
               hipStream_t stream) override {
    refreshKernelArgs();
    AlltoallArgs& args = kernelArgs_;

    if (config.deviceTriggered) {
      // Use 1 block with 1 warp (64 threads) for device-triggered mode
      alltoallTriggerKernel<<<1, 64, 0, stream>>>(args, 1, currentSignal_);
    } else {
      // Use 1 block with 8 warps (512 threads) for device-initiated mode
      sdmaAlltoallKernel<<<1, 512, 0, stream>>>(args, 1, currentSignal_);
    }
    currentSignal_++;
  }

  void getBw(double deltaSec, double& algBw, double& busBw) override {
    // Algorithmic BW
    algBw = (currentSize_ / (1024.0 * 1024.0 * 1024.0)) / deltaSec;

    // Bus BW (allgather: (N-1)/N factor)
    // Each rank sends its data to N-1 peers
    size_t totalBusBytes = (nranks_ - 1) * currentSize_ / nranks_;
    busBw = (totalBusBytes / (1024.0 * 1024.0 * 1024.0)) / deltaSec;
  }

  size_t getInputBufferSize(size_t nelemsPerRank, int nranks) const override {
    return nelemsPerRank * nranks * sizeof(int);
  }

  size_t getResultBufferSize(size_t nelemsPerRank, int nranks) const override {
    return nelemsPerRank * nranks * sizeof(int);
  }

  size_t getExpectedBufferSize(size_t nelemsPerRank,
                               int nranks) const override {
    return nelemsPerRank * nranks * sizeof(int);
  }

  void setBuffers(int* input, int* result, uint64_t* barrierSigs,
                  uint64_t* sdmaSigs, uint32_t* triggerFlags) override {
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
    // Note: remoteBufs not used for AllToAll (no reduction phase)
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

    // Allocate per-peer completion
    // Use uncached memory for efficient polling by GPU and SDMA coherency
    // int nPeer = nranks - 1;
    if (!counters_) {
      HIP_CHECK(hipExtMallocWithFlags((void**)&counters_,
                                      nranks * sizeof(uint64_t),
                                      hipDeviceMallocUncached));
      // Initialize counters to 0
      HIP_CHECK(hipMemset(counters_, 0, nranks * sizeof(uint64_t)));
    }

    markKernelArgsDirty();
  }

private:
  void markKernelArgsDirty() {
    kernelArgsDirty_ = true;
  }

  void refreshKernelArgs() {
    if (!kernelArgsDirty_) {
      return;
    }

    kernelArgs_ = {};
    kernelArgs_.localInput = inputBuf_;
    kernelArgs_.localResult = resultBuf_;
    kernelArgs_.localBarrierSignals = barrierSignals_;
    kernelArgs_.localSdmaSignals = sdmaSignals_;
    kernelArgs_.localCounters = counters_;
    kernelArgs_.remoteBarrierSignals = remoteBarrierSignals_;
    kernelArgs_.remoteSdmaSignals = remoteSdmaSignals_;
    kernelArgs_.triggerFlags = triggerFlags_;
    kernelArgs_.myrank = rank_;
    kernelArgs_.nranks = nranks_;
    kernelArgs_.nelemsPerRank = currentElemsPerRank_;

    // Only need remoteDst for AllToAll (no remoteBufs needed)
    for (int i = 0; i < MAX_GPUS; ++i) {
      if (remoteDst_)
        kernelArgs_.remoteDst[i] = remoteDst_[i];
    }

    if (!config_.deviceTriggered && queues_) {
      for (int peer = 0; peer < nranks_; ++peer) {
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
  uint64_t* counters_ = nullptr; // Per-peer completion counters
  uint32_t* triggerFlags_ = nullptr;
  sdma_ep::SdmaQueueInfo* queues_ = nullptr;
  sdma_ep::SdmaQueueHostHandle* hostHandles_ = nullptr;
  int** remoteBufs_ = nullptr; // Not used for AllToAll
  int** remoteDst_ = nullptr;
  uint64_t** remoteBarrierSignals_ = nullptr;
  uint64_t** remoteSdmaSignals_ = nullptr;

  AlltoallArgs kernelArgs_{};
  bool kernelArgsDirty_ = true;
  std::vector<uint32_t> chunkContributors_;
  size_t maxChunksPerBlock_ = 0;
  uint32_t currentTriggerBase_ = 0; // Tracks expected trigger value across
                                    // iterations
};

// Main entry point
int main(int argc, char** argv) {
  SdmaAlltoallTestColl coll;
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
