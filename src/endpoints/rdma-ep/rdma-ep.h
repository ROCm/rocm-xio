/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef RDMA_EP_H
#define RDMA_EP_H

#include <cstdint>
#include <string>

#include <hip/hip_runtime.h>

/*
 * RDMA (Remote Direct Memory Access) Endpoint
 *
 * This endpoint simulates RDMA operations with support for multiple
 * hardware vendors:
 * - MLX5 (Mellanox/NVIDIA ConnectX-5 and later)
 * - BNXT_RE (Broadcom NetXtreme RDMA)
 * - IONIC (Pensando Ionic RDMA)
 * - PVRDMA (VMware Paravirtualized RDMA)
 *
 * Reference: Based on linux-rdma/rdma-core repository
 * Downloaded headers in include/external/rdma/ for reference
 */

// Magic ID for rdma-ep queue entries
#define RDMA_EP_MAGIC_ID 0xF3

// RDMA endpoint queue entry sizes
// RDMA WQE (Work Queue Entry) typically 64 bytes
// RDMA CQE (Completion Queue Entry) typically 32-64 bytes depending on vendor
#define RDMA_EP_SQE_SIZE 64 // RDMA Work Queue Entry (WQE): 64 bytes
#define RDMA_EP_CQE_SIZE 64 // RDMA Completion Queue Entry (CQE): 64 bytes

//
// RDMA Vendor Types
//
enum class RDMAVendor : uint8_t {
  MLX5 = 0,    // Mellanox/NVIDIA ConnectX
  BNXT_RE = 1, // Broadcom NetXtreme
  IONIC = 2,   // Pensando Ionic RDMA
  PVRDMA = 3,  // VMware Paravirtualized RDMA
  UNKNOWN = 0xFF
};

//
// RDMA Operation Types (WQE opcodes)
// Based on IB verbs operations
//
#define RDMA_OP_SEND 0x00             // Send operation
#define RDMA_OP_SEND_IMM 0x01         // Send with immediate data
#define RDMA_OP_RDMA_WRITE 0x08       // RDMA Write
#define RDMA_OP_RDMA_WRITE_IMM 0x09   // RDMA Write with immediate
#define RDMA_OP_RDMA_READ 0x10        // RDMA Read
#define RDMA_OP_ATOMIC_CMP_SWP 0x11   // Atomic compare and swap
#define RDMA_OP_ATOMIC_FETCH_ADD 0x12 // Atomic fetch and add

//
// RDMA Completion Status
//
#define RDMA_WC_SUCCESS 0x00
#define RDMA_WC_LOC_LEN_ERR 0x01
#define RDMA_WC_LOC_QP_OP_ERR 0x02
#define RDMA_WC_LOC_PROT_ERR 0x03
#define RDMA_WC_WR_FLUSH_ERR 0x04
#define RDMA_WC_REM_ACCESS_ERR 0x10
#define RDMA_WC_REM_OP_ERR 0x11
#define RDMA_WC_RETRY_EXC_ERR 0x12
#define RDMA_WC_RNR_RETRY_EXC_ERR 0x13

//
// RDMA Work Queue Entry (WQE) - Submission Queue Entry
// Abstracted structure representing RDMA work requests
//
struct rdma_wqe {
  // Control segment
  uint8_t opcode;  // RDMA operation type
  uint8_t vendor;  // RDMAVendor type
  uint16_t wqe_id; // Work queue entry ID
  uint32_t length; // Transfer length in bytes

  // Address segment
  uint64_t local_addr;  // Local memory address
  uint64_t remote_addr; // Remote memory address (for RDMA ops)
  uint32_t lkey;        // Local memory key
  uint32_t rkey;        // Remote memory key

  // Immediate data / atomic operands
  union {
    uint32_t imm_data;    // Immediate data for SEND_IMM/WRITE_IMM
    uint64_t compare_add; // For atomic operations
  };

  // Reserved for vendor-specific extensions
  uint64_t vendor_specific;
  uint8_t pad[16]; // Padding to match RDMA_EP_SQE_SIZE (64 - 48 = 16)
} __attribute__((packed));

