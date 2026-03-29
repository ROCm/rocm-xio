/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "nvme-ep.h"
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

__host__ __device__ sqeType sqeRead(volatile sqeType* sqeAddress) {
  sqeType result;
  // Copy the entire structure byte-by-byte to handle volatile correctly
  const volatile uint8_t* src = reinterpret_cast<const volatile uint8_t*>(
    sqeAddress);
  uint8_t* dst = reinterpret_cast<uint8_t*>(&result);
  for (size_t i = 0; i < sizeof(sqeType); i++) {
    dst[i] = src[i];
  }
  return result;
}

__host__ __device__ cqeType cqeRead(volatile cqeType* cqeAddress) {
  cqeType result;
  // Copy the entire structure byte-by-byte to handle volatile correctly
  const volatile uint8_t* src = reinterpret_cast<const volatile uint8_t*>(
    cqeAddress);
  uint8_t* dst = reinterpret_cast<uint8_t*>(&result);
  for (size_t i = 0; i < sizeof(cqeType); i++) {
    dst[i] = src[i];
  }
  return result;
}

__host__ __device__ void sqeWrite(sqeType sqeData,
                                  volatile sqeType* sqeAddress) {
  //*sqeAddress = sqeData;

  // Write byte-by-byte to volatile pointer to ensure all writes are visible
  // This matches sqeRead's approach and ensures proper volatile semantics
  const uint8_t* src = reinterpret_cast<const uint8_t*>(&sqeData);
  volatile uint8_t* dst = reinterpret_cast<volatile uint8_t*>(sqeAddress);
  for (size_t i = 0; i < sizeof(sqeType); i++) {
    dst[i] = src[i];
  }

#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif // __HIP_DEVICE_COMPILE__
}

