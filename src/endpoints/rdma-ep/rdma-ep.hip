/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstring>
#include <iostream>

#include <hip/hip_runtime.h>

#include "axiio-endpoint-config.h"
#include "axiio-endpoint.h"
#include "rdma-ep.h"

// Include vendor-specific headers
#include "bnxt/bnxt-rdma.h"
#include "ionic/ionic-rdma.h"
#include "mlx/mlx5-rdma.h"
#include "pvrdma/pvrdma-rdma.h"

/*
 * RDMA Endpoint Implementation
 *
 * This endpoint simulates RDMA operations across multiple vendors:
 * - MLX5 (Mellanox/NVIDIA ConnectX)
 * - BNXT_RE (Broadcom NetXtreme)
 * - IONIC (Pensando Ionic RDMA)
 * - PVRDMA (VMware Paravirtualized RDMA)
 *
 * Reference headers downloaded from linux-rdma/rdma-core:
 *   Run 'make fetch-rdma-headers' to download reference headers
 *   Headers location: include/external/rdma/
 *
 * The structures in rdma-ep.h are abstracted from the actual vendor
 * implementations found in the downloaded headers.
 */

// Namespace all rdma-ep implementation to avoid conflicts
namespace rdma_ep {

// Helper function to create AxiioEndpoint object for this endpoint
__host__ AxiioEndpoint createEndpoint() {
  return AxiioEndpoint(EndpointType::RDMA_EP);
}

// Use types from rdma-ep.h
typedef struct rdma_wqe sqeType;
typedef struct rdma_cqe cqeType;

// Verify that the queue entry sizes match rdma-ep expectations
static_assert(sizeof(sqeType) == RDMA_EP_SQE_SIZE, "rdma-ep SQE size mismatch");
static_assert(sizeof(cqeType) == RDMA_EP_CQE_SIZE, "rdma-ep CQE size mismatch");

// Static assert to ensure our queue types can hold RDMA structures
static_assert(sizeof(sqeType) >= sizeof(struct rdma_wqe),
              "sqeType must be at least 64 bytes for RDMA WQE");
static_assert(sizeof(cqeType) >= sizeof(struct rdma_cqe),
              "cqeType must be at least 64 bytes for RDMA CQE");

//
// RDMA-specific helper functions
//

// Helper function to compare RDMA commands (by wqe_id and opcode)
__host__ __device__ bool sqeEqual(const sqeType* a, const sqeType* b) {
  return (a->wqe_id == b->wqe_id) && (a->opcode == b->opcode);
}

// Helper function to compare RDMA completions (by wqe_id)
__host__ __device__ bool cqeEqual(const cqeType* a, const cqeType* b) {
  return a->wqe_id == b->wqe_id;
}

// Read RDMA WQE from volatile memory (byte-by-byte for safety)
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

// Read RDMA CQE from volatile memory (byte-by-byte for safety)
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

// Write RDMA WQE to memory (byte-by-byte for safety)
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

// Write RDMA CQE to memory (byte-by-byte for safety)
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

// Poll for new RDMA command (detects changes in wqe_id or opcode)
__host__ __device__ sqeType sqePoll(sqeType sqeLast,
                                    volatile sqeType* sqeAddress) {
  sqeType sqeNew;
  while (true) {
    sqeNew = sqeRead(sqeAddress);
    if (!sqeEqual(&sqeNew, &sqeLast))
      return sqeNew;
  }
}

// Poll for new RDMA completion (detects changes in wqe_id)
__host__ __device__ cqeType cqePoll(cqeType cqeLast,
                                    volatile cqeType* cqeAddress) {
  cqeType cqeNew;
  while (true) {
    cqeNew = cqeRead(cqeAddress);
    if (!cqeEqual(&cqeNew, &cqeLast))
      return cqeNew;
  }
}

// Generate RDMA completion from work request (simulate RDMA NIC)
__host__ __device__ cqeType cqeGenFromSqe(const sqeType* sqeData,
                                          uint64_t timestamp) {
  const sqeType* wqe = sqeData;
  cqeType result = {};
  struct rdma_cqe* cqe = &result; // cqeType is struct rdma_cqe

  // Simulate successful RDMA operation
  cqe->wqe_id = wqe->wqe_id;
  cqe->vendor = wqe->vendor;
  cqe->status = RDMA_WC_SUCCESS;
  cqe->byte_len = wqe->length;
  cqe->imm_data = 0;
  cqe->timestamp = timestamp;

  // Set vendor-specific fields based on vendor type
  RDMAVendor vendor = static_cast<RDMAVendor>(wqe->vendor);
  switch (vendor) {
    case RDMAVendor::MLX5:
      // Extract QP number from vendor_specific field
      cqe->mlx5.src_qp = static_cast<uint32_t>(wqe->vendor_specific >> 32);
      cqe->mlx5.flags = static_cast<uint32_t>(wqe->vendor_specific &
                                              0xFFFFFFFF);
      break;
    case RDMAVendor::BNXT_RE:
      // Simulate SQ/CQ consumer indices
      cqe->bnxt.sq_cons_idx = wqe->wqe_id;
      cqe->bnxt.cq_cons_idx = wqe->wqe_id;
      break;
    case RDMAVendor::IONIC:
      // Extract QP number
      cqe->ionic.qpn = static_cast<uint32_t>(wqe->vendor_specific >> 32);
      cqe->ionic.reserved = 0;
      break;
    case RDMAVendor::PVRDMA:
      // Extract QP number
      cqe->pvrdma.qpn = static_cast<uint32_t>(wqe->vendor_specific >> 32);
      cqe->pvrdma.reserved = 0;
      break;
    default:
      cqe->vendor_data = 0;
      break;
  }

  cqe->reserved = 0;

  // Simple validation: check for invalid opcodes
  if (wqe->opcode > RDMA_OP_ATOMIC_FETCH_ADD && wqe->opcode != 0xFF) {
    cqe->status = RDMA_WC_LOC_QP_OP_ERR;
  }

  return result;
}

// Use HIP's built-in wall_clock64() function directly - no wrapper needed

} // namespace rdma_ep

