/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef NVME_EP_H
#define NVME_EP_H

#include <cstdint>
#include <string>

#include <hip/hip_runtime.h>

#include <CLI/CLI.hpp>

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

// Global debug flag (defined in nvme-ep.hip)
// Note: This needs to be accessible across translation units, so it's declared
// here and defined in nvme-ep.hip
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
__device__ void nvme_ep_driveEndpoint(unsigned sqeIterations, void* sqeAddr,
                                      void* cqeAddr,
                                      unsigned long long int* startTime,
                                      unsigned long long int* endTime);

// Drive endpoint with data buffers (uses real PRPs)
// Returns final sq_tail value for doorbell ringing
__device__ uint16_t nvme_ep_driveEndpointWithBuffers(
  unsigned sqeIterations, void* sqeAddr, void* cqeAddr,
  unsigned long long int* startTime, unsigned long long int* endTime,
  uint8_t* readBuffer, uint8_t* writeBuffer, size_t bufferSize,
  uint32_t blockSize, enum nvme_test_pattern pattern, uint64_t readBufferDma,
  uint64_t writeBufferDma, uint32_t lfsr_seed = 0);

// Emulate endpoint
__host__ __device__ void nvme_ep_emulateEndpoint(unsigned sqeIterations,
                                                 void* sqeAddr, void* cqeAddr);

// Host function to set global debug flag for GPU endpoint functions
__host__ void nvme_ep_set_debug(bool debug);

// GPU-based read verification kernel
// Verifies read data matches expected pattern using LFSR/seed without CPU
// touching buffers Returns verified count and mismatch count via output
// parameters
__global__ void nvme_ep_verify_reads_gpu(
  const uint8_t* readBuffer, void* sqeAddr, void* cqeAddr,
  uint32_t numCompletions, uint32_t blockSize, enum nvme_test_pattern pattern,
  uint32_t lfsr_seed, uint32_t* verifiedCount, uint32_t* mismatchCount);

//
// NVMe Endpoint Configuration Structure
//

namespace nvme_ep {

/**
 * NVMe Endpoint Configuration Structure
 *
 * Contains all NVMe-specific configuration options that were previously
 * scattered in the main tester's cmdLineArgs structure.
 */
struct NvmeEpConfig {
  // Device and queue configuration
  std::string device; // NVMe device path (e.g., /dev/nvme0 or /dev/nvme-axiio)
  bool useKernelModule; // Use kernel module (/dev/nvme-axiio)
  uint16_t queueId;     // Queue ID to use (0=admin, 1+=IO queues)

  // Physical addresses (usually auto-detected)
  uint64_t doorbellAddr; // Physical address of doorbell register
  uint64_t sqBaseAddr;   // Physical base address of submission queue
  uint64_t cqBaseAddr;   // Physical base address of completion queue
  size_t sqSize;         // Size of submission queue in bytes
  size_t cqSize;         // Size of completion queue in bytes

  // I/O operation parameters
  uint32_t nsid;             // Namespace ID (default: 1)
  size_t transferSize;       // Transfer size in bytes (default: 4096)
  size_t lbaRangeGiB;        // LBA range to test in GiB (default: 1)
  std::string accessPattern; // "sequential" or "random" (default: "random")
  unsigned blockSize;        // Block size in bytes (default: 512)

  // Data buffer configuration
  bool useDataBuffers;   // Enable data buffer allocation
  size_t dataBufferSize; // Size of data buffers in bytes

  // Test pattern configuration
  std::string testPattern; // Pattern: sequential, zeros, ones, random,
                           // block_id, lfsr
  uint32_t lfsrSeed;       // Seed for LFSR pattern (0 = derive from LBA)

  // I/O operation counts
  unsigned readIo;  // Number of read I/O operations
  unsigned writeIo; // Number of write I/O operations

  // Operation mode flags
  bool cpuOnlyMode;         // Use CPU for command generation
  bool hijackExistingQueue; // DANGEROUS: Use existing kernel queue
  bool writeOnlyMode;       // Write-only mode
  bool readOnlyMode;        // Read-only mode
  bool skipQueueCleanup;    // Skip queue deletion on exit

  // Verification options
  bool verifyTrace;          // Verify doorbell operations in QEMU trace
  std::string traceFilePath; // Path to QEMU trace log file
  bool verifyReads;          // Verify read data matches expected pattern
  bool gpuVerifyReads; // Use GPU-based verification (no CPU buffer access)

  // Legacy/backward compatibility flags
  bool useRealHardware; // Legacy: Use real NVMe hardware