__host__ __device__ void cqeWrite(cqeType cqeData,
                                  volatile cqeType* cqeAddress) {
  const uint8_t* src = reinterpret_cast<const uint8_t*>(&cqeData);
  volatile uint8_t* dst = reinterpret_cast<volatile uint8_t*>(cqeAddress);
  for (size_t i = 0; i < sizeof(cqeType); i++) {
    dst[i] = src[i];
  }
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
  const XioEndpointConfig& config,
  const nvmeIoParams& ioParams,
  const nvmeDoorbellParams& doorbellParams,
  const nvmeBufferParams& bufferParams) {

  sqeType* sqeAddr =
    static_cast<sqeType*>(config.submissionQueue);
  cqeType* cqeAddr =
    static_cast<cqeType*>(config.completionQueue);

  const unsigned num_read_ops = (unsigned)ioParams.readIo;
  const unsigned num_write_ops =
    (unsigned)ioParams.writeIo;
  const unsigned total_ops = num_read_ops + num_write_ops;
  const bool infinite_is_read = (num_read_ops > 0);

  uint32_t batch_size = ioParams.batchSize;
  if (batch_size == 0) {
    batch_size = ioParams.infiniteMode
                   ? (uint32_t)(ioParams.queueSize - 1)
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
  const size_t transfer_size =
    (size_t)blocks * ioParams.lbaSize;

  const bool has_write_buffer =
    (bufferParams.writeBuffer != nullptr &&
     bufferParams.bufferSize > 0);
  const bool has_read_buffer =
    (bufferParams.readBuffer != nullptr &&
     bufferParams.bufferSize > 0);

  if (has_write_buffer) {
    dataPatternParams patternParams;
    patternParams.buffer = bufferParams.writeBuffer;
    patternParams.size = bufferParams.bufferSize;
    patternParams.offset = 0;
    patternParams.lbaSize = ioParams.lbaSize;
    patternParams.lfsrSeed = ioParams.lfsrSeed;
    patternParams.errorOffset = nullptr;
    dataPattern(false, patternParams);
  }

  uint16_t cq_head = 0;
  uint8_t expected_phase = 1;
  uint16_t sq_tail = 0;

  constexpr unsigned kMaxTimedBatch = 256;
  unsigned long long int batchStartTimes[kMaxTimedBatch];
  const bool useBatchTiming =
    (config.timingStats != nullptr);
  if (useBatchTiming && batch_size > kMaxTimedBatch) {
    batch_size = kMaxTimedBatch;
  }

  unsigned ops_done = 0;
  while ((ioParams.infiniteMode || ops_done < total_ops) &&
         (config.stopRequested == nullptr ||
          !*config.stopRequested)) {
    unsigned batch_count = batch_size;
    if (!ioParams.infiniteMode &&
        ops_done + batch_count > total_ops) {
      batch_count = total_ops - ops_done;
    }

    for (unsigned b = 0; b < batch_count; b++) {
      unsigned op_idx = ops_done + b;
      uint16_t cmd_id =
        (uint16_t)((op_idx % 65535) + 1);

      bool is_read_op;
      if (ioParams.infiniteMode) {
        is_read_op = infinite_is_read;
      } else if (num_write_ops > 0 &&
                 num_read_ops > 0) {
        is_read_op = (op_idx >= num_write_ops);
      } else {
        is_read_op = (num_read_ops > 0);
      }

      uint64_t lba =
        getRandomLba(op_idx, cmd_id, blocks, ioParams);

      sqeType sqeLocal = {};
      sqeType* sqe = &sqeLocal;
      sqe->opcode = is_read_op ? nvme_cmd_read
                                : nvme_cmd_write;
      sqe->command_id = cmd_id;
      sqe->nsid = nsid;

      uint64_t buf_off = (uint64_t)b * transfer_size;
      bool prp_valid = false;

      if (is_read_op && has_read_buffer) {
        if (buf_off + transfer_size <=
            bufferParams.bufferSize) {
          uint64_t addr =
            bufferParams.readBufferDma
              ? (bufferParams.readBufferDma + buf_off)
              : (uint64_t)(bufferParams.readBuffer +
                           buf_off);
          calculatePrps(addr, transfer_size, sqe);
          prp_valid = true;
        }
      } else if (!is_read_op && has_write_buffer) {
        if (buf_off + transfer_size <=
            bufferParams.bufferSize) {
          uint64_t addr =
            bufferParams.writeBufferDma
              ? (bufferParams.writeBufferDma + buf_off)
              : (uint64_t)(bufferParams.writeBuffer +
                           buf_off);
          calculatePrps(addr, transfer_size, sqe);
          prp_valid = true;
        }
      }

      if (!prp_valid) {
        __builtin_trap();
      }
      sqeSetup(sqe, lba, blocks);

      if (!ioParams.infiniteMode &&
          config.startTimes != nullptr) {
        config.startTimes[op_idx] = wall_clock64();
      } else if (useBatchTiming &&
                 b < kMaxTimedBatch) {
        batchStartTimes[b] = wall_clock64();
      }

      nvme_ep::sqeWrite(
        sqeLocal, &sqeAddr[sq_tail]);
      sq_tail =
        (sq_tail + 1) % ioParams.queueSize;
    }

    __threadfence_system();
    nvme_ep::ringDoorbell(sq_tail, doorbellParams);

    for (unsigned b = 0; b < batch_count; b++) {
      unsigned op_idx = ops_done + b;

      volatile cqeType* cqe_entry =
        &cqeAddr[cq_head];

      nvme_ep::cqeType cqe_new;
      unsigned poll_count = 0;
      while (true) {
        if (config.stopRequested != nullptr &&
            poll_count % 100 == 0 &&
            *config.stopRequested) {
          return;
        }
        cqe_new = nvme_ep::cqeRead(cqe_entry);
        uint8_t phase =
          NVME_CQE_STATUS_PHASE(cqe_new.status);
        if (phase == expected_phase) {
          break;
        }
        poll_count++;
        if (poll_count >= NVME_EP_MAX_POLLS) {
          printf("NVMe CQ poll timeout after %u "
                 "polls (cq_head=%u "
                 "expected_phase=%u)\n",
                 poll_count, (unsigned)cq_head,
                 (unsigned)expected_phase);
          __builtin_trap();
        }
      }

      if (!nvme_ep::cqeOk(&cqe_new)) {
        printf("NVMe CQE error: status=0x%04x "
               "sc=0x%02x sct=0x%02x "
               "cmd_id=%u sq_head=%u\n",
               (unsigned)cqe_new.status,
               (unsigned)nvme_ep::cqeStatusCode(
                 &cqe_new),
               (unsigned)nvme_ep::cqeStatusType(
                 &cqe_new),
               (unsigned)cqe_new.command_id,
               (unsigned)cqe_new.sq_head);
        __builtin_trap();
      }

      if (!ioParams.infiniteMode &&
          config.endTimes != nullptr) {
        config.endTimes[op_idx] = wall_clock64();
      } else if (useBatchTiming &&
                 b < kMaxTimedBatch) {
        unsigned long long int endTime =
          wall_clock64();
        if (endTime > batchStartTimes[b]) {
          updateTimingStats(
            config.timingStats,
            endTime - batchStartTimes[b]);
        }
      }

      cq_head =
        (cq_head + 1) % ioParams.queueSize;
      if (cq_head == 0) {
        expected_phase ^= 1;
      }
      nvme_ep::ringDoorbell(
        cq_head, doorbellParams,
        doorbellParams.doorbellOffset +
          nvme_ep::doorBellStride);
    }

    ops_done += batch_count;
  }
}

/**
 * Wavefront-cooperative batch path (batch_size > 1).
 *
 * Threads 1..batch_size each prepare one SQE per batch
 * iteration.  Thread 0 is the coordinator: it rings the
 * SQ doorbell, polls CQEs, and rings the CQ doorbell.
 * All threads reside in a single wavefront and
 * synchronize via __syncthreads().
 */
__device__ static void driveEndpointWavefront(
  const XioEndpointConfig& config,
  const nvmeIoParams& ioParams,
  const nvmeDoorbellParams& doorbellParams,
  const nvmeBufferParams& bufferParams) {

  const unsigned tid = threadIdx.x;

  sqeType* sqeAddr =
    static_cast<sqeType*>(config.submissionQueue);
  cqeType* cqeAddr =
    static_cast<cqeType*>(config.completionQueue);

  const unsigned num_read_ops = (unsigned)ioParams.readIo;
  const unsigned num_write_ops =
    (unsigned)ioParams.writeIo;
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
  const size_t transfer_size =
    (size_t)blocks * ioParams.lbaSize;

  const bool has_write_buffer =
    (bufferParams.writeBuffer != nullptr &&
     bufferParams.bufferSize > 0);
  const bool has_read_buffer =
    (bufferParams.readBuffer != nullptr &&
     bufferParams.bufferSize > 0);

  const bool useBatchTiming =
    (config.timingStats != nullptr);

  // Shared state managed by thread 0, read by all
  __shared__ uint16_t sh_sq_tail;
  __shared__ uint16_t sh_cq_head;
  __shared__ uint8_t sh_expected_phase;
  __shared__ unsigned sh_ops_done;
  __shared__ unsigned sh_batch_count;
  __shared__ bool sh_stop;
  __shared__ unsigned long long int sh_startTimes[64];

  if (tid == 0) {
    sh_sq_tail = 0;
    sh_cq_head = 0;
    sh_expected_phase = 1;
    sh_ops_done = 0;
    sh_stop = false;

    if (has_write_buffer) {
      dataPatternParams patternParams;
      patternParams.buffer = bufferParams.writeBuffer;
      patternParams.size = bufferParams.bufferSize;
      patternParams.offset = 0;
      patternParams.lbaSize = ioParams.lbaSize;
      patternParams.lfsrSeed = ioParams.lfsrSeed;
      patternParams.errorOffset = nullptr;
      dataPattern(false, patternParams);
    }
  }
  __syncthreads();

  while (!sh_stop) {
    // --- Phase 1: thread 0 computes batch parameters ---
    if (tid == 0) {
      unsigned bc = batch_size;
      if (!ioParams.infiniteMode &&
          sh_ops_done + bc > total_ops) {
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
        uint16_t cmd_id =
          (uint16_t)((op_idx % 65535) + 1);

        bool is_read_op;
        if (ioParams.infiniteMode) {
          is_read_op = infinite_is_read;
        } else if (num_write_ops > 0 &&
                   num_read_ops > 0) {
          is_read_op = (op_idx >= num_write_ops);
        } else {
          is_read_op = (num_read_ops > 0);
        }

        uint64_t lba = getRandomLba(
          op_idx, cmd_id, blocks, ioParams);

        sqeType sqeLocal = {};
        sqeType* sqe = &sqeLocal;
        sqe->opcode = is_read_op ? nvme_cmd_read
                                  : nvme_cmd_write;
        sqe->command_id = cmd_id;
        sqe->nsid = nsid;

        uint64_t buf_off =
          (uint64_t)b * transfer_size;
        bool prp_valid = false;

        if (is_read_op && has_read_buffer) {
          if (buf_off + transfer_size <=
              bufferParams.bufferSize) {
            uint64_t addr =
              bufferParams.readBufferDma
                ? (bufferParams.readBufferDma +
                   buf_off)
                : (uint64_t)(
                    bufferParams.readBuffer +
                    buf_off);
            calculatePrps(
              addr, transfer_size, sqe);
            prp_valid = true;
          }
        } else if (!is_read_op &&
                   has_write_buffer) {
          if (buf_off + transfer_size <=
              bufferParams.bufferSize) {
            uint64_t addr =
              bufferParams.writeBufferDma
                ? (bufferParams.writeBufferDma +
                   buf_off)
                : (uint64_t)(
                    bufferParams.writeBuffer +
                    buf_off);
            calculatePrps(
              addr, transfer_size, sqe);
            prp_valid = true;
          }
        }

        if (!prp_valid) {
          __builtin_trap();
        }
        sqeSetup(sqe, lba, blocks);

        if (!ioParams.infiniteMode &&
            config.startTimes != nullptr) {
          config.startTimes[op_idx] =
            wall_clock64();
        } else if (useBatchTiming && b < 64) {
          sh_startTimes[b] = wall_clock64();
        }

        uint16_t my_slot =
          (sq_tail_base + b) % ioParams.queueSize;
        nvme_ep::sqeWrite(
          sqeLocal, &sqeAddr[my_slot]);
      }
    }
    __syncthreads();

    // --- Phase 3: thread 0 rings doorbell, polls CQEs ---
    if (tid == 0) {
      uint16_t new_tail =
        (sq_tail_base + batch_count) %
        ioParams.queueSize;
      sh_sq_tail = new_tail;

      __threadfence_system();
      nvme_ep::ringDoorbell(
        new_tail, doorbellParams);

      uint16_t cq_head = sh_cq_head;
      uint8_t expected_phase = sh_expected_phase;

      for (unsigned b = 0; b < batch_count; b++) {
        unsigned op_idx = ops_done + b;

        volatile cqeType* cqe_entry =
          &cqeAddr[cq_head];

        nvme_ep::cqeType cqe_new;
        unsigned poll_count = 0;
        while (true) {
          if (config.stopRequested != nullptr &&
              poll_count % 100 == 0 &&
              *config.stopRequested) {
            sh_stop = true;
            break;
          }
          cqe_new =
            nvme_ep::cqeRead(cqe_entry);
          uint8_t phase =
            NVME_CQE_STATUS_PHASE(
              cqe_new.status);
          if (phase == expected_phase) {
            break;
          }
          poll_count++;
          if (poll_count >= NVME_EP_MAX_POLLS) {
            printf(
              "NVMe CQ poll timeout after "
              "%u polls (cq_head=%u "
              "expected_phase=%u)\n",
              poll_count, (unsigned)cq_head,
              (unsigned)expected_phase);
            __builtin_trap();
          }
        }

        if (sh_stop) {
          break;
        }

        if (!nvme_ep::cqeOk(&cqe_new)) {
          printf(
            "NVMe CQE error: status=0x%04x "
            "sc=0x%02x sct=0x%02x "
            "cmd_id=%u sq_head=%u\n",
            (unsigned)cqe_new.status,
            (unsigned)nvme_ep::cqeStatusCode(
              &cqe_new),
            (unsigned)nvme_ep::cqeStatusType(
              &cqe_new),
            (unsigned)cqe_new.command_id,
            (unsigned)cqe_new.sq_head);
          __builtin_trap();
        }

        if (!ioParams.infiniteMode &&
            config.endTimes != nullptr) {
          config.endTimes[op_idx] =
            wall_clock64();
        } else if (useBatchTiming && b < 64) {
          unsigned long long int endTime =
            wall_clock64();
          if (endTime > sh_startTimes[b]) {
            updateTimingStats(
              config.timingStats,
              endTime - sh_startTimes[b]);
          }
        }

        cq_head =
          (cq_head + 1) % ioParams.queueSize;
        if (cq_head == 0) {
          expected_phase ^= 1;
        }
        nvme_ep::ringDoorbell(
          cq_head, doorbellParams,
          doorbellParams.doorbellOffset +
            nvme_ep::doorBellStride);
      }

      sh_cq_head = cq_head;
      sh_expected_phase = expected_phase;
      sh_ops_done = ops_done + batch_count;

      if (!ioParams.infiniteMode &&
          sh_ops_done >= total_ops) {
        sh_stop = true;
      }
      if (config.stopRequested != nullptr &&
          *config.stopRequested) {
        sh_stop = true;
      }
    }
    __syncthreads();
  }
}

__device__ void driveEndpoint(
  const XioEndpointConfig& config,
  const nvmeIoParams& ioParams,
  const nvmeDoorbellParams& doorbellParams,
  const nvmeBufferParams& bufferParams) {

  if (ioParams.batchSize > 1) {
    driveEndpointWavefront(
      config, ioParams, doorbellParams, bufferParams);
  } else {
    driveEndpointSingle(
      config, ioParams, doorbellParams, bufferParams);
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
 * Register NVMe endpoint-specific CLI options
 *
 * This function registers all NVMe-specific command-line options with
 * the CLI11 parser. Options are registered with shorter names (without
 * --nvme- prefix) for cleaner CLI, but backward-compatible aliases
 * are also provided.
 *
 * @param app CLI11 App object to add options to
 * @param config Pointer to nvmeEpConfig structure to populate
 */
__host__ void registerCliOptions(CLI::App& app, nvme_ep::nvmeEpConfig* config) {
  const std::string nvme_group = "NVMe Endpoint Options";

  app
    .add_option("--access-pattern", config->ioParams.accessPattern,
                "IO access pattern: 'sequential' or 'random'.")
    ->default_val("random")
    ->check(CLI::IsMember({"sequential", "random"}))
    ->group(nvme_group);
  app
    .add_option("--data-buffer-size", config->bufferParams.bufferSize,
                "Size of data buffers for NVMe IO (bytes).")
    ->default_val(1024 * 1024)
    ->check(CLI::PositiveNumber)
    ->group(nvme_group);
  app
    .add_option("--controller", config->controller,
                "NVMe controller device path (required).")
    ->required()
    ->group(nvme_group);
  app
    .add_option("--base-lba", config->ioParams.baseLba,
                "Starting LBA for I/O operations (default: 0)")
    ->default_val(0)
    ->group(nvme_group);
  app
    .add_option("--lfsr-seed", config->ioParams.lfsrSeed,
                "Seed for LFSR pattern generation (0 = derive from LBA).")
    ->default_val(0)
    ->group(nvme_group);
  app
    .add_option("--read-io", config->ioParams.readIo,
                "Number of read I/O to perform. Negative values "
                "accepted for backward compatibility (converted "
                "to positive).")
    ->default_val(0)
    ->group(nvme_group);
  app
    .add_option("--queue-id", config->queueId,
                "NVMe queue ID to use (0=admin queue, 1+=IO queues). "
                "If not specified, auto-detects and uses the last available "
                "I/O queue.")
    ->default_val(0) // 0 means "auto-detect" - will be set in validateConfig
    ->check(CLI::Range(0, 65535))
    ->group(nvme_group);
  app
    .add_option("--queue-length", config->queueLength,
                "NVMe queue length in entries (must be power of 2, max 65536).")
    ->default_val(1024)
    ->check([](const std::string& str) {
      uint16_t val;
      try {
        val = static_cast<uint16_t>(std::stoul(str));
      } catch (...) {
        return std::string("Invalid number");
      }
      if (val == 0 || val > 65535) {
        return std::string("Queue length must be between 1 and 65535");
      }
      if ((val & (val - 1)) != 0) {
        return std::string("Queue length must be a power of 2");
      }
      return std::string();
    })
    ->group(nvme_group);
  app
    .add_option("--namespace", config->ioParams.nsid,
                "NVMe namespace ID (must be > 0, default: 1).")
    ->default_val(1)
    ->check(CLI::PositiveNumber)
    ->group(nvme_group);

  app
    .add_option("--lbas-per-io", config->ioParams.lbasPerIo,
                "Number of LBAs per I/O operation (default: 1).")
    ->default_val(1)
    ->check(CLI::PositiveNumber)
    ->group(nvme_group);
  app
    .add_option("--write-io", config->ioParams.writeIo,
                "Number of write I/O to perform. Negative values "
                "accepted for backward compatibility (converted "
                "to positive).")
    ->default_val(0)
    ->group(nvme_group);
  app
    .add_flag("--infinite", config->ioParams.infiniteMode,
              "Infinite mode: run forever. Requires exactly one "
              "of --read-io or --write-io to be non-zero.")
    ->group(nvme_group);
  app
    .add_option("--batch-size", config->ioParams.batchSize,
                "Number of SQEs to submit per doorbell ring. "
                "1 = sequential (one I/O at a time), "
                "0 = all at once, N = N SQEs per doorbell. "
                "When N > 1, each SQE is prepared by a "
                "separate GPU thread within one wavefront. "
                "Max value is wavefront_size - 1 "
                "(63 on CDNA, 31 on RDNA).")
    ->default_val(1)
    ->check(CLI::NonNegativeNumber)
    ->group(nvme_group);
}

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
  // Auto-detect maximum queue ID if queueId is 0 (default/unset)
  if (config->queueId == 0) {
    if (config->controller.empty()) {
      return "Cannot auto-detect queue ID: --controller not specified";
    }
    uint16_t max_queue_id = 0;
    int ret = queryMaxQueueId(config->controller.c_str(), &max_queue_id);
    if (ret != 0) {
      return "Failed to detect maximum queue ID. Please specify --queue-id "
             "manually.";
    }
    config->queueId = max_queue_id;
    fprintf(stdout, "Auto-detected and using last available queue ID: %u\n",
            config->queueId);
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
  // doorbell and polls CQEs). All threads must fit in a
  // single wavefront.
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
    if (config->ioParams.batchSize > waveSize - 1) {
      char buf[256];
      snprintf(buf, sizeof(buf),
               "--batch-size %u exceeds wavefront limit "
               "%u (wavefront_size %u - 1 for "
               "coordinator thread)",
               config->ioParams.batchSize,
               waveSize - 1, waveSize);
      return std::string(buf);
    }
    config->wavefrontSize = waveSize;
    fprintf(stdout,
            "Wavefront batch mode: batch_size=%u, "
            "wavefront_size=%u, kernel_threads=%u\n",
            config->ioParams.batchSize, waveSize,
            config->ioParams.batchSize + 1);
  }

  return std::string();
}

/**
 * Run NVMe endpoint operations
 *
 * This function sets up queues, allocates buffers, and launches the GPU
 * kernel to execute NVMe I/O operations.
 *
 * @param config Pointer to XioEndpointConfig structure containing queue
 *               pointers and common configuration
 * @return hipSuccess on success, error code on failure
 */
__host__ hipError_t run(XioEndpointConfig* config) {
  if (!config || !config->endpointConfig) {
    fprintf(stderr, "Error: nvme-ep requires endpoint configuration\n");
    return hipErrorInvalidValue;
  }

  nvme_ep::nvmeEpConfig* nvmeConfig = static_cast<nvme_ep::nvmeEpConfig*>(
    config->endpointConfig);

  // Queue creation is MANDATORY for nvme-ep - device must be specified
  if (nvmeConfig->controller.empty()) {
    fprintf(stderr,
            "Error: NVMe device not specified. --controller is required.\n");
    return hipErrorInvalidValue;
  }

  if (config->numThreads > 1) {
    fprintf(stderr, "Error: nvme-ep does not support "
                    "--threads > 1. Use --batch-size "
                    "> 1 for wavefront-cooperative "
                    "batching.\n");
    return hipErrorNotSupported;
  }

  // Compute the kernel thread count locally.  Do NOT
  // mutate config->numThreads -- the caller sized
  // timing arrays based on numThreads=1.
  unsigned kernelThreads = 1;
  if (nvmeConfig->ioParams.batchSize > 1) {
    kernelThreads =
      nvmeConfig->ioParams.batchSize + 1;
    fprintf(stdout,
            "Wavefront batch mode: launching %u "
            "threads (1 coordinator + %u SQE "
            "writers)\n",
            kernelThreads,
            nvmeConfig->ioParams.batchSize);
  }

  // Create NVMe queues - MUST succeed before proceeding
  // Use queue length from CLI configuration (default: 64)
  // NVMe queues are circular buffers - commands wrap around, so the queue
  // length must be large enough to handle outstanding commands without
  // overwriting unprocessed ones.
  uint16_t queue_size = nvmeConfig->queueLength;

  fprintf(stdout, "Using queue length: %u entries\n", queue_size);

  struct nvme_queue_info queue_info;
  int ret = createQueue(nvmeConfig->controller.c_str(), ROCM_XIO_DEVICE_PATH,
                        nvmeConfig->queueId, queue_size,
                        nvmeConfig->doorbellParams.nvmeTargetBdf,
                        config->memoryMode, // Respect memory mode like
                                            // test-ep
                        &queue_info);

  if (ret < 0) {
    fprintf(stderr, "Error: Failed to create NVMe queues: %s\n",
            strerror(-ret));
    fprintf(stderr,
            "Queue creation failed - cannot proceed with kernel launch.\n");
    return hipErrorInvalidValue;
  }

  // Mark queues as created for cleanup on SIGINT
  nvmeConfig->queuesCreated = true;
  nvmeConfig->queueInfo = queue_info;

  // Update config with created queue addresses
  // Use GPU pointers for kernel launch (obtained via hipHostGetDevicePointer)
  config->submissionQueue = queue_info.sq_gpu ? queue_info.sq_gpu
                                              : queue_info.sq_virt;
  config->completionQueue = queue_info.cq_gpu ? queue_info.cq_gpu
                                              : queue_info.cq_virt;
  nvmeConfig->sqBaseAddr = queue_info.sq_phys;
  nvmeConfig->cqBaseAddr = queue_info.cq_phys;
  nvmeConfig->sqSize = queue_info.sq_size;
  nvmeConfig->cqSize = queue_info.cq_size;

  fprintf(stdout, "NVMe queues created: SQ=0x%llx, CQ=0x%llx, queue_id=%u\n",
          (unsigned long long)queue_info.sq_phys,
          (unsigned long long)queue_info.cq_phys, nvmeConfig->queueId);
  fprintf(stdout, "Queue GPU pointers: SQ=%p (host=%p), CQ=%p (host=%p)\n",
          queue_info.sq_gpu, queue_info.sq_virt, queue_info.cq_gpu,
          queue_info.cq_virt);

  // Verify queues were created successfully
  if (!config->submissionQueue || !config->completionQueue) {
    fprintf(stdout,
            "Error: Queue creation succeeded but queue pointers are null\n");
    return hipErrorInvalidValue;
  }

  // Set up PCI MMIO bridge shadow buffer if enabled
  if (nvmeConfig->doorbellParams.usePciMmioBridge) {
    void* shadow_virt = nullptr;
    int ret_shadow = mapMmioBridgeShadowBuffer(
      nvmeConfig->doorbellParams.mmioBridgeBdf, &shadow_virt);
    if (ret_shadow < 0) {
      fprintf(stderr, "Failed to map PCI MMIO bridge shadow buffer.\n");
      return hipErrorInvalidValue;
    }
    fprintf(stdout, "PCI MMIO bridge shadow buffer mapped at %p.\n",
            shadow_virt);

    // Register shadow buffer for GPU access
    const size_t shadow_size = 8192;
    void* shadow_gpu_ptr = nullptr;
    int ret_register = registerMmioBridgeShadowBufferForGpu(shadow_virt,
                                                            shadow_size,
                                                            &shadow_gpu_ptr);
    if (ret_register < 0) {
      fprintf(stderr, "Failed to register PCI MMIO bridge shadow buffer.\n");
      return hipErrorInvalidValue;
    } else {
      nvmeConfig->doorbellParams.shadowBufferVirt = shadow_gpu_ptr;
    }
  } else {
    // PCI MMIO bridge is disabled - set up direct doorbell via BAR0
    void* bar0_cpu = nullptr;
    void* bar0_gpu = nullptr;
    int ret_bar0 = mapPciBar(nvmeConfig->doorbellParams.nvmeTargetBdf, 0,
                             &bar0_cpu, &bar0_gpu, 8192);
    if (ret_bar0 < 0) {
      fprintf(stderr,
              "Warning: Failed to map NVMe BAR0 for direct doorbell: %s\n",
              strerror(-ret_bar0));
      return hipErrorInvalidValue;
    }
    fprintf(stdout, "NVMe BAR0 mapped for direct doorbell access at %p.\n",
            bar0_gpu);
    nvmeConfig->doorbellParams.nvmeBar0Gpu = bar0_gpu;
  }

  bool usePciMmioBridge = nvmeConfig->doorbellParams.usePciMmioBridge;
  void* shadowBufferVirt = nvmeConfig->doorbellParams.shadowBufferVirt;
  void* nvmeBar0Gpu = nvmeConfig->doorbellParams.nvmeBar0Gpu;
  uint64_t lbaRangeLbas;

  // Query namespace capacity in LBAs
  uint64_t namespace_capacity = 0;
  int capacity_ret = queryNamespaceCapacity(nvmeConfig->controller.c_str(),
                                            nvmeConfig->ioParams.nsid,
                                            &namespace_capacity);
  if (capacity_ret == 0 && namespace_capacity > 0) {
    lbaRangeLbas = namespace_capacity;
    fprintf(stdout, "Using full namespace capacity: %llu LBAs\n",
            (unsigned long long)lbaRangeLbas);
  } else {
    fprintf(stderr, "Error: Failed to query namespace capacity\n");
    return hipErrorInvalidValue;
  }

  // Determine access pattern
  bool useRandomAccess = (nvmeConfig->ioParams.accessPattern == "random");

  // Calculate SQ doorbell offset
  const uint32_t doorbell_offset = nvme_ep::doorbellBase +
                                   (2 * nvmeConfig->queueId *
                                    nvme_ep::doorBellStride);

  // Allocate data buffers
  struct xioBufferInfo readBufferInfo = {};
  struct xioBufferInfo writeBufferInfo = {};

  // Allocate read buffer if read I/O is requested
  if (nvmeConfig->ioParams.readIo != 0) {
    hipError_t buf_err = allocateGpuAccessibleBuffer(
      nvmeConfig->bufferParams.bufferSize, config->memoryMode,
      nvmeConfig->doorbellParams.nvmeTargetBdf, nvmeConfig->controller.c_str(),
      &readBufferInfo);
    if (buf_err != hipSuccess) {
      fprintf(stderr, "Error: Failed to allocate read buffer: %s\n",
              hipGetErrorString(buf_err));
      return buf_err;
    }
  }

  // Allocate write buffer if write I/O is requested
  if (nvmeConfig->ioParams.writeIo != 0) {
    hipError_t buf_err = allocateGpuAccessibleBuffer(
      nvmeConfig->bufferParams.bufferSize, config->memoryMode,
      nvmeConfig->doorbellParams.nvmeTargetBdf, nvmeConfig->controller.c_str(),
      &writeBufferInfo);
    if (buf_err != hipSuccess) {
      fprintf(stderr, "Error: Failed to allocate write buffer: %s\n",
              hipGetErrorString(buf_err));
      return buf_err;
    }
  }

  // Validate queue pointers
  if (!config->submissionQueue || !config->completionQueue) {
    fprintf(stderr, "Error: Invalid queue pointers (sq=%p, cq=%p)\n",
            config->submissionQueue, config->completionQueue);
    return hipErrorInvalidValue;
  }

  // Verify queue pointers are GPU-accessible
  if (!validateGpuPointer(config->submissionQueue, "SQ", false)) {
    fprintf(stderr, "Error: Submission queue is not GPU-accessible.\n");
    return hipErrorInvalidValue;
  }
  if (!validateGpuPointer(config->completionQueue, "CQ", false)) {
    fprintf(stderr, "Error: Completion queue is not GPU-accessible.\n");
    return hipErrorInvalidValue;
  }

  // Verify shadowBufferVirt is GPU-accessible if it's non-null
  if (shadowBufferVirt != nullptr) {
    if (!validateGpuPointer(shadowBufferVirt, "Shadow buffer", false)) {
      fprintf(stderr, "Error: Shadow buffer is not GPU-accessible.\n");
      return hipErrorInvalidValue;
    }
  }

  // Verify nvmeBar0Gpu is GPU-accessible if it's non-null
  if (nvmeBar0Gpu != nullptr) {
    if (!validateGpuPointer(nvmeBar0Gpu, "BAR0", false)) {
      fprintf(stderr, "Error: NVMeBAR0 is not GPU-accessible.\n");
      return hipErrorInvalidValue;
    }
  }

  // Summarize the pointer state before launching kernel
  fprintf(stdout,
          "Launching kernel: sq=%p, cq=%p, startTimes=%p, endTimes=%p, "
          "shadowBuffer=%p, usePciMmioBridge=%d, nvmeBar0Gpu=%p\n",
          config->submissionQueue, config->completionQueue, config->startTimes,
          config->endTimes, shadowBufferVirt,
          nvmeConfig->doorbellParams.usePciMmioBridge, nvmeBar0Gpu);
  fprintf(stdout,
          "Data buffers: readBuffer=%p (dma=0x%llx), writeBuffer=%p "
          "(dma=0x%llx), size=%zu\n",
          readBufferInfo.gpuPtr ? readBufferInfo.gpuPtr
                                : readBufferInfo.hostPtr,
          (unsigned long long)readBufferInfo.dmaAddr,
          writeBufferInfo.gpuPtr ? writeBufferInfo.gpuPtr
                                 : writeBufferInfo.hostPtr,
          (unsigned long long)writeBufferInfo.dmaAddr,
          nvmeConfig->bufferParams.bufferSize);
  fprintf(stdout,
          "Kernel parameters: lbaSize=%u, blocks=%u, "
          "expected transfer_size=%u, "
          "writeBufferDma=0x%llx, batchSize=%u\n",
          nvmeConfig->ioParams.lbaSize, nvmeConfig->ioParams.lbasPerIo,
          nvmeConfig->ioParams.lbasPerIo * nvmeConfig->ioParams.lbaSize,
          (unsigned long long)writeBufferInfo.dmaAddr,
          nvmeConfig->ioParams.batchSize);

  // Build parameter structs for kernel launch
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

  // Validate that batch_size * transfer_size fits in the
  // data buffer. Each in-flight SQE in a batch uses its own
  // buffer region.
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
      fprintf(stderr,
              "Error: batch-size %u * transfer-size %llu "
              "= %llu exceeds data-buffer-size %zu. "
              "Increase --data-buffer-size or reduce "
              "--batch-size.\n",
              eff_batch, (unsigned long long)xfer, (unsigned long long)needed,
              nvmeConfig->bufferParams.bufferSize);
      return hipErrorInvalidValue;
    }
  }

  nvme_ep::nvmeDoorbellParams doorbellParams;
  doorbellParams.doorbellOffset = doorbell_offset;
  doorbellParams.nvmeTargetBdf = nvmeConfig->doorbellParams.nvmeTargetBdf;
  doorbellParams.shadowBufferVirt = shadowBufferVirt;
  doorbellParams.nvmeBar0Gpu = nvmeBar0Gpu;
  doorbellParams.usePciMmioBridge = usePciMmioBridge;

  nvme_ep::nvmeBufferParams bufferParams;
  bufferParams.readBuffer = readBufferInfo.gpuPtr
                              ? static_cast<uint8_t*>(readBufferInfo.gpuPtr)
                              : static_cast<uint8_t*>(readBufferInfo.hostPtr);
  bufferParams.writeBuffer = writeBufferInfo.gpuPtr
                               ? static_cast<uint8_t*>(writeBufferInfo.gpuPtr)
                               : static_cast<uint8_t*>(writeBufferInfo.hostPtr);
  bufferParams.bufferSize = nvmeConfig->bufferParams.bufferSize;
  bufferParams.readBufferDma = readBufferInfo.dmaAddr;
  bufferParams.writeBufferDma = writeBufferInfo.dmaAddr;

  // Prepare config struct for kernel launch
  XioEndpointConfig kernelConfig = *config;
  kernelConfig.endpointConfig = nullptr;

  hipLaunchKernelGGL(nvme_ep::gpuKernel, dim3(1),
                     dim3(kernelThreads), 0, 0,
                     kernelConfig, ioParams,
                     doorbellParams, bufferParams);

  fprintf(stdout, "Info: Kernel launched.\n");

  // Wait for GPU kernel to complete
  hipError_t err = hipDeviceSynchronize();

  // Detect if an error occurred
  if (err != hipSuccess) {
    fprintf(stdout,
            "Info: Device synchronization error: "
            "%s (code: %d).\n",
            hipGetErrorString(err), err);
  }

  // Delete NVMe queues before freeing buffers to ensure the
  // controller stops referencing queue/data memory regions
  fprintf(stdout, "\nCleaning up NVMe queues (queue_id=%u)...\n",
          nvmeConfig->queueId);
  int cleanup_fd = openDeviceWithRetry(nvmeConfig->controller.c_str(), O_RDWR,
                                       "NVMe device", 3, 50);
  if (cleanup_fd >= 0) {
    deleteQueue(cleanup_fd, nvmeConfig->queueId);
    close(cleanup_fd);
    nvmeConfig->queuesCreated = false;
  } else {
    fprintf(stderr,
            "Warning: Could not reopen NVMe device "
            "for queue cleanup: %s\n",
            strerror(errno));
  }

  // Free data buffers
  freeGpuAccessibleBuffer(&readBufferInfo);
  freeGpuAccessibleBuffer(&writeBufferInfo);

  return err;
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

  id_ns = static_cast<struct nvme_id_ns*>(malloc(nvme_ep::nvmeAdminRespSize));
  if (!id_ns) {
    return -ENOMEM;
  }
  memset(id_ns, 0, nvme_ep::nvmeAdminRespSize);

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
      fprintf(stdout, "Failed to identify namespace: %s\n", strerror(errno));
      ret = -errno;
      goto cleanup;
    }

    if (cmd.result & 0xFFFE) {
      uint16_t status = (cmd.result >> 1) & 0xFF;
      if (attempt < 4) {
        int delay_ms = 100 * (1 << attempt);
        fprintf(stdout,
                "Identify Namespace returned status "
                "0x%02x, retrying in %d ms "
                "(attempt %d/5)...\n",
                status, delay_ms, attempt + 1);
        usleep(delay_ms * 1000);
        memset(id_ns, 0, nvme_ep::nvmeAdminRespSize);
        continue;
      }
      fprintf(stdout,
              "Identify Namespace failed with status "
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
        fprintf(stdout,
                "Invalid LBA format index %u "
                "(max %u), retrying in %d ms "
                "(attempt %d/5)...\n",
                lba_format_idx, id_ns->nlbaf, delay_ms, attempt + 1);
        usleep(delay_ms * 1000);
        memset(id_ns, 0, nvme_ep::nvmeAdminRespSize);
        continue;
      }
      fprintf(stdout,
              "Invalid LBA format index %u "
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
        fprintf(stdout,
                "Identify Namespace returned "
                "lbads=%u (expected >= 9), "
                "retrying in %d ms "
                "(attempt %d/5)...\n",
                lbads, delay_ms, attempt + 1);
        usleep(delay_ms * 1000);
        memset(id_ns, 0, nvme_ep::nvmeAdminRespSize);
        continue;
      }
      fprintf(stdout,
              "Identify Namespace returned invalid "
              "lbads=%u after 5 attempts\n",
              lbads);
      ret = -EIO;
      goto cleanup;
    }

    *lba_size = 1U << lbads;
    fprintf(stdout, "Selected LBA size: %u bytes (lbads=%u)\n", *lba_size,
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
    free(id_ns);
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

  id_ns = static_cast<struct nvme_id_ns*>(malloc(nvme_ep::nvmeAdminRespSize));
  if (!id_ns) {
    return -ENOMEM;
  }
  memset(id_ns, 0, nvme_ep::nvmeAdminRespSize);

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
      fprintf(stdout, "Failed to identify namespace: %s\n", strerror(errno));
      ret = -errno;
      goto cleanup;
    }

    if (cmd.result & 0xFFFE) {
      uint16_t status = (cmd.result >> 1) & 0xFF;
      if (attempt < 4) {
        int delay_ms = 100 * (1 << attempt);
        fprintf(stdout,
                "Identify Namespace returned status "
                "0x%02x, retrying in %d ms "
                "(attempt %d/5)...\n",
                status, delay_ms, attempt + 1);
        usleep(delay_ms * 1000);
        memset(id_ns, 0, nvme_ep::nvmeAdminRespSize);
        continue;
      }
      fprintf(stdout,
              "Identify Namespace failed with status "
              "0x%02x after 5 attempts\n",
              status);
      ret = -EIO;
      goto cleanup;
    }

    // Command succeeded -- validate response data
    if (id_ns->nsze == 0) {
      if (attempt < 4) {
        int delay_ms = 100 * (1 << attempt);
        fprintf(stdout,
                "Identify Namespace returned "
                "nsze=0, retrying in %d ms "
                "(attempt %d/5)...\n",
                delay_ms, attempt + 1);
        usleep(delay_ms * 1000);
        memset(id_ns, 0, nvme_ep::nvmeAdminRespSize);
        continue;
      }
      fprintf(stdout, "Identify Namespace returned "
                      "nsze=0 after 5 attempts\n");
      ret = -EIO;
      goto cleanup;
    }

    *capacity_lbas = id_ns->nsze;
    fprintf(stdout, "Namespace capacity: %llu LBAs\n",
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
    free(id_ns);
  }
  return ret;
}