// Export rdma-ep functions for runtime dispatch
__host__ __device__ void rdma_ep_emulateEndpoint(unsigned sqeIterations,
                                                 void* sqeAddr, void* cqeAddr) {
  // Cast void* to endpoint-specific types
  rdma_ep::sqeType* sqePtr = static_cast<rdma_ep::sqeType*>(sqeAddr);
  rdma_ep::cqeType* cqePtr = static_cast<rdma_ep::cqeType*>(cqeAddr);

  // Read initial queue state to synchronize with tester's initialization
  rdma_ep::sqeType sqeOld = rdma_ep::sqeRead(
    (volatile rdma_ep::sqeType*)sqePtr);
  rdma_ep::cqeType cqeLocal = rdma_ep::cqeRead(
    (volatile rdma_ep::cqeType*)cqePtr);
  rdma_ep::sqeType sqeNew;

  unsigned commands_processed = 0;

  // Loop indefinitely until stop command (opcode 0xFF)
  while (true) {
    sqeNew = rdma_ep::sqePoll(sqeOld, (volatile rdma_ep::sqeType*)sqePtr);

    const rdma_ep::sqeType* wqe_new = &sqeNew;

    // Check for stop command (opcode 0xFF)
    if (wqe_new->opcode == 0xFF) {
      break;
    }

    // Process the RDMA command
#ifdef __HIP_DEVICE_COMPILE__
    uint64_t timestamp = wall_clock64();
#else
    uint64_t timestamp = 0; // Host code - no timing
#endif
    cqeLocal = rdma_ep::cqeGenFromSqe(&sqeNew, timestamp);
    rdma_ep::cqeWrite(cqeLocal, cqePtr);

    sqeOld = sqeNew;
    commands_processed++;

    // Safety check to prevent infinite loop
    if (commands_processed > sqeIterations * 2) {
      break;
    }
  }
}

