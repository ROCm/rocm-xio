/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "nvme-ep.h"
#include "rocm-xio-kmod.h"

// Host-only includes for IOCTL and file operations
#ifndef __HIP_DEVICE_COMPILE__
#include <errno.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <drm/amdgpu_drm.h>
#include <drm/drm.h>
#include <fcntl.h>
#include <linux/nvme_ioctl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#endif // __HIP_DEVICE_COMPILE__

namespace nvme_ep {

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

__host__ __device__ void sqeWrite(sqeType sqeData, sqeType* sqeAddress) {
  *sqeAddress = sqeData;
}

__host__ __device__ void cqeWrite(cqeType cqeData, cqeType* cqeAddress) {
  *cqeAddress = cqeData;
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
                                    uint16_t* sq_head_out) {
  cqeType cqeNew;
  while (true) {
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
    xio_ep::ringDoorbell(doorbellParams.nvmeBar0Gpu, offset, value);
  }
}

/**
 * Calculate LBA for an I/O operation
 *
 * @param op_index Operation index (0-based)
 * @param cmd_id Command ID for random seed generation
 * @param blocks Number of blocks per I/O operation
 * @param ioParams I/O parameters containing baseLba, lbaRangeLbas, and
 * useRandomAccess
 * @return Calculated LBA address
 */
static __host__ __device__ uint64_t getRandomLba(unsigned op_index,
                                                 uint16_t cmd_id,
                                                 uint32_t blocks,
                                                 const nvmeIoParams& ioParams) {
  if (ioParams.useRandomAccess && ioParams.lbaRangeLbas > 0) {
    // Random access mode: generate pseudo-random LBA within range
    uint64_t seed = (uint64_t)op_index * 0x9e3779b9 + cmd_id * 0x85ebca6b;
    seed ^= seed >> 16;
    seed *= 0xc2b2ae35;
    seed ^= seed >> 13;
    seed *= 0x9e3779b9;
    seed ^= seed >> 16;
    return ioParams.baseLba + (seed % ioParams.lbaRangeLbas);
  } else {
    // Sequential access mode
    if (ioParams.lbaRangeLbas > 0) {
      return ioParams.baseLba + ((op_index * blocks) % ioParams.lbaRangeLbas);
    } else {
      return ioParams.baseLba + (op_index * blocks);
    }
  }
}

__device__ void driveEndpoint(const XioEndpointConfig& config,
                              const nvmeIoParams& ioParams,
                              const nvmeDoorbellParams& doorbellParams,
                              const nvmeBufferParams& bufferParams) {
  // Extract queue pointers from config
  sqeType* sqeAddr = static_cast<sqeType*>(config.submissionQueue);
  cqeType* cqeAddr = static_cast<cqeType*>(config.completionQueue);

  const bool sequential_mode = (ioParams.readIo < 0 || ioParams.writeIo < 0);
  bool sequential_is_read = false;
  unsigned num_ops;
  unsigned num_read_ops = 0;
  unsigned num_write_ops = 0;
  if (sequential_mode) {
    if (ioParams.readIo < 0 && ioParams.writeIo < 0) {
      num_read_ops = -ioParams.readIo;
      num_write_ops = -ioParams.writeIo;
      num_ops = num_read_ops + num_write_ops;
    } else if (ioParams.readIo < 0) {
      num_ops = -ioParams.readIo;
      sequential_is_read = true;
      num_read_ops = num_ops;
    } else {
      num_ops = -ioParams.writeIo;
      sequential_is_read = false;
      num_write_ops = num_ops;
    }
  } else {
    num_ops = config.iterations;
  }

  const uint32_t nsid = ioParams.nsid;
  const uint32_t blocks = ioParams.lbasPerIo;
  const size_t transfer_size = blocks * ioParams.lbaSize;

  const bool has_write_buffer = (bufferParams.writeBuffer != nullptr &&
                                 bufferParams.bufferSize > 0);
  const bool has_read_buffer = (bufferParams.readBuffer != nullptr &&
                                bufferParams.bufferSize > 0);
  const bool write_only_mode = has_write_buffer && !has_read_buffer;
  const bool read_only_mode = has_read_buffer && !has_write_buffer;
  const bool alternate_mode = has_write_buffer && has_read_buffer;

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

  // Initialize phase tracking for completion polling
  uint16_t cq_head = 0;
  volatile cqeType* initial_cqe = &cqeAddr[cq_head];
  nvme_ep::cqeType initial_cqe_data = nvme_ep::cqeRead(
    (volatile nvme_ep::cqeType*)initial_cqe);
  uint8_t expected_phase = NVME_CQE_STATUS_PHASE(initial_cqe_data.status) ^ 1;
  (void)expected_phase; // Used in batch mode, set here for consistency

  // Track submission queue tail
  uint16_t sq_tail = 0;
  uint16_t last_sq_head = 0;

  if (sequential_mode) {
    for (unsigned i = 0; i < num_ops; i++) {
      uint16_t cmd_id = (uint16_t)(i + 1);

      bool is_read_op;
      unsigned op_index;
      if (num_read_ops > 0 && num_write_ops > 0) {
        if (i < num_write_ops) {
          is_read_op = false;
          op_index = i;
        } else {
          is_read_op = true;
          op_index = i - num_write_ops;
        }
      } else {
        is_read_op = sequential_is_read;
        op_index = i;
      }

      // Calculate LBA
      uint64_t lba = getRandomLba(i, cmd_id, blocks, ioParams);

      // Setup read or write command
      nvme_ep::sqeType sqeLocal = {};
      sqeType* sqe = &sqeLocal;
      sqe->opcode = is_read_op ? nvme_cmd_read : nvme_cmd_write;
      sqe->command_id = cmd_id;
      sqe->nsid = nsid;

      // Calculate PRPs based on command type (read or write)
      bool prp_valid = false;
      if (is_read_op && has_read_buffer) {
        // For sequential reads, reuse the same buffer for every I/O
        uint64_t buffer_offset = 0;
        if (buffer_offset + transfer_size <= bufferParams.bufferSize) {
          uint64_t buffer_addr =
            bufferParams.readBufferDma
              ? (bufferParams.readBufferDma + buffer_offset)
              : (uint64_t)(bufferParams.readBuffer + buffer_offset);
          calculatePrps(buffer_addr, transfer_size, sqe);
          prp_valid = true;
        }
      } else if (!is_read_op && has_write_buffer) {
        uint64_t buffer_offset = op_index * transfer_size;
        if (buffer_offset + transfer_size <= bufferParams.bufferSize) {
          uint64_t buffer_addr =
            bufferParams.writeBufferDma
              ? (bufferParams.writeBufferDma + buffer_offset)
              : (uint64_t)(bufferParams.writeBuffer + buffer_offset);
          calculatePrps(buffer_addr, transfer_size, sqe);
          prp_valid = true;
        }
      }

      // Fail if PRPs could not be calculated
      if (!prp_valid) {
        __builtin_trap();
      }
      sqeSetup(sqe, lba, blocks);

      // Record start time
      if (config.startTimes != nullptr) {
        config.startTimes[i] = wall_clock64();
      }

      // Write SQE and increment sq_tail
      nvme_ep::sqeWrite(sqeLocal, &sqeAddr[sq_tail]);
      sq_tail = (sq_tail + 1) % ioParams.queueSize;

      // Ring doorbell
      nvme_ep::ringDoorbell(sq_tail, doorbellParams);

      // Wait for completion using cqePoll
      volatile cqeType* cqe_entry = &cqeAddr[cq_head];
      uint16_t new_sq_head = 0;
      nvme_ep::cqeType cqe_new = nvme_ep::cqePoll(initial_cqe_data, cqe_entry,
                                                  last_sq_head, &new_sq_head);

      // Update tracking variables
      if (config.endTimes != nullptr && cmd_id >= 1 && cmd_id <= num_ops) {
        unsigned idx = cmd_id - 1;
        config.endTimes[idx] = wall_clock64();
      }
      cq_head = (cq_head + 1) % ioParams.queueSize;
      // Update CQ doorbell to notify controller we consumed the completion
      // CQ doorbell is at SQ doorbell offset + doorBellStride (4 bytes)
      nvme_ep::ringDoorbell(cq_head, doorbellParams,
                            doorbellParams.doorbellOffset +
                              nvme_ep::doorBellStride);
      uint8_t phase = NVME_CQE_STATUS_PHASE(cqe_new.status);
      expected_phase = phase ^ 1;
      last_sq_head = new_sq_head;
    }
  } else {
    // Batch mode: enqueue some number of SQEs, then ring doorbell,
    // then poll for completions

    sqeType sqeLocal = {};
    sqeType* sqe = &sqeLocal;

    // Issue a batch of commands
    for (unsigned i = 0; i < num_ops; i++) {
      uint16_t cmd_id = (uint16_t)(i + 1);

      // Calculate LBA
      uint64_t lba = getRandomLba(i, cmd_id, blocks, ioParams);

      // Determine command type
      bool is_read_command = false;
      if (write_only_mode) {
        is_read_command = false;
      } else if (read_only_mode) {
        is_read_command = true;
      } else if (alternate_mode) {
        is_read_command = (i % 2 == 0);
      } else {
        is_read_command = (i % 2 == 0);
      }

      bool is_write = !is_read_command;

      // Setup command
      sqe->opcode = is_write ? nvme_cmd_write : nvme_cmd_read;
      sqe->command_id = cmd_id;
      sqe->nsid = nsid;

      // Calculate PRPs
      bool prp_valid = false;
      if (is_read_command && has_read_buffer) {
        uint64_t buffer_offset = read_only_mode ? (i * transfer_size)
                                                : ((i / 2) * transfer_size);
        if (buffer_offset + transfer_size <= bufferParams.bufferSize) {
          uint64_t buffer_addr =
            bufferParams.readBufferDma
              ? (bufferParams.readBufferDma + buffer_offset)
              : (uint64_t)(bufferParams.readBuffer + buffer_offset);
          calculatePrps(buffer_addr, transfer_size, sqe);
          prp_valid = true;
        }
      } else if (is_write && has_write_buffer) {
        uint64_t buffer_offset = write_only_mode ? (i * transfer_size)
                                                 : ((i / 2) * transfer_size);
        if (buffer_offset + transfer_size <= bufferParams.bufferSize) {
          uint64_t buffer_addr =
            bufferParams.writeBufferDma
              ? (bufferParams.writeBufferDma + buffer_offset)
              : (uint64_t)(bufferParams.writeBuffer + buffer_offset);
          calculatePrps(buffer_addr, transfer_size, sqe);
          prp_valid = true;
        }
      }

      // Fail if PRPs could not be calculated
      if (!prp_valid) {
        __builtin_trap();
      }

      sqeSetup(sqe, lba, blocks);

      // Record start time
      if (config.startTimes != nullptr) {
        config.startTimes[i] = wall_clock64();
      }

      // Write SQE
      nvme_ep::sqeWrite(sqeLocal, &sqeAddr[sq_tail]);
      sq_tail = (sq_tail + 1) % ioParams.queueSize;
    }

    // Memory fence before doorbell
    __threadfence_system();

    // Ring doorbell once for all commands
    nvme_ep::ringDoorbell(sq_tail, doorbellParams);

    // Poll for all completions using cqePoll
    uint16_t completed_count = 0;
    nvme_ep::cqeType cqe_last = initial_cqe_data;

    while (completed_count < num_ops) {
      volatile cqeType* cqe_entry = &cqeAddr[cq_head];
      uint16_t new_sq_head = 0;
      nvme_ep::cqeType cqe_new = nvme_ep::cqePoll(cqe_last, cqe_entry,
                                                  last_sq_head, &new_sq_head);

      if (new_sq_head > last_sq_head && new_sq_head <= num_ops) {
        uint16_t new_completions = new_sq_head - last_sq_head;
        if (config.endTimes != nullptr) {
          uint64_t end_time = wall_clock64();
          for (uint16_t i = 0; i < new_completions; i++) {
            uint16_t completed_cmd_id = last_sq_head + 1 + i;
            if (completed_cmd_id >= 1 && completed_cmd_id <= num_ops) {
              unsigned idx = completed_cmd_id - 1;
              config.endTimes[idx] = end_time;
            }
          }
        }
        completed_count += new_completions;
        last_sq_head = new_sq_head;
        cq_head = (cq_head + 1) % ioParams.queueSize;
        // Update CQ doorbell to notify controller we consumed the completion
        // CQ doorbell is at SQ doorbell offset + doorBellStride (4 bytes)
        nvme_ep::ringDoorbell(cq_head, doorbellParams,
                              doorbellParams.doorbellOffset +
                                nvme_ep::doorBellStride);
        uint8_t phase = NVME_CQE_STATUS_PHASE(cqe_new.status);
        expected_phase = phase ^ 1;
        cqe_last = cqe_new;
      }
    }
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

} // namespace nvme_ep

#ifndef __HIP_DEVICE_COMPILE__

#include <fcntl.h>

namespace nvme_ep {

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
    .add_option(
      "--read-io", config->ioParams.readIo,
      "Number of read IO to perform. If negative, issues one SQE at a "
      "time waiting for completion before issuing the next.")
    ->default_val(0)
    ->group(nvme_group);
  app
    .add_option("--queue-id", config->queueId,
                "NVMe queue ID to use (0=admin queue, 1+=IO queues).")
    ->default_val(63)
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
    .add_option(
      "--write-io", config->ioParams.writeIo,
      "Number of write IO to perform. If negative, issues one SQE at a "
      "time waiting for completion before issuing the next.")
    ->default_val(0)
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
  // Validate that access pattern is valid
  if (config->ioParams.accessPattern != "sequential" &&
      config->ioParams.accessPattern != "random") {
    return "Access pattern must be 'sequential' or 'random'";
  }

  // Validate that at least one I/O count is != 0)
  if (config->ioParams.readIo == 0 && config->ioParams.writeIo == 0) {
    return "At least one of --read-io or --write-io must be specified with "
           "value != 0 (use negative values for sequential mode)";
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
    int bdf_ret = xioDetectPciMmioBridgeBdf(&detected_bdf);
    if (bdf_ret != 0) {
      return "Failed to detect PCI MMIO bridge BDF";
    }
    config->doorbellParams.mmioBridgeBdf = detected_bdf;
  }

  // Detect NVMe target BDF from controller device path
  uint16_t detected_nvme_bdf = 0;
  int nvme_bdf_ret = xioDetectBdfFromDevice(config->controller.c_str(),
                                            &detected_nvme_bdf);
  if (nvme_bdf_ret != 0) {
    return std::string("Failed to detect NVMe target BDF: ") +
           std::string(strerror(-nvme_bdf_ret));
  }
  config->doorbellParams.nvmeTargetBdf = detected_nvme_bdf;

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
    int ret_shadow = xioMapMmioBridgeShadowBuffer(
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
    int ret_register = xioRegisterMmioBridgeShadowBufferForGpu(shadow_virt,
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
    int ret_bar0 = xioMapPciBar(nvmeConfig->doorbellParams.nvmeTargetBdf, 0,
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
    hipError_t buf_err = xioAllocateGpuAccessibleBuffer(
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
    hipError_t buf_err = xioAllocateGpuAccessibleBuffer(
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
  if (!xioValidateGpuPointer(config->submissionQueue, "SQ", false)) {
    fprintf(stderr, "Error: Submission queue is not GPU-accessible.\n");
    return hipErrorInvalidValue;
  }
  if (!xioValidateGpuPointer(config->completionQueue, "CQ", false)) {
    fprintf(stderr, "Error: Completion queue is not GPU-accessible.\n");
    return hipErrorInvalidValue;
  }

  // Verify shadowBufferVirt is GPU-accessible if it's non-null
  if (shadowBufferVirt != nullptr) {
    if (!xioValidateGpuPointer(shadowBufferVirt, "Shadow buffer", false)) {
      fprintf(stderr, "Error: Shadow buffer is not GPU-accessible.\n");
      return hipErrorInvalidValue;
    }
  }

  // Verify nvmeBar0Gpu is GPU-accessible if it's non-null
  if (nvmeBar0Gpu != nullptr) {
    if (!xioValidateGpuPointer(nvmeBar0Gpu, "BAR0", false)) {
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
          "expected transfer_size=%u, writeBufferDma=0x%llx\n",
          nvmeConfig->ioParams.lbaSize, nvmeConfig->ioParams.lbasPerIo,
          nvmeConfig->ioParams.lbasPerIo * nvmeConfig->ioParams.lbaSize,
          (unsigned long long)writeBufferInfo.dmaAddr);

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

  hipLaunchKernelGGL(nvme_ep::gpuKernel, dim3(1), dim3(config->numThreads), 0,
                     0, kernelConfig, ioParams, doorbellParams, bufferParams);

  fprintf(stdout, "Info: Kernel launched.\n");

  // Wait for GPU kernel to complete
  hipError_t err = hipDeviceSynchronize();

  // Detect if an error occured
  if (err != hipSuccess) {
    fprintf(stdout, "Info: Device synchronization error: %s (code: %d).\n",
            hipGetErrorString(err), err);
  }

  // Free data buffers
  xioFreeGpuAccessibleBuffer(&readBufferInfo);
  xioFreeGpuAccessibleBuffer(&writeBufferInfo);

  return err;
}

// Host helper function
__host__ int queryLbaSize(const char* nvme_device, uint32_t nsid,
                          unsigned* lba_size) {
  int nvme_fd = -1;
  int ret = 0;
  struct nvme_passthru_cmd cmd;
  struct nvme_id_ns* id_ns = nullptr;
  uint8_t flbas = 0;
  uint8_t lba_format_idx = 0;
  uint8_t* lbaf_ptr = nullptr;
  uint8_t lbads = 0;
  uint16_t status = 0;
  uint8_t* response_base = nullptr;

  if (!nvme_device || !lba_size) {
    return -EINVAL;
  }

  // Allocate buffer for Identify Namespace response
  id_ns = static_cast<struct nvme_id_ns*>(malloc(nvme_ep::nvmeAdminRespSize));
  if (!id_ns) {
    return -ENOMEM;
  }
  memset(id_ns, 0, nvme_ep::nvmeAdminRespSize);

  // Open NVMe device
  nvme_fd = open(nvme_device, O_RDONLY);
  if (nvme_fd < 0) {
    fprintf(stdout, "Failed to open NVMe device %s: %s\n", nvme_device,
            strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Send Identify Namespace command
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_identify;
  cmd.nsid = nsid;
  cmd.cdw10 = 0; // CNS=0 (Identify Namespace)
  cmd.addr = reinterpret_cast<uint64_t>(id_ns);
  cmd.data_len = nvme_ep::nvmeAdminRespSize;
  cmd.timeout_ms = 0; // Use default timeout

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    fprintf(stdout, "Failed to identify namespace: %s\n", strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Check completion status
  if (cmd.result & 0xFFFE) {
    status = (cmd.result >> 1) & 0xFF;
    fprintf(stdout, "Identify Namespace failed with status 0x%02x\n", status);
    ret = -EIO;
    goto cleanup;
  }

  // Extract FLBAS (Formatted LBA and Metadata Size)
  flbas = id_ns->flbas;
  lba_format_idx = flbas & 0x0F;

  // Validate LBA format index
  if (lba_format_idx > id_ns->nlbaf) {
    fprintf(stdout, "Invalid LBA format index %u (max supported: %u)\n",
            lba_format_idx, id_ns->nlbaf);
    ret = -EINVAL;
    goto cleanup;
  }

  // Extract LBADS (LBA Data Size) from LBA Format structure
  response_base = reinterpret_cast<uint8_t*>(id_ns);
  lbaf_ptr = response_base + 128 + (lba_format_idx * 4);
  lbads = lbaf_ptr[2] & 0xFF;

  // LBA size = 2^LBADS bytes
  *lba_size = 1U << lbads;
  fprintf(stdout, "Selected LBA size: %u bytes (lbads=%u)\n", *lba_size, lbads);

  ret = 0;

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
  uint16_t status = 0;

  if (!nvme_device || !capacity_lbas) {
    return -EINVAL;
  }

  // Allocate buffer for Identify Namespace response
  id_ns = static_cast<struct nvme_id_ns*>(malloc(nvme_ep::nvmeAdminRespSize));
  if (!id_ns) {
    return -ENOMEM;
  }
  memset(id_ns, 0, nvme_ep::nvmeAdminRespSize);

  // Open NVMe device
  nvme_fd = open(nvme_device, O_RDONLY);
  if (nvme_fd < 0) {
    fprintf(stdout, "Failed to open NVMe device %s: %s\n", nvme_device,
            strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Send Identify Namespace command
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_identify;
  cmd.nsid = nsid;
  cmd.cdw10 = 0; // CNS=0 (Identify Namespace)
  cmd.addr = reinterpret_cast<uint64_t>(id_ns);
  cmd.data_len = nvme_ep::nvmeAdminRespSize;
  cmd.timeout_ms = 0; // Use default timeout

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    fprintf(stdout, "Failed to identify namespace: %s\n", strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Check completion status
  if (cmd.result & 0xFFFE) {
    status = (cmd.result >> 1) & 0xFF;
    fprintf(stdout, "Identify Namespace failed with status 0x%02x\n", status);
    ret = -EIO;
    goto cleanup;
  }

  // Extract NSZE (Namespace Size) - capacity in LBAs
  *capacity_lbas = id_ns->nsze;
  fprintf(stdout, "Namespace capacity: %llu LBAs\n",
          (unsigned long long)*capacity_lbas);

  ret = 0;

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
  int nvme_fd = open(nvme_device, O_RDONLY);
  if (nvme_fd < 0) {
    fprintf(stdout, "Failed to open NVMe device %s: %s\n", nvme_device,
            strerror(errno));
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

  int ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN64_CMD, &cmd);
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

__host__ int deleteQueue(int nvme_fd, uint16_t queue_id) {
  struct nvme_passthru_cmd cmd;
  int ret = 0;

  if (nvme_fd < 0) {
    return -EINVAL;
  }

  // Delete existing queues if they exist (ignore errors - queue may not exist)
  // Delete SQ first, then CQ (NVMe spec requirement: CQ cannot be deleted
  // while associated SQ exists)

  // Delete Submission Queue (DELETE_SQ)
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_delete_sq;
  cmd.nsid = 0;         // Admin commands use NSID 0
  cmd.cdw10 = queue_id; // QID
  cmd.data_len = 0;     // No data transfer for DELETE_SQ

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    // Ignore errors - queue may not exist
    fprintf(stdout, "Note: DELETE_SQ failed (queue may not exist): %s\n",
            strerror(errno));
  } else if (cmd.result & 0xFFFE) {
    // Check status code, but don't fail - queue may not exist
    uint16_t status_field = cmd.result & 0xFFFF;
    uint8_t sc = NVME_CQE_STATUS_SC(status_field);
    // Ignore errors - queue may not exist or may have already been deleted
    fprintf(
      stderr,
      "Note: DELETE_SQ returned status code 0x%02x (queue may not exist)\n",
      sc);
  }

  // Delete Completion Queue (DELETE_CQ)
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_delete_cq;
  cmd.nsid = 0;         // Admin commands use NSID 0
  cmd.cdw10 = queue_id; // QID
  cmd.data_len = 0;     // No data transfer for DELETE_CQ

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
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
                                 void* cq_virt) {
  struct nvme_passthru_cmd cmd;
  int ret = 0;

  if (nvme_fd < 0 || !sq_virt || !cq_virt || queue_size == 0) {
    return -EINVAL;
  }

  // Create Completion Queue first (CREATE_CQ)
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_create_cq;
  cmd.nsid = 0;                                  // Admin commands use NSID 0
  cmd.cdw10 = (queue_size - 1) << 16 | queue_id; // QSIZE | QID
  cmd.cdw11 = 0x00000001; // PC=1 (physically contiguous), IEN=0, IV=0
  // PRP1 will be injected by kprobe - pass virtual address as ubuffer
  cmd.addr = reinterpret_cast<uint64_t>(cq_virt);
  cmd.data_len = 0; // No data transfer for CREATE_CQ

  // Debug: Print what we're sending to the controller
  fprintf(stdout,
          "CREATE_CQ: queue_id=%u, queue_size=%u, cdw10=0x%08x "
          "(QSIZE-1=0x%04x in bits 31:16, QID=0x%04x in bits 15:0)\n",
          queue_id, queue_size, cmd.cdw10, (queue_size - 1), queue_id);

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
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

  // Create Submission Queue (CREATE_SQ)
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_create_sq;
  cmd.nsid = 0;                                  // Admin commands use NSID 0
  cmd.cdw10 = (queue_size - 1) << 16 | queue_id; // QSIZE | QID
  cmd.cdw11 = (queue_id << 16) | 0x0001;         // CQID | QPRIO=0, PC=1
  // PRP1 will be injected by kprobe - pass virtual address as ubuffer
  cmd.addr = reinterpret_cast<uint64_t>(sq_virt);
  cmd.data_len = 0; // No data transfer for CREATE_SQ

  // Debug: Print what we're sending to the controller
  fprintf(stdout,
          "CREATE_SQ: queue_id=%u, queue_size=%u, cdw10=0x%08x "
          "(QSIZE-1=0x%04x in bits 31:16, QID=0x%04x in bits 15:0), "
          "cdw11=0x%08x (CQID=0x%04x in bits 31:16)\n",
          queue_id, queue_size, cmd.cdw10, (queue_size - 1), queue_id,
          cmd.cdw11, queue_id);

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
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

__host__ int createQueue(const char* nvme_device,
                         const char* kernel_module_device, uint16_t queue_id,
                         uint16_t queue_size, uint16_t nvme_bdf,
                         unsigned memory_mode, struct nvme_queue_info* info) {
  int kmod_fd = -1;
  int nvme_fd = -1;
  int ret = 0;
  hipError_t sqe_err = hipSuccess;
  hipError_t cqe_err = hipSuccess;
  hipError_t sq_hip_err = hipSuccess;
  hipError_t cq_hip_err = hipSuccess;
  void* sq_virt = nullptr;
  void* cq_virt = nullptr;
  void* sq_gpu = nullptr;
  void* cq_gpu = nullptr;
  bool sq_uses_coherent = false;
  bool cq_uses_coherent = false;
  bool sq_is_device = (memory_mode & 0x1) != 0;
  bool cq_is_device = (memory_mode & 0x2) != 0;
  uint64_t sq_phys = 0;
  uint64_t cq_phys = 0;
  struct drm_amdgpu_gem_userptr sq_userptr = {};
  struct drm_amdgpu_gem_userptr cq_userptr = {};
  size_t page_size = 0;
  size_t sq_size_aligned = 0;
  size_t cq_size_aligned = 0;

  if (!nvme_device || !kernel_module_device || !info) {
    return -EINVAL;
  }

  // Validate queue_size is power of 2 and non-zero
  if (queue_size == 0 || (queue_size & (queue_size - 1)) != 0) {
    return -EINVAL;
  }

  // Calculate queue sizes in bytes
  const size_t sq_size_bytes = queue_size * NVME_EP_SQE_SIZE;
  const size_t cq_size_bytes = queue_size * NVME_EP_CQE_SIZE;

  // Calculate page-aligned sizes for GEM_USERPTR
  page_size = sysconf(_SC_PAGESIZE);
  sq_size_aligned = ((sq_size_bytes + page_size - 1) / page_size) * page_size;
  cq_size_aligned = ((cq_size_bytes + page_size - 1) / page_size) * page_size;

  // Zero-initialize output structure
  memset(info, 0, sizeof(*info));
  info->sq_size = sq_size_bytes;
  info->cq_size = cq_size_bytes;

  // Open kernel module device
  kmod_fd = open(kernel_module_device, O_RDWR);
  if (kmod_fd < 0) {
    fprintf(stdout, "Failed to open kernel module device %s: %s\n",
            kernel_module_device, strerror(errno));
    return -errno;
  }

  // Detect if NVMe device is emulated (QEMU) or a real
  bool is_emulated = false;
  int detect_ret = xioDetectEmulatedNvme(nvme_device, &is_emulated);
  if (detect_ret != 0) {
    fprintf(stderr, "Error: Failed to detect NVMe type for %s: %s.\n",
            nvme_device, strerror(-detect_ret));
    return -detect_ret;
  }
  fprintf(stdout, "NVMe device %s detected as: %s.\n", nvme_device,
          is_emulated ? "EMULATED" : "REAL");

  nvme_fd = open(nvme_device, O_RDWR);
  if (nvme_fd < 0) {
    fprintf(stderr, "Failed to open NVMe device %s: %s.\n", nvme_device,
            strerror(errno));
    close(kmod_fd);
    return -errno;
  }

  // Allocate SQ buffer
  sqe_err = xioAllocateQueue(sq_size_bytes, sq_is_device, "submission queue",
                             &sq_virt);
  if (sqe_err != hipSuccess) {
    fprintf(stdout, "Failed to allocate SQ buffer: %s\n",
            hipGetErrorString(sqe_err));
    ret = -ENOMEM;
    goto cleanup;
  }

  // Allocate CQ buffer
  cqe_err = xioAllocateQueue(cq_size_bytes, cq_is_device, "completion queue",
                             &cq_virt);
  if (cqe_err != hipSuccess) {
    fprintf(stdout, "Failed to allocate CQ buffer: %s\n",
            hipGetErrorString(cqe_err));
    xioFreeQueue(sq_virt, sq_is_device, "submission queue");
    ret = -ENOMEM;
    goto cleanup;
  }

  // Zero-initialize queues
  memset(sq_virt, 0, sq_size_bytes);
  memset(cq_virt, 0, cq_size_bytes);

  // Reallocate host memory queues with hipHostMallocCoherent for GPU-PCIe
  // coherency This is critical for gfx900 (MI250) where GPU writes must be
  // immediately visible to PCIe devices like NVMe controllers
  if (!sq_is_device) {
    sq_uses_coherent = xioReallocateQueue(&sq_virt, sq_size_bytes,
                                          "submission queue");
  }
  if (!cq_is_device) {
    cq_uses_coherent = xioReallocateQueue(&cq_virt, cq_size_bytes,
                                          "completion queue");
  }

  // Register queues with GPU
  if (!xioRegQueueGpu(sq_virt, sq_size_aligned, sq_is_device,
                      "submission queue", &sq_userptr)) {
    goto cleanup;
  }
  if (!xioRegQueueGpu(cq_virt, cq_size_aligned, cq_is_device,
                      "completion queue", &cq_userptr)) {
    goto cleanup;
  }

  // Step 2: Register with HIP
  // Skip hipHostRegister if:
  // 1. Memory was allocated with hipHostMallocCoherent (already registered)
  // 2. Memory is device memory (allocated via HSA, already GPU-accessible)
  if (!sq_uses_coherent && !sq_is_device) {
    sq_hip_err = hipHostRegister(sq_virt, sq_size_bytes, hipHostRegisterMapped);
    if (sq_hip_err != hipSuccess) {
      fprintf(stdout, "Warning: Failed to register SQ with HIP: %s\n",
              hipGetErrorString(sq_hip_err));
      ret = -EIO;
      goto cleanup;
    }
  }

  if (!cq_uses_coherent && !cq_is_device) {
    cq_hip_err = hipHostRegister(cq_virt, cq_size_bytes, hipHostRegisterMapped);
    if (cq_hip_err != hipSuccess) {
      fprintf(stdout, "Warning: Failed to register CQ with HIP: %s\n",
              hipGetErrorString(cq_hip_err));
      if (!sq_uses_coherent && !sq_is_device) {
        (void)hipHostUnregister(sq_virt); // Ignore return value in cleanup
      }
      ret = -EIO;
      goto cleanup;
    }
  }

  // Step 3: Get GPU pointers
  sq_gpu = xioGetGpuPointer(sq_virt, sq_is_device, "submission queue");
  if (!sq_gpu) {
    if (!sq_uses_coherent) {
      (void)hipHostUnregister(sq_virt); // Ignore return value in cleanup
    }
    if (!cq_uses_coherent && !cq_is_device) {
      (void)hipHostUnregister(cq_virt); // Ignore return value in cleanup
    }
    ret = -EIO;
    goto cleanup;
  }

  cq_gpu = xioGetGpuPointer(cq_virt, cq_is_device, "completion queue");
  if (!cq_gpu) {
    if (!sq_uses_coherent && !sq_is_device) {
      (void)hipHostUnregister(sq_virt); // Ignore return value in cleanup
    }
    if (!cq_uses_coherent) {
      (void)hipHostUnregister(cq_virt); // Ignore return value in cleanup
    }
    ret = -EIO;
    goto cleanup;
  }

  fprintf(
    stdout,
    "Info: Queues registered with GPU: SQ=%p (host=%p), CQ=%p (host=%p)\n",
    sq_gpu, sq_virt, cq_gpu, cq_virt);

  // Get physical addresses for queues
  sq_phys = xioGetPhysAddr(sq_virt, sq_size_bytes, sq_is_device, nvme_bdf,
                           kernel_module_device, is_emulated,
                           "submission queue");
  if (sq_phys == 0 && sq_is_device) {
    ret = -ENOTSUP;
    goto cleanup;
  }

  cq_phys = xioGetPhysAddr(cq_virt, cq_size_bytes, cq_is_device, nvme_bdf,
                           kernel_module_device, is_emulated,
                           "completion queue");
  if (cq_phys == 0 && cq_is_device) {
    ret = -ENOTSUP;
    goto cleanup;
  }

  // Register queue addresses with kernel module for kprobe injection
  ret = xioKmodRegQueue(kmod_fd, sq_virt, sq_phys, sq_size_bytes, 0,
                        "submission queue");
  if (ret < 0) {
    goto cleanup;
  }

  ret = xioKmodRegQueue(kmod_fd, cq_virt, cq_phys, cq_size_bytes, 1,
                        "completion queue");
  if (ret < 0) {
    goto cleanup;
  }

  // Delete existing queues if they exist
  deleteQueue(nvme_fd, queue_id);

  // Create queues via NVMe admin commands
  ret = createQueueCommands(nvme_fd, queue_id, queue_size, sq_virt, cq_virt);
  if (ret < 0) {
    goto cleanup;
  }

  // Calculate doorbell address
  // Doorbell base is typically at BAR0 + 0x1000
  // SQ doorbell: DB_BASE + (2 * qid * doorbell_stride)
  // For now, we'll set a placeholder - caller should get this from device info
  info->doorbell = 0; // TODO: Get from device info

  // Fill output structure
  info->sq_virt = sq_virt;
  info->cq_virt = cq_virt;
  info->sq_gpu = sq_gpu; // GPU-accessible pointer for kernel launch
  info->cq_gpu = cq_gpu; // GPU-accessible pointer for kernel launch
  info->sq_phys = sq_phys;
  info->cq_phys = cq_phys;
  info->sq_dmabuf_fd = -1; // Not currently used
  info->cq_dmabuf_fd = -1; // Not currently used

  close(nvme_fd);
  close(kmod_fd);
  return 0;

cleanup:
  // Unregister from HIP if we registered (non-coherent, non-device
  // allocations)
  if (sq_virt && !sq_uses_coherent && !sq_is_device &&
      sq_hip_err == hipSuccess) {
    (void)hipHostUnregister(sq_virt); // Ignore return value in cleanup
  }
  if (cq_virt && !cq_uses_coherent && !cq_is_device &&
      cq_hip_err == hipSuccess) {
    (void)hipHostUnregister(cq_virt); // Ignore return value in cleanup
  }

  // Free queues - handle coherent allocation separately
  if (sq_virt) {
    if (sq_uses_coherent) {
      // Free HIP coherent memory
      (void)hipHostFree(sq_virt);
    } else {
      // Free using standard free function
      xioFreeQueue(sq_virt, sq_is_device, "submission queue");
    }
  }
  if (cq_virt) {
    if (cq_uses_coherent) {
      // Free HIP coherent memory
      (void)hipHostFree(cq_virt);
    } else {
      // Free using standard free function
      xioFreeQueue(cq_virt, cq_is_device, "completion queue");
    }
  }
  if (nvme_fd >= 0) {
    close(nvme_fd);
  }
  if (kmod_fd >= 0) {
    close(kmod_fd);
  }
  return ret;
}

} // namespace nvme_ep

#endif // __HIP_DEVICE_COMPILE__
