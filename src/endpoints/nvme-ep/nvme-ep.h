/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef NVME_EP_H
#define NVME_EP_H

#include <cstdint>

#include <hip/hip_runtime.h>

// Forward declarations (actual definitions are in axiio-endpoint.h)
struct sqeType_s;
struct cqeType_s;

/*
 * NVMe Definitions for AxIIO nvme-ep Endpoint
 *
 * These definitions are based on the NVM Express specification and the
 * Linux kernel NVMe implementation. For reference, see:
 *   - Linux kernel: include/linux/nvme.h
 *   - NVMe spec: https://nvmexpress.org/specifications/
 *
 * To fetch the latest Linux kernel NVMe headers for reference:
 *   make fetch-nvme-headers
 *
 * The downloaded headers will be in include/external/ for reference.
 */

// Magic ID for nvme-ep queue entries
#define NVME_EP_MAGIC_ID 0xF1

// NVMe endpoint queue entry sizes
// These match the NVMe specification requirements
#define NVME_EP_SQE_SIZE 64 // NVMe Submission Queue Entry: 64 bytes
#define NVME_EP_CQE_SIZE 16 // NVMe Completion Queue Entry: 16 bytes

//
// NVMe Command Opcodes (NVM Command Set)
// Reference: Linux kernel enum nvme_opcode
//
#define NVME_CMD_FLUSH 0x00
#define NVME_CMD_WRITE 0x01
#define NVME_CMD_READ 0x02
#define NVME_CMD_WRITE_UNCOR 0x04
#define NVME_CMD_COMPARE 0x05
#define NVME_CMD_WRITE_ZEROS 0x08
#define NVME_CMD_DSM 0x09 // Dataset Management
#define NVME_CMD_VERIFY 0x0c
#define NVME_CMD_RESV_REGISTER 0x0d
#define NVME_CMD_RESV_REPORT 0x0e
#define NVME_CMD_RESV_ACQUIRE 0x11
#define NVME_CMD_RESV_RELEASE 0x15

// Admin Command Opcodes
#define NVME_ADMIN_DELETE_SQ 0x00
#define NVME_ADMIN_CREATE_SQ 0x01
#define NVME_ADMIN_GET_LOG_PAGE 0x02
#define NVME_ADMIN_DELETE_CQ 0x04
#define NVME_ADMIN_CREATE_CQ 0x05
#define NVME_ADMIN_IDENTIFY 0x06
#define NVME_ADMIN_ABORT_CMD 0x08
#define NVME_ADMIN_SET_FEATURES 0x09
#define NVME_ADMIN_GET_FEATURES 0x0a
#define NVME_ADMIN_ASYNC_EVENT 0x0c
#define NVME_ADMIN_NS_MGMT 0x0d
#define NVME_ADMIN_ACTIVATE_FW 0x10
#define NVME_ADMIN_DOWNLOAD_FW 0x11
#define NVME_ADMIN_NS_ATTACH 0x15
#define NVME_ADMIN_FORMAT_NVM 0x80
#define NVME_ADMIN_SECURITY_SEND 0x81
#define NVME_ADMIN_SECURITY_RECV 0x82

//
// NVMe Status Code Types
//
#define NVME_SCT_GENERIC 0x0
#define NVME_SCT_CMD_SPECIFIC 0x1
#define NVME_SCT_MEDIA_ERROR 0x2
#define NVME_SCT_VENDOR 0x7

//
// NVMe Generic Command Status Codes
//
#define NVME_SC_SUCCESS 0x00
#define NVME_SC_INVALID_OPCODE 0x01
#define NVME_SC_INVALID_FIELD 0x02
#define NVME_SC_CMDID_CONFLICT 0x03
#define NVME_SC_DATA_XFER_ERROR 0x04
#define NVME_SC_POWER_LOSS 0x05
#define NVME_SC_INTERNAL 0x06
#define NVME_SC_ABORT_REQ 0x07
#define NVME_SC_ABORT_QUEUE 0x08
#define NVME_SC_FUSED_FAIL 0x09
#define NVME_SC_FUSED_MISSING 0x0a
#define NVME_SC_INVALID_NS 0x0b
#define NVME_SC_CMD_SEQ_ERROR 0x0c
#define NVME_SC_LBA_RANGE 0x80
#define NVME_SC_CAP_EXCEEDED 0x81
#define NVME_SC_NS_NOT_READY 0x82
#define NVME_SC_RESERVATION_CONFLICT 0x83

