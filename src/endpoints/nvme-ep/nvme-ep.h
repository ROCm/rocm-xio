/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef NVME_EP_H
#define NVME_EP_H

#include <cstdint>
#include <cstring>
#include <string>

#include <hip/hip_runtime.h>

#include <CLI/CLI.hpp>

#include "external/linux-nvme.h"
#include "axiio.h"

/*
 * NVMe Definitions for AxIIO nvme-ep Endpoint
 *
 * This header uses Linux kernel NVMe headers from include/external/linux-nvme.h
 * for standard NVMe definitions (opcodes, status codes, etc.) while maintaining
 * compatibility structures for HIP device code.
 *
 * Reference:
 *   - Linux kernel: include/linux/nvme.h
 *   - NVMe spec: https://nvmexpress.org/specifications/
 *
 * To fetch the latest Linux kernel NVMe headers:
 *   make fetch-nvme-headers
 *
 * The downloaded headers will be in src/include/external/
 */

// NVMe definitions auto-generated from Linux kernel headers
// Source: src/include/external/linux-nvme.h (downloaded via 'make
// fetch-nvme-headers') The kernel headers require kernel-specific includes that
// aren't available in userspace/HIP compilation, so we auto-extract only the
// enum values we need. Generated file: src/include/nvme-ep-generated.h
#include "nvme-ep-generated.h"

// Use lowercase enum values directly from generated file
// No need for uppercase compatibility macros - enum values work everywhere
// Status code types (NVME_SCT_*) are also in the generated file

// Endpoint queue entry sizes (derived from kernel defines in generated file)
#define NVME_EP_SQE_SIZE (1 << NVME_NVM_IOSQES) // 64 bytes
#define NVME_EP_CQE_SIZE (1 << NVME_NVM_IOCQES) // 16 bytes

// Structures (struct nvme_sqe and struct nvme_cqe) are defined in
// nvme-ep-generated.h They are adapted from kernel structures (struct
// nvme_common_command and struct nvme_completion) with standard types instead
// of kernel types (__le32/__le64) for HIP device code compatibility

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

