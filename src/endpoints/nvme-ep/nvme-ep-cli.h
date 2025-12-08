/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef NVME_EP_CLI_H
#define NVME_EP_CLI_H

#include <string>

#include <CLI/CLI.hpp>

#include "nvme-ep-config.h"

namespace nvme_ep {

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

#endif // NVME_EP_CLI_H
