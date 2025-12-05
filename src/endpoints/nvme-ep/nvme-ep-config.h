/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef NVME_EP_CONFIG_H
#define NVME_EP_CONFIG_H

#include <cstdint>
#include <string>

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

} // namespace nvme_ep

#endif // NVME_EP_CONFIG_H
