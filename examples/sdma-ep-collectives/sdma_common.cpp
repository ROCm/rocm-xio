/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * SDMA collective test engine implementation
 */

#include "sdma_common.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include <endpoints/sdma-ep/sdma-ep.h>
#include <endpoints/sdma-ep/sdma-host-queue.h>
#include <xio.h>

// Forward declare xio::enablePeerAccess
namespace xio {
void enablePeerAccess(int srcDevice, int dstDevice);
}

SdmaTestEngine::SdmaTestEngine(int argc, char** argv, SdmaTestColl* coll)
  : coll_(coll) {
  parseArgs(argc, argv);
}

SdmaTestEngine::~SdmaTestEngine() {
}

void SdmaTestEngine::parseArgs(int argc, char** argv) {
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-w") == 0 && i + 1 < argc) {
      warmup_ = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-n") == 0 && i + 1 < argc) {
      iters_ = atoi(argv[++i]);
    } else if (strcmp(argv[i], "--min-bytes") == 0 && i + 1 < argc) {
      const char* value = argv[++i];
      char* end = nullptr;
      unsigned long long parsed = strtoull(value, &end, 0);
      if (end == value) {
        fprintf(stderr, "Invalid value for --min-bytes: %s\n", value);
        exit(1);
      }
      minBytes_ = static_cast<size_t>(parsed);
    } else if (strcmp(argv[i], "--max-bytes") == 0 && i + 1 < argc) {
      const char* value = argv[++i];
      char* end = nullptr;
      unsigned long long parsed = strtoull(value, &end, 0);
      if (end == value) {
        fprintf(stderr, "Invalid value for --max-bytes: %s\n", value);
        exit(1);
      }
      maxBytes_ = static_cast<size_t>(parsed);
    } else if (strcmp(argv[i], "--step-bytes") == 0 && i + 1 < argc) {
      const char* value = argv[++i];
      char* end = nullptr;
      unsigned long long parsed = strtoull(value, &end, 0);
      if (end == value) {
        fprintf(stderr, "Invalid value for --step-bytes: %s\n", value);
        exit(1);
      }
      stepBytes_ = static_cast<size_t>(parsed);
    } else if (strcmp(argv[i], "--step-factor") == 0 && i + 1 < argc) {
      const char* value = argv[++i];
      char* end = nullptr;
      unsigned long long parsed = strtoull(value, &end, 0);
      if (end == value || parsed == 0) {
        fprintf(stderr, "Invalid value for --step-factor: %s\n", value);
        exit(1);
      }
      stepFactor_ = static_cast<size_t>(parsed);
    } else if (strcmp(argv[i], "--device-triggered") == 0) {
      config_.deviceTriggered = true;
    } else if (strcmp(argv[i], "--no-validate") == 0) {
      validate_ = false;
    }
  }
}

void SdmaTestEngine::initialize() {
  bootstrapMPI();

  if (maxBytes_ < minBytes_) {
    if (rank_ == 0) {
      fprintf(stderr, "Invalid size range: min-bytes (%zu) > max-bytes (%zu)\n",
              minBytes_, maxBytes_);
    }
    MPI_Abort(MPI_COMM_WORLD, 1);
  }

  if (stepBytes_ == 0) {
    if (stepFactor_ <= 1) {
      if (rank_ == 0) {
        fprintf(
          stderr,
          "Invalid sweep configuration: step-factor must be greater than 1 "
          "when step-bytes is not provided.\n");
      }
      MPI_Abort(MPI_COMM_WORLD, 1);
    }
  } else {
    stepFactor_ = std::max<size_t>(stepFactor_, 1);
  }

  if (rank_ == 0) {
    printf("# SDMA Collective Benchmark\n");
    printf("# Ranks: %d, Mode: %s\n", nranks_,
           config_.deviceTriggered ? "device-triggered" : "device-initiated");
    printf("# Warmup: %d, Iterations: %d, Validation: %s\n", warmup_, iters_,
           validate_ ? "ON" : "OFF");
    if (stepBytes_ > 0) {
      printf("# Size sweep: min=%zu bytes max=%zu bytes step=+%zu bytes\n",
             minBytes_, maxBytes_, stepBytes_);
    } else {
      printf("# Size sweep: min=%zu bytes max=%zu bytes step=x%zu\n", minBytes_,
             maxBytes_, stepFactor_);
    }
    printf("#\n");
    printf("# %12s  %10s  %12s  %12s  %8s\n", "Size(B)", "Time(us)",
           "AlgBW(GB/s)", "BusBW(GB/s)", "#Errors");
    printf(
      "#-------------------------------------------------------------------\n");
  }

  // Set HIP device
  HIP_CHECK(hipSetDevice(rank_));

  // Initialize XIO
  int rc = xio::sdma_ep::initEndpoint();
  if (rc != 0) {
    fprintf(stderr, "[rank %d] sdma_ep::initEndpoint failed (%d)\n", rank_, rc);
    MPI_Abort(MPI_COMM_WORLD, 1);
  }
}

