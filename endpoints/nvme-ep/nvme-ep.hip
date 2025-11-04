/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstring>
#include <iostream>

#include <hip/hip_runtime.h>

#include "axiio-endpoints.h"
#include "nvme-ep.h"

// Namespace all nvme-ep implementation to avoid conflicts
namespace nvme_ep {

// Use types from axiio-endpoints.h (generic queue structures)
typedef sqeType_s sqeType;
typedef cqeType_s cqeType;

// Static assert to ensure our queue types can hold NVMe structures
static_assert(sizeof(sqeType) >= sizeof(struct nvme_sqe),
              "sqeType must be at least 64 bytes for NVMe SQE");
static_assert(sizeof(cqeType) >= sizeof(struct nvme_cqe),
              "cqeType must be at least 16 bytes for NVMe CQE");

// Verify that the queue entry sizes match nvme-ep expectations
static_assert(sizeof(sqeType) == NVME_EP_SQE_SIZE, "nvme-ep SQE size mismatch");
static_assert(sizeof(cqeType) == NVME_EP_CQE_SIZE, "nvme-ep CQE size mismatch");

//
// NVMe-specific helper functions
//

// Extract NVMe SQE from generic sqeType
__host__ __device__ static inline struct nvme_sqe* nvme_sqe_from_generic(
  sqeType* sqe) {
  return reinterpret_cast<struct nvme_sqe*>(sqe);
}

// Extract NVMe CQE from generic cqeType
__host__ __device__ static inline struct nvme_cqe* nvme_cqe_from_generic(
  cqeType* cqe) {
  return reinterpret_cast<struct nvme_cqe*>(cqe);
}

// Extract const NVMe SQE from generic sqeType
__host__ __device__ static inline const struct nvme_sqe*
nvme_sqe_from_generic_const(const sqeType* sqe) {
  return reinterpret_cast<const struct nvme_sqe*>(sqe);
}

// Extract const NVMe CQE from generic cqeType
__host__ __device__ static inline const struct nvme_cqe*
nvme_cqe_from_generic_const(const cqeType* cqe) {
  return reinterpret_cast<const struct nvme_cqe*>(cqe);
}

// Compare two NVMe SQEs by command ID
__host__ __device__ bool nvme_sqe_equal(const sqeType* a, const sqeType* b) {
  const struct nvme_sqe* sqe_a = nvme_sqe_from_generic_const(a);
  const struct nvme_sqe* sqe_b = nvme_sqe_from_generic_const(b);
  return (sqe_a->command_id == sqe_b->command_id &&
          sqe_a->opcode == sqe_b->opcode);
}

// Compare two NVMe CQEs by command ID
__host__ __device__ bool nvme_cqe_equal(const cqeType* a, const cqeType* b) {
  const struct nvme_cqe* cqe_a = nvme_cqe_from_generic_const(a);
  const struct nvme_cqe* cqe_b = nvme_cqe_from_generic_const(b);
  return (cqe_a->command_id == cqe_b->command_id);
}

// Helper function to compare sqeType structs (legacy compatibility)
__host__ __device__ bool sqeEqual(const sqeType* a, const sqeType* b) {
  return nvme_sqe_equal(a, b);
}

// Helper function to compare cqeType structs (legacy compatibility)
__host__ __device__ bool cqeEqual(const cqeType* a, const cqeType* b) {
  return nvme_cqe_equal(a, b);
}

// Read SQE - copies entire NVMe command structure
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

// Read CQE - copies entire NVMe completion structure
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

// Write SQE - copies entire NVMe command structure with memory fence
__host__ __device__ void sqeWrite(sqeType sqeData, sqeType* sqeAddress) {
  // Copy entire structure
  const uint8_t* src = reinterpret_cast<const uint8_t*>(&sqeData);
  uint8_t* dst = reinterpret_cast<uint8_t*>(sqeAddress);
  for (size_t i = 0; i < sizeof(sqeType); i++) {
    dst[i] = src[i];
  }
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif // __HIP_DEVICE_COMPILE__
}

// Write CQE - copies entire NVMe completion structure with memory fence
__host__ __device__ void cqeWrite(cqeType cqeData, cqeType* cqeAddress) {
  // Copy entire structure
  const uint8_t* src = reinterpret_cast<const uint8_t*>(&cqeData);
  uint8_t* dst = reinterpret_cast<uint8_t*>(cqeAddress);
  for (size_t i = 0; i < sizeof(cqeType); i++) {
    dst[i] = src[i];
  }
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif // __HIP_DEVICE_COMPILE__
}

// Poll for new SQE - waits for command ID to change
__host__ __device__ sqeType sqePoll(sqeType sqeLast,
                                    volatile sqeType* sqeAddress) {
  sqeType sqeNew;
  while (true) {
    sqeNew = sqeRead(sqeAddress);
    const struct nvme_sqe* nvme_new = nvme_sqe_from_generic_const(&sqeNew);
    const struct nvme_sqe* nvme_last = nvme_sqe_from_generic_const(&sqeLast);

    // Check if we got a new command (different command ID or different opcode)
    if (nvme_new->command_id != nvme_last->command_id ||
        nvme_new->opcode != nvme_last->opcode) {
      return sqeNew;
    }
  }
}

// Poll for new CQE - waits for command ID to change
__host__ __device__ cqeType cqePoll(cqeType cqeLast,
                                    volatile cqeType* cqeAddress) {
  cqeType cqeNew;
  while (true) {
    cqeNew = cqeRead(cqeAddress);
    const struct nvme_cqe* nvme_new = nvme_cqe_from_generic_const(&cqeNew);
    const struct nvme_cqe* nvme_last = nvme_cqe_from_generic_const(&cqeLast);

    // Check if we got a new completion (different command ID)
    if (nvme_new->command_id != nvme_last->command_id) {
      return cqeNew;
    }
  }
}

// Generate a completion entry from a submission entry
// This simulates NVMe controller behavior for testing
__host__ __device__ cqeType cqeGenFromSqe(const sqeType* sqeData) {
  cqeType result = {}; // Zero initialize

  const struct nvme_sqe* sqe = nvme_sqe_from_generic_const(sqeData);
  struct nvme_cqe* cqe = nvme_cqe_from_generic(&result);

  // Set command ID to match the SQE
  cqe->command_id = sqe->command_id;

  // Set result based on command type (simulated behavior)
  switch (sqe->opcode) {
    case NVME_CMD_READ:
    case NVME_CMD_WRITE:
      // For read/write, result could be number of blocks transferred
      cqe->result = sqe->cdw12 + 1; // NLB is 0-based
      break;
    case NVME_CMD_FLUSH:
      cqe->result = 0;
      break;
    default:
      cqe->result = 0;
      break;
  }

  // Set status to success (Phase=1, SC=0, SCT=0)
  cqe->status = NVME_STATUS_MAKE(1, NVME_SC_SUCCESS, NVME_SCT_GENERIC);

  // Set SQ head/ID (for testing, just mirror command ID)
  cqe->sq_head = sqe->command_id;
  cqe->sq_id = 0;

  return result;
}

__host__ __device__ unsigned long long int wall_clock64() {
#ifdef __HIP_DEVICE_COMPILE__
  return __builtin_readcyclecounter();
#else
  return 0;
#endif
}

} // namespace nvme_ep

