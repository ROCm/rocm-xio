/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Common infrastructure for SDMA-based collective operations
 *
 * This header provides the framework for implementing GPU collectives
 * (AllReduce, AllGather, AllToAll, etc.) using AMD SDMA engines.
 *
 * Design:
 * - SdmaTestEngine: Handles orchestration (MPI, buffers, queues, benchmarking)
 * - SdmaTestColl: Collective-specific implementation (kernels, validation)
 * - Shared utilities: crossGpuBarrier, PeerIndexing
 */

#ifndef SDMA_COMMON_HPP
#define SDMA_COMMON_HPP

#include <cstdint>
#include <string>
#include <vector>

#include <hip/hip_runtime.h>

#include <mpi.h>

// Include SDMA headers for complete type definitions
#include <endpoints/sdma-ep/sdma-ep.h>
#include <endpoints/sdma-ep/sdma-host-queue.h>
#include <endpoints/sdma-ep/sdma_device.hpp>

// Constants
static constexpr int MAX_GPUS = 8;
static constexpr size_t CHUNK_SIZE_KB = 256;
static constexpr int WARP_SIZE = 64;

// Configuration for runtime options
struct SdmaTestConfig {
  int nBlocks = 8;
  int nThreadsPerBlock = 512;
  bool deviceTriggered = false;
};

// Per-(GPU pair, block) pointer structure
// Groups all pointers needed for one block to communicate with one peer GPU
struct SdmaGpuPairBlockPtrs {
  // Peer GPU data
  int* remoteBuf;                // Input data on peer GPU
  int* remoteDst;                // Where to write results on peer GPU
  uint64_t* remoteBarrierSignal; // Barrier signal on peer GPU
  uint64_t* remoteSdmaSignal;    // SDMA completion signal on peer GPU

  // Local pointers for this block
  uint64_t* localBarrierSignal; // This block's barrier signal
  uint64_t* localSdmaSignal;    // This block's SDMA signal

  // Queue for SDMA operations to this peer
  xio::sdma_ep::SdmaQueueHandle* queue;
};

// Utility: Peer indexing helper
// Centralizes the (peer < myrank) ? peer : peer - 1 pattern
class PeerIndexing {
public:
  static int peerToLocalIndex(int myrank, int peer) {
    return (peer < myrank) ? peer : peer - 1;
  }

  static int myIndexOnPeer(int myrank, int peer) {
    return (myrank < peer) ? myrank : myrank - 1;
  }

  static int signalSlot(int blockIdx, int peerLocalIdx, int nPeer) {
    return blockIdx * nPeer + peerLocalIdx;
  }
};

// Device utility: Cross-GPU barrier synchronization.
//
// Layout matches the engine: `remoteBarrierSignals` is a flat
// `uint64_t**` of size `nBlocks * nPeer`, where slot
// `block * nPeer + peerLocalIdx` points into the corresponding peer's
// signal buffer at this rank's slot. `localBarrierSignals` is a flat
// `uint64_t*` of the same size on this rank.
//
// Each block reads/writes only its own row of `nPeer` slots, so the
// load index includes `blockIdx` (a previous version dropped this and
// would have aliased rows across blocks).
__device__ inline void crossGpuBarrier(uint64_t** remoteBarrierSignals,
                                       uint64_t* localBarrierSignals,
                                       int blockIdx, int nPeer,
                                       uint64_t expectedSignal) {
  if (threadIdx.x < static_cast<uint32_t>(nPeer)) {
    int slotIdx = blockIdx * nPeer + static_cast<int>(threadIdx.x);
    __atomic_store_n(remoteBarrierSignals[slotIdx], expectedSignal,
                     __ATOMIC_RELAXED);
    while (__atomic_load_n(&localBarrierSignals[slotIdx], __ATOMIC_RELAXED) <
           expectedSignal) {
    }
  }
  __syncthreads();
}

// Forward declaration
class SdmaTestColl;

// Test orchestration engine
// Handles all collective-agnostic infrastructure:
// - MPI coordination
// - SDMA queue creation and IPC handle exchange
// - Buffer allocation
// - Benchmarking loop
// - Validation
class SdmaTestEngine {
public:
  SdmaTestEngine(int argc, char** argv, SdmaTestColl* coll);
  ~SdmaTestEngine();

  // Lifecycle
  void initialize();      // MPI + XIO setup
  void allocateBuffers(); // Allocate device + host buffers
  void setupQueues();     // Create SDMA queues, IPC handles
  void runBenchmark();    // Warmup + timed iterations + validation
  void cleanup();         // Free resources