void SdmaTestEngine::bootstrapMPI() {
  MPI_Init(nullptr, nullptr);
  MPI_Comm_size(MPI_COMM_WORLD, &nranks_);
  MPI_Comm_rank(MPI_COMM_WORLD, &rank_);

  if (nranks_ < 2) {
    if (rank_ == 0)
      fprintf(stderr, "Collective requires at least 2 ranks\n");
    MPI_Finalize();
    exit(1);
  }

  if (nranks_ != MAX_GPUS) {
    if (rank_ == 0) {
      fprintf(
        stderr,
        "sdma-ep-collectives currently supports exactly %d ranks; got %d\n",
        MAX_GPUS, nranks_);
    }
    MPI_Finalize();
    exit(1);
  }

  if (nranks_ > MAX_GPUS) {
    if (rank_ == 0)
      fprintf(stderr, "Max supported ranks: %d\n", MAX_GPUS);
    MPI_Finalize();
    exit(1);
  }
}

void SdmaTestEngine::allocateBuffers() {
  // Allocate maximum size buffers
  size_t maxElemsPerRank = maxBytes_ / sizeof(int);

  size_t inputBytes = coll_->getInputBufferSize(maxElemsPerRank, nranks_);
  size_t resultBytes = coll_->getResultBufferSize(maxElemsPerRank, nranks_);
  size_t expectedBytes = coll_->getExpectedBufferSize(maxElemsPerRank, nranks_);

  // Device allocations (uncached for SDMA)
  HIP_CHECK(hipExtMallocWithFlags((void**)&inputBuf_, inputBytes,
                                  hipDeviceMallocUncached));
  HIP_CHECK(hipExtMallocWithFlags((void**)&resultBuf_, resultBytes,
                                  hipDeviceMallocUncached));

  int nPeer = nranks_ - 1;

  // Signal buffers
  HIP_CHECK(hipExtMallocWithFlags((void**)&barrierSignals_,
                                  config_.nBlocks * nPeer * sizeof(uint64_t),
                                  hipDeviceMallocUncached));
  HIP_CHECK(hipExtMallocWithFlags((void**)&sdmaSignals_,
                                  config_.nBlocks * nPeer * sizeof(uint64_t),
                                  hipDeviceMallocUncached));

  // Trigger flags for device-triggered mode
  // Calculate max chunks
  constexpr size_t nInt4PerChunk = (CHUNK_SIZE_KB * 1024) / sizeof(int4);
  size_t maxInt4PerRank = maxElemsPerRank / 4;
  size_t maxInt4PerBlock = (maxInt4PerRank + config_.nBlocks - 1) /
                           config_.nBlocks;
  size_t maxChunks = (maxInt4PerBlock + nInt4PerChunk - 1) / nInt4PerChunk;
  triggerFlagCapacity_ = maxChunks;

  HIP_CHECK(hipExtMallocWithFlags((void**)&triggerFlags_,
                                  maxChunks * sizeof(uint32_t),
                                  hipDeviceMallocUncached));

  // Host allocation for expected results
  expectedBuf_ = new int[expectedBytes / sizeof(int)];

  // Pass buffers to collective
  coll_->setBuffers(inputBuf_, resultBuf_, barrierSignals_, sdmaSignals_,
                    triggerFlags_);
}