// Config-based driveEndpoint function
__device__ void rdma_ep_driveEndpoint(const AxiioEndpointConfig& config,
                                      void* sqeAddr, void* cqeAddr) {
  // Cast void* to endpoint-specific types
  rdma_ep::sqeType* sqePtr = static_cast<rdma_ep::sqeType*>(sqeAddr);
  rdma_ep::cqeType* cqePtr = static_cast<rdma_ep::cqeType*>(cqeAddr);

  rdma_ep::sqeType sqeLocal = {};
  rdma_ep::cqeType cqeLocal = {};

  struct rdma_wqe* wqe = &sqeLocal;
  struct rdma_cqe* cqe = &cqeLocal;

  // Initialize CQE with invalid wqe_id for first poll
  cqe->wqe_id = 0xFFFF;

  // Dummy addresses and keys for RDMA operations
  uint64_t local_addr = 0x1000000;
  uint64_t remote_addr = 0x2000000;
  uint32_t lkey = 0x12345678;
  uint32_t rkey = 0x87654321;
  uint32_t transfer_size = 4096; // 4KB transfers

  // Cycle through different vendors
  RDMAVendor vendors[] = {RDMAVendor::MLX5, RDMAVendor::BNXT_RE,
                          RDMAVendor::IONIC, RDMAVendor::PVRDMA};
  int num_vendors = sizeof(vendors) / sizeof(vendors[0]);

  // Extract timing arrays from config
  unsigned long long int* startTime = config.startTimes;
  unsigned long long int* endTime = config.endTimes;

  for (unsigned i = 0; i < config.iterations; i++) {
    // Start wqe IDs at 1 to avoid conflicts with zero-initialized memory
    uint16_t wqe_id = static_cast<uint16_t>(i + 1);

    // Select vendor in round-robin fashion
    RDMAVendor vendor = vendors[i % num_vendors];

    // Alternate between different RDMA operations
    if (i % 3 == 0) {
      // RDMA SEND operation
      rdma_wqe_setup_send(wqe, wqe_id, vendor, local_addr + (i * transfer_size),
                          transfer_size, lkey);
    } else if (i % 3 == 1) {
      // RDMA WRITE operation
      rdma_wqe_setup_write(wqe, wqe_id, vendor,
                           local_addr + (i * transfer_size),
                           remote_addr + (i * transfer_size), transfer_size,
                           lkey, rkey);
    } else {
      // RDMA READ operation
      rdma_wqe_setup_read(wqe, wqe_id, vendor, local_addr + (i * transfer_size),
                          remote_addr + (i * transfer_size), transfer_size,
                          lkey, rkey);
    }

    // Set vendor-specific fields
    switch (vendor) {
      case RDMAVendor::MLX5:
        mlx5_wqe_set_vendor_specific(wqe, 1000 + i, false, false);
        break;
      case RDMAVendor::BNXT_RE:
        bnxt_wqe_set_vendor_specific(wqe, i, 0);
        break;
      case RDMAVendor::IONIC:
        ionic_wqe_set_vendor_specific(wqe, 2000 + i, true, false);
        break;
      case RDMAVendor::PVRDMA:
        pvrdma_wqe_set_vendor_specific(wqe, 3000 + i, true, false);
        break;
      default:
        break;
    }

    // Submit command and wait for completion
    if (startTime != nullptr) {
      startTime[i] = wall_clock64();
    }
    rdma_ep::sqeWrite(sqeLocal, sqePtr);
    cqeLocal = rdma_ep::cqePoll(cqeLocal, (volatile rdma_ep::cqeType*)cqePtr);
    if (endTime != nullptr) {
      endTime[i] = wall_clock64();
    }

    // Verify completion
    if (cqe->wqe_id != wqe_id) {
      // WQE ID mismatch - error condition
      // In a real implementation, would handle this error
    }

    if (!rdma_cqe_ok(cqe)) {
      // Operation failed - error condition
      // In a real implementation, would handle this error
    }
  }

  // Send stop command (opcode 0xFF, wqe_id 0xFFFF)
  wqe->opcode = 0xFF;
  wqe->wqe_id = 0xFFFF;
  rdma_ep::sqeWrite(sqeLocal, sqePtr);
}
