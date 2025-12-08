/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef SDMA_EP_H
#define SDMA_EP_H

#include <cstdint>

#include <hip/hip_runtime.h>

/*
 * SDMA (System DMA) Endpoint
 *
 * This endpoint simulates AMD SDMA engine operations for DMA transfers.
 * SDMA packets are used to perform memory-to-memory copies, fills, and
 * other DMA operations on AMD GPUs.
 *
 * Reference: Based on sdma_queue_struct.h and AMD SDMA specifications
 */

// Magic ID for sdma-ep queue entries
#define SDMA_EP_MAGIC_ID 0xF2

// SDMA endpoint queue entry sizes
// SDMA packets are typically 16-32 bytes depending on operation type
// Using 32 bytes for SQE to accommodate various SDMA packet types
// Using 16 bytes for CQE for status and completion information
#define SDMA_EP_SQE_SIZE 32 // SDMA Submission Queue Entry: 32 bytes
#define SDMA_EP_CQE_SIZE 16 // SDMA Completion Queue Entry: 16 bytes

//
// SDMA Opcodes (simplified subset)
// Reference: AMD SDMA engine specifications
//
#define SDMA_OP_NOP 0x00       // No operation
#define SDMA_OP_COPY 0x01      // Linear memory copy
#define SDMA_OP_WRITE 0x02     // Direct write
#define SDMA_OP_FENCE 0x05     // Memory fence
#define SDMA_OP_POLL 0x08      // Poll memory location
#define SDMA_OP_COND_EXE 0x09  // Conditional execution
#define SDMA_OP_ATOMIC 0x0A    // Atomic operation
#define SDMA_OP_TIMESTAMP 0x0D // Get timestamp
#define SDMA_OP_PTEPDE 0x12    // PTE/PDE update

//
// SDMA Status Codes
//
#define SDMA_STATUS_SUCCESS 0x00
#define SDMA_STATUS_ERROR 0x01
#define SDMA_STATUS_PAGE_FAULT 0x02
#define SDMA_STATUS_TIMEOUT 0x03
#define SDMA_STATUS_INVALID_OP 0x04

//
// SDMA Submission Queue Entry (32 bytes)
// Simplified SDMA packet structure for basic operations
//
struct sdma_sqe {
  // Header (8 bytes)
  uint32_t opcode : 8;     // SDMA opcode
  uint32_t sub_opcode : 8; // Sub-opcode for specific variants
  uint32_t flags : 16;     // Control flags
  uint32_t count;          // Transfer size or operation count

  // Source and Destination (16 bytes)
  uint64_t src_addr; // Source address
  uint64_t dst_addr; // Destination address

  // Command-specific fields (8 bytes)
  uint32_t command_id; // Command identifier for tracking
  uint32_t reserved;   // Reserved for future use
} __attribute__((packed));

//
// SDMA Completion Queue Entry (16 bytes)
// Reports completion status of SDMA operations
//
struct sdma_cqe {
  uint32_t command_id; // Matches command_id from SQE
  uint32_t status;     // Status code (SDMA_STATUS_*)
  uint64_t timestamp;  // Completion timestamp
} __attribute__((packed));

//
// Helper functions to create SDMA commands
//

// Create an SDMA Copy command
__host__ __device__ static inline void sdma_sqe_setup_copy(struct sdma_sqe* sqe,
                                                           uint32_t cmd_id,
                                                           uint64_t src,
                                                           uint64_t dst,
                                                           uint32_t size) {
  sqe->opcode = SDMA_OP_COPY;
  sqe->sub_opcode = 0;
  sqe->flags = 0;
  sqe->count = size;
  sqe->src_addr = src;
  sqe->dst_addr = dst;
  sqe->command_id = cmd_id;
  sqe->reserved = 0;
}

// Create an SDMA Write command
__host__ __device__ static inline void sdma_sqe_setup_write(
  struct sdma_sqe* sqe, uint32_t cmd_id, uint64_t dst, uint32_t value) {
  sqe->opcode = SDMA_OP_WRITE;
  sqe->sub_opcode = 0;
  sqe->flags = 0;
  sqe->count = sizeof(uint32_t);
  sqe->src_addr = value; // Value stored in src_addr for write operations
  sqe->dst_addr = dst;
  sqe->command_id = cmd_id;
  sqe->reserved = 0;
}

// Create an SDMA Fence command
__host__ __device__ static inline void sdma_sqe_setup_fence(
  struct sdma_sqe* sqe, uint32_t cmd_id) {
  sqe->opcode = SDMA_OP_FENCE;
  sqe->sub_opcode = 0;
  sqe->flags = 0;
  sqe->count = 0;
  sqe->src_addr = 0;
  sqe->dst_addr = 0;
  sqe->command_id = cmd_id;
  sqe->reserved = 0;
}

// Create an SDMA Timestamp command
__host__ __device__ static inline void sdma_sqe_setup_timestamp(
  struct sdma_sqe* sqe, uint32_t cmd_id, uint64_t dst) {
  sqe->opcode = SDMA_OP_TIMESTAMP;
  sqe->sub_opcode = 0;
  sqe->flags = 0;
  sqe->count = sizeof(uint64_t);
  sqe->src_addr = 0;
  sqe->dst_addr = dst;
  sqe->command_id = cmd_id;
  sqe->reserved = 0;
}

//
// Helper functions for completion queue entries
//

// Check if SDMA operation completed successfully
__host__ __device__ static inline bool sdma_cqe_ok(const struct sdma_cqe* cqe) {
  return cqe->status == SDMA_STATUS_SUCCESS;
}

// Get status code from CQE
__host__ __device__ static inline uint32_t sdma_cqe_status(
  const struct sdma_cqe* cqe) {
  return cqe->status;
}

// Create a successful completion entry
__host__ __device__ static inline void sdma_cqe_setup_success(
  struct sdma_cqe* cqe, uint32_t cmd_id, uint64_t timestamp) {
  cqe->command_id = cmd_id;
  cqe->status = SDMA_STATUS_SUCCESS;
  cqe->timestamp = timestamp;
}

// Create an error completion entry
__host__ __device__ static inline void sdma_cqe_setup_error(
  struct sdma_cqe* cqe, uint32_t cmd_id, uint32_t status_code,
  uint64_t timestamp) {
  cqe->command_id = cmd_id;
  cqe->status = status_code;
  cqe->timestamp = timestamp;
}

#endif // SDMA_EP_H