void SdmaTestEngine::setupQueues() {
  int nPeer = nranks_ - 1;

  // Allocate queue info arrays
  queueInfos_ = new xio::sdma_ep::SdmaQueueInfo[MAX_GPUS]();

  if (config_.deviceTriggered) {
    hostHandles_.reserve(nranks_);
  }

  // Create SDMA queues for each peer
  for (int peer = 0; peer < nranks_; ++peer) {
    if (peer == rank_) {
      if (config_.deviceTriggered) {
        hostHandles_.push_back(xio::sdma_ep::SdmaQueueHostHandle(nullptr));
      }
      continue;
    }

    xio::enablePeerAccess(rank_, peer);

    int rc;
    if (config_.deviceTriggered) {
      rc = xio::sdma_ep::createHostQueue(rank_, peer, &queueInfos_[peer]);
      if (rc != 0) {
        fprintf(stderr, "[rank %d] createHostQueue(%d->%d) failed (%d)\n",
                rank_, rank_, peer, rc);
        MPI_Abort(MPI_COMM_WORLD, 1);
      }
      hostHandles_.push_back(xio::sdma_ep::getHostHandle(rank_, peer, 0));
    } else {
      rc = xio::sdma_ep::createQueue(rank_, peer, &queueInfos_[peer]);
      if (rc != 0) {
        fprintf(stderr, "[rank %d] createQueue(%d->%d) failed (%d)\n", rank_,
                rank_, peer, rc);
        MPI_Abort(MPI_COMM_WORLD, 1);
      }
    }
  }

  setupIpcHandles();

  // Pass queues to collective
  coll_->setQueues(queueInfos_, hostHandles_.data());
}

void SdmaTestEngine::setupIpcHandles() {
  int nPeer = nranks_ - 1;

  // Get IPC handles for local buffers
  hipIpcMemHandle_t inputHandle, resultHandle, barrierHandle, sdmaHandle;
  HIP_CHECK(hipIpcGetMemHandle(&inputHandle, inputBuf_));
  HIP_CHECK(hipIpcGetMemHandle(&resultHandle, resultBuf_));
  HIP_CHECK(hipIpcGetMemHandle(&barrierHandle, barrierSignals_));
  HIP_CHECK(hipIpcGetMemHandle(&sdmaHandle, sdmaSignals_));

  // Exchange handles via MPI
  hipIpcMemHandle_t* allInputHandles = new hipIpcMemHandle_t[nranks_];
  hipIpcMemHandle_t* allResultHandles = new hipIpcMemHandle_t[nranks_];
  hipIpcMemHandle_t* allBarrierHandles = new hipIpcMemHandle_t[nranks_];
  hipIpcMemHandle_t* allSdmaHandles = new hipIpcMemHandle_t[nranks_];

  MPI_Allgather(&inputHandle, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                allInputHandles, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                MPI_COMM_WORLD);
  MPI_Allgather(&resultHandle, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                allResultHandles, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                MPI_COMM_WORLD);
  MPI_Allgather(&barrierHandle, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                allBarrierHandles, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                MPI_COMM_WORLD);
  MPI_Allgather(&sdmaHandle, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                allSdmaHandles, sizeof(hipIpcMemHandle_t), MPI_BYTE,
                MPI_COMM_WORLD);

  // Open peer buffers
  for (int peer = 0; peer < nranks_; ++peer) {
    if (peer == rank_) {
      remoteBufs_[peer] = nullptr;
      remoteDst_[peer] = nullptr;
      continue;
    }

    HIP_CHECK(hipIpcOpenMemHandle((void**)&remoteBufs_[peer],
                                  allInputHandles[peer],
                                  hipIpcMemLazyEnablePeerAccess));
    HIP_CHECK(hipIpcOpenMemHandle((void**)&remoteDst_[peer],
                                  allResultHandles[peer],
                                  hipIpcMemLazyEnablePeerAccess));
  }

  // Allocate and populate remote signal pointers
  uint64_t** hostBarrierPtrs = new uint64_t*[config_.nBlocks * nPeer];
  uint64_t** hostSdmaPtrs = new uint64_t*[config_.nBlocks * nPeer];

  for (int peer = 0; peer < nranks_; ++peer) {
    if (peer == rank_)
      continue;

    int peerIdx = PeerIndexing::peerToLocalIndex(rank_, peer);
    int myIdxOnPeer = PeerIndexing::myIndexOnPeer(rank_, peer);

    uint64_t* peerBarrierSignals;
    uint64_t* peerSdmaSignals;

    HIP_CHECK(hipIpcOpenMemHandle((void**)&peerBarrierSignals,
                                  allBarrierHandles[peer],
                                  hipIpcMemLazyEnablePeerAccess));
    HIP_CHECK(hipIpcOpenMemHandle((void**)&peerSdmaSignals,
                                  allSdmaHandles[peer],
                                  hipIpcMemLazyEnablePeerAccess));

    for (int b = 0; b < config_.nBlocks; ++b) {
      int slot = PeerIndexing::signalSlot(b, peerIdx, nPeer);
      hostBarrierPtrs[slot] = peerBarrierSignals +
                              PeerIndexing::signalSlot(b, myIdxOnPeer, nPeer);
      hostSdmaPtrs[slot] = peerSdmaSignals +
                           PeerIndexing::signalSlot(b, myIdxOnPeer, nPeer);
    }
  }

  // Copy pointer arrays to device
  HIP_CHECK(hipMalloc(&remoteBarrierSignals_,
                      config_.nBlocks * nPeer * sizeof(uint64_t*)));
  HIP_CHECK(hipMalloc(&remoteSdmaSignals_,
                      config_.nBlocks * nPeer * sizeof(uint64_t*)));

  HIP_CHECK(hipMemcpy(remoteBarrierSignals_, hostBarrierPtrs,
                      config_.nBlocks * nPeer * sizeof(uint64_t*),
                      hipMemcpyHostToDevice));
  HIP_CHECK(hipMemcpy(remoteSdmaSignals_, hostSdmaPtrs,
                      config_.nBlocks * nPeer * sizeof(uint64_t*),
                      hipMemcpyHostToDevice));

  // Pass IPC handles to collective
  coll_->setIpcHandles(remoteBufs_, remoteDst_, remoteBarrierSignals_,
                       remoteSdmaSignals_);

  // Cleanup temporary arrays
  delete[] allInputHandles;
  delete[] allResultHandles;
  delete[] allBarrierHandles;
  delete[] allSdmaHandles;
  delete[] hostBarrierPtrs;
  delete[] hostSdmaPtrs;
}