// Create an NVMe Read or Write command
__host__ __device__ static inline void nvme_sqe_setup_rw(
  struct nvme_sqe* sqe, bool is_write, uint16_t cid, uint32_t nsid,
  uint64_t slba, uint32_t nlb, uint64_t prp1, uint64_t prp2) {
  sqe->opcode = is_write ? nvme_cmd_write : nvme_cmd_read;
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

// Convenience wrappers for backward compatibility
__host__ __device__ static inline void nvme_sqe_setup_read(
  struct nvme_sqe* sqe, uint16_t cid, uint32_t nsid, uint64_t slba,
  uint32_t nlb, uint64_t prp1, uint64_t prp2) {
  nvme_sqe_setup_rw(sqe, false, cid, nsid, slba, nlb, prp1, prp2);
}

__host__ __device__ static inline void nvme_sqe_setup_write(
  struct nvme_sqe* sqe, uint16_t cid, uint32_t nsid, uint64_t slba,
  uint32_t nlb, uint64_t prp1, uint64_t prp2) {
  nvme_sqe_setup_rw(sqe, true, cid, nsid, slba, nlb, prp1, prp2);
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

// NVMe page size (from generated file: NVME_PAGE_SIZE, extracted from kernel
// header)

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
// Always uses LFSR pattern with optional seeding
//

// Generate or verify LFSR test data pattern
// is_verify: false = generate pattern into buffer, true = verify buffer against
// pattern Returns: true on success (generate always succeeds, verify returns
// match result)
__host__ __device__ static inline bool nvme_pattern(
  bool is_verify, uint8_t* buffer, size_t size, uint64_t offset,
  uint32_t lbaSize, size_t* error_offset = nullptr, uint32_t lfsr_seed = 0) {
  uint64_t lba = offset / lbaSize;
  uint32_t base_seed = (uint32_t)(lba * 0x12345678);
  uint32_t seed = base_seed ^ lfsr_seed; // XOR combines seeds

  for (size_t i = 0; i < size; i++) {
    uint32_t rng = (uint32_t)(lba * 0x9e3779b9 + seed + i);
    rng ^= rng >> 16;
    rng *= 0x85ebca6b;
    rng ^= rng >> 13;
    rng *= 0xc2b2ae35;
    rng ^= rng >> 16;
    uint8_t expected = (uint8_t)(rng & 0xFF);

    if (is_verify) {
      // Verify mode: check buffer matches expected pattern
      if (buffer[i] != expected) {
        if (error_offset) {
          *error_offset = i;
        }
        return false;
      }
    } else {
      // Generate mode: write expected pattern to buffer
      buffer[i] = expected;
    }
  }

  return true;
}

// Convenience wrappers for backward compatibility
__host__ __device__ static inline void nvme_generate_pattern(
  uint8_t* buffer, size_t size, uint64_t offset, uint32_t lbaSize,
  uint32_t lfsr_seed = 0) {
  nvme_pattern(false, buffer, size, offset, lbaSize, nullptr, lfsr_seed);
}

__host__ __device__ static inline bool nvme_verify_pattern(
  const uint8_t* buffer, size_t size, uint64_t offset, uint32_t lbaSize,
  size_t* error_offset, uint32_t lfsr_seed = 0) {
  // Cast away const for the combined function (it won't modify in verify mode)
  return nvme_pattern(true, const_cast<uint8_t*>(buffer), size, offset, lbaSize,
                      error_offset, lfsr_seed);
}

//
// Forward declarations for NVMe endpoint functions
//

// Forward declarations for types
struct nvme_sqe;
struct nvme_cqe;

// Drive endpoint - merged function that handles both batch and sequential modes
// Sequential mode: if readIo < 0 or writeIo < 0, issues one SQE at a time
// waiting for completion
__device__ void nvme_ep_driveEndpoint(
  const AxiioEndpointConfig& config, struct nvme_sqe* sqeAddr,
  struct nvme_cqe* cqeAddr, uint32_t lbaSize, uint64_t base_lba,
  bool usePciMmioBridge, void* shadowBufferVirt, uint16_t nvmeTargetBdf,
  uint16_t queueId, uint32_t doorbell_offset, uint8_t* readBuffer,
  uint8_t* writeBuffer, size_t bufferSize, uint64_t readBufferDma,
  uint64_t writeBufferDma, uint32_t lfsrSeed, uint16_t queue_size,
  uint64_t lba_range_lbas, bool use_random_access, void* nvmeBar0Gpu,
  int readIo, int writeIo);

//
// Host helper function for NVMe queue creation via IOCTL
//

/**
 * Structure to hold queue creation results
 */
struct nvme_queue_info {
  void* sq_virt;     // Virtual address of submission queue (host pointer)
  void* cq_virt;     // Virtual address of completion queue (host pointer)
  void* sq_gpu;      // GPU-accessible pointer for submission queue
  void* cq_gpu;      // GPU-accessible pointer for completion queue
  uint64_t sq_phys;  // Physical address of submission queue
  uint64_t cq_phys;  // Physical address of completion queue
  uint64_t sq_size;  // Size of submission queue in bytes
  uint64_t cq_size;  // Size of completion queue in bytes
  uint64_t doorbell; // Physical address of doorbell register
  int sq_dmabuf_fd;  // dmabuf file descriptor for SQ
  int cq_dmabuf_fd;  // dmabuf file descriptor for CQ
};

/**
 * Query LBA size from NVMe controller
 *
 * This function queries the NVMe controller to determine the logical block
 * size (LBA size) of namespace 1 using the Identify Namespace command.
 *
 * @param nvme_device Path to NVMe device (e.g., "/dev/nvme0")
 * @param nsid Namespace ID (default: 1)
 * @param lba_size Output parameter for LBA size in bytes
 * @return 0 on success, negative error code on failure
 */
__host__ int nvme_ep_query_lba_size(const char* nvme_device, uint32_t nsid,
                                    unsigned* lba_size);

/**
 * Query namespace capacity in LBAs from NVMe controller
 *
 * This function queries the NVMe controller to determine the namespace
 * capacity (NSZE - Namespace Size) of namespace 1 using the Identify
 * Namespace command.
 *
 * @param nvme_device Path to NVMe device (e.g., "/dev/nvme0")
 * @param nsid Namespace ID (default: 1)
 * @param capacity_lbas Output parameter for namespace capacity in LBAs
 * @return 0 on success, negative error code on failure
 */
__host__ int nvme_ep_query_namespace_capacity(const char* nvme_device,
                                              uint32_t nsid,
                                              uint64_t* capacity_lbas);

/**
 * Create NVMe IO queue pair via IOCTL interface using kernel module
 *
 * This function:
 * 1. Allocates VRAM buffers for SQ and CQ using HIP
 * 2. Gets physical addresses via kernel module IOCTL
 * 3. Registers queue addresses with kernel module for kprobe injection
 * 4. Creates queues via NVMe IOCTL (CREATE_CQ and CREATE_SQ)
 * 5. The kprobe automatically injects the correct physical addresses
 *
 * @param nvme_device Path to NVMe device (e.g., "/dev/nvme0")
 * @param kernel_module_device Path to kernel module device
 *                            (e.g., "/dev/rocm-axiio")
 * @param queue_id Queue ID to create (0=admin, 1+=IO queues)
 * @param queue_size Queue size in entries (must be power of 2, max 65536)
 * @param nvme_bdf NVMe device BDF in 0xBBDD format (for kernel module)
 * @param info Output structure to hold queue information
 * @return 0 on success, negative error code on failure
 */
__host__ int nvme_ep_create_queue_via_ioctl(
  const char* nvme_device, const char* kernel_module_device, uint16_t queue_id,
  uint16_t queue_size, uint16_t nvme_bdf, unsigned memory_mode,
  struct nvme_queue_info* info);

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
  std::string device;   // NVMe controller device path for queue creation IOCTL
                        // (e.g., /dev/nvme0, /dev/nvme1). Used as target for
                        // CREATE_SQ/CREATE_CQ IOCTL calls.
  uint16_t queueId;     // Queue ID to use (0=admin, 1+=IO queues)
  uint16_t queueLength; // Queue length in entries (must be power of 2, default:
                        // 64)

  // Physical addresses
  uint64_t doorbellAddr; // Physical address of doorbell register
  uint64_t sqBaseAddr;   // Physical base address of submission queue
  uint64_t cqBaseAddr;   // Physical base address of completion queue
  size_t sqSize;         // Size of submission queue in bytes
  size_t cqSize;         // Size of completion queue in bytes

  // I/O operation parameters
  std::string accessPattern; // "sequential" or "random" (default: "random")
  unsigned lbaSize;          // LBA size in bytes (default: 512, auto-detected)
  uint64_t baseLba;          // Starting LBA for I/O operations (default: 0)

  // Data buffer configuration
  size_t dataBufferSize; // Size of data buffers in bytes

  // Test pattern configuration
  uint32_t lfsrSeed; // Seed for LFSR pattern (0 = derive from LBA)

  // I/O operation counts
  int readIo;  // Number of read I/O operations (negative for sequential mode)
  int writeIo; // Number of write I/O operations (negative for sequential mode)

  // PCI MMIO Bridge configuration (Requires OOT QEMU)
  bool usePciMmioBridge;  // Use PCI MMIO bridge for doorbell routing
  uint16_t mmioBridgeBdf; // PCI MMIO bridge BDF (0xBBDD format, e.g., 0x0400
                          // for 00:04.0)
  uint16_t nvmeTargetBdf; // NVMe target device BDF (0xBBDD format, e.g., 0x0600
                          // for 00:06.0)
  void* shadowBufferVirt; // Virtual address of PCI MMIO bridge shadow buffer
                          // (mapped from GPA)

  // Direct doorbell configuration (when PCI MMIO bridge is disabled)
  void* nvmeBar0Gpu; // GPU-accessible pointer to NVMe BAR0 (for direct doorbell
                     // access)

  // Default constructor
  NvmeEpConfig()
    : device(""), queueId(63), queueLength(64), doorbellAddr(0), sqBaseAddr(0),
      cqBaseAddr(0), sqSize(0), cqSize(0), accessPattern("random"),
      lbaSize(512), baseLba(0),    // Default: start at LBA 0
      dataBufferSize(1024 * 1024), // 1 MB default
      lfsrSeed(0), readIo(0),
      writeIo(0), // Default: 0 (must specify at least one)
      usePciMmioBridge(false),
      mmioBridgeBdf(0x0020), // Default: 00:04.0 (bus=0, device=4, function=0 =
                             // 0x0020)
      nvmeTargetBdf(0x0030), // Default: 00:06.0 (bus=0, device=6, function=0 =
                             // 0x0030)
      shadowBufferVirt(nullptr), nvmeBar0Gpu(nullptr) {
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
                "IO access pattern: 'sequential' or 'random'.")
    ->default_val("random")
    ->check(CLI::IsMember({"sequential", "random"}))
    ->group(nvme_group);

  app
    .add_option("--data-buffer-size", config->dataBufferSize,
                "Size of data buffers for NVMe IO (bytes).")
    ->default_val(1024 * 1024) // 1 MB default
    ->check(CLI::PositiveNumber)
    ->group(nvme_group);

  app
    .add_option("--controller", config->device,
                "NVMe controller device path (required).")
    ->required()
    ->group(nvme_group);

  app
    .add_option("--base-lba", config->baseLba,
                "Starting LBA for I/O operations (default: 0)")
    ->default_val(0)
    ->group(nvme_group);

  app
    .add_option("--lfsr-seed", config->lfsrSeed,
                "Seed for LFSR pattern generation (0 = derive from LBA).")
    ->default_val(0)
    ->group(nvme_group);

  app
    .add_option(
      "--read-io", config->readIo,
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
    .add_option(
      "--write-io", config->writeIo,
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
 * @param config Pointer to NvmeEpConfig structure
 * @return Empty string if valid, error message otherwise
 */
inline std::string validateConfig(NvmeEpConfig* config) {
  if (config->accessPattern != "sequential" &&
      config->accessPattern != "random") {
    return "Access pattern must be 'sequential' or 'random'";
  }

  // Validate that at least one I/O count is != 0 (negative values enable
  // sequential mode)
  if (config->readIo == 0 && config->writeIo == 0) {
    return "At least one of --read-io or --write-io must be specified with "
           "value != 0 (use negative values for sequential mode)";
  }

  // Validate that --controller is specified
  if (config->device.empty()) {
    return "--controller must be specified";
  }

  // Auto-detect LBA size from controller
  unsigned detected_lba_size = 0;
  int ret = nvme_ep_query_lba_size(config->device.c_str(), 1,
                                   &detected_lba_size);
  if (ret != 0) {
    return "Failed to query LBA size from controller: " +
           std::string(strerror(-ret));
  }
  config->lbaSize = detected_lba_size;

  // Auto-detect PCI MMIO bridge BDF if --pci-mmio-bridge is set
  if (config->usePciMmioBridge) {
    uint16_t detected_bdf = 0;
    int bdf_ret = axiioDetectPciMmioBridgeBdf(&detected_bdf);
    if (bdf_ret != 0) {
      return "Failed to detect PCI MMIO bridge BDF";
    }
    config->mmioBridgeBdf = detected_bdf;
  }

  // Auto-detect NVMe target BDF from controller device path
  uint16_t detected_nvme_bdf = 0;
  int nvme_bdf_ret = axiioDetectBdfFromDevice(config->device.c_str(),
                                              &detected_nvme_bdf);
  if (nvme_bdf_ret != 0) {
    return std::string("Failed to detect NVMe target BDF: ") +
           std::string(strerror(-nvme_bdf_ret));
  }
  config->nvmeTargetBdf = detected_nvme_bdf;

  // Note: Emulated vs passthrough detection is done on-demand when registering
  // buffers, not stored in config

  return std::string();
}

/**
 * Get iterations count for NVMe endpoint
 *
 * Returns the sum of readIo + writeIo, which represents the total number
 * of I/O operations to perform.
 *
 * @param endpointConfig Pointer to NvmeEpConfig structure
 * @return Total number of iterations (readIo + writeIo)
 */
inline unsigned getIterations(void* endpointConfig) {
  if (endpointConfig) {
    NvmeEpConfig* nvmeConfig = static_cast<NvmeEpConfig*>(endpointConfig);
    if (nvmeConfig->writeIo < 0) {
      // Sequential mode: use absolute value of writeIo
      return -nvmeConfig->writeIo;
    }
    if (nvmeConfig->readIo < 0) {
      // Sequential mode: use absolute value of readIo
      return -nvmeConfig->readIo;
    }
    return nvmeConfig->readIo + nvmeConfig->writeIo;
  }
  return 0;
}

} // namespace nvme_ep

#endif // NVME_EP_H
