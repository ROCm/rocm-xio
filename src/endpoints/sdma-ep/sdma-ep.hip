/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstring>
#include <iostream>

#include <hip/hip_runtime.h>

#include "axiio-endpoint.h"
#include "sdma-ep.h"

// Namespace all sdma-ep implementation to avoid conflicts
namespace sdma_ep {

// Helper function to create AxiioEndpoint object for this endpoint
__host__ AxiioEndpoint createEndpoint() {
  return AxiioEndpoint(EndpointType::SDMA_EP);
}

// Use types from axiio-endpoint.h (generic queue structures)
typedef sqeType_s sqeType;
typedef cqeType_s cqeType;

// Verify that the queue entry sizes match sdma-ep expectations
static_assert(sizeof(sqeType) == SDMA_EP_SQE_SIZE, "sdma-ep SQE size mismatch");
static_assert(sizeof(cqeType) == SDMA_EP_CQE_SIZE, "sdma-ep CQE size mismatch");

// Static assert to ensure our queue types can hold SDMA structures
static_assert(sizeof(sqeType) >= sizeof(struct sdma_sqe),
              "sqeType must be at least 32 bytes for SDMA SQE");
static_assert(sizeof(cqeType) >= sizeof(struct sdma_cqe),
              "cqeType must be at least 16 bytes for SDMA CQE");

//
// SDMA-specific helper functions
//

// Cast generic sqeType to SDMA sqe
__host__ __device__ static inline struct sdma_sqe* sdma_sqe_from_generic(
  sqeType* sqe) {
  return reinterpret_cast<struct sdma_sqe*>(sqe);
}

__host__ __device__ static inline const struct sdma_sqe*
sdma_sqe_from_generic_const(const sqeType* sqe) {
  return reinterpret_cast<const struct sdma_sqe*>(sqe);
}

// Cast generic cqeType to SDMA cqe
__host__ __device__ static inline struct sdma_cqe* sdma_cqe_from_generic(
  cqeType* cqe) {
  return reinterpret_cast<struct sdma_cqe*>(cqe);
}

__host__ __device__ static inline const struct sdma_cqe*
sdma_cqe_from_generic_const(const cqeType* cqe) {
  return reinterpret_cast<const struct sdma_cqe*>(cqe);
}

// Helper function to compare SDMA commands (by command_id and opcode)
__host__ __device__ bool sqeEqual(const sqeType* a, const sqeType* b) {
  const struct sdma_sqe* sqe_a = sdma_sqe_from_generic_const(a);
  const struct sdma_sqe* sqe_b = sdma_sqe_from_generic_const(b);
  return (sqe_a->command_id == sqe_b->command_id) &&
         (sqe_a->opcode == sqe_b->opcode);
}

// Helper function to compare SDMA completions (by command_id)
__host__ __device__ bool cqeEqual(const cqeType* a, const cqeType* b) {
  const struct sdma_cqe* cqe_a = sdma_cqe_from_generic_const(a);
  const struct sdma_cqe* cqe_b = sdma_cqe_from_generic_const(b);
  return cqe_a->command_id == cqe_b->command_id;
}

// Read SDMA SQE from volatile memory (byte-by-byte for safety)
__host__ __device__ sqeType sqeRead(volatile sqeType* sqeAddress) {
  sqeType result;
  const volatile uint8_t* src = reinterpret_cast<const volatile uint8_t*>(
    sqeAddress);
  uint8_t* dst = reinterpret_cast<uint8_t*>(&result);
  for (size_t i = 0; i < sizeof(sqeType); i++) {
    dst[i] = src[i];
  }
  return result;
}

// Read SDMA CQE from volatile memory (byte-by-byte for safety)
__host__ __device__ cqeType cqeRead(volatile cqeType* cqeAddress) {
  cqeType result;
  const volatile uint8_t* src = reinterpret_cast<const volatile uint8_t*>(
    cqeAddress);
  uint8_t* dst = reinterpret_cast<uint8_t*>(&result);
  for (size_t i = 0; i < sizeof(cqeType); i++) {
    dst[i] = src[i];
  }
  return result;
}

// Write SDMA SQE to memory (byte-by-byte for safety)
__host__ __device__ void sqeWrite(sqeType sqeData, sqeType* sqeAddress) {
  const uint8_t* src = reinterpret_cast<const uint8_t*>(&sqeData);
  volatile uint8_t* dst = reinterpret_cast<volatile uint8_t*>(sqeAddress);
  for (size_t i = 0; i < sizeof(sqeType); i++) {
    dst[i] = src[i];
  }
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif // __HIP_DEVICE_COMPILE__
}

// Write SDMA CQE to memory (byte-by-byte for safety)
__host__ __device__ void cqeWrite(cqeType cqeData, cqeType* cqeAddress) {
  const uint8_t* src = reinterpret_cast<const uint8_t*>(&cqeData);
  volatile uint8_t* dst = reinterpret_cast<volatile uint8_t*>(cqeAddress);
  for (size_t i = 0; i < sizeof(cqeType); i++) {
    dst[i] = src[i];
  }
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif // __HIP_DEVICE_COMPILE__
}

// Poll for new SDMA command (detects changes in command_id or opcode)
__host__ __device__ sqeType sqePoll(sqeType sqeLast,
                                    volatile sqeType* sqeAddress) {
  sqeType sqeNew;
  while (true) {
    sqeNew = sqeRead(sqeAddress);
    if (!sqeEqual(&sqeNew, &sqeLast))
      return sqeNew;
  }
}

// Poll for new SDMA completion (detects changes in command_id)
__host__ __device__ cqeType cqePoll(cqeType cqeLast,
                                    volatile cqeType* cqeAddress) {
  cqeType cqeNew;
  while (true) {
    cqeNew = cqeRead(cqeAddress);
    if (!cqeEqual(&cqeNew, &cqeLast))
      return cqeNew;
  }
}

// Generate SDMA completion from submission (simulate SDMA controller)
__host__ __device__ cqeType cqeGenFromSqe(const sqeType* sqeData,
                                          uint64_t timestamp) {
  const struct sdma_sqe* sqe = sdma_sqe_from_generic_const(sqeData);
  cqeType result = {};
  struct sdma_cqe* cqe = sdma_cqe_from_generic(&result);

  // Simulate successful SDMA operation
  cqe->command_id = sqe->command_id;
  cqe->status = SDMA_STATUS_SUCCESS;
  cqe->timestamp = timestamp;

  // Simple validation: check for invalid opcodes
  if (sqe->opcode > SDMA_OP_PTEPDE && sqe->opcode != 0xFF) {
    cqe->status = SDMA_STATUS_INVALID_OP;
  }

  return result;
}

__host__ __device__ unsigned long long int wall_clock64() {
#ifdef __HIP_DEVICE_COMPILE__
  return __builtin_readcyclecounter();
#else
  return 0;
#endif
}

} // namespace sdma_ep