//
// NVMe Submission Queue Entry (64 bytes)
// This structure represents a standard NVMe command
//
struct nvme_sqe {
  // DW0: Command Dword 0
  uint8_t opcode;      // Command opcode
  uint8_t flags;       // FUSE and PSDT fields
  uint16_t command_id; // Command identifier

  // DW1: Namespace Identifier
  uint32_t nsid; // Namespace ID

  // DW2-3: Reserved
  uint32_t cdw2;
  uint32_t cdw3;

  // DW4-5: Metadata Pointer
  uint64_t metadata;

  // DW6-9: Data Pointer (PRP Entry 1 and 2, or SGL)
  union {
    struct {
      uint64_t prp1; // PRP Entry 1
      uint64_t prp2; // PRP Entry 2
    } prp;
    struct {
      uint64_t addr;     // SGL Address
      uint32_t length;   // SGL Length
      uint32_t key_type; // SGL Key and Type
    } sgl;
  } dptr;

  // DW10-15: Command Specific
  uint32_t cdw10;
  uint32_t cdw11;
  uint32_t cdw12;
  uint32_t cdw13;
  uint32_t cdw14;
  uint32_t cdw15;
} __attribute__((packed));

//
// NVMe Completion Queue Entry (16 bytes)
// This structure represents the completion status of a command
//
struct nvme_cqe {
  // DW0: Command Specific
  union {
    uint32_t result; // Command-specific result
    struct {
      uint32_t cdw0; // Generic DW0
    };
  };

  // DW1: Reserved
  uint32_t rsvd;

  // DW2: SQ Head Pointer and SQ Identifier
  uint16_t sq_head; // SQ Head Pointer
  uint16_t sq_id;   // SQ Identifier

  // DW3: Command ID, Phase, and Status
  uint16_t command_id; // Command Identifier
  uint16_t status; // Status Field (Phase Tag + Status Code + Status Code Type +
                   // More + DNR)
} __attribute__((packed));

//
// Helper macros for NVMe CQE status field
//
#define NVME_CQE_STATUS_PHASE(status) (((status) >> 0) & 0x1)
#define NVME_CQE_STATUS_SC(status) (((status) >> 1) & 0xFF)
#define NVME_CQE_STATUS_SCT(status) (((status) >> 9) & 0x7)
#define NVME_CQE_STATUS_CRD(status) (((status) >> 12) & 0x3)
#define NVME_CQE_STATUS_MORE(status) (((status) >> 14) & 0x1)
#define NVME_CQE_STATUS_DNR(status) (((status) >> 15) & 0x1)

#define NVME_STATUS_MAKE(phase, sc, sct)                                       \
  ((((phase) & 0x1) << 0) | (((sc) & 0xFF) << 1) | (((sct) & 0x7) << 9))

//
// Helper functions to create NVMe commands
//

// Create an NVMe Read command
__host__ __device__ static inline void nvme_sqe_setup_read(
  struct nvme_sqe* sqe, uint16_t cid, uint32_t nsid, uint64_t slba,
  uint32_t nlb, uint64_t prp1, uint64_t prp2) {
  sqe->opcode = NVME_CMD_READ;
  sqe->flags = 0;
  sqe->command_id = cid;
  sqe->nsid = nsid;
  sqe->cdw2 = 0;
  sqe->cdw3 = 0;
  sqe->metadata = 0;
  sqe->dptr.prp.prp1 = prp1;
  sqe->dptr.prp.prp2 = prp2;
  sqe->cdw10 = (uint32_t)(slba & 0xFFFFFFFF);         // SLBA lower 32 bits
  sqe->cdw11 = (uint32_t)((slba >> 32) & 0xFFFFFFFF); // SLBA upper 32 bits
  sqe->cdw12 = nlb - 1; // Number of logical blocks (0's based)
  sqe->cdw13 = 0;
  sqe->cdw14 = 0;
  sqe->cdw15 = 0;
}

