/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "nvme-ep.h"
#include "xio-data-pattern.hpp"
#include "xio-env.h"
#include "xio-timing.h"

// Host-only includes for IOCTL and file operations
#ifndef __HIP_DEVICE_COMPILE__
#include <errno.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <fcntl.h>
#include <linux/nvme_ioctl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#endif // __HIP_DEVICE_COMPILE__

namespace xio::nvme_ep {

/**
 * @brief Read an NVMe SQE from a volatile queue slot
 *        using 8-byte wide loads via XioComDequeue.
 *
 * @param sqeAddress  Volatile pointer to the SQE slot.
 * @return Copy of the SQE structure.
 */
__host__ __device__ sqeType sqeRead(volatile sqeType* sqeAddress) {
  sqeType result;
  xio::XioComDequeue<sizeof(sqeType)>(sqeAddress, &result);
  return result;
}

/**
 * @brief Read an NVMe CQE from a volatile queue slot
 *        using 8-byte wide loads via XioComDequeue.
 *
 * @param cqeAddress  Volatile pointer to the CQE slot.
 * @return Copy of the CQE structure.
 */
__host__ __device__ cqeType cqeRead(volatile cqeType* cqeAddress) {
  cqeType result;
  xio::XioComDequeue<sizeof(cqeType)>(cqeAddress, &result);
  return result;
}

/**
 * @brief Write an NVMe SQE to a volatile queue slot
 *        using 8-byte wide stores via XioComEnqueue.
 *
 * Does not fence; the caller is responsible for
 * fencing before the subsequent doorbell write
 * (ringDoorbell provides its own pre-fence).
 *
 * @param sqeData     SQE to write (passed by value).
 * @param sqeAddress  Volatile pointer to the SQE slot.
 */
__host__ __device__ void sqeWrite(sqeType sqeData,
                                  volatile sqeType* sqeAddress) {
  xio::XioComEnqueue<sizeof(sqeType)>(&sqeData, sqeAddress);
}

/**
 * @brief Write an NVMe CQE to a volatile queue slot
 *        using 8-byte wide stores via XioComEnqueue.
 *
 * @param cqeData     CQE to write (passed by value).
 * @param cqeAddress  Volatile pointer to the CQE slot.
 */
__host__ __device__ void cqeWrite(cqeType cqeData,
                                  volatile cqeType* cqeAddress) {
  xio::XioComEnqueue<sizeof(cqeType)>(&cqeData, cqeAddress);
}

// Poll for new SQE - waits for command ID to change
__host__ __device__ sqeType sqePoll(sqeType sqeLast,
                                    volatile sqeType* sqeAddress) {
  sqeType sqeNew;
  while (true) {
    sqeNew = sqeRead(sqeAddress);
    if (sqeNew.command_id != sqeLast.command_id) {
      return sqeNew;
    }
  }
}

__host__ __device__ cqeType cqePoll(cqeType cqeLast,
                                    volatile cqeType* cqeAddress,
                                    uint16_t last_sq_head,
                                    uint16_t* sq_head_out,
                                    const volatile bool* stopRequested) {
  // Check stop flag before entering polling loop
  if (stopRequested != nullptr && *stopRequested) {
    if (sq_head_out != nullptr) {
      *sq_head_out = last_sq_head;
    }
    return cqeLast;
  }

  cqeType cqeNew;
  unsigned poll_count = 0;
  while (true) {
    // Check stop flag periodically (every 100 polls to balance responsiveness
    // and overhead)
    if (stopRequested != nullptr && poll_count % 100 == 0 && *stopRequested) {
      // Stop requested - return last known CQE to exit gracefully
      if (sq_head_out != nullptr) {
        *sq_head_out = last_sq_head;
      }
      return cqeLast;
    }

    cqeNew = cqeRead(cqeAddress);
    uint16_t sq_head = cqeNew.sq_head;

    bool sq_head_increased = false;
    if (sq_head > last_sq_head) {
      // Normal case: sq_head increased without wrapping
      sq_head_increased = true;
    } else if (sq_head < last_sq_head) {
      uint16_t diff = last_sq_head - sq_head;
      if (diff > 32768 || (last_sq_head > 32768 && sq_head < 32768)) {
        sq_head_increased = true;
      }
    }

    if (sq_head_increased) {
      // sq_head progressed - this is a new completion
      if (sq_head_out != nullptr) {
        *sq_head_out = sq_head;
      }
      return cqeNew;
    }

    // Fallback: check command ID change (less reliable but still useful)
    if (cqeNew.command_id != cqeLast.command_id) {
      if (sq_head_out != nullptr) {
        *sq_head_out = sq_head;
      }
      return cqeNew;
    }

    poll_count++;
    // Safety: prevent infinite loop if max polls exceeded
    if (poll_count >= NVME_EP_MAX_POLLS) {
      // Max polls reached - return last known CQE
      if (sq_head_out != nullptr) {
        *sq_head_out = last_sq_head;
      }
      return cqeLast;
    }
  }
}

__host__ __device__ void ringDoorbell(uint16_t value,
                                      const nvmeDoorbellParams& doorbellParams,
                                      uint32_t offset_override) {
  uint32_t offset = (offset_override != UINT32_MAX)
                      ? offset_override
                      : doorbellParams.doorbellOffset;
  if (doorbellParams.usePciMmioBridge &&
      doorbellParams.shadowBufferVirt != nullptr) {
    genPciMmioBridgeCmd(doorbellParams.shadowBufferVirt,
                        doorbellParams.nvmeTargetBdf, 0, offset, value,
                        PCI_MMIO_BRIDGE_CMD_WRITE, 4);
  } else {
    xio::ringDoorbell(doorbellParams.nvmeBar0Gpu, offset, value);
  }
}

/**
 * Calculate LBA for an I/O operation
 *
 * @param op_index Operation index (0-based)
 * @param cmd_id Command ID for random seed generation
 * @param blocks Number of blocks per I/O operation
 * @param ioParams I/O parameters containing baseLba,
 *                 lbaRangeLbas, useRandomAccess, and
 *                 lfsrSeed. When lfsrSeed is non-zero it
 *                 is mixed into the hash so that different
 *                 seed values produce different LBA
 *                 sequences across runs.
 * @return Calculated LBA address
 */
static __host__ __device__ uint64_t getRandomLba(unsigned op_index,
                                                 uint16_t cmd_id,
                                                 uint32_t blocks,
                                                 const nvmeIoParams& ioParams) {
  if (ioParams.useRandomAccess && ioParams.lbaRangeLbas > 0) {
    uint64_t seed = (uint64_t)op_index * 0x9e3779b9 + cmd_id * 0x85ebca6b +
                    ioParams.lfsrSeed;
    seed ^= seed >> 16;
    seed *= 0xc2b2ae35;
    seed ^= seed >> 13;
    seed *= 0x9e3779b9;
    seed ^= seed >> 16;
    uint64_t max_lba = (blocks > 0 && ioParams.lbaRangeLbas >= blocks)
                         ? (static_cast<uint64_t>(ioParams.lbaRangeLbas) -
                            static_cast<uint64_t>(blocks) + 1U)
                         : 1;
    return ioParams.baseLba + (seed % max_lba);
  } else {
    // Sequential access mode
    if (ioParams.lbaRangeLbas > 0) {
      return ioParams.baseLba + ((op_index * blocks) % ioParams.lbaRangeLbas);
    } else {
      return ioParams.baseLba + (op_index * blocks);
    }
  }
}

/**
 * Single-thread batch path (batch_size <= 1).
 *
 * Thread 0 sequentially prepares all SQEs, rings the
 * doorbell, and polls for completions.  This is the
 * original code path preserved for backward compat.
 */
__device__ static void driveEndpointSingle(
  const XioEndpointConfig& config, const nvmeIoParams& ioParams,
  const nvmeDoorbellParams& doorbellParams,
  const nvmeBufferParams& bufferParams) {
  sqeType* sqeAddr = static_cast<sqeType*>(config.submissionQueue);
  cqeType* cqeAddr = static_cast<cqeType*>(config.completionQueue);

  const unsigned num_read_ops = (unsigned)ioParams.readIo;
  const unsigned num_write_ops = (unsigned)ioParams.writeIo;
  const unsigned total_ops = num_read_ops + num_write_ops;
  const bool infinite_is_read = (num_read_ops > 0);

  uint32_t batch_size = ioParams.batchSize;
  if (batch_size == 0) {
    batch_size = ioParams.infiniteMode ? (uint32_t)(ioParams.queueSize - 1)
                                       : total_ops;
  }
  if (batch_size > (uint32_t)(ioParams.queueSize - 1)) {
    batch_size = ioParams.queueSize - 1;
  }
  if (!ioParams.infiniteMode && batch_size > total_ops) {
    batch_size = total_ops;
  }

  const uint32_t nsid = ioParams.nsid;
  const uint32_t blocks = ioParams.lbasPerIo;
  const size_t transfer_size = (size_t)blocks * ioParams.lbaSize;

  const bool has_write_buffer = (bufferParams.writeBuffer != nullptr &&
                                 bufferParams.bufferSize > 0);
  const bool has_read_buffer = (bufferParams.readBuffer != nullptr &&
                                bufferParams.bufferSize > 0);

  if (has_write_buffer) {
    xio::DataPatternParams pp{
      bufferParams.writeBuffer, bufferParams.bufferSize, 0,
      ioParams.lbaSize,         ioParams.lfsrSeed,       nullptr};
    xio::dataPattern(false, pp);
  }

  uint16_t cq_head = 0;
  uint8_t expected_phase = 1;
  uint16_t sq_tail = 0;

  constexpr unsigned kMaxTimedBatch = 256;
  unsigned long long int batchStartTimes[kMaxTimedBatch];
  const bool useBatchTiming = (config.timingStats != nullptr);
  if (useBatchTiming && batch_size > kMaxTimedBatch) {
    batch_size = kMaxTimedBatch;
  }

  constexpr unsigned kMaxPrecomputedPrps = 256;
  uint64_t readPrp1[kMaxPrecomputedPrps];
  uint64_t readPrp2[kMaxPrecomputedPrps];
  uint64_t writePrp1[kMaxPrecomputedPrps];
  uint64_t writePrp2[kMaxPrecomputedPrps];
  bool prpsPrecomputed = false;

  uint32_t precompute_count = batch_size;
  if (precompute_count > kMaxPrecomputedPrps)
    precompute_count = kMaxPrecomputedPrps;

  if (precompute_count > 0) {
    sqeType tmpSqe = {};
    for (uint32_t b = 0; b < precompute_count; b++) {
      uint64_t buf_off = (uint64_t)b * transfer_size;
      uint32_t prpOff = b * bufferParams.prpEntriesPerCmd;
      uint64_t* prpSlot = bufferParams.prpListPool
                            ? bufferParams.prpListPool + prpOff
                            : nullptr;
      uint64_t prpSlotDma = bufferParams.prpListPoolDma
                              ? bufferParams.prpListPoolDma +
                                  prpOff * sizeof(uint64_t)
                              : 0;
      uint32_t pageOff = (uint32_t)(buf_off / NVME_PAGE_SIZE);
      uint64_t intraPageOff = buf_off % NVME_PAGE_SIZE;

      if (has_read_buffer &&
          buf_off + transfer_size <= bufferParams.bufferSize) {
        uint64_t addr = bufferParams.readPagePhysAddrs
                          ? bufferParams.readPagePhysAddrs[pageOff] +
                              intraPageOff
                        : bufferParams.readBufferDma
                          ? (bufferParams.readBufferDma + buf_off)
                          : (uint64_t)(bufferParams.readBuffer + buf_off);
        calculatePrps(addr, transfer_size, &tmpSqe, prpSlot, prpSlotDma,
                      bufferParams.readPagePhysAddrs, pageOff);
        readPrp1[b] = tmpSqe.dptr.prp.prp1;
        readPrp2[b] = tmpSqe.dptr.prp.prp2;
      }

      if (has_write_buffer &&
          buf_off + transfer_size <= bufferParams.bufferSize) {
        uint64_t addr = bufferParams.writePagePhysAddrs
                          ? bufferParams.writePagePhysAddrs[pageOff] +
                              intraPageOff
                        : bufferParams.writeBufferDma
                          ? (bufferParams.writeBufferDma + buf_off)
                          : (uint64_t)(bufferParams.writeBuffer + buf_off);
        calculatePrps(addr, transfer_size, &tmpSqe, prpSlot, prpSlotDma,
                      bufferParams.writePagePhysAddrs, pageOff);
        writePrp1[b] = tmpSqe.dptr.prp.prp1;
        writePrp2[b] = tmpSqe.dptr.prp.prp2;
      }
    }
    prpsPrecomputed = true;
  }

  unsigned ops_done = 0;
  while ((ioParams.infiniteMode || ops_done < total_ops) &&
         (config.stopRequested == nullptr || !*config.stopRequested)) {
    unsigned batch_count = batch_size;
    if (!ioParams.infiniteMode && ops_done + batch_count > total_ops) {
      batch_count = total_ops - ops_done;
    }

    for (unsigned b = 0; b < batch_count; b++) {
      unsigned op_idx = ops_done + b;
      uint16_t cmd_id = (uint16_t)((op_idx % 65535) + 1);

      unsigned long long int ss_build0 = 0;
      if (config.substepStats)
        ss_build0 = wall_clock64();

      bool is_read_op;
      if (ioParams.infiniteMode) {
        is_read_op = infinite_is_read;
      } else if (num_write_ops > 0 && num_read_ops > 0) {
        is_read_op = (op_idx >= num_write_ops);
      } else {
        is_read_op = (num_read_ops > 0);
      }

      uint64_t lba = getRandomLba(op_idx, cmd_id, blocks, ioParams);

      sqeType sqeLocal = {};
      sqeType* sqe = &sqeLocal;
      sqe->opcode = is_read_op ? nvme_cmd_read : nvme_cmd_write;
      sqe->command_id = cmd_id;
      sqe->nsid = nsid;

      if (prpsPrecomputed && b < precompute_count) {
        if (is_read_op) {
          sqe->dptr.prp.prp1 = readPrp1[b];
          sqe->dptr.prp.prp2 = readPrp2[b];
        } else {
          sqe->dptr.prp.prp1 = writePrp1[b];
          sqe->dptr.prp.prp2 = writePrp2[b];
        }
      } else {
        uint64_t buf_off = (uint64_t)b * transfer_size;
        uint32_t prpOff = b * bufferParams.prpEntriesPerCmd;
        uint64_t* prpSlot = bufferParams.prpListPool
                              ? bufferParams.prpListPool + prpOff
                              : nullptr;
        uint64_t prpSlotDma = bufferParams.prpListPoolDma
                                ? bufferParams.prpListPoolDma +
                                    prpOff * sizeof(uint64_t)
                                : 0;
        uint32_t pageOff = (uint32_t)(buf_off / NVME_PAGE_SIZE);
        uint64_t intraPageOff = buf_off % NVME_PAGE_SIZE;

        if (is_read_op && has_read_buffer) {
          if (buf_off + transfer_size <= bufferParams.bufferSize) {
            uint64_t addr =
              bufferParams.readPagePhysAddrs
                ? bufferParams.readPagePhysAddrs[pageOff] + intraPageOff
              : bufferParams.readBufferDma
                ? (bufferParams.readBufferDma + buf_off)
                : (uint64_t)(bufferParams.readBuffer + buf_off);
            calculatePrps(addr, transfer_size, sqe, prpSlot, prpSlotDma,
                          bufferParams.readPagePhysAddrs, pageOff);
          } else {
            __builtin_trap();
          }
        } else if (!is_read_op && has_write_buffer) {
          if (buf_off + transfer_size <= bufferParams.bufferSize) {
            uint64_t addr =
              bufferParams.writePagePhysAddrs
                ? bufferParams.writePagePhysAddrs[pageOff] + intraPageOff
              : bufferParams.writeBufferDma
                ? (bufferParams.writeBufferDma + buf_off)
                : (uint64_t)(bufferParams.writeBuffer + buf_off);
            calculatePrps(addr, transfer_size, sqe, prpSlot, prpSlotDma,
                          bufferParams.writePagePhysAddrs, pageOff);
          } else {
            __builtin_trap();
          }
        } else {
          __builtin_trap();
        }
      }

      sqeSetup(sqe, lba, blocks);

      if (config.substepStats) {
        unsigned long long int ss_build1 = wall_clock64();
        config.substepStats->sqeBuild += ss_build1 - ss_build0;
        config.substepStats->buildCount++;
      }

      if (!ioParams.infiniteMode && config.startTimes != nullptr) {
        config.startTimes[op_idx] = wall_clock64();
      } else if (useBatchTiming && b < kMaxTimedBatch) {
        batchStartTimes[b] = wall_clock64();
      }

      unsigned long long int ss_t0 = 0, ss_t1 = 0;
      if (config.substepStats)
        ss_t0 = wall_clock64();

      nvme_ep::sqeWrite(sqeLocal, &sqeAddr[sq_tail]);

      if (config.substepStats) {
        ss_t1 = wall_clock64();
        config.substepStats->sqeEnqueue += ss_t1 - ss_t0;
      }

      sq_tail = (sq_tail + 1) % ioParams.queueSize;
    }

    unsigned long long int ss_db0 = 0, ss_db1 = 0;
    if (config.substepStats)
      ss_db0 = wall_clock64();

    nvme_ep::ringDoorbell(sq_tail, doorbellParams);

    if (config.substepStats) {
      ss_db1 = wall_clock64();
      config.substepStats->doorbell += ss_db1 - ss_db0;
    }

    unsigned long long int ss_poll0 = 0;
    if (config.substepStats)
      ss_poll0 = wall_clock64();

    for (unsigned b = 0; b < batch_count; b++) {
      unsigned op_idx = ops_done + b;

      volatile cqeType* cqe_entry = &cqeAddr[cq_head];

      nvme_ep::cqeType cqe_new;
      unsigned poll_count = 0;
      while (true) {
        if (config.stopRequested != nullptr && poll_count % 100 == 0 &&
            *config.stopRequested) {
          return;
        }
        cqe_new = nvme_ep::cqeRead(cqe_entry);
        uint8_t phase = NVME_CQE_STATUS_PHASE(cqe_new.status);
        if (phase == expected_phase) {
          break;
        }
        poll_count++;
        if (poll_count >= NVME_EP_MAX_POLLS) {
          printf("NVMe CQ poll timeout after %u "
                 "polls (cq_head=%u "
                 "expected_phase=%u)\n",
                 poll_count, (unsigned)cq_head, (unsigned)expected_phase);
          __builtin_trap();
        }
      }

      if (!nvme_ep::cqeOk(&cqe_new)) {
        printf("NVMe CQE error: status=0x%04x "
               "sc=0x%02x sct=0x%02x "
               "cmd_id=%u sq_head=%u\n",
               (unsigned)cqe_new.status,
               (unsigned)nvme_ep::cqeStatusCode(&cqe_new),
               (unsigned)nvme_ep::cqeStatusType(&cqe_new),
               (unsigned)cqe_new.command_id, (unsigned)cqe_new.sq_head);
        __builtin_trap();
      }

      if (!ioParams.infiniteMode && config.endTimes != nullptr) {
        config.endTimes[op_idx] = wall_clock64();
      } else if (useBatchTiming && b < kMaxTimedBatch) {
        unsigned long long int endTime = wall_clock64();
        if (endTime > batchStartTimes[b]) {
          updateTimingStats(config.timingStats, endTime - batchStartTimes[b]);
        }
      }

      cq_head = (cq_head + 1) % ioParams.queueSize;
      if (cq_head == 0) {
        expected_phase ^= 1;
      }
    }

    if (config.substepStats) {
      unsigned long long int ss_poll1 = wall_clock64();
      config.substepStats->cqPoll += ss_poll1 - ss_poll0;
    }

    unsigned long long int ss_cqdb0 = 0;
    if (config.substepStats)
      ss_cqdb0 = wall_clock64();

    nvme_ep::ringDoorbell(cq_head, doorbellParams,
                          doorbellParams.doorbellOffset +
                            nvme_ep::doorBellStride);

    if (config.substepStats) {
      unsigned long long int ss_cqdb1 = wall_clock64();
      config.substepStats->cqDoorbell += ss_cqdb1 - ss_cqdb0;
      config.substepStats->count += batch_count;
    }

    ops_done += batch_count;
  }
}

/**
 * Cooperative batch path (batch_size > 1).
 *
 * Threads 1..batch_size each prepare one SQE per batch
 * iteration.  Thread 0 is the coordinator: it rings the
 * SQ doorbell, polls CQEs, and rings the CQ doorbell.
 * Threads synchronize via __syncthreads() and may span
 * multiple wavefronts within one thread block.
 */
__device__ static void driveEndpointWavefront(
  const XioEndpointConfig& config, const nvmeIoParams& ioParams,
  const nvmeDoorbellParams& doorbellParams,
  const nvmeBufferParams& bufferParams) {
  const unsigned tid = threadIdx.x;

  sqeType* sqeAddr = static_cast<sqeType*>(config.submissionQueue);
  cqeType* cqeAddr = static_cast<cqeType*>(config.completionQueue);

  const unsigned num_read_ops = (unsigned)ioParams.readIo;
  const unsigned num_write_ops = (unsigned)ioParams.writeIo;
  const unsigned total_ops = num_read_ops + num_write_ops;
  const bool infinite_is_read = (num_read_ops > 0);

  uint32_t batch_size = ioParams.batchSize;
  if (batch_size > (uint32_t)(ioParams.queueSize - 1)) {
    batch_size = ioParams.queueSize - 1;
  }
  if (!ioParams.infiniteMode && batch_size > total_ops) {
    batch_size = total_ops;
  }

  const uint32_t nsid = ioParams.nsid;
  const uint32_t blocks = ioParams.lbasPerIo;
  const size_t transfer_size = (size_t)blocks * ioParams.lbaSize;

  const bool has_write_buffer = (bufferParams.writeBuffer != nullptr &&
                                 bufferParams.bufferSize > 0);
  const bool has_read_buffer = (bufferParams.readBuffer != nullptr &&
                                bufferParams.bufferSize > 0);

  const bool useBatchTiming = (config.timingStats != nullptr);

  // Shared state managed by thread 0, read by all
  __shared__ uint16_t sh_sq_tail;
  __shared__ uint16_t sh_cq_head;
  __shared__ uint8_t sh_expected_phase;
  __shared__ unsigned sh_ops_done;
  __shared__ unsigned sh_batch_count;
  __shared__ bool sh_stop;
  __shared__ bool sh_error;
  extern __shared__ unsigned long long int sh_startTimes[];

  if (tid == 0) {
    sh_sq_tail = 0;
    sh_cq_head = 0;
    sh_expected_phase = 1;
    sh_ops_done = 0;
    sh_stop = false;
    sh_error = false;

    if (has_write_buffer) {
      xio::DataPatternParams pp{
        bufferParams.writeBuffer, bufferParams.bufferSize, 0,
        ioParams.lbaSize,         ioParams.lfsrSeed,       nullptr};
      xio::dataPattern(false, pp);
    }
  }
  __syncthreads();

  while (!sh_stop) {
    // --- Phase 1: thread 0 computes batch parameters ---
    if (tid == 0) {
      unsigned bc = batch_size;
      if (!ioParams.infiniteMode && sh_ops_done + bc > total_ops) {
        bc = total_ops - sh_ops_done;
      }
      sh_batch_count = bc;
    }
    __syncthreads();

    const unsigned batch_count = sh_batch_count;
    const unsigned ops_done = sh_ops_done;
    const uint16_t sq_tail_base = sh_sq_tail;

    // --- Phase 2: threads 1..B prepare SQEs ---
    // tid 1 handles SQE index 0, tid 2 handles SQE
    // index 1, etc.
    if (tid >= 1) {
      unsigned b = tid - 1;
      if (b < batch_count) {
        unsigned op_idx = ops_done + b;
        uint16_t cmd_id = (uint16_t)((op_idx % 65535) + 1);

        bool is_read_op;
        if (ioParams.infiniteMode) {
          is_read_op = infinite_is_read;
        } else if (num_write_ops > 0 && num_read_ops > 0) {
          is_read_op = (op_idx >= num_write_ops);
        } else {
          is_read_op = (num_read_ops > 0);
        }

        uint64_t lba = getRandomLba(op_idx, cmd_id, blocks, ioParams);

        sqeType sqeLocal = {};
        sqeType* sqe = &sqeLocal;
        sqe->opcode = is_read_op ? nvme_cmd_read : nvme_cmd_write;
        sqe->command_id = cmd_id;
        sqe->nsid = nsid;

        uint64_t buf_off = (uint64_t)b * transfer_size;
        bool prp_valid = false;

        uint32_t prpOff = b * bufferParams.prpEntriesPerCmd;
        uint64_t* prpSlot = bufferParams.prpListPool
                              ? bufferParams.prpListPool + prpOff
                              : nullptr;
        uint64_t prpSlotDma = bufferParams.prpListPoolDma
                                ? bufferParams.prpListPoolDma +
                                    prpOff * sizeof(uint64_t)
                                : 0;
        uint32_t pageOff = (uint32_t)(buf_off / NVME_PAGE_SIZE);
        uint64_t intraPageOff = buf_off % NVME_PAGE_SIZE;

        if (is_read_op && has_read_buffer) {
          if (buf_off + transfer_size <= bufferParams.bufferSize) {
            uint64_t addr = bufferParams.readPagePhysAddrs
                              ? bufferParams.readPagePhysAddrs[pageOff] +
                                  intraPageOff
                            : bufferParams.readBufferDma
                              ? (bufferParams.readBufferDma + buf_off)
                              : (uint64_t)(bufferParams.readBuffer + buf_off);
            calculatePrps(addr, transfer_size, sqe, prpSlot, prpSlotDma,
                          bufferParams.readPagePhysAddrs, pageOff);
            prp_valid = true;
          }
        } else if (!is_read_op && has_write_buffer) {
          if (buf_off + transfer_size <= bufferParams.bufferSize) {
            uint64_t addr = bufferParams.writePagePhysAddrs
                              ? bufferParams.writePagePhysAddrs[pageOff] +
                                  intraPageOff
                            : bufferParams.writeBufferDma
                              ? (bufferParams.writeBufferDma + buf_off)
                              : (uint64_t)(bufferParams.writeBuffer + buf_off);
            calculatePrps(addr, transfer_size, sqe, prpSlot, prpSlotDma,
                          bufferParams.writePagePhysAddrs, pageOff);
            prp_valid = true;
          }
        }

        if (!prp_valid) {
          printf("NVMe PRP setup failed: "
                 "tid=%u op_idx=%u b=%u\n",
                 tid, op_idx, b);
          sh_error = true;
        }

        if (!sh_error) {
          sqeSetup(sqe, lba, blocks);

          if (!ioParams.infiniteMode && config.startTimes != nullptr) {
            config.startTimes[op_idx] = wall_clock64();
          } else if (useBatchTiming) {
            sh_startTimes[b] = wall_clock64();
          }

          uint16_t my_slot = (sq_tail_base + b) % ioParams.queueSize;
          nvme_ep::sqeWrite(sqeLocal, &sqeAddr[my_slot]);
        }
      }
    }
    __syncthreads();

    if (sh_error) {
      sh_stop = true;
      break;
    }

    // --- Phase 3: thread 0 rings doorbell, polls CQEs ---
    if (tid == 0) {
      uint16_t new_tail = (sq_tail_base + batch_count) % ioParams.queueSize;
      sh_sq_tail = new_tail;

      nvme_ep::ringDoorbell(new_tail, doorbellParams);

      uint16_t cq_head = sh_cq_head;
      uint8_t expected_phase = sh_expected_phase;

      for (unsigned b = 0; b < batch_count; b++) {
        unsigned op_idx = ops_done + b;

        volatile cqeType* cqe_entry = &cqeAddr[cq_head];

        nvme_ep::cqeType cqe_new;
        unsigned poll_count = 0;
        while (true) {
          if (config.stopRequested != nullptr && poll_count % 100 == 0 &&
              *config.stopRequested) {
            sh_stop = true;
            break;
          }
          cqe_new = nvme_ep::cqeRead(cqe_entry);
          uint8_t phase = NVME_CQE_STATUS_PHASE(cqe_new.status);
          if (phase == expected_phase) {
            break;
          }
          poll_count++;
          if (poll_count >= NVME_EP_MAX_POLLS) {
            printf("NVMe CQ poll timeout after "
                   "%u polls (cq_head=%u "
                   "expected_phase=%u)\n",
                   poll_count, (unsigned)cq_head, (unsigned)expected_phase);
            sh_stop = true;
            break;
          }
        }

        if (sh_stop) {
          break;
        }

        if (!nvme_ep::cqeOk(&cqe_new)) {
          printf("NVMe CQE error: status=0x%04x "
                 "sc=0x%02x sct=0x%02x "
                 "cmd_id=%u sq_head=%u\n",
                 (unsigned)cqe_new.status,
                 (unsigned)nvme_ep::cqeStatusCode(&cqe_new),
                 (unsigned)nvme_ep::cqeStatusType(&cqe_new),
                 (unsigned)cqe_new.command_id, (unsigned)cqe_new.sq_head);
          sh_stop = true;
          break;
        }

        if (!ioParams.infiniteMode && config.endTimes != nullptr) {
          config.endTimes[op_idx] = wall_clock64();
        } else if (useBatchTiming) {
          unsigned long long int endTime = wall_clock64();
          if (endTime > sh_startTimes[b]) {
            updateTimingStats(config.timingStats, endTime - sh_startTimes[b]);
          }
        }

        cq_head = (cq_head + 1) % ioParams.queueSize;
        if (cq_head == 0) {
          expected_phase ^= 1;
        }
      }

      if (!sh_stop) {
        nvme_ep::ringDoorbell(cq_head, doorbellParams,
                              doorbellParams.doorbellOffset +
                                nvme_ep::doorBellStride);
      }

      sh_cq_head = cq_head;
      sh_expected_phase = expected_phase;
      sh_ops_done = ops_done + batch_count;

      if (!ioParams.infiniteMode && sh_ops_done >= total_ops) {
        sh_stop = true;
      }
      if (config.stopRequested != nullptr && *config.stopRequested) {
        sh_stop = true;
      }
    }
    __syncthreads();
  }
}

__device__ void driveEndpoint(const XioEndpointConfig& config,
                              const nvmeIoParams& ioParams,
                              const nvmeDoorbellParams& doorbellParams,
                              const nvmeBufferParams& bufferParams) {
  if (ioParams.batchSize > 1) {
    driveEndpointWavefront(config, ioParams, doorbellParams, bufferParams);
  } else {
    driveEndpointSingle(config, ioParams, doorbellParams, bufferParams);
  }
}

/**
 * GPU kernel entry point for NVMe endpoint operations
 *
 * This kernel function is launched from host code to execute NVMe I/O
 * operations on the GPU. It calls driveEndpoint with the provided struct
 * parameters.
 *
 * @param config Base endpoint configuration (endpointConfig field set to
 * nullptr)
 * @param ioParams NVMe I/O parameters struct
 * @param doorbellParams Doorbell configuration parameters struct
 * @param bufferParams Data buffer parameters struct
 */
__global__ void gpuKernel(XioEndpointConfig config, nvmeIoParams ioParams,
                          nvmeDoorbellParams doorbellParams,
                          nvmeBufferParams bufferParams) {
  // Ensure endpointConfig is nullptr (host pointer not accessible from GPU)
  config.endpointConfig = nullptr;

  // Call driveEndpoint with struct parameters
  driveEndpoint(config, ioParams, doorbellParams, bufferParams);
}

} // namespace xio::nvme_ep