  // Validation
  size_t validateResults(); // Compare result vs expected

  // Getters
  const SdmaTestConfig& getConfig() const {
    return config_;
  }
  int getRank() const {
    return rank_;
  }
  int getNranks() const {
    return nranks_;
  }

private:
  // Setup helpers
  void parseArgs(int argc, char** argv);
  void bootstrapMPI();
  void setupIpcHandles();
  void createSdmaQueues(bool deviceTriggered);
  void reportResults(double avgTimeMs, size_t totalBytes, size_t totalErrors,
                     bool hasValidation);

  // Configuration
  SdmaTestConfig config_;
  SdmaTestColl* coll_;

  // MPI state
  int rank_;
  int nranks_;

  // Benchmark parameters
  int warmup_ = 5;
  int iters_ = 20;
  bool validate_ = true;
  size_t minBytes_ = 4096;
  size_t maxBytes_ = 256 * 1024 * 1024;
  size_t stepFactor_ = 2;
  size_t currentElemsPerRank_ = 0;
  size_t currentTotalBytes_ = 0;

  // Device buffers
  int* inputBuf_ = nullptr;
  int* resultBuf_ = nullptr;
  uint64_t* barrierSignals_ = nullptr;
  uint64_t* sdmaSignals_ = nullptr;
  uint32_t* triggerFlags_ = nullptr;
  size_t triggerFlagCapacity_ = 0;

  // Host buffer for validation
  int* expectedBuf_ = nullptr;

  // SDMA infrastructure
  xio::sdma_ep::SdmaQueueInfo* queueInfos_ = nullptr;
  std::vector<xio::sdma_ep::SdmaQueueHostHandle> hostHandles_;

  // IPC handles to peer GPUs. The arrays below store the base
  // pointers returned by hipIpcOpenMemHandle() for each peer so they
  // can be released in cleanup(). Without this we would leak the
  // mappings for the lifetime of the process.
  int* remoteBufs_[MAX_GPUS] = {};
  int* remoteDst_[MAX_GPUS] = {};
  uint64_t* peerBarrierBases_[MAX_GPUS] = {};
  uint64_t* peerSdmaBases_[MAX_GPUS] = {};
  uint64_t** remoteBarrierSignals_ = nullptr;
  uint64_t** remoteSdmaSignals_ = nullptr;
};

// Collective operations interface
// Each collective (AllReduce, AllGather, etc.) implements this interface
class SdmaTestColl {
public:
  virtual ~SdmaTestColl() = default;

  // Initialize input/expected buffers for a given size
  // Called before each benchmark size
  virtual void initData(int rank, int nranks, void* inputBuf, void* expectedBuf,
                        size_t nelemsPerRank) = 0;

  // Setup for a specific test size
  // Called before warmup and before each benchmark size
  virtual void setupCollTest(size_t size) = 0;

  // Pre-program SDMA operations for multiple iterations (device-triggered mode)
  // Called before timed iterations to keep programming outside measurement
  virtual void preprogramIterations(int iters) = 0;

  // Execute the collective operation
  virtual void runColl(const SdmaTestConfig& config, int rank, int nranks,
                       hipStream_t stream) = 0;

  // Compute bandwidth metrics (collective-specific formula)
  virtual void getBw(double deltaSec, double& algBw, double& busBw) = 0;

  // Get buffer size requirements (collective-specific)
  virtual size_t getInputBufferSize(size_t nelemsPerRank, int nranks) const = 0;
  virtual size_t getResultBufferSize(size_t nelemsPerRank,
                                     int nranks) const = 0;
  virtual size_t getExpectedBufferSize(size_t nelemsPerRank,
                                       int nranks) const = 0;

  // Set pointers to engine-managed resources
  // Called by engine after allocation
  virtual void setBuffers(int* input, int* result, uint64_t* barrierSigs,
                          uint64_t* sdmaSigs, uint32_t* triggerFlags) = 0;

  virtual void setQueues(xio::sdma_ep::SdmaQueueInfo* queues,
                         xio::sdma_ep::SdmaQueueHostHandle* hostHandles) = 0;

  virtual void setIpcHandles(int** remoteBufs, int** remoteDst,
                             uint64_t** remoteBarrierSignals,
                             uint64_t** remoteSdmaSignals) = 0;
};

#endif // SDMA_COMMON_HPP