__host__ int checkRootfs(const char* nvme_device) {
  char ns_device[256];
  snprintf(ns_device, sizeof(ns_device), "%sn1", nvme_device);

  // Check /proc/mounts for root mount
  FILE* f = fopen("/proc/mounts", "r");
  if (!f) {
    fprintf(stdout, "Warning: Failed to open /proc/mounts\n");
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
    fprintf(stdout,
            "ERROR: NVMe device %s appears to be the root filesystem!\n",
            nvme_device);
    fprintf(stdout, "This operation will NOT proceed on rootfs to prevent data "
                    "corruption.\n");
    fprintf(stdout, "Please specify a different NVMe device.\n");
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

  // Allocate buffer on heap to ensure kernel can access it
  // Stack-allocated buffers might not work with ioctl
  uint8_t* buffer = (uint8_t*)malloc(nvme_ep::nvmeLogPageSize);
  if (!buffer) {
    fprintf(stdout, "Failed to allocate SMART log buffer\n");
    close(nvme_fd);
    return -ENOMEM;
  }
  memset(buffer, 0, nvme_ep::nvmeLogPageSize);

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
    fprintf(stdout, "Failed to read SMART log: %s\n", strerror(errno));
    free(buffer);
    close(nvme_fd);
    return -errno;
  }

  // Check completion status
  if (cmd.result & 0xFFFE) {
    uint16_t status = (cmd.result >> 1) & 0xFF;
    fprintf(stdout, "SMART log read failed with status 0x%02x\n", status);
    free(buffer);
    close(nvme_fd);
    return -EIO;
  }

  // Copy data from buffer to structure
  memcpy(smart_log, buffer, nvme_ep::nvmeLogPageSize);

  free(buffer);
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
    fprintf(stderr,
            "Error: Failed to open %s: %s\n"
            "Cannot determine maximum queue ID. Please specify --queue-id "
            "manually.\n",
            sysfs_path, strerror(errno));
    return -errno;
  }

  unsigned int queue_count = 0;
  if (fscanf(f, "%u", &queue_count) != 1) {
    fprintf(stderr,
            "Error: Failed to parse queue count from %s\n"
            "Cannot determine maximum queue ID. Please specify --queue-id "
            "manually.\n",
            sysfs_path);
    fclose(f);
    return -EIO;
  }
  fclose(f);

  if (queue_count == 0) {
    fprintf(stderr,
            "Error: Queue count is 0 in %s\n"
            "Cannot determine maximum queue ID. Please specify --queue-id "
            "manually.\n",
            sysfs_path);
    return -EINVAL;
  }

  // queue_count includes 1 admin queue (QID 0) + N I/O queues (QID 1-N)
  // So the last I/O queue ID is queue_count - 1
  // But we need at least 1 I/O queue, so queue_count must be >= 2
  if (queue_count < 2) {
    fprintf(stderr,
            "Error: Only %u queue(s) available (need at least 2: 1 admin + 1 "
            "I/O)\n"
            "Cannot use any I/O queues. Please check device configuration.\n",
            queue_count);
    return -EINVAL;
  }

  *max_queue_id = static_cast<uint16_t>(queue_count - 1);
  fprintf(stdout,
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
  fprintf(stdout,
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
    fprintf(stdout, "DELETE_SQ completed successfully.\n");
    // Check status code even if ioctl succeeded
    if (cmd.result & 0xFFFE) {
      uint16_t status_field = cmd.result & 0xFFFF;
      uint8_t sc = NVME_CQE_STATUS_SC(status_field);
      fprintf(stdout,
              "Note: DELETE_SQ returned status code 0x%02x (queue may not "
              "exist)\n",
              sc);
    }
  } else {
    // ioctl failed - could be timeout or other error
    if (errno == ETIMEDOUT) {
      fprintf(stderr,
              "Warning: DELETE_SQ timed out for queue_id=%u. This may "
              "indicate the queue ID is invalid or the controller is busy. "
              "The controller may have been reset.\n",
              queue_id);
      controller_reset_detected = true;
    } else {
      fprintf(stdout,
              "Note: DELETE_SQ failed (queue may not exist): %s (errno=%d)\n",
              strerror(errno), errno);
    }
  }

  // If controller was reset, wait for it to stabilize before proceeding
  if (controller_reset_detected) {
    fprintf(stdout,
            "Waiting 2 seconds for controller to stabilize after reset...\n");
    sleep(2);
  }

  // Delete Completion Queue (DELETE_CQ)
  fprintf(stdout, "Sending DELETE_CQ command for queue_id=%u...\n", queue_id);
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_delete_cq;
  cmd.nsid = 0;           // Admin commands use NSID 0
  cmd.cdw10 = queue_id;   // QID
  cmd.data_len = 0;       // No data transfer for DELETE_CQ
  cmd.timeout_ms = 30000; // 30 second timeout

  ret = ioctlEintrSafe(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret == 0) {
    fprintf(stdout, "DELETE_CQ completed successfully.\n");
  } else {
    fprintf(stdout, "DELETE_CQ ioctl returned: %d\n", ret);
  }
  if (ret < 0) {
    // Ignore errors - queue may not exist
    fprintf(stdout, "Note: DELETE_CQ failed (queue may not exist): %s\n",
            strerror(errno));
  } else if (cmd.result & 0xFFFE) {
    // Check status code, but don't fail - queue may not exist
    uint16_t status_field = cmd.result & 0xFFFF;
    uint8_t sc = NVME_CQE_STATUS_SC(status_field);
    // Ignore errors - queue may not exist or may have already been deleted
    fprintf(
      stderr,
      "Note: DELETE_CQ returned status code 0x%02x (queue may not exist)\n",
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

  fprintf(stdout,
          "CREATE_CQ: queue_id=%u, queue_size=%u, "
          "cdw10=0x%08x, PC=%d\n",
          queue_id, queue_size, cmd.cdw10, cq_pc ? 1 : 0);

  ret = ioctlEintrSafe(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    if (errno == EACCES || errno == EPERM) {
      fprintf(stderr, "ERROR: Failed to create completion queue: %s\n",
              strerror(errno));
      fprintf(stderr, "Note: CREATE_CQ IOCTL requires root permissions.\n");
      fprintf(stderr,
              "Please ensure you have CAP_SYS_ADMIN capability or run with "
              "sudo.\n");
    } else {
      fprintf(stderr, "ERROR: Failed to create completion queue: %s\n",
              strerror(errno));
    }
    fprintf(stderr, "ERROR: Cannot proceed - queue creation failed.\n");
    return -errno;
  }

  // Check completion status
  if (cmd.result & 0xFFFE) {
    uint16_t status_field = cmd.result & 0xFFFF;
    uint8_t sc = NVME_CQE_STATUS_SC(status_field);
    uint8_t sct = NVME_CQE_STATUS_SCT(status_field);
    fprintf(stderr,
            "ERROR: CREATE_CQ failed with status code 0x%02x (SCT=%u)\n", sc,
            sct);
    if (sc == NVME_SC_INVALID_FIELD) {
      fprintf(
        stderr,
        "  Error: Invalid field in command (queue_id=%u, queue_size=%u)\n",
        queue_id, queue_size);
    } else if (sc == NVME_SC_CAP_EXCEEDED) {
      fprintf(stderr,
              "  Error: Queue size exceeds controller capabilities "
              "(queue_size=%u)\n",
              queue_size);
    }
    fprintf(stderr, "ERROR: Cannot proceed - queue creation failed.\n");
    return -EIO;
  }

  fprintf(stdout,
          "Successfully created completion queue (queue_id=%u, size=%u)\n",
          queue_id, queue_size);

  // Re-zero completion queue after creation to clear any stale entries
  // This is especially important after a controller reset
  memset(cq_virt, 0, queue_size * NVME_EP_CQE_SIZE);
  fprintf(stdout, "Re-zeroed completion queue to clear any stale entries.\n");

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

  fprintf(stdout,
          "CREATE_SQ: queue_id=%u, queue_size=%u, "
          "cdw10=0x%08x, cdw11=0x%08x, PC=%d\n",
          queue_id, queue_size, cmd.cdw10, cmd.cdw11, sq_pc ? 1 : 0);

  ret = ioctlEintrSafe(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    fprintf(stderr, "ERROR: Failed to create submission queue: %s\n",
            strerror(errno));
    fprintf(stderr, "ERROR: Cannot proceed - queue creation failed.\n");
    return -errno;
  }

  // Check completion status
  if (cmd.result & 0xFFFE) {
    uint16_t status_field = cmd.result & 0xFFFF;
    uint8_t sc = NVME_CQE_STATUS_SC(status_field);
    uint8_t sct = NVME_CQE_STATUS_SCT(status_field);
    fprintf(stderr,
            "ERROR: CREATE_SQ failed with status code 0x%02x (SCT=%u)\n", sc,
            sct);
    if (sc == NVME_SC_INVALID_FIELD) {
      fprintf(stderr,
              "  Error: Invalid field in command (queue_id=%u, queue_size=%u, "
              "CQID=%u)\n",
              queue_id, queue_size, queue_id);
    } else if (sc == NVME_SC_CAP_EXCEEDED) {
      fprintf(stderr,
              "  Error: Queue size exceeds controller capabilities "
              "(queue_size=%u)\n",
              queue_size);
    }
    fprintf(stderr, "ERROR: Cannot proceed - queue creation failed.\n");
    return -EIO;
  }

  fprintf(stdout,
          "Successfully created submission queue (queue_id=%u, size=%u)\n",
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
        fprintf(stderr, "Warning: munlock failed for PRP list '%s': %s\n",
                (name != nullptr) ? name : "unknown", strerror(errno));
      }
    } else {
      fprintf(stderr,
              "Warning: failed to get page size for munlock of PRP list '%s'\n",
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
    fprintf(stdout,
            "Failed to open kernel module device "
            "%s: %s\n",
            kernel_module_device, strerror(errno));
    return -errno;
  }

  bool is_emulated = false;
  int detect_ret = detectEmulatedNvme(nvme_device, &is_emulated);
  if (detect_ret != 0) {
    fprintf(stderr,
            "Error: Failed to detect NVMe type "
            "for %s: %s.\n",
            nvme_device, strerror(-detect_ret));
    close(kmod_fd);
    return -detect_ret;
  }
  fprintf(stdout, "NVMe device %s detected as: %s.\n", nvme_device,
          is_emulated ? "EMULATED" : "REAL");

  nvme_fd = openDeviceWithRetry(nvme_device, O_RDWR, "NVMe device", 5, 100);
  if (nvme_fd < 0) {
    fprintf(stderr, "Failed to open NVMe device %s: %s.\n", nvme_device,
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
      fprintf(stdout, "Warning: Could not read CQR, "
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
    fprintf(stdout,
            "CQR=1: using contiguous DMA for "
            "submission queue (%zu bytes)\n",
            sq_size_bytes);
    ret = setupContigQueueForGpu(sq_size_bytes, nvme_bdf, "submission queue",
                                 &sq_setup);
    if (ret < 0) {
      size_t max_sq = NVME_PAGE_SIZE / NVME_EP_SQE_SIZE;
      fprintf(stderr,
              "Error: Contiguous alloc failed for "
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
    fprintf(stdout,
            "CQR=1: using contiguous DMA for "
            "completion queue (%zu bytes)\n",
            cq_size_bytes);
    ret = setupContigQueueForGpu(cq_size_bytes, nvme_bdf, "completion queue",
                                 &cq_setup);
    if (ret < 0) {
      size_t max_cq = NVME_PAGE_SIZE / NVME_EP_CQE_SIZE;
      fprintf(stderr,
              "Error: Contiguous alloc failed for "
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

    fprintf(stdout,
            "Queue PC flags: SQ PC=%d (%zu bytes, "
            "%s%s), CQ PC=%d (%zu bytes, %s%s)\n",
            sq_pc ? 1 : 0, sq_size_bytes, sq_is_device ? "device" : "host",
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

    fprintf(stdout,
            "Deleting existing queues (queue_id=%u) "
            "if they exist...\n",
            queue_id);
    deleteQueue(nvme_fd, queue_id);
    fprintf(stdout, "Queue deletion completed.\n");

    fprintf(stdout, "Waiting 500ms before creating "
                    "queues...\n");
    usleep(500000);

    fprintf(stdout,
            "Creating NVMe queues (queue_id=%u, "
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

// C-compatible cleanup function for signal handlers
extern "C" __host__ int nvme_ep_cleanup_queues(void* endpointConfig) {
  if (!endpointConfig) {
    return -EINVAL;
  }

  // Cast to nvmeEpConfig - we know this is safe if called for nvme-ep
  nvme_ep::nvmeEpConfig* nvmeConfig = static_cast<nvme_ep::nvmeEpConfig*>(
    endpointConfig);

  // Only attempt cleanup if queues were actually created
  if (!nvmeConfig->queuesCreated) {
    return 0; // No queues to clean up
  }

  // Check if controller path is valid
  if (nvmeConfig->controller.empty()) {
    return -EINVAL;
  }

  // Reopen device (device was closed after queue creation)
  int nvme_fd = openDeviceWithRetry(nvmeConfig->controller.c_str(), O_RDWR,
                                    "NVMe device", 3, 50);
  if (nvme_fd < 0) {
    fprintf(stderr,
            "Warning: Failed to reopen NVMe device for queue cleanup: %s\n",
            strerror(errno));
    return -errno;
  }

  // Attempt to delete queues
  fprintf(stdout,
          "\nSIGINT received: Attempting to delete NVMe queues "
          "(queue_id=%u)...\n",
          nvmeConfig->queueId);
  int ret = deleteQueue(nvme_fd, nvmeConfig->queueId);
  close(nvme_fd);

  if (ret == 0) {
    fprintf(stdout, "NVMe queues deleted successfully.\n");
    nvmeConfig->queuesCreated = false;
  } else {
    fprintf(stderr, "Warning: Failed to delete NVMe queues: %s\n",
            strerror(-ret));
  }

  // Host-side teardown of PRP lists and contiguous queue mappings.
  // Idempotent: all pointers/IDs are cleared after use.
#ifndef __HIP_DEVICE_COMPILE__
  {
    nvme_queue_info* qinfo = &nvmeConfig->queueInfo;
    long page_sz = sysconf(_SC_PAGESIZE);

    if (qinfo->sq_prp_list) {
      if (page_sz > 0)
        munlock(qinfo->sq_prp_list, static_cast<size_t>(page_sz));
      free(qinfo->sq_prp_list);
      qinfo->sq_prp_list = nullptr;
    }
    if (qinfo->cq_prp_list) {
      if (page_sz > 0)
        munlock(qinfo->cq_prp_list, static_cast<size_t>(page_sz));
      free(qinfo->cq_prp_list);
      qinfo->cq_prp_list = nullptr;
    }

    if (qinfo->sq_virt && qinfo->sq_contig_id) {
      struct xioQueueSetup sq_setup = {};
      sq_setup.virt = qinfo->sq_virt;
      sq_setup.gpu = qinfo->sq_gpu;
      sq_setup.phys = qinfo->sq_phys;
      sq_setup.uses_contig = true;
      sq_setup.contig_id = qinfo->sq_contig_id;
      freeContigQueue(&sq_setup, qinfo->sq_size, "submission queue");
      qinfo->sq_virt = nullptr;
      qinfo->sq_gpu = nullptr;
      qinfo->sq_contig_id = 0;
    }
    if (qinfo->cq_virt && qinfo->cq_contig_id) {
      struct xioQueueSetup cq_setup = {};
      cq_setup.virt = qinfo->cq_virt;
      cq_setup.gpu = qinfo->cq_gpu;
      cq_setup.phys = qinfo->cq_phys;
      cq_setup.uses_contig = true;
      cq_setup.contig_id = qinfo->cq_contig_id;
      freeContigQueue(&cq_setup, qinfo->cq_size, "completion queue");
      qinfo->cq_virt = nullptr;
      qinfo->cq_gpu = nullptr;
      qinfo->cq_contig_id = 0;
    }

    if (qinfo->sq_dmabuf_fd >= 0) {
      close(qinfo->sq_dmabuf_fd);
      qinfo->sq_dmabuf_fd = -1;
    }
    if (qinfo->cq_dmabuf_fd >= 0) {
      close(qinfo->cq_dmabuf_fd);
      qinfo->cq_dmabuf_fd = -1;
    }
  }
#endif // __HIP_DEVICE_COMPILE__

  return ret;
}

} // namespace xio::nvme_ep

#endif // __HIP_DEVICE_COMPILE__