//
// RDMA Completion Queue Entry (CQE)
// Reports completion status of WQEs
//
struct rdma_cqe {
  uint16_t wqe_id;    // Matches WQE ID
  uint8_t vendor;     // RDMAVendor type
  uint8_t status;     // Completion status (RDMA_WC_*)
  uint32_t byte_len;  // Number of bytes transferred
  uint32_t imm_data;  // Immediate data (if present)
  uint64_t timestamp; // Completion timestamp

  // Vendor-specific fields
  union {
    struct {
      uint32_t src_qp; // Source QP number (for MLX5)
      uint32_t flags;  // Completion flags
    } mlx5;
    struct {
      uint32_t sq_cons_idx; // SQ consumer index (for BNXT)
      uint32_t cq_cons_idx; // CQ consumer index
    } bnxt;
    struct {
      uint32_t qpn; // Queue pair number (for IONIC)
      uint32_t reserved;
    } ionic;
    struct {
      uint32_t qpn; // Queue pair number (for PVRDMA)
      uint32_t reserved;
    } pvrdma;
    uint64_t vendor_data;
  };

  uint64_t reserved; // Reserved for alignment
  uint8_t pad[28];   // Padding to match RDMA_EP_CQE_SIZE (64 - 36 = 28)
} __attribute__((packed));

//
// Helper functions to create RDMA commands
//

// Create an RDMA SEND operation
__host__ __device__ static inline void rdma_wqe_setup_send(
  struct rdma_wqe* wqe, uint16_t wqe_id, RDMAVendor vendor, uint64_t local_addr,
  uint32_t length, uint32_t lkey) {
  wqe->opcode = RDMA_OP_SEND;
  wqe->vendor = static_cast<uint8_t>(vendor);
  wqe->wqe_id = wqe_id;
  wqe->length = length;
  wqe->local_addr = local_addr;
  wqe->remote_addr = 0;
  wqe->lkey = lkey;
  wqe->rkey = 0;
  wqe->imm_data = 0;
  wqe->vendor_specific = 0;
}

// Create an RDMA WRITE operation
__host__ __device__ static inline void rdma_wqe_setup_write(
  struct rdma_wqe* wqe, uint16_t wqe_id, RDMAVendor vendor, uint64_t local_addr,
  uint64_t remote_addr, uint32_t length, uint32_t lkey, uint32_t rkey) {
  wqe->opcode = RDMA_OP_RDMA_WRITE;
  wqe->vendor = static_cast<uint8_t>(vendor);
  wqe->wqe_id = wqe_id;
  wqe->length = length;
  wqe->local_addr = local_addr;
  wqe->remote_addr = remote_addr;
  wqe->lkey = lkey;
  wqe->rkey = rkey;
  wqe->imm_data = 0;
  wqe->vendor_specific = 0;
}

// Create an RDMA READ operation
__host__ __device__ static inline void rdma_wqe_setup_read(
  struct rdma_wqe* wqe, uint16_t wqe_id, RDMAVendor vendor, uint64_t local_addr,
  uint64_t remote_addr, uint32_t length, uint32_t lkey, uint32_t rkey) {
  wqe->opcode = RDMA_OP_RDMA_READ;
  wqe->vendor = static_cast<uint8_t>(vendor);
  wqe->wqe_id = wqe_id;
  wqe->length = length;
  wqe->local_addr = local_addr;
  wqe->remote_addr = remote_addr;
  wqe->lkey = lkey;
  wqe->rkey = rkey;
  wqe->imm_data = 0;
  wqe->vendor_specific = 0;
}

//
// Helper functions for completion queue entries
//

// Check if RDMA operation completed successfully
__host__ __device__ static inline bool rdma_cqe_ok(const struct rdma_cqe* cqe) {
  return cqe->status == RDMA_WC_SUCCESS;
}

// Get status code from CQE
__host__ __device__ static inline uint8_t rdma_cqe_status(
  const struct rdma_cqe* cqe) {
  return cqe->status;
}