// Create an NVMe Write command
__host__ __device__ static inline void nvme_sqe_setup_write(
  struct nvme_sqe* sqe, uint16_t cid, uint32_t nsid, uint64_t slba,
  uint32_t nlb, uint64_t prp1, uint64_t prp2) {
  sqe->opcode = NVME_CMD_WRITE;
  sqe->flags = 0;
  sqe->command_id = cid;
  sqe->nsid = nsid;
  sqe->cdw2 = 0;
  sqe->cdw3 = 0;
  sqe->metadata = 0;
  sqe->dptr.prp.prp1 = prp1;
  sqe->dptr.prp.prp2 = prp2;
  sqe->cdw10 = (uint32_t)(slba & 0xFFFFFFFF);
  sqe->cdw11 = (uint32_t)((slba >> 32) & 0xFFFFFFFF);
  sqe->cdw12 = nlb - 1; // Number of logical blocks (0's based)
  sqe->cdw13 = 0;
  sqe->cdw14 = 0;
  sqe->cdw15 = 0;
}

// Create an NVMe Flush command
__host__ __device__ static inline void nvme_sqe_setup_flush(
  struct nvme_sqe* sqe, uint16_t cid, uint32_t nsid) {
  sqe->opcode = NVME_CMD_FLUSH;
  sqe->flags = 0;
  sqe->command_id = cid;
  sqe->nsid = nsid;
  sqe->cdw2 = 0;
  sqe->cdw3 = 0;
  sqe->metadata = 0;
  sqe->dptr.prp.prp1 = 0;
  sqe->dptr.prp.prp2 = 0;
  sqe->cdw10 = 0;
  sqe->cdw11 = 0;
  sqe->cdw12 = 0;
  sqe->cdw13 = 0;
  sqe->cdw14 = 0;
  sqe->cdw15 = 0;
}

// Check if CQE indicates success
__host__ __device__ static inline bool nvme_cqe_ok(const struct nvme_cqe* cqe) {
  uint16_t status = cqe->status;
  uint8_t sc = NVME_CQE_STATUS_SC(status);
  uint8_t sct = NVME_CQE_STATUS_SCT(status);
  return (sct == NVME_SCT_GENERIC && sc == NVME_SC_SUCCESS);
}

// Get status code from CQE
__host__ __device__ static inline uint8_t nvme_cqe_status_code(
  const struct nvme_cqe* cqe) {
  return NVME_CQE_STATUS_SC(cqe->status);
}

// Get status code type from CQE
__host__ __device__ static inline uint8_t nvme_cqe_status_type(
  const struct nvme_cqe* cqe) {
  return NVME_CQE_STATUS_SCT(cqe->status);
}

//
// NVMe Data Buffer and PRP Helper Functions
//

// NVMe page size (typically 4KB)
#define NVME_PAGE_SIZE 4096

// Calculate PRP entries from a buffer address
// For buffers <= page size, only PRP1 is needed
// For buffers > page size, PRP2 contains either:
//   - Address of next page (if buffer spans 2 pages)
//   - Address of PRP list (if buffer spans > 2 pages)
__host__ __device__ static inline void nvme_calculate_prps(uint64_t buffer_addr,
                                                           uint32_t buffer_size,
                                                           uint64_t* prp1,
                                                           uint64_t* prp2) {
  *prp1 = buffer_addr;
  *prp2 = 0;

  // Calculate how much data the first page can hold
  uint64_t offset_in_page = buffer_addr & (NVME_PAGE_SIZE - 1);
  uint64_t first_page_size = NVME_PAGE_SIZE - offset_in_page;

  // If buffer fits in first page, we're done
  if (buffer_size <= first_page_size) {
    return;
  }

  // Buffer spans multiple pages - set PRP2 to next page
  // (Simplified: doesn't handle PRP lists for >2 pages)
  *prp2 = (buffer_addr + first_page_size) & ~(NVME_PAGE_SIZE - 1);
}

//
// Data Pattern Generation and Verification
//

// Test pattern types
enum nvme_test_pattern {
  NVME_PATTERN_SEQUENTIAL = 0, // Incrementing bytes
  NVME_PATTERN_ZEROS = 1,      // All zeros
  NVME_PATTERN_ONES = 2,       // All ones (0xFF)
  NVME_PATTERN_RANDOM = 3,     // Pseudo-random (based on offset)
  NVME_PATTERN_BLOCK_ID = 4,   // Block ID repeated
  NVME_PATTERN_LFSR = 5        // LFSR-based deterministic pattern
};