// Export nvme-ep functions for runtime dispatch
extern "C" {

//
// Emulate Endpoint - Acts as NVMe controller
// Polls for SQEs from the GPU, generates CQEs in response
//
// Note: This version doesn't access data buffers - it just processes commands
// For real hardware testing, the actual NVMe controller handles data transfer
//
__host__ __device__ void nvme_ep_emulateEndpoint(unsigned sqeIterations,
                                                 sqeType_s* sqeAddr,
                                                 cqeType_s* cqeAddr) {
  nvme_ep::sqeType sqeNew = {};
  nvme_ep::sqeType sqeOld = {};
  nvme_ep::cqeType cqeLocal = {}; // Zero-initialize

  // Read initial queue state to sync with tester initialization
  sqeOld = nvme_ep::sqeRead((volatile nvme_ep::sqeType*)sqeAddr);
  cqeLocal = nvme_ep::cqeRead((volatile nvme_ep::cqeType*)cqeAddr);

  struct nvme_sqe* sqe_old = nvme_ep::nvme_sqe_from_generic(&sqeOld);

  // If queue is zero-initialized, set to expect first command (ID = 1)
  if (sqe_old->command_id == 0 && sqe_old->opcode == 0) {
    sqe_old->command_id = 0; // Keep as 0 to detect change to 1
    sqe_old->opcode = 0;
  }

  unsigned commands_processed = 0;

  // Keep processing commands until we get the stop command
  while (true) {
    // Poll for new command from GPU
    sqeNew = nvme_ep::sqePoll(sqeOld, (volatile nvme_ep::sqeType*)sqeAddr);

    const struct nvme_sqe* sqe_new = nvme_ep::nvme_sqe_from_generic_const(
      &sqeNew);

    // Check for stop command (opcode 0xFF)
    if (sqe_new->opcode == 0xFF) {
      break;
    }

    // Generate completion for this command
    cqeLocal = nvme_ep::cqeGenFromSqe(&sqeNew);

    // Write completion back
    nvme_ep::cqeWrite(cqeLocal, (nvme_ep::cqeType*)cqeAddr);

    // Update old to current for next poll
    sqeOld = sqeNew;
    commands_processed++;

    // Safety check - if we've processed way more than expected, something is
    // wrong
    if (commands_processed > sqeIterations * 2) {
      break;
    }
  }
}

//
// Drive Endpoint (with data buffers) - Acts as NVMe host driver
// Issues NVMe commands from GPU and waits for completions
//
// This version accepts data buffers for real I/O testing
// If readBuffer/writeBuffer are NULL, uses dummy PRP addresses
//
__device__ void nvme_ep_driveEndpointWithBuffers(
  unsigned sqeIterations, sqeType_s* sqeAddr, cqeType_s* cqeAddr,
  unsigned long long int* startTime, unsigned long long int* endTime,
  uint8_t* readBuffer, uint8_t* writeBuffer, size_t bufferSize,
  uint32_t blockSize, enum nvme_test_pattern pattern) {
  nvme_ep::sqeType sqeLocal = {};
  nvme_ep::cqeType cqeLocal = {};

  struct nvme_sqe* sqe = nvme_ep::nvme_sqe_from_generic(&sqeLocal);
  struct nvme_cqe* cqe = nvme_ep::nvme_cqe_from_generic(&cqeLocal);

  // Initialize CQE with invalid command ID for first poll
  cqe->command_id = 0xFFFF;

  // Test parameters
  const uint32_t nsid = 1;          // Namespace ID
  const uint64_t base_lba = 0x1000; // Starting LBA
  const uint32_t blocks = 8;        // Number of blocks per operation

  // Calculate buffer size per command (blocks * block_size)
  const size_t transfer_size = blocks * blockSize;

  // Use real buffers if provided
  const bool use_real_buffers = (readBuffer != nullptr &&
                                 writeBuffer != nullptr && bufferSize > 0);

  // If using real buffers, generate write data
  if (use_real_buffers && writeBuffer) {
    // Generate test pattern in write buffer
    nvme_generate_pattern(writeBuffer, bufferSize, pattern, 0);
  }

  // Issue read/write commands
  for (unsigned i = 0; i < sqeIterations; i++) {
    // Start command IDs at 1 to avoid confusion with zero-initialized memory
    uint16_t cmd_id = (uint16_t)(i + 1);
    uint64_t lba = base_lba + (i * blocks);

    uint64_t prp1, prp2;

    // Alternate between read and write commands
    if (i % 2 == 0) {
      // Issue Read command
      if (use_real_buffers) {
        // Calculate PRPs from read buffer
        uint64_t buffer_offset = (i / 2) * transfer_size;
        if (buffer_offset + transfer_size <= bufferSize) {
          nvme_calculate_prps((uint64_t)(readBuffer + buffer_offset),
                              transfer_size, &prp1, &prp2);
        } else {
          // Buffer overflow - use dummy addresses
          prp1 = 0xDEADBEEF00000000ULL;
          prp2 = 0xCAFEBABE00000000ULL;
        }
      } else {
        // No buffers - use dummy addresses
        prp1 = 0xDEADBEEF00000000ULL;
        prp2 = 0xCAFEBABE00000000ULL;
      }

      nvme_sqe_setup_read(sqe, cmd_id, nsid, lba, blocks, prp1, prp2);
    } else {
      // Issue Write command
      if (use_real_buffers) {
        // Calculate PRPs from write buffer
        uint64_t buffer_offset = (i / 2) * transfer_size;
        if (buffer_offset + transfer_size <= bufferSize) {
          nvme_calculate_prps((uint64_t)(writeBuffer + buffer_offset),
                              transfer_size, &prp1, &prp2);
        } else {
          // Buffer overflow - use dummy addresses
          prp1 = 0xDEADBEEF00000000ULL;
          prp2 = 0xCAFEBABE00000000ULL;
        }
      } else {
        // No buffers - use dummy addresses
        prp1 = 0xDEADBEEF00000000ULL;
        prp2 = 0xCAFEBABE00000000ULL;
      }

      nvme_sqe_setup_write(sqe, cmd_id, nsid, lba, blocks, prp1, prp2);
    }

    // Record start time
    startTime[i] = nvme_ep::wall_clock64();

    // Submit command to queue
    nvme_ep::sqeWrite(sqeLocal, (nvme_ep::sqeType*)sqeAddr);

    // Poll for completion
    cqeLocal = nvme_ep::cqePoll(cqeLocal, (volatile nvme_ep::cqeType*)cqeAddr);

    // Record end time
    endTime[i] = nvme_ep::wall_clock64();

    // Verify completion matches our command
    const struct nvme_cqe* cqe_result = nvme_ep::nvme_cqe_from_generic_const(
      &cqeLocal);
    if (cqe_result->command_id != cmd_id) {
      // Command ID mismatch - could indicate error
      // In a real implementation, would handle this error
    }

    // Check if command succeeded
    if (!nvme_cqe_ok(cqe_result)) {
      // Command failed - could indicate error
      // In a real implementation, would handle this error
    }

    // For read commands with real buffers, verify data
    if (use_real_buffers && (i % 2 == 0) && readBuffer) {
      uint64_t buffer_offset = (i / 2) * transfer_size;
      if (buffer_offset + transfer_size <= bufferSize) {
        size_t error_offset;
        if (!nvme_verify_pattern(readBuffer + buffer_offset, transfer_size,
                                 pattern, buffer_offset, &error_offset)) {
          // Data verification failed
          // In a real implementation, would handle this error
        }
      }
    }
  }

  // Send stop command (opcode 0xFF) to signal emulator to exit
  sqe->opcode = 0xFF;
  sqe->command_id = 0xFFFF;
  sqe->nsid = 0;
  nvme_ep::sqeWrite(sqeLocal, (nvme_ep::sqeType*)sqeAddr);
}

//
// Drive Endpoint (backward compatible) - Acts as NVMe host driver
// This version uses dummy PRP addresses for backward compatibility
//
__device__ void nvme_ep_driveEndpoint(unsigned sqeIterations,
                                      sqeType_s* sqeAddr, cqeType_s* cqeAddr,
                                      unsigned long long int* startTime,
                                      unsigned long long int* endTime) {
  // Call the buffer-aware version with NULL pointers (dummy mode)
  nvme_ep_driveEndpointWithBuffers(sqeIterations, sqeAddr, cqeAddr, startTime,
                                   endTime, nullptr, nullptr, 0, 512,
                                   NVME_PATTERN_SEQUENTIAL);
}

} // extern "C"