// Create a successful completion entry
__host__ __device__ static inline void rdma_cqe_setup_success(
  struct rdma_cqe* cqe, uint16_t wqe_id, RDMAVendor vendor, uint32_t byte_len,
  uint64_t timestamp) {
  cqe->wqe_id = wqe_id;
  cqe->vendor = static_cast<uint8_t>(vendor);
  cqe->status = RDMA_WC_SUCCESS;
  cqe->byte_len = byte_len;
  cqe->imm_data = 0;
  cqe->timestamp = timestamp;
  cqe->vendor_data = 0;
  cqe->reserved = 0;
}

// Create an error completion entry
__host__ __device__ static inline void rdma_cqe_setup_error(
  struct rdma_cqe* cqe, uint16_t wqe_id, RDMAVendor vendor, uint8_t status_code,
  uint64_t timestamp) {
  cqe->wqe_id = wqe_id;
  cqe->vendor = static_cast<uint8_t>(vendor);
  cqe->status = status_code;
  cqe->byte_len = 0;
  cqe->imm_data = 0;
  cqe->timestamp = timestamp;
  cqe->vendor_data = 0;
  cqe->reserved = 0;
}

// Get vendor name as string
__host__ __device__ static inline const char* rdma_vendor_name(
  RDMAVendor vendor) {
  switch (vendor) {
    case RDMAVendor::MLX5:
      return "MLX5";
    case RDMAVendor::BNXT_RE:
      return "BNXT_RE";
    case RDMAVendor::IONIC:
      return "IONIC";
    case RDMAVendor::PVRDMA:
      return "PVRDMA";
    default:
      return "UNKNOWN";
  }
}

//
// RDMA Endpoint Configuration Structure
//

namespace rdma_ep {

/**
 * RDMA Endpoint Configuration Structure
 *
 * Contains all RDMA-specific configuration options for the endpoint.
 */
struct RdmaEpConfig {
  unsigned iterations = 128;            // Number of RDMA operations
  std::string vendorStr = "mlx5";       // Vendor string (converted to enum)
  RDMAVendor vendor = RDMAVendor::MLX5; // Selected vendor (or UNKNOWN for
                                        // "all")
  bool emulate = false;                 // Emulation mode (no hardware)
  unsigned queueLength = 64;            // Queue length (power of 2)
  uint32_t transferSize = 4096;         // Transfer size per operation (bytes)
  // Future: Add vendor-specific options (QP number, doorbell address, etc.)
};

} // namespace rdma_ep

// Forward declaration for CLI::App (only needed in host code)
namespace CLI {
class App;
}

namespace rdma_ep {

/**
 * Register RDMA endpoint-specific CLI options
 *
 * @param app CLI11 App object to add options to
 * @param config Pointer to RdmaEpConfig structure to populate
 */
__host__ void registerCliOptions(CLI::App& app, RdmaEpConfig* config);

/**
 * Validate RDMA endpoint configuration
 *
 * @param config Pointer to RdmaEpConfig structure
 * @return Empty string if valid, error message otherwise
 */
__host__ std::string validateConfig(RdmaEpConfig* config);

/**
 * Get iterations count for RDMA endpoint
 *
 * @param endpointConfig Pointer to RdmaEpConfig structure
 * @return Number of iterations
 */
__host__ unsigned getIterations(void* endpointConfig);

// Type aliases for queue operations (matching rdma-ep.hip)
typedef struct rdma_wqe sqeType;
typedef struct rdma_cqe cqeType;

// Forward declarations for queue operations (defined in rdma-ep.hip)
// These are __host__ __device__ functions available for host code
__host__ __device__ bool sqeEqual(const sqeType* a, const sqeType* b);
__host__ __device__ bool cqeEqual(const cqeType* a, const cqeType* b);
__host__ __device__ sqeType sqeRead(volatile sqeType* sqeAddress);
__host__ __device__ cqeType cqeRead(volatile cqeType* cqeAddress);
__host__ __device__ void sqeWrite(sqeType sqeData, sqeType* sqeAddress);
__host__ __device__ void cqeWrite(cqeType cqeData, cqeType* cqeAddress);
__host__ __device__ cqeType cqeGenFromSqe(const sqeType* sqeData,
                                          uint64_t timestamp);

} // namespace rdma_ep

#endif // RDMA_EP_H