// Forward declaration of global debug flag (defined in nvme-ep.hip)
extern __device__ bool g_nvme_ep_debug;

// Generate test data pattern
__host__ __device__ static inline void nvme_generate_pattern(
  uint8_t* buffer, size_t size, enum nvme_test_pattern pattern, uint64_t offset,
  uint32_t lfsr_seed = 0) {
  // Debug: Print first few bytes before writing
#ifdef __HIP_DEVICE_COMPILE__
  if (threadIdx.x == 0 && blockIdx.x == 0 && size > 0 && g_nvme_ep_debug) {
#else
  if (false) {
#endif
    printf("GPU: nvme_generate_pattern: buffer=%p, size=%zu, pattern=%d\n",
           buffer, size, pattern);
    printf("GPU: First byte before write: 0x%02x\n", buffer[0]);
  }

  switch (pattern) {
    case NVME_PATTERN_SEQUENTIAL:
      // Write in chunks to avoid long loops
      for (size_t i = 0; i < size; i++) {
#ifdef __HIP_DEVICE_COMPILE__
        if (i < 10 && threadIdx.x == 0 && blockIdx.x == 0 && g_nvme_ep_debug) {
          printf("GPU: Writing buffer[%zu] = 0x%02x\n", i,
                 (uint8_t)((offset + i) & 0xFF));
        }
#endif
        buffer[i] = (uint8_t)((offset + i) & 0xFF);
#ifdef __HIP_DEVICE_COMPILE__
        if (i == 9 && threadIdx.x == 0 && blockIdx.x == 0 && g_nvme_ep_debug) {
          printf("GPU: First 10 bytes written, continuing...\n");
        }
#endif
      }
#ifdef __HIP_DEVICE_COMPILE__
      if (threadIdx.x == 0 && blockIdx.x == 0 && g_nvme_ep_debug) {
        printf("GPU: Pattern generation complete, first byte after: 0x%02x\n",
               buffer[0]);
      }
#endif
      break;

    case NVME_PATTERN_ZEROS:
      for (size_t i = 0; i < size; i++) {
        buffer[i] = 0x00;
      }
      break;

    case NVME_PATTERN_ONES:
      for (size_t i = 0; i < size; i++) {
        buffer[i] = 0xFF;
      }
      break;

    case NVME_PATTERN_RANDOM:
      // Simple pseudo-random based on offset
      for (size_t i = 0; i < size; i++) {
        uint64_t seed = offset + i;
        seed = (seed ^ (seed >> 30)) * 0xBF58476D1CE4E5B9ULL;
        seed = (seed ^ (seed >> 27)) * 0x94D049BB133111EBULL;
        buffer[i] = (uint8_t)((seed ^ (seed >> 31)) & 0xFF);
      }
      break;

    case NVME_PATTERN_BLOCK_ID:
      // Fill with block ID
      for (size_t i = 0; i < size; i += sizeof(uint64_t)) {
        uint64_t* ptr = (uint64_t*)(buffer + i);
        if (i + sizeof(uint64_t) <= size) {
          *ptr = offset;
        } else {
          // Handle partial block at end
          for (size_t j = i; j < size; j++) {
            buffer[j] = (uint8_t)((offset >> ((j - i) * 8)) & 0xFF);
          }
        }
      }
      break;

    case NVME_PATTERN_LFSR: {
      // LFSR-based deterministic pattern
      // offset is treated as LBA, seed is combined with LBA-derived seed
      // XOR combines user seed with LBA seed: seed=0 uses LBA-only, seed!=0
      // varies pattern
      uint64_t lba = offset / 512; // Assuming 512-byte blocks
      uint32_t base_seed = (uint32_t)(lba * 0x12345678);
      uint32_t seed = base_seed ^ lfsr_seed; // XOR combines seeds
      for (size_t i = 0; i < size; i++) {
        uint32_t rng = (uint32_t)(lba * 0x9e3779b9 + seed + i);
        rng ^= rng >> 16;
        rng *= 0x85ebca6b;
        rng ^= rng >> 13;
        rng *= 0xc2b2ae35;
        rng ^= rng >> 16;
        buffer[i] = (uint8_t)(rng & 0xFF);
      }
      break;
    }
  }
}

// Verify test data pattern
__host__ __device__ static inline bool nvme_verify_pattern(
  const uint8_t* buffer, size_t size, enum nvme_test_pattern pattern,
  uint64_t offset, size_t* error_offset, uint32_t lfsr_seed = 0) {
  uint8_t expected;

  for (size_t i = 0; i < size; i++) {
    switch (pattern) {
      case NVME_PATTERN_SEQUENTIAL:
        expected = (uint8_t)((offset + i) & 0xFF);
        break;

      case NVME_PATTERN_ZEROS:
        expected = 0x00;
        break;

      case NVME_PATTERN_ONES:
        expected = 0xFF;
        break;

      case NVME_PATTERN_RANDOM: {
        uint64_t seed = offset + i;
        seed = (seed ^ (seed >> 30)) * 0xBF58476D1CE4E5B9ULL;
        seed = (seed ^ (seed >> 27)) * 0x94D049BB133111EBULL;
        expected = (uint8_t)((seed ^ (seed >> 31)) & 0xFF);
      } break;

      case NVME_PATTERN_BLOCK_ID:
        expected = (uint8_t)((offset >> ((i % sizeof(uint64_t)) * 8)) & 0xFF);
        break;

      case NVME_PATTERN_LFSR: {
        // LFSR-based verification (same as generation)
        // XOR combines user seed with LBA seed: seed=0 uses LBA-only,
        // seed!=0 varies pattern
        uint64_t lba = offset / 512; // Assuming 512-byte blocks
        uint32_t base_seed = (uint32_t)(lba * 0x12345678);
        uint32_t seed = base_seed ^ lfsr_seed; // XOR combines seeds
        uint32_t rng = (uint32_t)(lba * 0x9e3779b9 + seed + i);
        rng ^= rng >> 16;
        rng *= 0x85ebca6b;
        rng ^= rng >> 13;
        rng *= 0xc2b2ae35;
        rng ^= rng >> 16;
        expected = (uint8_t)(rng & 0xFF);
        break;
      }

      default:
        expected = buffer[i]; // Always pass for unknown patterns
        break;
    }

    if (buffer[i] != expected) {
      if (error_offset) {
        *error_offset = i;
      }
      return false;
    }
  }

  return true;
}

//
// Forward declarations for NVMe endpoint functions
//

// Standard drive endpoint (uses dummy PRPs)
extern "C" __device__ void nvme_ep_driveEndpoint(
  unsigned sqeIterations, sqeType_s* sqeAddr, cqeType_s* cqeAddr,
  unsigned long long int* startTime, unsigned long long int* endTime);

// Drive endpoint with data buffers (uses real PRPs)
// Returns final sq_tail value for doorbell ringing
extern "C" __device__ uint16_t nvme_ep_driveEndpointWithBuffers(
  unsigned sqeIterations, sqeType_s* sqeAddr, cqeType_s* cqeAddr,
  unsigned long long int* startTime, unsigned long long int* endTime,
  uint8_t* readBuffer, uint8_t* writeBuffer, size_t bufferSize,
  uint32_t blockSize, enum nvme_test_pattern pattern, uint64_t readBufferDma,
  uint64_t writeBufferDma, uint32_t lfsr_seed = 0);

// Emulate endpoint
extern "C" __host__ __device__ void nvme_ep_emulateEndpoint(
  unsigned sqeIterations, sqeType_s* sqeAddr, cqeType_s* cqeAddr);

// Host function to set global debug flag for GPU endpoint functions
extern "C" __host__ void nvme_ep_set_debug(bool debug);

// GPU-based read verification kernel
// Verifies read data matches expected pattern using LFSR/seed without CPU
// touching buffers Returns verified count and mismatch count via output
// parameters
extern "C" __global__ void nvme_ep_verify_reads_gpu(
  const uint8_t* readBuffer, void* sqeAddr, void* cqeAddr,
  uint32_t numCompletions, uint32_t blockSize, enum nvme_test_pattern pattern,
  uint32_t lfsr_seed, uint32_t* verifiedCount, uint32_t* mismatchCount);

#endif // NVME_EP_H