#ifndef __HIP_DEVICE_COMPILE__

#include <fcntl.h>

namespace xio::nvme_ep {

static int ioctlEintrSafe(int fd, unsigned long request, void* arg) {
  int ret;
  do {
    ret = ioctl(fd, request, arg);
  } while (ret < 0 && errno == EINTR);
  return ret;
}

//
// NVMe Endpoint CLI Options
//

/**
 * Validate NVMe endpoint configuration
 *
 * This function also auto-detects LBA size from the controller.
 * --controller is required and LBA size is always queried from it.
 *
 * @param config Pointer to nvmeEpConfig structure
 * @return Empty string if valid, error message otherwise
 */
__host__ std::string validateConfig(nvmeEpConfig* config) {
  // Auto-detect maximum queue ID if queueId is 0 (default)
  if (config->queueId == 0) {
    if (config->controller.empty()) {
      return "Cannot auto-detect queue ID: "
             "--controller not specified";
    }
    uint16_t max_queue_id = 0;
    int ret = queryMaxQueueId(config->controller.c_str(), &max_queue_id);
    if (ret != 0) {
      return "Failed to detect maximum queue ID. "
             "Please specify --queue-id manually.";
    }
    config->queueId = max_queue_id;
    ROCXIO_LOG_INFO("Auto-detected last available queue "
                    "ID: %u\n",
                    config->queueId);
  }

  // Multi-queue validation: ensure enough I/O queues
  // are available for the requested --num-queues count.
  // Queue IDs are allocated as a contiguous range
  // ending at queueId (i.e. queueId - numQueues + 1
  // through queueId).
  if (config->numQueues > 1) {
    if (config->queueId < config->numQueues) {
      char buf[256];
      snprintf(buf, sizeof(buf),
               "--num-queues %u requires at least %u "
               "IO queue IDs but queueId is %u "
               "(queue 0 is the admin queue)",
               config->numQueues, config->numQueues, config->queueId);
      return std::string(buf);
    }
    uint16_t baseQid = config->queueId - (config->numQueues - 1);
    ROCXIO_LOG_INFO("Multi-queue mode: %u queues "
                    "(IDs %u..%u)\n",
                    config->numQueues, baseQid, config->queueId);
  }

  // Validate that access pattern is valid
  if (config->ioParams.accessPattern != "sequential" &&
      config->ioParams.accessPattern != "random") {
    return "Access pattern must be 'sequential' or 'random'";
  }

  // Backward compatibility: convert negative readIo/writeIo
  // to positive. Negative values previously meant "sequential
  // mode" which is now the default (batch-size 1).
  if (config->ioParams.readIo < 0) {
    config->ioParams.readIo = -config->ioParams.readIo;
  }
  if (config->ioParams.writeIo < 0) {
    config->ioParams.writeIo = -config->ioParams.writeIo;
  }

  // Validate infinite mode requirements
  if (config->ioParams.infiniteMode) {
    bool has_read = (config->ioParams.readIo != 0);
    bool has_write = (config->ioParams.writeIo != 0);
    if (has_read && has_write) {
      return "--infinite requires exactly one of --read-io "
             "or --write-io to be non-zero, not both";
    }
    if (!has_read && !has_write) {
      return "--infinite requires exactly one of --read-io "
             "or --write-io to be non-zero";
    }
  } else {
    if (config->ioParams.readIo == 0 && config->ioParams.writeIo == 0) {
      return "At least one of --read-io or --write-io "
             "must be non-zero";
    }
  }

  // Validate that --controller is specified
  if (config->controller.empty()) {
    return "--controller must be specified";
  }

  // Detect LBA size from controller/namespace
  unsigned detected_lba_size = 0;
  int ret = queryLbaSize(config->controller.c_str(), config->ioParams.nsid,
                         &detected_lba_size);
  if (ret != 0) {
    return "Failed to obtain LBA size from controller: " +
           std::string(strerror(-ret));
  }
  config->ioParams.lbaSize = detected_lba_size;

  // Detect PCI MMIO bridge BDF if --pci-mmio-bridge is set
  if (config->doorbellParams.usePciMmioBridge) {
    uint16_t detected_bdf = 0;
    int bdf_ret = detectPciMmioBridgeBdf(&detected_bdf);
    if (bdf_ret != 0) {
      return "Failed to detect PCI MMIO bridge BDF";
    }
    config->doorbellParams.mmioBridgeBdf = detected_bdf;
  }

  // Detect NVMe target BDF from controller device path
  uint16_t detected_nvme_bdf = 0;
  int nvme_bdf_ret = detectBdfFromDevice(config->controller.c_str(),
                                         &detected_nvme_bdf);
  if (nvme_bdf_ret != 0) {
    return std::string("Failed to detect NVMe target BDF: ") +
           std::string(strerror(-nvme_bdf_ret));
  }
  config->doorbellParams.nvmeTargetBdf = detected_nvme_bdf;

  // Query wavefront size and validate batch_size.
  // When batch_size > 1 the kernel uses batch_size + 1
  // threads (threads 1..B write SQEs, thread 0 rings the
  // doorbell and polls CQEs).  The batch_size is capped
  // by queueSize - 1 (max in-flight SQEs).  It may span
  // multiple wavefronts within one thread block.
  if (config->ioParams.batchSize > 1) {
    int deviceId = 0;
    hipError_t hip_err = hipGetDevice(&deviceId);
    if (hip_err != hipSuccess) {
      return "Failed to query current HIP device";
    }
    hipDeviceProp_t deviceProp;
    hip_err = hipGetDeviceProperties(&deviceProp, deviceId);
    if (hip_err != hipSuccess) {
      return "Failed to query HIP device properties";
    }
    uint32_t waveSize = (uint32_t)deviceProp.warpSize;
    uint32_t maxBlockSize = (uint32_t)deviceProp.maxThreadsPerBlock;

    // batch_size + 1 threads must fit in one block
    if (config->ioParams.batchSize + 1 > maxBlockSize) {
      char buf[256];
      snprintf(buf, sizeof(buf),
               "--batch-size %u + 1 coordinator "
               "exceeds max block size %u",
               config->ioParams.batchSize, maxBlockSize);
      return std::string(buf);
    }

    config->wavefrontSize = waveSize;
    unsigned wavefronts = (config->ioParams.batchSize + 1 + waveSize - 1) /
                          waveSize;
    ROCXIO_LOG_INFO("Wavefront batch mode: batch_size=%u, "
                    "wavefront_size=%u, kernel_threads=%u"
                    " (%u wavefront%s)\n",
                    config->ioParams.batchSize, waveSize,
                    config->ioParams.batchSize + 1, wavefronts,
                    wavefronts > 1 ? "s" : "");
  }

  return std::string();
}

/**
 * Run NVMe endpoint operations
 *
 * Sets up queues, allocates buffers, and launches GPU
 * kernels.  Supports multi-queue mode where each queue
 * gets its own kernel on a separate HIP stream.
 *
 * @param config Base endpoint configuration
 * @return hipSuccess on success, error code on failure
 */
__host__ hipError_t run(XioEndpointConfig* config) {
  if (!config || !config->endpointConfig) {
    ROCXIO_LOG_ERROR("nvme-ep requires endpoint "
                     "configuration\n");
    return hipErrorInvalidValue;
  }

  nvme_ep::nvmeEpConfig* nvmeConfig = static_cast<nvme_ep::nvmeEpConfig*>(
    config->endpointConfig);

  if (nvmeConfig->controller.empty()) {
    ROCXIO_LOG_ERROR("NVMe device not specified. "
                     "--controller is required.\n");
    return hipErrorInvalidValue;
  }

  if (config->numThreads > 1) {
    ROCXIO_LOG_ERROR("nvme-ep does not support "
                     "--threads > 1. Use --batch-size > 1 "
                     "for cooperative batching.\n");
    return hipErrorNotSupported;
  }

  const uint16_t numQueues = nvmeConfig->numQueues;

  // ---- Enforce less-timing mode ----
  // When batch_size > 1 or num-queues > 1, per-op
  // timing arrays (startTimes/endTimes) are not
  // meaningful.  Force the lightweight stats path.
  bool forcedLessTiming = false;
  if (nvmeConfig->ioParams.batchSize > 1 || numQueues > 1) {
    if (config->startTimes != nullptr) {
      ROCXIO_LOG_INFO("Forcing less-timing mode "
                      "(batch_size=%u, num_queues=%u)\n",
                      nvmeConfig->ioParams.batchSize, numQueues);
      forcedLessTiming = true;
    }
  }

  // Compute the kernel thread count locally.  Do NOT
  // mutate config->numThreads -- the caller sized
  // timing arrays based on numThreads=1.
  uint16_t queue_size = nvmeConfig->queueLength;

  // Compute effective batch size matching the device-side
  // logic: batchSize 0 means "all at once" (total_ops in
  // finite mode, queueSize-1 in infinite mode).
  uint32_t effBatch = nvmeConfig->ioParams.batchSize;
  if (effBatch == 0) {
    unsigned total_ops = (unsigned)nvmeConfig->ioParams.readIo +
                         (unsigned)nvmeConfig->ioParams.writeIo;
    effBatch = nvmeConfig->ioParams.infiniteMode
                 ? (uint32_t)(queue_size - 1)
                 : total_ops;
  }
  if (effBatch > (uint32_t)(queue_size - 1))
    effBatch = queue_size - 1;
  {
    unsigned total_ops = (unsigned)nvmeConfig->ioParams.readIo +
                         (unsigned)nvmeConfig->ioParams.writeIo;
    if (!nvmeConfig->ioParams.infiniteMode && effBatch > total_ops)
      effBatch = total_ops;
  }

  unsigned kernelThreads = 1;
  if (effBatch > 1) {
    kernelThreads = effBatch + 1;
    ROCXIO_LOG_INFO("Batch mode: launching %u threads "
                    "(1 coordinator + %u SQE writers)\n",
                    kernelThreads, effBatch);
  }
  ROCXIO_LOG_INFO("Using queue length: %u entries\n", queue_size);

  // ---- Doorbell access setup (shared) ----
  if (nvmeConfig->doorbellParams.usePciMmioBridge) {
    void* shadow_virt = nullptr;
    int ret_shadow = mapMmioBridgeShadowBuffer(
      nvmeConfig->doorbellParams.mmioBridgeBdf, &shadow_virt);
    if (ret_shadow < 0) {
      ROCXIO_LOG_ERROR("Failed to map PCI MMIO bridge "
                       "shadow buffer.\n");
      return hipErrorInvalidValue;
    }
    ROCXIO_LOG_INFO("PCI MMIO bridge shadow buffer "
                    "mapped at %p.\n",
                    shadow_virt);
    const size_t shadow_size = 8192;
    void* shadow_gpu_ptr = nullptr;
    int ret_reg = registerMmioBridgeShadowBufferForGpu(shadow_virt, shadow_size,
                                                       &shadow_gpu_ptr);
    if (ret_reg < 0) {
      ROCXIO_LOG_ERROR("Failed to register PCI MMIO bridge "
                       "shadow buffer.\n");
      return hipErrorInvalidValue;
    }
    nvmeConfig->doorbellParams.shadowBufferVirt = shadow_gpu_ptr;
  } else {
    void* bar0_cpu = nullptr;
    void* bar0_gpu = nullptr;
    int ret_bar0 = mapPciBar(nvmeConfig->doorbellParams.nvmeTargetBdf, 0,
                             &bar0_cpu, &bar0_gpu, 8192);
    if (ret_bar0 < 0) {
      ROCXIO_LOG_WARN("Failed to map NVMe BAR0 "
                      "for direct doorbell: %s\n",
                      strerror(-ret_bar0));
      return hipErrorInvalidValue;
    }
    ROCXIO_LOG_INFO("NVMe BAR0 mapped for direct "
                    "doorbell access at %p.\n",
                    bar0_gpu);
    nvmeConfig->doorbellParams.nvmeBar0Gpu = bar0_gpu;
  }

  bool usePciMmioBridge = nvmeConfig->doorbellParams.usePciMmioBridge;
  void* shadowBufferVirt = nvmeConfig->doorbellParams.shadowBufferVirt;
  void* nvmeBar0Gpu = nvmeConfig->doorbellParams.nvmeBar0Gpu;

  // Verify shared GPU pointers
  if (shadowBufferVirt != nullptr) {
    if (!validateGpuPointer(shadowBufferVirt, "Shadow buffer", false)) {
      ROCXIO_LOG_ERROR("Shadow buffer is not "
                       "GPU-accessible.\n");
      return hipErrorInvalidValue;
    }
  }
  if (nvmeBar0Gpu != nullptr) {
    if (!validateGpuPointer(nvmeBar0Gpu, "BAR0", false)) {
      ROCXIO_LOG_ERROR("NVMe BAR0 is not "
                       "GPU-accessible.\n");
      return hipErrorInvalidValue;
    }
  }

  // ---- Namespace capacity query (shared) ----
  uint64_t lbaRangeLbas;
  {
    uint64_t namespace_capacity = 0;
    int cap_ret = queryNamespaceCapacity(nvmeConfig->controller.c_str(),
                                         nvmeConfig->ioParams.nsid,
                                         &namespace_capacity);
    if (cap_ret == 0 && namespace_capacity > 0) {
      lbaRangeLbas = namespace_capacity;
      ROCXIO_LOG_INFO("Using full namespace capacity: "
                      "%llu LBAs\n",
                      (unsigned long long)lbaRangeLbas);
    } else {
      ROCXIO_LOG_ERROR("Failed to query namespace "
                       "capacity\n");
      return hipErrorInvalidValue;
    }
  }

  bool useRandomAccess = (nvmeConfig->ioParams.accessPattern == "random");

  // ---- Build shared ioParams ----
  nvme_ep::nvmeIoParams ioParams;
  ioParams.lbaSize = nvmeConfig->ioParams.lbaSize;
  ioParams.baseLba = nvmeConfig->ioParams.baseLba;
  ioParams.lbaRangeLbas = lbaRangeLbas;
  ioParams.useRandomAccess = useRandomAccess;
  ioParams.readIo = nvmeConfig->ioParams.readIo;
  ioParams.writeIo = nvmeConfig->ioParams.writeIo;
  ioParams.lfsrSeed = nvmeConfig->ioParams.lfsrSeed;
  ioParams.nsid = nvmeConfig->ioParams.nsid;
  ioParams.lbasPerIo = nvmeConfig->ioParams.lbasPerIo;
  ioParams.queueSize = queue_size;
  ioParams.infiniteMode = nvmeConfig->ioParams.infiniteMode;
  ioParams.batchSize = nvmeConfig->ioParams.batchSize;
  ioParams.wavefrontSize = nvmeConfig->wavefrontSize;

  // ---- Validate batch buffer sizing ----
  {
    uint32_t eff_batch = ioParams.batchSize;
    if (eff_batch == 0) {
      eff_batch = ioParams.infiniteMode
                    ? (uint32_t)(queue_size - 1)
                    : (uint32_t)(ioParams.readIo + ioParams.writeIo);
    }
    if (eff_batch > (uint32_t)(queue_size - 1)) {
      eff_batch = queue_size - 1;
    }
    uint64_t xfer = (uint64_t)ioParams.lbasPerIo * ioParams.lbaSize;
    uint64_t needed = (uint64_t)eff_batch * xfer;
    if (needed > nvmeConfig->bufferParams.bufferSize) {
      ROCXIO_LOG_ERROR("batch-size %u * "
                       "transfer-size %llu = %llu exceeds "
                       "data-buffer-size %zu. Increase "
                       "--data-buffer-size or reduce "
                       "--batch-size.\n",
                       eff_batch, (unsigned long long)xfer,
                       (unsigned long long)needed,
                       nvmeConfig->bufferParams.bufferSize);
      return hipErrorInvalidValue;
    }
  }

  // Dynamic shared memory for batch timing
  size_t dynShmemBytes = 0;
  if (effBatch > 1) {
    dynShmemBytes = effBatch * sizeof(unsigned long long int);
  }

  // ---- Per-queue state vectors ----
  if (nvmeConfig->queueId < numQueues) {
    ROCXIO_LOG_ERROR("queueId %u too low for "
                     "%u queues (need queueId >= numQueues)\n",
                     nvmeConfig->queueId, numQueues);
    return hipErrorInvalidValue;
  }
  uint16_t baseQueueId = nvmeConfig->queueId - (numQueues - 1);

  nvmeConfig->queueIds.clear();
  nvmeConfig->queueInfos.clear();
  nvmeConfig->queueIds.reserve(numQueues);
  nvmeConfig->queueInfos.reserve(numQueues);

  hipError_t result = hipSuccess;
  std::vector<struct xioBufferInfo> readBufs(numQueues);
  std::vector<struct xioBufferInfo> writeBufs(numQueues);
  std::vector<hipStream_t> streams(numQueues, nullptr);
  std::vector<XioTimingStats*> perQueueStats(numQueues, nullptr);

  uint64_t xfer_size = (uint64_t)nvmeConfig->ioParams.lbasPerIo *
                       nvmeConfig->ioParams.lbaSize;
  constexpr uint32_t kMaxPrpListEntries = NVME_PAGE_SIZE / sizeof(uint64_t);
  uint32_t xfer_pages = (uint32_t)((xfer_size + NVME_PAGE_SIZE - 1) /
                                   NVME_PAGE_SIZE);
  if (xfer_pages > kMaxPrpListEntries + 1) {
    ROCXIO_LOG_ERROR("Transfer size %llu bytes (%u pages) "
                     "exceeds single PRP list page limit "
                     "(%u + 1 pages). Reduce --lbas-per-io.\n",
                     (unsigned long long)xfer_size, xfer_pages,
                     kMaxPrpListEntries);
    return hipErrorInvalidValue;
  }
  uint32_t prpEntriesPerCmd = (xfer_size > NVME_PAGE_SIZE)
                                ? (uint32_t)((xfer_size / NVME_PAGE_SIZE) + 1)
                                : 0;
  uint32_t prpStridePerCmd = prpEntriesPerCmd;
  if (prpStridePerCmd > 0) {
    uint32_t s = 1;
    while (s < prpStridePerCmd)
      s <<= 1;
    prpStridePerCmd = s;
  }
  uint32_t prpPoolEntriesPerQueue = prpStridePerCmd * effBatch;
  size_t prpPoolBytes = (size_t)prpPoolEntriesPerQueue * sizeof(uint64_t);
  long sys_page_sz = sysconf(_SC_PAGESIZE);
  size_t host_page = (sys_page_sz > 0) ? (size_t)sys_page_sz : 4096;
  if (prpPoolBytes > 0) {
    prpPoolBytes = (prpPoolBytes + host_page - 1) & ~(host_page - 1);
  }

  struct PrpPool {
    void* ptr = nullptr;
    void* gpuPtr = nullptr;
    uint64_t dma = 0;
    size_t size = 0;
    bool hipAllocated = false;
  };
  std::vector<PrpPool> prpPools(numQueues);

  // Allocate per-queue timing stats when forcing
  // less-timing or when the caller already set up
  // less-timing mode (timingStats != null).
  bool useLessTiming = forcedLessTiming || config->timingStats != nullptr;
  if (useLessTiming) {
    for (uint16_t q = 0; q < numQueues; q++) {
      hipError_t ts_err = xio::allocHostMemory(sizeof(XioTimingStats),
                                               (void**)&perQueueStats[q],
                                               "NVMe queue stats",
                                               XIO_HOST_MEM_MAPPED);
      if (ts_err != hipSuccess || !perQueueStats[q]) {
        ROCXIO_LOG_ERROR("Failed to allocate timing "
                         "stats for queue %u\n",
                         q);
        result = hipErrorMemoryAllocation;
        goto cleanup;
      }
      perQueueStats[q]->minDuration = ULLONG_MAX;
      perQueueStats[q]->maxDuration = 0;
      perQueueStats[q]->sumDuration = 0;
      perQueueStats[q]->count = 0;
    }
  }

  // ---- Check GPU lockup timeout for infinite mode ----
  // Multi-wavefront kernels with __syncthreads() barriers
  // cannot be preempted by the GPU scheduler. If the
  // amdgpu lockup_timeout is finite, the driver will
  // reset the GPU after the timeout expires. The param
  // is read-only at runtime; set at module load time.
  if (ioParams.infiniteMode && kernelThreads > nvmeConfig->wavefrontSize) {
    const char* sysfs_path = "/sys/module/amdgpu/parameters/lockup_timeout";
    FILE* f = fopen(sysfs_path, "r");
    if (f) {
      char buf[64] = {};
      bool timeout_ok = false;
      if (fgets(buf, sizeof(buf), f)) {
        char* comma1 = strchr(buf, ',');
        if (comma1) {
          char* compute_str = comma1 + 1;
          char* comma2 = strchr(compute_str, ',');
          if (comma2)
            *comma2 = '\0';
          int compute_val = atoi(compute_str);
          timeout_ok = (compute_val < 0);
        } else {
          int val = atoi(buf);
          timeout_ok = (val < 0);
        }
      }
      fclose(f);

      if (!timeout_ok) {
        fprintf(stderr, "Error: amdgpu lockup_timeout is not "
                        "set to infinity.\n"
                        "  Multi-wavefront infinite kernels "
                        "cannot be preempted and will "
                        "trigger a GPU reset.\n"
                        "  Fix: add to /etc/modprobe.d/"
                        "amdgpu-lockup.conf:\n"
                        "    options amdgpu "
                        "lockup_timeout=-1\n"
                        "  Then: sudo update-initramfs -u "
                        "&& sudo reboot\n");
        return hipErrorNotSupported;
      }
    }
  }

  // ---- Create queues and launch kernels ----
  for (uint16_t q = 0; q < numQueues; q++) {
    uint16_t qid = baseQueueId + q;

    struct nvme_queue_info queueInfo = {};
    int ret = createQueue(nvmeConfig->controller.c_str(), ROCM_XIO_DEVICE_PATH,
                          qid, queue_size,
                          nvmeConfig->doorbellParams.nvmeTargetBdf,
                          config->memoryMode, &queueInfo);

    if (ret < 0) {
      ROCXIO_LOG_ERROR("Failed to create NVMe "
                       "queue %u: %s\n",
                       qid, strerror(-ret));
      result = hipErrorInvalidValue;
      goto cleanup;
    }

    nvmeConfig->queueIds.push_back(qid);
    nvmeConfig->queueInfos.push_back(queueInfo);
    nvmeConfig->queuesCreated = true;
    struct nvme_queue_info& qi = nvmeConfig->queueInfos.back();

    ROCXIO_LOG_INFO("Queue %u created: SQ=0x%llx, "
                    "CQ=0x%llx\n",
                    qid, (unsigned long long)qi.sq_phys,
                    (unsigned long long)qi.cq_phys);

    void* sq_ptr = qi.sq_gpu ? qi.sq_gpu : qi.sq_virt;
    void* cq_ptr = qi.cq_gpu ? qi.cq_gpu : qi.cq_virt;
    if (!sq_ptr || !cq_ptr) {
      ROCXIO_LOG_ERROR("Queue %u pointers are "
                       "null\n",
                       qid);
      result = hipErrorInvalidValue;
      goto cleanup;
    }
    if (!validateGpuPointer(sq_ptr, "SQ", false) ||
        !validateGpuPointer(cq_ptr, "CQ", false)) {
      ROCXIO_LOG_ERROR("Queue %u not "
                       "GPU-accessible\n",
                       qid);
      result = hipErrorInvalidValue;
      goto cleanup;
    }

    // Allocate per-queue data buffers
    if (nvmeConfig->ioParams.readIo != 0) {
      hipError_t buf_err = allocateGpuAccessibleBuffer(
        nvmeConfig->bufferParams.bufferSize, config->memoryMode,
        nvmeConfig->doorbellParams.nvmeTargetBdf,
        nvmeConfig->controller.c_str(), &readBufs[q]);
      if (buf_err != hipSuccess) {
        ROCXIO_LOG_ERROR("Failed to allocate read "
                         "buffer for queue %u: %s\n",
                         qid, hipGetErrorString(buf_err));
        result = buf_err;
        goto cleanup;
      }
    }
    if (nvmeConfig->ioParams.writeIo != 0) {
      hipError_t buf_err = allocateGpuAccessibleBuffer(
        nvmeConfig->bufferParams.bufferSize, config->memoryMode,
        nvmeConfig->doorbellParams.nvmeTargetBdf,
        nvmeConfig->controller.c_str(), &writeBufs[q]);
      if (buf_err != hipSuccess) {
        ROCXIO_LOG_ERROR("Failed to allocate write "
                         "buffer for queue %u: %s\n",
                         qid, hipGetErrorString(buf_err));
        result = buf_err;
        goto cleanup;
      }
    }

    if (prpPoolBytes > 0) {
      void* pool = nullptr;
      hipError_t alloc_err = hipHostMalloc(&pool, prpPoolBytes,
                                           hipHostMallocMapped);
      if (alloc_err != hipSuccess || !pool) {
        ROCXIO_LOG_ERROR("Failed to allocate PRP list pool "
                         "for queue %u: %s\n",
                         qid, hipGetErrorString(alloc_err));
        result = hipErrorMemoryAllocation;
        goto cleanup;
      }
      memset(pool, 0, prpPoolBytes);

      uint64_t pool_dma = getPhysAddr(pool);
      if (pool_dma == 0) {
        ROCXIO_LOG_ERROR("Failed to get PRP pool phys addr "
                         "for queue %u\n",
                         qid);
        (void)hipHostFree(pool);
        result = hipErrorInvalidValue;
        goto cleanup;
      }

      void* gpu_pool = nullptr;
      (void)hipHostGetDevicePointer(&gpu_pool, pool, 0);
      if (!gpu_pool) {
        gpu_pool = pool;
      }

      prpPools[q].ptr = pool;
      prpPools[q].gpuPtr = gpu_pool;
      prpPools[q].dma = pool_dma;
      prpPools[q].size = prpPoolBytes;
      prpPools[q].hipAllocated = true;

      ROCXIO_LOG_INFO("  PRP pool queue %u: virt=%p "
                      "gpu=%p phys=0x%016llx (%zu bytes, "
                      "%u entries/cmd)\n",
                      qid, pool, gpu_pool, (unsigned long long)pool_dma,
                      prpPoolBytes, prpEntriesPerCmd);
    }

    // Create HIP stream for this queue
    if (numQueues > 1) {
      hipError_t s_err = hipStreamCreate(&streams[q]);
      if (s_err != hipSuccess) {
        ROCXIO_LOG_ERROR("Failed to create HIP "
                         "stream for queue %u: %s\n",
                         qid, hipGetErrorString(s_err));
        result = s_err;
        goto cleanup;
      }
    }

    // Build per-queue kernel parameters
    uint32_t qDoorbell = nvme_ep::doorbellBase +
                         (2 * qid * nvme_ep::doorBellStride);

    nvme_ep::nvmeDoorbellParams qDoorbellParams;
    qDoorbellParams.doorbellOffset = qDoorbell;
    qDoorbellParams.nvmeTargetBdf = nvmeConfig->doorbellParams.nvmeTargetBdf;
    qDoorbellParams.shadowBufferVirt = shadowBufferVirt;
    qDoorbellParams.nvmeBar0Gpu = nvmeBar0Gpu;
    qDoorbellParams.usePciMmioBridge = usePciMmioBridge;

    nvme_ep::nvmeBufferParams qBufParams = {};
    qBufParams.readBuffer = readBufs[q].gpuPtr
                              ? static_cast<uint8_t*>(readBufs[q].gpuPtr)
                              : static_cast<uint8_t*>(readBufs[q].hostPtr);
    qBufParams.writeBuffer = writeBufs[q].gpuPtr
                               ? static_cast<uint8_t*>(writeBufs[q].gpuPtr)
                               : static_cast<uint8_t*>(writeBufs[q].hostPtr);
    qBufParams.bufferSize = nvmeConfig->bufferParams.bufferSize;
    qBufParams.readBufferDma = readBufs[q].dmaAddr;
    qBufParams.writeBufferDma = writeBufs[q].dmaAddr;
    qBufParams.readPagePhysAddrs = readBufs[q].pagePhysAddrs;
    qBufParams.writePagePhysAddrs = writeBufs[q].pagePhysAddrs;
    qBufParams.readNumPages = readBufs[q].numPages;
    qBufParams.writeNumPages = writeBufs[q].numPages;
    qBufParams.prpListPool = prpPools[q].gpuPtr
                               ? static_cast<uint64_t*>(prpPools[q].gpuPtr)
                               : static_cast<uint64_t*>(prpPools[q].ptr);
    qBufParams.prpListPoolDma = prpPools[q].dma;
    qBufParams.prpEntriesPerCmd = prpStridePerCmd;

    XioEndpointConfig kernelConfig = *config;
    kernelConfig.endpointConfig = nullptr;
    kernelConfig.submissionQueue = sq_ptr;
    kernelConfig.completionQueue = cq_ptr;

    if (forcedLessTiming) {
      kernelConfig.startTimes = nullptr;
      kernelConfig.endTimes = nullptr;
    }
    if (useLessTiming) {
      kernelConfig.timingStats = perQueueStats[q];
    }

    // Keep backward compat: update nvmeConfig
    // with the first queue's info for single-queue
    if (q == 0) {
      nvmeConfig->queueInfo = nvmeConfig->queueInfos[0];
      nvmeConfig->sqBaseAddr = qi.sq_phys;
      nvmeConfig->cqBaseAddr = qi.cq_phys;
      nvmeConfig->sqSize = qi.sq_size;
      nvmeConfig->cqSize = qi.cq_size;
      config->submissionQueue = sq_ptr;
      config->completionQueue = cq_ptr;
    }

    ROCXIO_LOG_INFO("Launching kernel for queue %u "
                    "(stream %p)\n",
                    qid, (void*)streams[q]);

    hipLaunchKernelGGL(nvme_ep::gpuKernel, dim3(1), dim3(kernelThreads),
                       dynShmemBytes, streams[q], kernelConfig, ioParams,
                       qDoorbellParams, qBufParams);
  }

  ROCXIO_LOG_INFO("%u kernel%s launched.\n", numQueues,
                  numQueues > 1 ? "s" : "");

  // Wait for all GPU kernels to complete
  result = hipDeviceSynchronize();
  if (result != hipSuccess) {
    ROCXIO_LOG_INFO("Device synchronization error: "
                    "%s (code: %d).\n",
                    hipGetErrorString(result), result);
  }

  // ---- Verify read buffers ----
  if (result == hipSuccess && nvmeConfig->ioParams.readIo > 0) {
    for (uint16_t q = 0; q < numQueues; q++) {
      uint8_t* rbuf = readBufs[q].gpuPtr
                        ? static_cast<uint8_t*>(readBufs[q].gpuPtr)
                        : static_cast<uint8_t*>(readBufs[q].hostPtr);
      if (!rbuf)
        continue;
      size_t bsz = nvmeConfig->bufferParams.bufferSize;
      uint8_t* host_rb = nullptr;
      if (readBufs[q].gpuPtr) {
        host_rb = static_cast<uint8_t*>(malloc(bsz));
        if (host_rb)
          (void)hipMemcpy(host_rb, rbuf, bsz, hipMemcpyDeviceToHost);
        rbuf = host_rb;
      }
      if (rbuf) {
        xio::DataPatternParams vp{
          rbuf, bsz, 0, ioParams.lbaSize, ioParams.lfsrSeed, nullptr};
        if (xio::dataPattern(true, vp))
          config->verifyPass += static_cast<uint32_t>(
            nvmeConfig->ioParams.readIo);
        else
          config->verifyFail += static_cast<uint32_t>(
            nvmeConfig->ioParams.readIo);
      }
      free(host_rb);
    }
  }

  // ---- Aggregate per-queue timing stats ----
  if (useLessTiming && numQueues > 1 && config->timingStats != nullptr) {
    XioTimingStats* agg = config->timingStats;
    agg->minDuration = ULLONG_MAX;
    agg->maxDuration = 0;
    agg->sumDuration = 0;
    agg->count = 0;
    for (uint16_t q = 0; q < numQueues; q++) {
      if (!perQueueStats[q])
        continue;
      if (perQueueStats[q]->minDuration < agg->minDuration) {
        agg->minDuration = perQueueStats[q]->minDuration;
      }
      if (perQueueStats[q]->maxDuration > agg->maxDuration) {
        agg->maxDuration = perQueueStats[q]->maxDuration;
      }
      agg->sumDuration += perQueueStats[q]->sumDuration;
      agg->count += perQueueStats[q]->count;
    }
    ROCXIO_LOG_INFO("Aggregated timing across %u queues: "
                    "%llu ops\n",
                    numQueues, (unsigned long long)agg->count);
  } else if (useLessTiming && numQueues == 1 &&
             config->timingStats != nullptr && perQueueStats[0] != nullptr) {
    *config->timingStats = *perQueueStats[0];
  } else if (useLessTiming && numQueues == 1 &&
             config->timingStats == nullptr && perQueueStats[0] != nullptr) {
    config->timingStats = perQueueStats[0];
    perQueueStats[0] = nullptr;
  }

cleanup:
  // ---- Cleanup: delete successfully created NVMe queues ----
  if (nvmeConfig->queuesCreated) {
    uint16_t nCreated = (uint16_t)nvmeConfig->queueIds.size();
    ROCXIO_LOG_INFO("\nCleaning up %u NVMe queue%s...\n", nCreated,
                    nCreated > 1 ? "s" : "");
    int cleanup_fd = openDeviceWithRetry(nvmeConfig->controller.c_str(), O_RDWR,
                                         "NVMe device", 3, 50);
    if (cleanup_fd >= 0) {
      for (uint16_t q = 0; q < nCreated; q++) {
        deleteQueue(cleanup_fd, nvmeConfig->queueIds[q]);
      }
      close(cleanup_fd);
      nvmeConfig->queuesCreated = false;
    } else {
      ROCXIO_LOG_WARN("Could not reopen NVMe "
                      "device for queue cleanup: %s\n",
                      strerror(errno));
    }
  }

  // Free per-queue PRP list pools
  for (uint16_t q = 0; q < numQueues; q++) {
    if (prpPools[q].ptr && prpPools[q].hipAllocated) {
      (void)hipHostFree(prpPools[q].ptr);
    }
  }

  // Free per-queue data buffers
  for (uint16_t q = 0; q < numQueues; q++) {
    freeGpuAccessibleBuffer(&readBufs[q]);
    freeGpuAccessibleBuffer(&writeBufs[q]);
  }

  // Destroy non-default HIP streams
  for (uint16_t q = 0; q < numQueues; q++) {
    if (streams[q] != nullptr) {
      (void)hipStreamDestroy(streams[q]);
    }
  }

  for (uint16_t q = 0; q < numQueues; q++) {
    if (perQueueStats[q] != nullptr)
      xio::freeHostMemory(perQueueStats[q], XIO_HOST_MEM_MAPPED);
  }

  return result;
}

// Host helper function
__host__ int queryLbaSize(const char* nvme_device, uint32_t nsid,
                          unsigned* lba_size) {
  int nvme_fd = -1;
  int ret = 0;
  struct nvme_passthru_cmd cmd;
  struct nvme_id_ns* id_ns = nullptr;

  if (!nvme_device || !lba_size) {
    return -EINVAL;
  }

  {
    hipError_t herr = xio::allocHostMemory(nvme_ep::nvmeAdminRespSize,
                                           (void**)&id_ns, "Identify Namespace",
                                           XIO_HOST_MEM_PLAIN);
    if (herr != hipSuccess || !id_ns)
      return -ENOMEM;
  }

  nvme_fd = openDeviceWithRetry(nvme_device, O_RDONLY, "NVMe device", 5, 100);
  if (nvme_fd < 0) {
    ret = -errno;
    goto cleanup;
  }

  // Send Identify Namespace with retry for both status
  // errors and invalid response data (e.g. lbads=0 from
  // transient controller state after VRAM queue teardown)
  for (int attempt = 0; attempt < 5; attempt++) {
    memset(&cmd, 0, sizeof(cmd));
    cmd.opcode = nvme_admin_identify;
    cmd.nsid = nsid;
    cmd.cdw10 = 0; // CNS=0 (Identify Namespace)
    cmd.addr = reinterpret_cast<uint64_t>(id_ns);
    cmd.data_len = nvme_ep::nvmeAdminRespSize;
    cmd.timeout_ms = 0;

    ret = ioctlEintrSafe(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
    if (ret < 0) {
      ROCXIO_LOG_INFO("Failed to identify namespace: %s\n", strerror(errno));
      ret = -errno;
      goto cleanup;
    }

    if (cmd.result & 0xFFFE) {
      uint16_t status = (cmd.result >> 1) & 0xFF;
      if (attempt < 4) {
        int delay_ms = 100 * (1 << attempt);
        ROCXIO_LOG_INFO("Identify Namespace returned status "
                        "0x%02x, retrying in %d ms "
                        "(attempt %d/5)...\n",
                        status, delay_ms, attempt + 1);
        usleep(delay_ms * 1000);
        memset(id_ns, 0, nvme_ep::nvmeAdminRespSize);
        continue;
      }
      ROCXIO_LOG_INFO("Identify Namespace failed with status "
                      "0x%02x after 5 attempts\n",
                      status);
      ret = -EIO;
      goto cleanup;
    }

    // Command succeeded -- validate response data
    uint8_t flbas = id_ns->flbas;
    uint8_t lba_format_idx = flbas & 0x0F;

    if (lba_format_idx > id_ns->nlbaf) {
      if (attempt < 4) {
        int delay_ms = 100 * (1 << attempt);
        ROCXIO_LOG_INFO("Invalid LBA format index %u "
                        "(max %u), retrying in %d ms "
                        "(attempt %d/5)...\n",
                        lba_format_idx, id_ns->nlbaf, delay_ms, attempt + 1);
        usleep(delay_ms * 1000);
        memset(id_ns, 0, nvme_ep::nvmeAdminRespSize);
        continue;
      }
      ROCXIO_LOG_INFO("Invalid LBA format index %u "
                      "(max supported: %u) after "
                      "5 attempts\n",
                      lba_format_idx, id_ns->nlbaf);
      ret = -EINVAL;
      goto cleanup;
    }

    uint8_t lbads = id_ns->lbaf[lba_format_idx].ds;

    // NVMe spec mandates lbads >= 9 (512-byte minimum)
    if (lbads < 9) {
      if (attempt < 4) {
        int delay_ms = 100 * (1 << attempt);
        ROCXIO_LOG_INFO("Identify Namespace returned "
                        "lbads=%u (expected >= 9), "
                        "retrying in %d ms "
                        "(attempt %d/5)...\n",
                        lbads, delay_ms, attempt + 1);
        usleep(delay_ms * 1000);
        memset(id_ns, 0, nvme_ep::nvmeAdminRespSize);
        continue;
      }
      ROCXIO_LOG_INFO("Identify Namespace returned invalid "
                      "lbads=%u after 5 attempts\n",
                      lbads);
      ret = -EIO;
      goto cleanup;
    }

    *lba_size = 1U << lbads;
    ROCXIO_LOG_INFO("Selected LBA size: %u bytes (lbads=%u)\n", *lba_size,
                    lbads);
    ret = 0;
    goto cleanup;
  }

  ret = -EIO;

cleanup:
  if (nvme_fd >= 0) {
    close(nvme_fd);
  }
  if (id_ns) {
    xio::freeHostMemory(id_ns, XIO_HOST_MEM_PLAIN);
  }
  return ret;
}

__host__ int queryNamespaceCapacity(const char* nvme_device, uint32_t nsid,
                                    uint64_t* capacity_lbas) {
  int nvme_fd = -1;
  int ret = 0;
  struct nvme_passthru_cmd cmd;
  struct nvme_id_ns* id_ns = nullptr;

  if (!nvme_device || !capacity_lbas) {
    return -EINVAL;
  }

  {
    hipError_t herr = xio::allocHostMemory(nvme_ep::nvmeAdminRespSize,
                                           (void**)&id_ns,
                                           "Identify Namespace capacity",
                                           XIO_HOST_MEM_PLAIN);
    if (herr != hipSuccess || !id_ns)
      return -ENOMEM;
  }

  nvme_fd = openDeviceWithRetry(nvme_device, O_RDONLY, "NVMe device", 5, 100);
  if (nvme_fd < 0) {
    ret = -errno;
    goto cleanup;
  }

  // Send Identify Namespace with retry for both status
  // errors and invalid response data (nsze=0 from
  // transient controller state after VRAM queue teardown)
  for (int attempt = 0; attempt < 5; attempt++) {
    memset(&cmd, 0, sizeof(cmd));
    cmd.opcode = nvme_admin_identify;
    cmd.nsid = nsid;
    cmd.cdw10 = 0; // CNS=0 (Identify Namespace)
    cmd.addr = reinterpret_cast<uint64_t>(id_ns);
    cmd.data_len = nvme_ep::nvmeAdminRespSize;
    cmd.timeout_ms = 0;

    ret = ioctlEintrSafe(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
    if (ret < 0) {
      ROCXIO_LOG_INFO("Failed to identify namespace: %s\n", strerror(errno));
      ret = -errno;
      goto cleanup;
    }

    if (cmd.result & 0xFFFE) {
      uint16_t status = (cmd.result >> 1) & 0xFF;
      if (attempt < 4) {
        int delay_ms = 100 * (1 << attempt);
        ROCXIO_LOG_INFO("Identify Namespace returned status "
                        "0x%02x, retrying in %d ms "
                        "(attempt %d/5)...\n",
                        status, delay_ms, attempt + 1);
        usleep(delay_ms * 1000);
        memset(id_ns, 0, nvme_ep::nvmeAdminRespSize);
        continue;
      }
      ROCXIO_LOG_INFO("Identify Namespace failed with status "
                      "0x%02x after 5 attempts\n",
                      status);
      ret = -EIO;
      goto cleanup;
    }

    // Command succeeded -- validate response data
    if (id_ns->nsze == 0) {
      if (attempt < 4) {
        int delay_ms = 100 * (1 << attempt);
        ROCXIO_LOG_INFO("Identify Namespace returned "
                        "nsze=0, retrying in %d ms "
                        "(attempt %d/5)...\n",
                        delay_ms, attempt + 1);
        usleep(delay_ms * 1000);
        memset(id_ns, 0, nvme_ep::nvmeAdminRespSize);
        continue;
      }
      ROCXIO_LOG_INFO("Identify Namespace returned "
                      "nsze=0 after 5 attempts\n");
      ret = -EIO;
      goto cleanup;
    }

    *capacity_lbas = id_ns->nsze;
    ROCXIO_LOG_INFO("Namespace capacity: %llu LBAs\n",
                    (unsigned long long)*capacity_lbas);
    ret = 0;
    goto cleanup;
  }

  ret = -EIO;

cleanup:
  if (nvme_fd >= 0) {
    close(nvme_fd);
  }
  if (id_ns) {
    xio::freeHostMemory(id_ns, XIO_HOST_MEM_PLAIN);
  }
  return ret;
}

__host__ int checkRootfs(const char* nvme_device) {
  char ns_device[256];
  snprintf(ns_device, sizeof(ns_device), "%sn1", nvme_device);

  // Check /proc/mounts for root mount
  FILE* f = fopen("/proc/mounts", "r");
  if (!f) {
    ROCXIO_LOG_WARN("Failed to open /proc/mounts\n");
    return 0;
  }

  char line[512];
  bool is_rootfs = false;
  while (fgets(line, sizeof(line), f)) {
    // Format: device mount_point filesystem ...
    char device[256], mount_point[256];
    if (sscanf(line, "%255s %255s", device, mount_point) == 2) {
      if (strcmp(mount_point, "/") == 0) {
        // Check if this device matches our NVMe device
        if (strstr(device, ns_device) != nullptr ||
            strstr(device, nvme_device) != nullptr) {
          is_rootfs = true;
          break;
        }
      }
    }
  }
  fclose(f);

  if (is_rootfs) {
    ROCXIO_LOG_ERROR("NVMe device %s appears to be the root filesystem!\n",
                     nvme_device);
    ROCXIO_LOG_ERROR("This operation will NOT proceed on rootfs to prevent "
                     "data corruption.\n");
    ROCXIO_LOG_ERROR("Please specify a different NVMe device.\n");
    return -1;
  }

  return 0;
}

__host__ int readSmartLog(const char* nvme_device,
                          struct nvme_smart_log* smart_log) {
  int nvme_fd = -1;
  // Open NVMe device with retry (device may be temporarily busy)
  nvme_fd = openDeviceWithRetry(nvme_device, O_RDONLY, "NVMe device", 5, 100);
  if (nvme_fd < 0) {
    return -errno;
  }

  uint8_t* buffer = nullptr;
  {
    hipError_t herr = xio::allocHostMemory(nvme_ep::nvmeLogPageSize,
                                           (void**)&buffer, "SMART log buffer",
                                           XIO_HOST_MEM_PLAIN);
    if (herr != hipSuccess || !buffer) {
      ROCXIO_LOG_INFO("Failed to allocate SMART log buffer\n");
      close(nvme_fd);
      return -ENOMEM;
    }
  }

  // Use NVME_IOCTL_ADMIN64_CMD with nvme_passthru_cmd64
  struct nvme_passthru_cmd64 cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_get_log_page;
  cmd.nsid = 0xFFFFFFFF;
  cmd.cdw10 = (((nvme_ep::nvmeLogPageSize / 4) - 1) << 16) | 0x02;
  cmd.cdw11 = 0x00000000;
  cmd.cdw12 = 0x00000000;
  cmd.addr = reinterpret_cast<uint64_t>(buffer);
  cmd.data_len = nvme_ep::nvmeLogPageSize;
  cmd.timeout_ms = 0;

  int ret = ioctlEintrSafe(nvme_fd, NVME_IOCTL_ADMIN64_CMD, &cmd);
  if (ret < 0) {
    ROCXIO_LOG_INFO("Failed to read SMART log: %s\n", strerror(errno));
    xio::freeHostMemory(buffer, XIO_HOST_MEM_PLAIN);
    close(nvme_fd);
    return -errno;
  }

  // Check completion status
  if (cmd.result & 0xFFFE) {
    uint16_t status = (cmd.result >> 1) & 0xFF;
    ROCXIO_LOG_INFO("SMART log read failed with status 0x%02x\n", status);
    xio::freeHostMemory(buffer, XIO_HOST_MEM_PLAIN);
    close(nvme_fd);
    return -EIO;
  }

  memcpy(smart_log, buffer, nvme_ep::nvmeLogPageSize);

  xio::freeHostMemory(buffer, XIO_HOST_MEM_PLAIN);
  close(nvme_fd);
  return 0;
}

__host__ int queryMaxQueueId(const char* nvme_device, uint16_t* max_queue_id) {
  if (!nvme_device || !max_queue_id) {
    return -EINVAL;
  }

  // Extract device name from path (e.g., "/dev/nvme1" -> "nvme1")
  const char* device_name = strrchr(nvme_device, '/');
  if (!device_name) {
    device_name = nvme_device;
  } else {
    device_name++; // Skip the '/'
  }

  // Build sysfs path: /sys/class/nvme/nvme1/queue_count
  char sysfs_path[256];
  snprintf(sysfs_path, sizeof(sysfs_path), "/sys/class/nvme/%s/queue_count",
           device_name);

  FILE* f = fopen(sysfs_path, "r");
  if (!f) {
    ROCXIO_LOG_ERROR("Failed to open %s: %s\n"
                     "Cannot determine maximum queue ID. Please specify "
                     "--queue-id manually.\n",
                     sysfs_path, strerror(errno));
    return -errno;
  }

  unsigned int queue_count = 0;
  if (fscanf(f, "%u", &queue_count) != 1) {
    ROCXIO_LOG_ERROR("Failed to parse queue count from %s\n"
                     "Cannot determine maximum queue ID. Please specify "
                     "--queue-id manually.\n",
                     sysfs_path);
    fclose(f);
    return -EIO;
  }
  fclose(f);

  if (queue_count == 0) {
    ROCXIO_LOG_ERROR("Queue count is 0 in %s\n"
                     "Cannot determine maximum queue ID. Please specify "
                     "--queue-id manually.\n",
                     sysfs_path);
    return -EINVAL;
  }

  // queue_count includes 1 admin queue (QID 0) + N I/O queues (QID 1-N)
  // So the last I/O queue ID is queue_count - 1
  // But we need at least 1 I/O queue, so queue_count must be >= 2
  if (queue_count < 2) {
    ROCXIO_LOG_ERROR("Only %u queue(s) available (need at least 2: 1 admin + 1 "
                     "I/O)\n"
                     "Cannot use any I/O queues. Please check device "
                     "configuration.\n",
                     queue_count);
    return -EINVAL;
  }

  *max_queue_id = static_cast<uint16_t>(queue_count - 1);
  ROCXIO_LOG_INFO(
    "Detected %u total queues (1 admin + %u I/O). Using last I/O queue "
    "ID: %u\n",
    queue_count, queue_count - 1, *max_queue_id);

  return 0;
}

__host__ int deleteQueue(int nvme_fd, uint16_t queue_id) {
  struct nvme_passthru_cmd cmd;
  int ret = 0;
  bool controller_reset_detected = false;

  if (nvme_fd < 0) {
    return -EINVAL;
  }

  // Delete existing queues if they exist (ignore errors - queue may not exist)
  // Delete SQ first, then CQ (NVMe spec requirement: CQ cannot be deleted
  // while associated SQ exists)

  // Delete Submission Queue (DELETE_SQ)
  // Note: DELETE_SQ may take time if the queue has pending commands - the
  // controller waits for all commands to complete before deletion
  // Also note: DELETE_SQ on a non-existent queue ID may hang - this is
  // expected behavior per NVMe spec
  ROCXIO_LOG_INFO(
    "Sending DELETE_SQ command for queue_id=%u (this may take time if "
    "queue has pending commands or doesn't exist)...\n",
    queue_id);
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_delete_sq;
  cmd.nsid = 0;           // Admin commands use NSID 0
  cmd.cdw10 = queue_id;   // QID
  cmd.data_len = 0;       // No data transfer for DELETE_SQ
  cmd.timeout_ms = 30000; // 30 second timeout (DELETE_SQ can take time)

  ret = ioctlEintrSafe(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret == 0) {
    ROCXIO_LOG_INFO("DELETE_SQ completed successfully.\n");
    // Check status code even if ioctl succeeded
    if (cmd.result & 0xFFFE) {
      uint16_t status_field = cmd.result & 0xFFFF;
      uint8_t sc = NVME_CQE_STATUS_SC(status_field);
      ROCXIO_LOG_INFO("Note: DELETE_SQ returned status code 0x%02x (queue may "
                      "not exist)\n",
                      sc);
    }
  } else {
    // ioctl failed - could be timeout or other error
    if (errno == ETIMEDOUT) {
      ROCXIO_LOG_WARN("DELETE_SQ timed out for queue_id=%u. This may "
                      "indicate the queue ID is invalid or the controller is "
                      "busy. The controller may have been reset.\n",
                      queue_id);
      controller_reset_detected = true;
    } else {
      ROCXIO_LOG_INFO("Note: DELETE_SQ failed (queue may not exist): %s "
                      "(errno=%d)\n",
                      strerror(errno), errno);
    }
  }

  // If controller was reset, wait for it to stabilize before proceeding
  if (controller_reset_detected) {
    ROCXIO_LOG_INFO(
      "Waiting 2 seconds for controller to stabilize after reset...\n");
    sleep(2);
  }

  // Delete Completion Queue (DELETE_CQ)
  ROCXIO_LOG_INFO("Sending DELETE_CQ command for queue_id=%u...\n", queue_id);
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_delete_cq;
  cmd.nsid = 0;           // Admin commands use NSID 0
  cmd.cdw10 = queue_id;   // QID
  cmd.data_len = 0;       // No data transfer for DELETE_CQ
  cmd.timeout_ms = 30000; // 30 second timeout

  ret = ioctlEintrSafe(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret == 0) {
    ROCXIO_LOG_INFO("DELETE_CQ completed successfully.\n");
  } else {
    ROCXIO_LOG_INFO("DELETE_CQ ioctl returned: %d\n", ret);
  }
  if (ret < 0) {
    // Ignore errors - queue may not exist
    ROCXIO_LOG_INFO("Note: DELETE_CQ failed (queue may not exist): %s\n",
                    strerror(errno));
  } else if (cmd.result & 0xFFFE) {
    // Check status code, but don't fail - queue may not exist
    uint16_t status_field = cmd.result & 0xFFFF;
    uint8_t sc = NVME_CQE_STATUS_SC(status_field);
    // Ignore errors - queue may not exist or may have already been deleted
    ROCXIO_LOG_INFO("Note: DELETE_CQ returned status code 0x%02x (queue may "
                    "not exist)\n",
                    sc);
  }

  return 0;
}

__host__ int createQueueCommands(int nvme_fd, uint16_t queue_id,
                                 uint16_t queue_size, void* sq_virt,
                                 void* cq_virt, bool sq_pc, bool cq_pc) {
  struct nvme_passthru_cmd cmd;
  int ret = 0;

  if (nvme_fd < 0 || !sq_virt || !cq_virt || queue_size == 0) {
    return -EINVAL;
  }

  // Create Completion Queue first (CREATE_CQ)
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_create_cq;
  cmd.nsid = 0;
  cmd.cdw10 = (queue_size - 1) << 16 | queue_id;
  cmd.cdw11 = cq_pc ? 0x00000001 : 0x00000000;
  cmd.addr = reinterpret_cast<uint64_t>(cq_virt);
  cmd.data_len = 0;

  ROCXIO_LOG_INFO("CREATE_CQ: queue_id=%u, queue_size=%u, "
                  "cdw10=0x%08x, PC=%d\n",
                  queue_id, queue_size, cmd.cdw10, cq_pc ? 1 : 0);

  ret = ioctlEintrSafe(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    if (errno == EACCES || errno == EPERM) {
      ROCXIO_LOG_ERROR("Failed to create completion queue: %s\n",
                       strerror(errno));
      ROCXIO_LOG_INFO("Note: CREATE_CQ IOCTL requires root permissions.\n");
      ROCXIO_LOG_ERROR("Please ensure you have CAP_SYS_ADMIN capability or "
                       "run with sudo.\n");
    } else {
      ROCXIO_LOG_ERROR("Failed to create completion queue: %s\n",
                       strerror(errno));
    }
    ROCXIO_LOG_ERROR("Cannot proceed - queue creation failed.\n");
    return -errno;
  }

  // Check completion status
  if (cmd.result & 0xFFFE) {
    uint16_t status_field = cmd.result & 0xFFFF;
    uint8_t sc = NVME_CQE_STATUS_SC(status_field);
    uint8_t sct = NVME_CQE_STATUS_SCT(status_field);
    ROCXIO_LOG_ERROR("CREATE_CQ failed with status code 0x%02x (SCT=%u)\n", sc,
                     sct);
    if (sc == NVME_SC_INVALID_FIELD) {
      ROCXIO_LOG_ERROR("Invalid field in command (queue_id=%u, "
                       "queue_size=%u)\n",
                       queue_id, queue_size);
    } else if (sc == NVME_SC_CAP_EXCEEDED) {
      ROCXIO_LOG_ERROR("Queue size exceeds controller capabilities "
                       "(queue_size=%u)\n",
                       queue_size);
    }
    ROCXIO_LOG_ERROR("Cannot proceed - queue creation failed.\n");
    return -EIO;
  }

  ROCXIO_LOG_INFO("Successfully created completion queue (queue_id=%u, "
                  "size=%u)\n",
                  queue_id, queue_size);

  // Re-zero completion queue after creation to clear any stale entries
  // This is especially important after a controller reset
  memset(cq_virt, 0, queue_size * NVME_EP_CQE_SIZE);
  ROCXIO_LOG_INFO("Re-zeroed completion queue to clear any stale entries.\n");

  // Small delay to allow controller to stabilize after CQ creation
  usleep(100000); // 100ms delay

  // Create Submission Queue (CREATE_SQ)
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_create_sq;
  cmd.nsid = 0;
  cmd.cdw10 = (queue_size - 1) << 16 | queue_id;
  cmd.cdw11 = (queue_id << 16) | (sq_pc ? 0x0001 : 0x0000);
  cmd.addr = reinterpret_cast<uint64_t>(sq_virt);
  cmd.data_len = 0;

  ROCXIO_LOG_INFO("CREATE_SQ: queue_id=%u, queue_size=%u, "
                  "cdw10=0x%08x, cdw11=0x%08x, PC=%d\n",
                  queue_id, queue_size, cmd.cdw10, cmd.cdw11, sq_pc ? 1 : 0);

  ret = ioctlEintrSafe(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    ROCXIO_LOG_ERROR("Failed to create submission queue: %s\n",
                     strerror(errno));
    ROCXIO_LOG_ERROR("Cannot proceed - queue creation failed.\n");
    return -errno;
  }

  // Check completion status
  if (cmd.result & 0xFFFE) {
    uint16_t status_field = cmd.result & 0xFFFF;
    uint8_t sc = NVME_CQE_STATUS_SC(status_field);
    uint8_t sct = NVME_CQE_STATUS_SCT(status_field);
    ROCXIO_LOG_ERROR("CREATE_SQ failed with status code 0x%02x (SCT=%u)\n", sc,
                     sct);
    if (sc == NVME_SC_INVALID_FIELD) {
      ROCXIO_LOG_ERROR("Invalid field in command (queue_id=%u, "
                       "queue_size=%u, CQID=%u)\n",
                       queue_id, queue_size, queue_id);
    } else if (sc == NVME_SC_CAP_EXCEEDED) {
      ROCXIO_LOG_ERROR("Queue size exceeds controller capabilities "
                       "(queue_size=%u)\n",
                       queue_size);
    }
    ROCXIO_LOG_ERROR("Cannot proceed - queue creation failed.\n");
    return -EIO;
  }

  ROCXIO_LOG_INFO("Successfully created submission queue (queue_id=%u, "
                  "size=%u)\n",
                  queue_id, queue_size);

  return 0;
}

static void freeQueueSetup(struct xioQueueSetup* s, bool is_device,
                           const char* name, size_t size = 0) {
  if (!s || !s->virt)
    return;
  if (s->prp_list) {
#ifndef __HIP_DEVICE_COMPILE__
    long page_sz = sysconf(_SC_PAGESIZE);
    if (page_sz > 0) {
      int rc = munlock(s->prp_list, static_cast<size_t>(page_sz));
      if (rc != 0) {
        ROCXIO_LOG_WARN("munlock failed for PRP list '%s': %s\n",
                        (name != nullptr) ? name : "unknown", strerror(errno));
      }
    } else {
      ROCXIO_LOG_WARN("failed to get page size for munlock of PRP list '%s'\n",
                      (name != nullptr) ? name : "unknown");
    }
#endif // __HIP_DEVICE_COMPILE__
    free(s->prp_list);
    s->prp_list = nullptr;
    s->prp_list_phys = 0;
  }
  if (s->uses_contig) {
    freeContigQueue(s, size, name);
  } else if (s->uses_coherent) {
    (void)hipHostFree(s->virt);
  } else {
    freeQueue(s->virt, is_device, name);
  }
  s->virt = nullptr;
  s->gpu = nullptr;
}

__host__ int createQueue(const char* nvme_device,
                         const char* kernel_module_device, uint16_t queue_id,
                         uint16_t queue_size, uint16_t nvme_bdf,
                         unsigned memory_mode, struct nvme_queue_info* info) {
  int kmod_fd = -1;
  int nvme_fd = -1;
  int ret = 0;
  struct xioQueueSetup sq_setup = {};
  struct xioQueueSetup cq_setup = {};
  bool sq_is_device = (memory_mode & XIO_MEM_MODE_SQ_DEVICE) != 0;
  bool cq_is_device = (memory_mode & XIO_MEM_MODE_CQ_DEVICE) != 0;

  if (!nvme_device || !kernel_module_device || !info)
    return -EINVAL;

  if (queue_size == 0 || (queue_size & (queue_size - 1)) != 0)
    return -EINVAL;

  const size_t sq_size_bytes = queue_size * NVME_EP_SQE_SIZE;
  const size_t cq_size_bytes = queue_size * NVME_EP_CQE_SIZE;

  memset(info, 0, sizeof(*info));
  info->sq_size = sq_size_bytes;
  info->cq_size = cq_size_bytes;

  kmod_fd = open(kernel_module_device, O_RDWR);
  if (kmod_fd < 0) {
    ROCXIO_LOG_INFO("Failed to open kernel module device "
                    "%s: %s\n",
                    kernel_module_device, strerror(errno));
    return -errno;
  }

  bool is_emulated = false;
  int detect_ret = detectEmulatedNvme(nvme_device, &is_emulated);
  if (detect_ret != 0) {
    ROCXIO_LOG_ERROR("Failed to detect NVMe type "
                     "for %s: %s.\n",
                     nvme_device, strerror(-detect_ret));
    close(kmod_fd);
    return -detect_ret;
  }
  ROCXIO_LOG_INFO("NVMe device %s detected as: %s.\n", nvme_device,
                  is_emulated ? "EMULATED" : "REAL");

  nvme_fd = openDeviceWithRetry(nvme_device, O_RDWR, "NVMe device", 5, 100);
  if (nvme_fd < 0) {
    ROCXIO_LOG_ERROR("Failed to open NVMe device %s: %s.\n", nvme_device,
                     strerror(errno));
    close(kmod_fd);
    return -errno;
  }

  // Read CQR before allocation so we can choose the
  // right allocation path.
  bool cqr = false;
  {
    int cqr_ret = readNvmeCapCqr(nvme_bdf, &cqr);
    if (cqr_ret < 0) {
      ROCXIO_LOG_WARN("Could not read CQR, "
                      "assuming contiguous required "
                      "(PC=1).\n");
      cqr = true;
    }
  }

  // HIP allocators (hipMalloc, hipHostMalloc) always return
  // page-aligned memory, so size > NVME_PAGE_SIZE is sufficient
  // to determine multi-page spanning.
  bool sq_multi_page = !sq_is_device && sq_size_bytes > NVME_PAGE_SIZE;
  bool cq_multi_page = !cq_is_device && cq_size_bytes > NVME_PAGE_SIZE;

  // CQR=1 + multi-page: use contiguous DMA path
  if (cqr && sq_multi_page) {
    ROCXIO_LOG_INFO("CQR=1: using contiguous DMA for "
                    "submission queue (%zu bytes)\n",
                    sq_size_bytes);
    ret = setupContigQueueForGpu(sq_size_bytes, nvme_bdf, "submission queue",
                                 &sq_setup);
    if (ret < 0) {
      size_t max_sq = NVME_PAGE_SIZE / NVME_EP_SQE_SIZE;
      ROCXIO_LOG_ERROR("Contiguous alloc failed for "
                       "SQ. Try --queue-length %zu or "
                       "smaller.\n",
                       max_sq);
      goto cleanup;
    }
  } else {
    ret = setupQueueForGpu(sq_size_bytes, sq_is_device, nvme_bdf,
                           kernel_module_device, is_emulated,
                           "submission queue", &sq_setup);
    if (ret < 0)
      goto cleanup;
  }

  if (cqr && cq_multi_page) {
    ROCXIO_LOG_INFO("CQR=1: using contiguous DMA for "
                    "completion queue (%zu bytes)\n",
                    cq_size_bytes);
    ret = setupContigQueueForGpu(cq_size_bytes, nvme_bdf, "completion queue",
                                 &cq_setup);
    if (ret < 0) {
      size_t max_cq = NVME_PAGE_SIZE / NVME_EP_CQE_SIZE;
      ROCXIO_LOG_ERROR("Contiguous alloc failed for "
                       "CQ. Try --queue-length %zu or "
                       "smaller.\n",
                       max_cq);
      freeQueueSetup(&sq_setup, sq_is_device, "submission queue",
                     sq_size_bytes);
      goto cleanup;
    }
  } else {
    ret = setupQueueForGpu(cq_size_bytes, cq_is_device, nvme_bdf,
                           kernel_module_device, is_emulated,
                           "completion queue", &cq_setup);
    if (ret < 0) {
      freeQueueSetup(&sq_setup, sq_is_device, "submission queue",
                     sq_size_bytes);
      goto cleanup;
    }
  }

  // PC flags: contiguous allocs always use PC=1
  {
    bool sq_pc = cqr || !sq_multi_page;
    bool cq_pc = cqr || !cq_multi_page;

    ROCXIO_LOG_INFO("Queue PC flags: SQ PC=%d (%zu bytes, "
                    "%s%s), CQ PC=%d (%zu bytes, %s%s)\n",
                    sq_pc ? 1 : 0, sq_size_bytes,
                    sq_is_device ? "device" : "host",
                    sq_setup.uses_contig ? ", contig" : "", cq_pc ? 1 : 0,
                    cq_size_bytes, cq_is_device ? "device" : "host",
                    cq_setup.uses_contig ? ", contig" : "");

    // Build PRP lists for multi-page host queues
    // (only when CQR=0 allows non-contiguous)
    if (!cqr && sq_multi_page) {
      ret = buildQueuePrpList(&sq_setup, sq_size_bytes, sq_is_device,
                              "submission queue");
      if (ret < 0) {
        freeQueueSetup(&sq_setup, sq_is_device, "submission queue",
                       sq_size_bytes);
        freeQueueSetup(&cq_setup, cq_is_device, "completion queue",
                       cq_size_bytes);
        goto cleanup;
      }
    }
    if (!cqr && cq_multi_page) {
      ret = buildQueuePrpList(&cq_setup, cq_size_bytes, cq_is_device,
                              "completion queue");
      if (ret < 0) {
        freeQueueSetup(&sq_setup, sq_is_device, "submission queue",
                       sq_size_bytes);
        freeQueueSetup(&cq_setup, cq_is_device, "completion queue",
                       cq_size_bytes);
        goto cleanup;
      }
    }

    ret = kmodRegQueue(kmod_fd, sq_setup.virt, sq_setup.phys, sq_size_bytes, 0,
                       nvme_bdf, sq_setup.prp2, "submission queue");
    if (ret < 0) {
      freeQueueSetup(&sq_setup, sq_is_device, "submission queue",
                     sq_size_bytes);
      freeQueueSetup(&cq_setup, cq_is_device, "completion queue",
                     cq_size_bytes);
      goto cleanup;
    }

    ret = kmodRegQueue(kmod_fd, cq_setup.virt, cq_setup.phys, cq_size_bytes, 1,
                       nvme_bdf, cq_setup.prp2, "completion queue");
    if (ret < 0) {
      freeQueueSetup(&sq_setup, sq_is_device, "submission queue",
                     sq_size_bytes);
      freeQueueSetup(&cq_setup, cq_is_device, "completion queue",
                     cq_size_bytes);
      goto cleanup;
    }

    ROCXIO_LOG_INFO("Deleting existing queues (queue_id=%u) "
                    "if they exist...\n",
                    queue_id);
    deleteQueue(nvme_fd, queue_id);
    ROCXIO_LOG_INFO("Queue deletion completed.\n");

    ROCXIO_LOG_INFO("Waiting 500ms before creating "
                    "queues...\n");
    usleep(500000);

    ROCXIO_LOG_INFO("Creating NVMe queues (queue_id=%u, "
                    "queue_size=%u)...\n",
                    queue_id, queue_size);
    ret = createQueueCommands(nvme_fd, queue_id, queue_size, sq_setup.virt,
                              cq_setup.virt, sq_pc, cq_pc);
    if (ret < 0) {
      freeQueueSetup(&sq_setup, sq_is_device, "submission queue",
                     sq_size_bytes);
      freeQueueSetup(&cq_setup, cq_is_device, "completion queue",
                     cq_size_bytes);
      goto cleanup;
    }
  }

  info->doorbell = 0;
  info->sq_virt = sq_setup.virt;
  info->cq_virt = cq_setup.virt;
  info->sq_gpu = sq_setup.gpu;
  info->cq_gpu = cq_setup.gpu;
  info->sq_phys = sq_setup.phys;
  info->cq_phys = cq_setup.phys;
  info->sq_dmabuf_fd = -1;
  info->cq_dmabuf_fd = -1;
  info->sq_prp_list = sq_setup.prp_list;
  info->cq_prp_list = cq_setup.prp_list;
  info->sq_contig_id = sq_setup.contig_id;
  info->cq_contig_id = cq_setup.contig_id;

  close(nvme_fd);
  close(kmod_fd);
  return 0;

cleanup:
  if (sq_setup.virt)
    freeQueueSetup(&sq_setup, sq_is_device, "submission queue", sq_size_bytes);
  if (cq_setup.virt)
    freeQueueSetup(&cq_setup, cq_is_device, "completion queue", cq_size_bytes);
  if (nvme_fd >= 0)
    close(nvme_fd);
  if (kmod_fd >= 0)
    close(kmod_fd);
  return ret;
}

// C-compatible cleanup function for signal handlers.
// Iterates over all queues that were created by run().
extern "C" __host__ int nvme_ep_cleanup_queues(void* endpointConfig) {
  if (!endpointConfig) {
    return -EINVAL;
  }

  nvme_ep::nvmeEpConfig* nvmeConfig = static_cast<nvme_ep::nvmeEpConfig*>(
    endpointConfig);

  if (!nvmeConfig->queuesCreated) {
    return 0;
  }
  if (nvmeConfig->controller.empty()) {
    return -EINVAL;
  }

  int nvme_fd = openDeviceWithRetry(nvmeConfig->controller.c_str(), O_RDWR,
                                    "NVMe device", 3, 50);
  if (nvme_fd < 0) {
    ROCXIO_LOG_WARN("Failed to reopen NVMe "
                    "device for queue cleanup: %s\n",
                    strerror(errno));
    return -errno;
  }

  int ret = 0;
  if (!nvmeConfig->queueIds.empty()) {
    ROCXIO_LOG_INFO("\nSIGINT received: Deleting %zu "
                    "NVMe queue%s...\n",
                    nvmeConfig->queueIds.size(),
                    nvmeConfig->queueIds.size() > 1 ? "s" : "");
    for (size_t q = 0; q < nvmeConfig->queueIds.size(); q++) {
      int r = deleteQueue(nvme_fd, nvmeConfig->queueIds[q]);
      if (r != 0)
        ret = r;
    }
  } else {
    ROCXIO_LOG_INFO("\nSIGINT received: Deleting NVMe "
                    "queue %u...\n",
                    nvmeConfig->queueId);
    ret = deleteQueue(nvme_fd, nvmeConfig->queueId);
  }
  close(nvme_fd);

  if (ret == 0) {
    ROCXIO_LOG_INFO("NVMe queues deleted successfully.\n");
    nvmeConfig->queuesCreated = false;
  } else {
    ROCXIO_LOG_WARN("Failed to delete NVMe "
                    "queues: %s\n",
                    strerror(-ret));
  }

#ifndef __HIP_DEVICE_COMPILE__
  {
    long page_sz = sysconf(_SC_PAGESIZE);
    auto cleanupQinfo = [&](nvme_queue_info* qi) {
      if (qi->sq_prp_list) {
        if (page_sz > 0)
          munlock(qi->sq_prp_list, static_cast<size_t>(page_sz));
        free(qi->sq_prp_list);
        qi->sq_prp_list = nullptr;
      }
      if (qi->cq_prp_list) {
        if (page_sz > 0)
          munlock(qi->cq_prp_list, static_cast<size_t>(page_sz));
        free(qi->cq_prp_list);
        qi->cq_prp_list = nullptr;
      }
      if (qi->sq_virt && qi->sq_contig_id) {
        struct xioQueueSetup sq_s = {};
        sq_s.virt = qi->sq_virt;
        sq_s.gpu = qi->sq_gpu;
        sq_s.phys = qi->sq_phys;
        sq_s.uses_contig = true;
        sq_s.contig_id = qi->sq_contig_id;
        freeContigQueue(&sq_s, qi->sq_size, "submission queue");
        qi->sq_virt = nullptr;
        qi->sq_gpu = nullptr;
        qi->sq_contig_id = 0;
      }
      if (qi->cq_virt && qi->cq_contig_id) {
        struct xioQueueSetup cq_s = {};
        cq_s.virt = qi->cq_virt;
        cq_s.gpu = qi->cq_gpu;
        cq_s.phys = qi->cq_phys;
        cq_s.uses_contig = true;
        cq_s.contig_id = qi->cq_contig_id;
        freeContigQueue(&cq_s, qi->cq_size, "completion queue");
        qi->cq_virt = nullptr;
        qi->cq_gpu = nullptr;
        qi->cq_contig_id = 0;
      }
      if (qi->sq_dmabuf_fd >= 0) {
        close(qi->sq_dmabuf_fd);
        qi->sq_dmabuf_fd = -1;
      }
      if (qi->cq_dmabuf_fd >= 0) {
        close(qi->cq_dmabuf_fd);
        qi->cq_dmabuf_fd = -1;
      }
    };

    if (!nvmeConfig->queueInfos.empty()) {
      for (auto& qi : nvmeConfig->queueInfos) {
        cleanupQinfo(&qi);
      }
    } else {
      cleanupQinfo(&nvmeConfig->queueInfo);
    }
  }
#endif // __HIP_DEVICE_COMPILE__

  return ret;
}

} // namespace xio::nvme_ep

#endif // __HIP_DEVICE_COMPILE__