  // Default constructor
  NvmeEpConfig()
    : device(""), useKernelModule(false), queueId(63), doorbellAddr(0),
      sqBaseAddr(0), cqBaseAddr(0), sqSize(0), cqSize(0), nsid(1),
      transferSize(4096), lbaRangeGiB(1), accessPattern("random"),
      blockSize(512), useDataBuffers(true), // Always use data buffers for NVMe
      dataBufferSize(1024 * 1024)           // 1 MB default
      ,
      testPattern("sequential"), lfsrSeed(0), readIo(64),
      writeIo(64), // Default: 64 reads, 64 writes
      cpuOnlyMode(false), hijackExistingQueue(false), writeOnlyMode(false),
      readOnlyMode(false), skipQueueCleanup(false), verifyTrace(false),
      traceFilePath("/tmp/rocm-axiio-nvme-trace.log"), verifyReads(false),
      gpuVerifyReads(false), useRealHardware(false) {
  }
};

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
 * @param config Pointer to NvmeEpConfig structure to populate
 */
inline void registerCliOptions(CLI::App& app, NvmeEpConfig* config) {
  // Group all NVMe endpoint-specific options together
  // This ensures they appear in their own section below global options
  const std::string nvme_group = "NVMe Endpoint Options";

  // NVMe endpoint options in alphabetical order by long name
  app
    .add_option("--access-pattern", config->accessPattern,
                "Access pattern: 'sequential' or 'random'.")
    ->default_val("random")
    ->check(CLI::IsMember({"sequential", "random"}))
    ->group(nvme_group);

  app
    .add_option("--block-size", config->blockSize,
                "NVMe block size in bytes (typically 512 or 4096).")
    ->default_val(512)
    ->check(CLI::PositiveNumber)
    ->group(nvme_group);

  app
    .add_flag(
      "--cpu-only", config->cpuOnlyMode,
      "Use CPU for NVMe command generation (no GPU, no PCIe atomics required).")
    ->default_val(false)
    ->default_str("")
    ->group(nvme_group);

  app
    .add_option(
      "--data-buffer-size", config->dataBufferSize,
      "Size of data buffers for NVMe I/O testing (bytes). "
      "If not specified, will be auto-calculated as "
      "(read-io + write-io) * 8 * block-size (kernel uses 8 blocks per "
      "operation).")
    ->default_val(1024 * 1024) // 1 MB default
    ->check(CLI::PositiveNumber)
    ->group(nvme_group);

  app
    .add_option("--device", config->device,
                "NVMe device path (e.g., /dev/nvme0 or /dev/nvme-axiio). "
                "Enables automatic hardware setup.")
    ->default_val("")
    ->group(nvme_group);

  app
    .add_flag("--hijack-existing-queue", config->hijackExistingQueue,
              "⚠️  DANGEROUS: Use existing kernel queue without creating new "
              "one (for testing).")
    ->default_val(false)
    ->default_str("")
    ->group(nvme_group);

  app
    .add_flag("--kernel-module", config->useKernelModule,
              "Use kernel module (/dev/nvme-axiio) for queue management "
              "instead of direct device access.")
    ->default_val(false)
    ->default_str("")
    ->group(nvme_group);

  app
    .add_option("--lba-range-gib", config->lbaRangeGiB,
                "LBA range to test in GiB (e.g., 1 for first 1GiB).")
    ->default_val(1)
    ->check(CLI::PositiveNumber)
    ->group(nvme_group);

  app
    .add_option("--lfsr-seed", config->lfsrSeed,
                "Seed for LFSR pattern generation (0 = derive from LBA). "
                "Allows different data patterns for same LBA.")
    ->default_val(0)
    ->group(nvme_group);

  app
    .add_option("--nsid", config->nsid, "NVMe namespace ID for I/O operations.")
    ->default_val(1)
    ->check(CLI::Range(1u, 0xFFFFFFFFu))
    ->group(nvme_group);

  app
    .add_option("--read-io", config->readIo,
                "Number of read I/O operations to perform.")
    ->default_val(64)
    ->check(CLI::NonNegativeNumber)
    ->group(nvme_group);

  app
    .add_flag(
      "--read-only", config->readOnlyMode,
      "Read-only mode: only allocate read buffer, issue only read commands.")
    ->default_val(false)
    ->default_str("")
    ->group(nvme_group);

  app
    .add_option("--queue-id", config->queueId,
                "NVMe queue ID to use (0=admin queue, 1+=IO queues). "
                "Use high ID to avoid kernel conflicts.")
    ->default_val(63)
    ->check(CLI::Range(0, 65535))
    ->group(nvme_group);

  app
    .add_flag("--skip-queue-cleanup", config->skipQueueCleanup,
              "Skip queue deletion on exit (faster, leaves queues active).")
    ->default_val(false)
    ->default_str("")
    ->group(nvme_group);

  app
    .add_option("--test-pattern", config->testPattern,
                "Data test pattern: sequential, zeros, ones, random, "
                "block_id, lfsr. Use lfsr with --lfsr-seed for deterministic "
                "LFSR-based patterns.")
    ->default_val("sequential")
    ->check([](const std::string& val) {
      return (val == "sequential" || val == "zeros" || val == "ones" ||
              val == "random" || val == "block_id" || val == "lfsr")
               ? std::string()
               : std::string("Pattern must be: sequential, zeros, ones, "
                             "random, block_id, or lfsr");
    })
    ->group(nvme_group);

  app
    .add_option("--trace-file", config->traceFilePath,
                "Path to QEMU NVMe trace log file for verification. "
                "Default: /tmp/rocm-axiio-nvme-trace.log")
    ->default_val("/tmp/rocm-axiio-nvme-trace.log")
    ->group(nvme_group);

  app
    .add_option("--transfer-size", config->transferSize,
                "Transfer size for NVMe I/O operations in bytes "
                "(e.g., 4096 for 4KiB).")
    ->default_val(4096)
    ->check(CLI::PositiveNumber)
    ->group(nvme_group);

  app
    .add_flag("--verify-reads", config->verifyReads,
              "Verify read data matches expected pattern after test completes. "
              "Requires --test-pattern (and --lfsr-seed if using lfsr pattern) "
              "to match the pattern used when data was written. If using "
              "--read-only mode, ensure data was previously written with "
              "matching pattern/seed.")
    ->default_val(false)
    ->default_str("")
    ->group(nvme_group);

  app
    .add_flag(
      "--gpu-verify-reads", config->gpuVerifyReads,
      "Use GPU-based verification (faster, no CPU buffer access). "
      "Requires --verify-reads to be enabled. Uses LFSR pattern and seed "
      "for verification entirely on GPU.")
    ->default_val(false)
    ->default_str("")
    ->group(nvme_group);

  app
    .add_flag(
      "--verify-trace", config->verifyTrace,
      "Verify doorbell operations in QEMU trace log after test completes.")
    ->default_val(false)
    ->default_str("")
    ->group(nvme_group);

  app
    .add_option("--write-io", config->writeIo,
                "Number of write I/O operations to perform.")
    ->default_val(64)
    ->check(CLI::NonNegativeNumber)
    ->group(nvme_group);

  app
    .add_flag(
      "--write-only", config->writeOnlyMode,
      "Write-only mode: only allocate write buffer, issue only write commands.")
    ->default_val(false)
    ->default_str("")
    ->group(nvme_group);

  // Physical addresses (usually auto-detected, kept for advanced users)
  const std::string nvme_advanced_group = "NVMe Endpoint Advanced Options";

  app
    .add_option("--cq-base", config->cqBaseAddr,
                "Physical base address of NVMe completion queue (hex). "
                "Auto-detected if --device is specified.")
    ->default_val(0ULL)
    ->group(nvme_advanced_group);

  app
    .add_option("--cq-size", config->cqSize,
                "Size of NVMe completion queue in bytes. "
                "Auto-detected if --device is specified.")
    ->default_val(0ULL)
    ->check(CLI::NonNegativeNumber)
    ->group(nvme_advanced_group);

  app
    .add_option("--doorbell", config->doorbellAddr,
                "Physical address of NVMe doorbell register (hex). "
                "Auto-detected if --device is specified.")
    ->default_val(0ULL)
    ->group(nvme_advanced_group);

  app
    .add_option("--sq-base", config->sqBaseAddr,
                "Physical base address of NVMe submission queue (hex). "
                "Auto-detected if --device is specified.")
    ->default_val(0ULL)
    ->group(nvme_advanced_group);

  app
    .add_option("--sq-size", config->sqSize,
                "Size of NVMe submission queue in bytes. "
                "Auto-detected if --device is specified.")
    ->default_val(0ULL)
    ->check(CLI::NonNegativeNumber)
    ->group(nvme_advanced_group);
}

/**
 * Validate NVMe endpoint configuration
 *
 * @param config Pointer to NvmeEpConfig structure
 * @return Empty string if valid, error message otherwise
 */
inline std::string validateConfig(NvmeEpConfig* config) {
  if (config->writeOnlyMode && config->readOnlyMode) {
    return "Cannot specify both --write-only and --read-only";
  }

  if (config->accessPattern != "sequential" &&
      config->accessPattern != "random") {
    return "Access pattern must be 'sequential' or 'random'";
  }

  // Note: useDataBuffers is always true for NVMe endpoint (data buffers are
  // always used), so no validation needed here.

  // Validate read/write I/O counts
  // In read-only mode, writeIo should be 0 (auto-set if not explicitly set)
  if (config->readOnlyMode && config->writeIo > 0) {
    config->writeIo = 0; // Force writeIo to 0 in read-only mode
  }
  // In write-only mode, readIo should be 0 (auto-set if not explicitly set)
  if (config->writeOnlyMode && config->readIo > 0) {
    config->readIo = 0; // Force readIo to 0 in write-only mode
  }
  // Validate that at least one is non-zero
  if (config->readIo == 0 && config->writeIo == 0) {
    return "At least one of --read-io or --write-io must be specified (both "
           "cannot be zero)";
  }

  if (config->verifyReads && config->writeOnlyMode) {
    return "--verify-reads cannot be used with --write-only mode (no read "
           "buffer available)";
  }

  if (config->gpuVerifyReads && !config->verifyReads) {
    return "--gpu-verify-reads requires --verify-reads to be enabled";
  }

  // Note: verifyReads with readOnlyMode is valid if data was written
  // beforehand, so we don't return an error here. A warning will be shown
  // during verification if needed.

  return ""; // Valid
}

} // namespace nvme_ep

#endif // NVME_EP_H