void SdmaTestEngine::runBenchmark() {
  hipEvent_t start, stop;
  HIP_CHECK(hipEventCreate(&start));
  HIP_CHECK(hipEventCreate(&stop));

  int nPeer = nranks_ - 1;

  for (size_t size = minBytes_; size <= maxBytes_;) {
    size_t requestedBytes = size;
    size_t elemsPerRank = (requestedBytes / sizeof(int)) /
                          static_cast<size_t>(nranks_);

    if (elemsPerRank == 0) {
      if (rank_ == 0) {
        fprintf(stderr, "Skipping size %zu: fewer than one int per rank.\n",
                requestedBytes);
      }
      size_t nextSize;
      if (stepBytes_ > 0) {
        nextSize = size + stepBytes_;
      } else {
        if (size > maxBytes_ / stepFactor_) {
          nextSize = maxBytes_ + 1;
        } else {
          nextSize = size * stepFactor_;
        }
      }
      if (nextSize <= size) {
        break;
      }
      size = nextSize;
      continue;
    }

    currentTotalBytes_ = elemsPerRank * static_cast<size_t>(nranks_) *
                         sizeof(int);
    currentElemsPerRank_ = elemsPerRank;

    if (currentTotalBytes_ != requestedBytes && rank_ == 0) {
      printf(
        "# Adjusted %zu -> %zu bytes to align with per-rank element count\n",
        requestedBytes, currentTotalBytes_);
    }

    coll_->setupCollTest(currentTotalBytes_);
    coll_->initData(rank_, nranks_, inputBuf_, expectedBuf_,
                    currentElemsPerRank_);

    HIP_CHECK(hipMemset(barrierSignals_, 0,
                        config_.nBlocks * nPeer * sizeof(uint64_t)));
    HIP_CHECK(
      hipMemset(sdmaSignals_, 0, config_.nBlocks * nPeer * sizeof(uint64_t)));
    if (triggerFlags_) {
      size_t bytes = triggerFlagCapacity_ * sizeof(uint32_t);
      if (bytes > 0) {
        HIP_CHECK(hipMemset(triggerFlags_, 0, bytes));
      }
    }
    HIP_CHECK(hipMemset(resultBuf_, 0, currentTotalBytes_));

    if (config_.deviceTriggered && warmup_ > 0) {
      coll_->preprogramIterations(warmup_);
    }

    MPI_Barrier(MPI_COMM_WORLD);

    for (int i = 0; i < warmup_; ++i) {
      coll_->runColl(config_, rank_, nranks_, 0);
    }
    HIP_CHECK(hipDeviceSynchronize());

    if (config_.deviceTriggered && iters_ > 0) {
      coll_->preprogramIterations(iters_);
    }

    MPI_Barrier(MPI_COMM_WORLD);

    HIP_CHECK(hipEventRecord(start));
    for (int i = 0; i < iters_; ++i) {
      coll_->runColl(config_, rank_, nranks_, 0);
    }
    HIP_CHECK(hipEventRecord(stop));
    HIP_CHECK(hipEventSynchronize(stop));

    float milliseconds = 0.0f;
    HIP_CHECK(hipEventElapsedTime(&milliseconds, start, stop));

    size_t totalErrors = 0;
    bool hasValidation = false;
    if (validate_) {
      if (config_.deviceTriggered) {
        coll_->preprogramIterations(1);
      }
      coll_->runColl(config_, rank_, nranks_, 0);
      HIP_CHECK(hipDeviceSynchronize());
      size_t nErrors = validateResults();

      MPI_Allreduce(&nErrors, &totalErrors, 1, MPI_UNSIGNED_LONG, MPI_SUM,
                    MPI_COMM_WORLD);
      hasValidation = true;
      // if (rank_ == 0) {
      //   printf("Validation (%zu bytes): %zu errors (%s)\n",
      //          currentTotalBytes_, totalErrors,
      //          totalErrors == 0 ? "PASSED" : "FAILED");
      // }
    }

    reportResults(milliseconds / static_cast<double>(iters_),
                  currentTotalBytes_, totalErrors, hasValidation);

    MPI_Barrier(MPI_COMM_WORLD);

    size_t nextSize;
    if (stepBytes_ > 0) {
      nextSize = size + stepBytes_;
    } else {
      if (size > maxBytes_ / stepFactor_) {
        nextSize = maxBytes_ + 1;
      } else {
        nextSize = size * stepFactor_;
      }
    }
    if (nextSize <= size) {
      break;
    }
    size = nextSize;
  }

  HIP_CHECK(hipEventDestroy(start));
  HIP_CHECK(hipEventDestroy(stop));
}