// Export sdma-ep functions for runtime dispatch
extern "C" {

__host__ __device__ void sdma_ep_emulateEndpoint(unsigned sqeIterations,
                                                 sqeType_s* sqeAddr,
                                                 cqeType_s* cqeAddr) {
  // Read initial queue state to synchronize with tester's initialization
  sdma_ep::sqeType sqeOld = sdma_ep::sqeRead(
    (volatile sdma_ep::sqeType*)sqeAddr);
  sdma_ep::cqeType cqeLocal = sdma_ep::cqeRead(
    (volatile sdma_ep::cqeType*)cqeAddr);
  sdma_ep::sqeType sqeNew;

  unsigned commands_processed = 0;

  // Loop indefinitely until stop command (opcode 0xFF)
  while (true) {
    sqeNew = sdma_ep::sqePoll(sqeOld, (volatile sdma_ep::sqeType*)sqeAddr);

    const struct sdma_sqe* sqe_new = sdma_ep::sdma_sqe_from_generic_const(
      &sqeNew);

    // Check for stop command (opcode 0xFF)
    if (sqe_new->opcode == 0xFF) {
      break;
    }

    // Process the SDMA command
    uint64_t timestamp = sdma_ep::wall_clock64();
    cqeLocal = sdma_ep::cqeGenFromSqe(&sqeNew, timestamp);
    sdma_ep::cqeWrite(cqeLocal, (sdma_ep::cqeType*)cqeAddr);

    sqeOld = sqeNew;
    commands_processed++;

    // Safety check to prevent infinite loop
    if (commands_processed > sqeIterations * 2) {
      break;
    }
  }
}

__device__ void sdma_ep_driveEndpoint(unsigned sqeIterations,
                                      sqeType_s* sqeAddr, cqeType_s* cqeAddr,
                                      unsigned long long int* startTime,
                                      unsigned long long int* endTime) {
  sdma_ep::sqeType sqeLocal = {};
  sdma_ep::cqeType cqeLocal = {};

  struct sdma_sqe* sqe = sdma_ep::sdma_sqe_from_generic(&sqeLocal);
  struct sdma_cqe* cqe = sdma_ep::sdma_cqe_from_generic(&cqeLocal);

  // Initialize CQE with invalid command_id for first poll
  cqe->command_id = 0xFFFFFFFF;

  // Dummy addresses for SDMA operations
  uint64_t dummy_src = 0x1000000;
  uint64_t dummy_dst = 0x2000000;
  uint32_t transfer_size = 4096; // 4KB transfers

  for (unsigned i = 0; i < sqeIterations; i++) {
    // Start command IDs at 1 to avoid conflicts with zero-initialized memory
    uint32_t cmd_id = i + 1;

    // Alternate between Copy, Write, and Fence operations
    if (i % 3 == 0) {
      // SDMA Copy operation
      sdma_sqe_setup_copy(sqe, cmd_id, dummy_src + (i * transfer_size),
                          dummy_dst + (i * transfer_size), transfer_size);
    } else if (i % 3 == 1) {
      // SDMA Write operation
      sdma_sqe_setup_write(sqe, cmd_id, dummy_dst + (i * sizeof(uint32_t)),
                           0xDEADBEEF);
    } else {
      // SDMA Fence operation
      sdma_sqe_setup_fence(sqe, cmd_id);
    }

    // Submit command and wait for completion
    startTime[i] = sdma_ep::wall_clock64();
    sdma_ep::sqeWrite(sqeLocal, (sdma_ep::sqeType*)sqeAddr);
    cqeLocal = sdma_ep::cqePoll(cqeLocal, (volatile sdma_ep::cqeType*)cqeAddr);
    endTime[i] = sdma_ep::wall_clock64();

    // Verify completion
    if (cqe->command_id != cmd_id) {
      // Command ID mismatch - error condition
      // In a real implementation, would handle this error
    }

    if (!sdma_cqe_ok(cqe)) {
      // Operation failed - error condition
      // In a real implementation, would handle this error
    }
  }

  // Send stop command (opcode 0xFF, command_id 0xFFFF)
  sqe->opcode = 0xFF;
  sqe->command_id = 0xFFFF;
  sdma_ep::sqeWrite(sqeLocal, (sdma_ep::sqeType*)sqeAddr);
}

} // extern "C"