size_t SdmaTestEngine::validateResults() {
  size_t nErrors = 0;
  size_t resultElems = coll_->getResultBufferSize(currentElemsPerRank_,
                                                  nranks_) /
                       sizeof(int);

  std::vector<int> resultHost(resultElems);
  HIP_CHECK(hipMemcpy(resultHost.data(), resultBuf_, resultElems * sizeof(int),
                      hipMemcpyDeviceToHost));

  for (size_t i = 0; i < resultElems; i++) {
    if (resultHost[i] != expectedBuf_[i]) {
      nErrors++;
      if (nErrors < 10) {
        printf("[rank %d] Mismatch at [%zu]: expected %d, got %d\n", rank_, i,
               expectedBuf_[i], resultHost[i]);
      }
    }
  }

  return nErrors;
}

void SdmaTestEngine::reportResults(double avgTimeMs, size_t totalBytes,
                                   size_t totalErrors, bool hasValidation) {
  double algBw, busBw;
  coll_->getBw(avgTimeMs / 1000.0, algBw, busBw);

  if (rank_ == 0) {
    if (hasValidation) {
      printf("  %12zu  %10.2f  %12.2f  %12.2f  %8zu\n", totalBytes,
             avgTimeMs * 1000.0, algBw, busBw, totalErrors);
    } else {
      printf("  %12zu  %10.2f  %12.2f  %12.2f  %8s\n", totalBytes,
             avgTimeMs * 1000.0, algBw, busBw, "N/A");
    }
  }
}

void SdmaTestEngine::cleanup() {
  if (inputBuf_)
    HIP_CHECK(hipFree(inputBuf_));
  if (resultBuf_)
    HIP_CHECK(hipFree(resultBuf_));
  if (barrierSignals_)
    HIP_CHECK(hipFree(barrierSignals_));
  if (sdmaSignals_)
    HIP_CHECK(hipFree(sdmaSignals_));
  if (triggerFlags_)
    HIP_CHECK(hipFree(triggerFlags_));
  if (remoteBarrierSignals_)
    HIP_CHECK(hipFree(remoteBarrierSignals_));
  if (remoteSdmaSignals_)
    HIP_CHECK(hipFree(remoteSdmaSignals_));

  delete[] expectedBuf_;
  delete[] queueInfos_;

  MPI_Finalize();
}
