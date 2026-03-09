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

#include "xio.h"
/*
 * NVMe Definitions for rocm-xio nvme-ep Endpoint
 */
#include "nvme-ep-generated.h"

namespace nvme_ep {

/**
 * Polling limits for completion queue operations
 */
#define NVME_EP_MAX_POLLS 10000000U            // Maximum polls before timeout
#define NVME_EP_MAX_POLLS_BEFORE_BACKOFF 1000U // Polls before backoff reset

/**
 * Doorbell register constants
 */
constexpr uint32_t doorbellBase = 0x1000U; // Base offset in BAR0
constexpr uint32_t doorBellStride = 4U;    // Bytes per doorbell register

/**
 * NVMe Admin command response size
 */
constexpr size_t nvmeAdminRespSize = 4096U; // Size of NVMe Identify response
                                            // (bytes)

/**
 * NVMe log page size
 */
constexpr size_t nvmeLogPageSize = 512U; // Size of NVMe log pages (e.g., SMART
                                         // log)

/**
 * Type aliases for queue entries
 */
typedef struct nvme_sqe sqeType;
typedef struct nvme_cqe cqeType;

/**
 * NVMe I/O parameters for device function execution
 *
 * Contains all NVMe-specific I/O configuration parameters needed for
 * driveEndpoint execution. This POD struct can be safely passed to GPU
 * device code.
 */
struct nvmeIoParams {
  uint32_t lbaSize;      // Logical block size in bytes
  uint64_t baseLba;      // Starting LBA for I/O operations
  uint64_t lbaRangeLbas; // LBA range limit (0 = no limit)
  bool useRandomAccess;  // true for random access, false for sequential
  int readIo;            // Number of read operations (negative = sequential)
  int writeIo;           // Number of write operations (negative = sequential)
  uint32_t lfsrSeed;     // Seed for LFSR test pattern (0 = derive from LBA)
  uint16_t queueSize;    // Queue size in entries
  uint32_t nsid;         // Namespace ID (must be > 0)
  uint32_t lbasPerIo;    // Number of LBAs per I/O operation (default: 1)
  bool infiniteMode;     // Infinite mode: run forever
};

/**
 * NVMe doorbell parameters for controller notification
 *
 * Contains doorbell configuration supporting both PCI MMIO bridge mode
 * and direct BAR0 access. At least one mode must be configured.
 */
struct nvmeDoorbellParams {
  uint32_t doorbellOffset; // Offset within BAR0 for doorbell register
  uint16_t nvmeTargetBdf;  // NVMe target device BDF (0xBBDD format)
  void* shadowBufferVirt;  // Shadow buffer pointer (MMIO bridge mode)
  void* nvmeBar0Gpu;       // GPU-accessible BAR0 pointer (direct mode)
  bool usePciMmioBridge;   // Use PCI MMIO bridge mode (vs direct BAR0)
};

/**
 * NVMe data buffer parameters for read/write operations
 *
 * Contains buffer pointers and DMA addresses for data transfer operations.
 * Buffers must be GPU-accessible. DMA addresses are used for PRP entries.
 */
struct nvmeBufferParams {
  uint8_t* readBuffer;     // Read buffer pointer (can be nullptr)
  uint8_t* writeBuffer;    // Write buffer pointer (can be nullptr)
  size_t bufferSize;       // Size of buffers in bytes
  uint64_t readBufferDma;  // DMA address for read buffer
  uint64_t writeBufferDma; // DMA address for write buffer
};

/**
 * Drive NVMe endpoint I/O operations from GPU device code
 *
 * This function executes NVMe read/write operations directly from GPU kernels,
 * supporting both batch mode (multiple operations queued) and sequential mode
 * (one operation at a time with completion waiting). The function handles
 * queue management, doorbell ringing, completion polling, and data pattern
 * generation/verification.
 *
 * @param config Base endpoint configuration containing queue pointers,
 *               timing arrays, and common parameters. The submissionQueue
 *               and completionQueue fields must be valid GPU-accessible
 *               pointers.
 * @param ioParams NVMe-specific I/O parameters including LBA configuration,
 *                 operation counts, access pattern, and test pattern seed.
 *                 Negative readIo/writeIo values indicate sequential mode.
 * @param doorbellParams Doorbell configuration for notifying the NVMe
 *                       controller. Supports both PCI MMIO bridge mode and
 *                       direct BAR0 access. At least one mode must be
 *                       configured (shadowBufferVirt for MMIO bridge or
 *                       nvmeBar0Gpu for direct access).
 * @param bufferParams Data buffer configuration for read/write operations.
 *                     Buffers must be GPU-accessible. DMA addresses are used
 *                     for PRP (Physical Region Page) entries in NVMe commands.
 *                     Buffers can be nullptr if not used for a given operation
 *                     type.
 *
 * @note This is a device function and must be called from GPU kernels.
 * @note Sequential mode: if readIo < 0 or writeIo < 0, operations are issued
 *       one at a time with completion waiting. Writes execute before reads
 *       when both are negative.
 * @note Batch mode: operations are queued and completed asynchronously.
 * @note The function uses config.iterations for batch mode operation count.
 */
__device__ void driveEndpoint(const XioEndpointConfig& config,
                              const nvmeIoParams& ioParams,
                              const nvmeDoorbellParams& doorbellParams,
                              const nvmeBufferParams& bufferParams);

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
__host__ int queryLbaSize(const char* nvme_device, uint32_t nsid,
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

__host__ int queryNamespaceCapacity(const char* nvme_device, uint32_t nsid,
                                    uint64_t* capacity_lbas);

/**
 * Check if NVMe device is the root filesystem
 *
 * This function checks /proc/mounts to determine if the specified NVMe
 * device is mounted as the root filesystem. This is useful to prevent
 * accidental data corruption during testing.
 *
 * @param nvme_device Path to NVMe device (e.g., "/dev/nvme0")
 * @return 0 if device is not rootfs (safe to use), -1 if device is rootfs
 *         (unsafe), or 0 if check cannot be performed (allows to proceed)
 */
__host__ int checkRootfs(const char* nvme_device);

/**
 * Read NVMe SMART/Health Information log page
 *
 * This function reads the SMART log page (Log Identifier 0x02) from the
 * NVMe controller. The SMART log contains various device statistics including
 * data units read/written, host commands completed, power cycles, etc.
 *
 * @param nvme_device Path to NVMe device (e.g., "/dev/nvme0")
 * @param smart_log Output structure to hold SMART log data (512 bytes)
 * @return 0 on success, negative error code on failure
 */
__host__ int readSmartLog(const char* nvme_device,
                          struct nvme_smart_log* smart_log);

/**
 * Query maximum number of queues supported by NVMe controller
 *
 * This function reads the queue count from sysfs to determine the maximum
 * number of queues. The sysfs queue_count represents the total number of
 * queues (1 admin queue + N I/O queues).
 *
 * @param nvme_device Path to NVMe device (e.g., "/dev/nvme1")
 * @param max_queue_id Output parameter for maximum queue ID (last I/O queue)
 * @return 0 on success, negative error code on failure
 *
 * @note Returns the last I/O queue ID (max_queue_id). Queue 0 is admin,
 *       queues 1-N are I/O queues, so if queue_count=33, max_queue_id=32.
 */
__host__ int queryMaxQueueId(const char* nvme_device, uint16_t* max_queue_id);

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
 *                            (e.g., "/dev/rocm-xio")
 * @param queue_id Queue ID to create (0=admin, 1+=IO queues)
 * @param queue_size Queue size in entries (must be power of 2, max 65536)
 * @param nvme_bdf NVMe device BDF in 0xBBDD format (for kernel module)
 * @param memory_mode Memory allocation mode (bits: 0=GPU write location, 1=CPU
 * write location)
 * @param info Output structure to hold queue information
 * @return 0 on success, negative error code on failure
 */
__host__ int createQueue(const char* nvme_device,
                         const char* kernel_module_device, uint16_t queue_id,
                         uint16_t queue_size, uint16_t nvme_bdf,
                         unsigned memory_mode, struct nvme_queue_info* info);

/**
 * Delete NVMe queues (SQ and CQ) for a given queue ID
 *
 * Deletes both the Submission Queue (SQ) and Completion Queue (CQ) for the
 * specified queue ID. The queues are deleted in the correct order: SQ first,
 * then CQ, as required by the NVMe specification (CQ cannot be deleted while
 * an associated SQ exists).
 *
 * Errors are logged but not fatal, as the queues may not exist. This function
 * is typically called before creating new queues to ensure a clean state.
 *
 * @param nvme_fd File descriptor for NVMe device (opened with open())
 * @param queue_id Queue ID to delete (0=admin, 1+=IO queues)
 *
 * @return 0 on success (or if queues don't exist), negative error code on
 *         fatal failure
 *
 * @note This function ignores errors from DELETE_SQ and DELETE_CQ commands,
 *       as the queues may not exist. Only fatal errors (e.g., invalid file
 *       descriptor) will cause a non-zero return value.
 */
__host__ int deleteQueue(int nvme_fd, uint16_t queue_id);

/**
 * Cleanup NVMe queues from signal handler
 *
 * This function attempts to delete NVMe queues when called from a signal
 * handler (e.g., SIGINT). It reopens the device and calls deleteQueue.
 *
 * @param endpointConfig Opaque pointer to nvmeEpConfig structure
 * @return 0 on success, negative error code on failure
 *
 * @note This function is safe to call from signal handlers (async-signal-safe)
 * @note Only attempts cleanup if queuesCreated flag is true
 */
extern "C" __host__ int nvme_ep_cleanup_queues(void* endpointConfig);

/**
 * Send NVMe CREATE_CQ and CREATE_SQ commands to create queues
 *
 * Sends the NVMe admin commands to create both the Completion Queue (CQ) and
 * Submission Queue (SQ) for the specified queue ID. The CQ is created first,
 * then the SQ (which references the CQ).
 *
 * Physical addresses are injected by the kernel module kprobe, so virtual
 * addresses are passed in the commands.
 *
 * @param nvme_fd File descriptor for NVMe device (opened with open())
 * @param queue_id Queue ID to create (0=admin, 1+=IO queues)
 * @param queue_size Queue size in entries (must be power of 2)
 * @param sq_virt Virtual address of submission queue buffer
 * @param cq_virt Virtual address of completion queue buffer
 *
 * @return 0 on success, negative error code on failure
 *
 * @note This function sends the CREATE_CQ and CREATE_SQ admin commands via
 *       NVME_IOCTL_ADMIN_CMD. The kernel module kprobe will inject the
 *       physical addresses into the PRP1 fields automatically.
 */
__host__ int createQueueCommands(int nvme_fd, uint16_t queue_id,
                                 uint16_t queue_size, void* sq_virt,
                                 void* cq_virt);

/**
 * Read NVMe Submission Queue Entry (SQE) from memory
 *
 * Safely reads an entire NVMe command structure from a volatile memory
 * location. This function performs a byte-by-byte copy to ensure correct
 * behavior with volatile pointers, which is necessary when accessing
 * memory-mapped I/O regions or shared memory that may be modified by
 * hardware or other threads.
 *
 * @param sqeAddress Pointer to the volatile SQE location to read from
 * @return Copy of the SQE structure containing the NVMe command data
 *
 * @note This function is safe for use with volatile pointers and can be
 *       called from both host and device code.
 * @note The function performs a byte-by-byte copy to avoid compiler
 *       optimizations that might skip volatile reads.
 */
__host__ __device__ sqeType sqeRead(volatile sqeType* sqeAddress);

/**
 * Read NVMe Completion Queue Entry (CQE) from memory
 *
 * Safely reads an entire NVMe completion structure from a volatile memory
 * location. This function performs a byte-by-byte copy to ensure correct
 * behavior with volatile pointers, which is necessary when accessing
 * memory-mapped I/O regions or shared memory that may be modified by
 * hardware or other threads.
 *
 * @param cqeAddress Pointer to the volatile CQE location to read from
 * @return Copy of the CQE structure containing the NVMe completion data
 *
 * @note This function is safe for use with volatile pointers and can be
 *       called from both host and device code.
 * @note The function performs a byte-by-byte copy to avoid compiler
 *       optimizations that might skip volatile reads.
 */
__host__ __device__ cqeType cqeRead(volatile cqeType* cqeAddress);

/**
 * Write NVMe Submission Queue Entry (SQE) to memory
 *
 * Safely writes an entire NVMe command structure to a volatile memory
 * location. This function performs a byte-by-byte copy followed by a
 * memory fence to ensure correct ordering and visibility of the write
 * operation. This is necessary when writing to memory-mapped I/O regions
 * or shared memory that may be accessed by hardware or other threads.
 *
 * @param sqeData The SQE structure containing the NVMe command data to
 *                write
 * @param sqeAddress Pointer to the volatile SQE location to write to
 *
 * @note This function is safe for use with volatile pointers and can be
 *       called from both host and device code.
 * @note The function performs a byte-by-byte copy to avoid compiler
 *       optimizations that might skip volatile writes.
 * @note A memory fence is executed after the write to ensure the data is
 *       visible to other threads/hardware before subsequent operations.
 */
__host__ __device__ void sqeWrite(sqeType sqeData,
                                  volatile sqeType* sqeAddress);

/**
 * Write NVMe Completion Queue Entry (CQE) to memory
 *
 * Safely writes an entire NVMe completion structure to a volatile memory
 * location. This function performs a byte-by-byte copy followed by a
 * memory fence to ensure correct ordering and visibility of the write
 * operation. This is necessary when writing to memory-mapped I/O regions
 * or shared memory that may be accessed by hardware or other threads.
 *
 * @param cqeData The CQE structure containing the NVMe completion data
 *                to write
 * @param cqeAddress Pointer to the volatile CQE location to write to
 *
 * @note This function is safe for use with volatile pointers and can be
 *       called from both host and device code.
 * @note The function performs a byte-by-byte copy to avoid compiler
 *       optimizations that might skip volatile writes.
 * @note A memory fence is executed after the write to ensure the data is
 *       visible to other threads/hardware before subsequent operations.
 */
__host__ __device__ void cqeWrite(cqeType cqeData,
                                  volatile cqeType* cqeAddress);

/**
 * Poll for new SQE - waits for command ID to change
 * Simple polling function that waits until a new command appears
 *
 * @param sqeLast Last known SQE state
 * @param sqeAddress Pointer to SQE to poll
 * @return New SQE when command ID or opcode changes
 */
__host__ __device__ sqeType sqePoll(sqeType sqeLast,
                                    volatile sqeType* sqeAddress);

/**
 * Poll for new CQE - waits for command ID to change or sq_head progression
 * Enhanced polling function that checks both command ID change and sq_head
 * progression for more robust completion detection. sq_head progression is
 * the definitive indicator of completion and works regardless of which CQE
 * slot the completion appears in.
 *
 * @param cqeLast Last known CQE state
 * @param cqeAddress Pointer to CQE to poll
 * @param last_sq_head Last known submission queue head value (for sq_head
 * tracking)
 * @param sq_head_out Output parameter for new sq_head value (can be nullptr)
 * @param stopRequested Optional pointer to stop flag - if set to true, polling
 *                      will exit early (can be nullptr)
 * @return New CQE when command ID changes or sq_head increases, or last CQE
 *         if stopRequested is true
 */
__host__ __device__ cqeType
cqePoll(cqeType cqeLast, volatile cqeType* cqeAddress,
        uint16_t last_sq_head = 0, uint16_t* sq_head_out = nullptr,
        const volatile bool* stopRequested = nullptr);

/**
 * Setup NVMe Submission Queue Entry (SQE) for Read or Write command
 *
 * Initializes an NVMe command structure (SQE) with the parameters needed
 * for a read or write operation. This function configures all required
 * fields including the opcode, command ID, namespace ID, starting LBA,
 * number of logical blocks, and PRP (Physical Region Page) pointers for
 * data transfer.
 *
 * The input SQE should have the following fields pre-filled:
 * - opcode: nvme_cmd_read or nvme_cmd_write
 * - command_id: Command ID (must be unique per queue)
 * - nsid: Namespace ID (typically 1 for first namespace)
 * - dptr.prp.prp1: First PRP entry (data buffer or first page)
 * - dptr.prp.prp2: Second PRP entry (0 if single page, or PRP list)
 * - cdw10: Lower 32 bits of starting LBA (or 0, will be set from slba)
 * - cdw11: Upper 32 bits of starting LBA (or 0, will be set from slba)
 * - cdw12: Number of logical blocks minus 1 (or 0, will be set from nlb)
 *
 * This function will:
 * - Set flags, cdw2, cdw3, metadata, cdw13-15 to 0
 * - If slba is non-zero, split it across cdw10 and cdw11
 * - If nlb is non-zero, set cdw12 to nlb-1 (0-based encoding)
 *
 * @param sqe Pointer to the NVMe SQE structure to initialize (input/output)
 * @param slba Starting Logical Block Address (0 to use existing cdw10/cdw11)
 * @param nlb Number of logical blocks to read/write (0 to use existing cdw12)
 *
 * @note The function sets nlb-1 in cdw12 because NVMe uses 0-based block
 *       counts (0 means 1 block, 1 means 2 blocks, etc.).
 * @note slba is split across cdw10 (lower 32 bits) and cdw11 (upper 32 bits)
 *       to support 64-bit LBA addresses.
 * @note This function can be called from both host and device code.
 * @note If slba is 0, the function preserves existing cdw10/cdw11 values.
 * @note If nlb is 0, the function preserves existing cdw12 value.
 */
__host__ __device__ inline void sqeSetup(struct nvme_sqe* sqe, uint64_t slba,
                                         uint32_t nlb) {
  // Zero out unused/reserved fields
  sqe->flags = 0;
  sqe->cdw2 = 0;
  sqe->cdw3 = 0;
  sqe->metadata = 0;
  sqe->cdw13 = 0;
  sqe->cdw14 = 0;
  sqe->cdw15 = 0;

  // Set LBA if provided
  if (slba != 0) {
    sqe->cdw10 = (uint32_t)(slba & 0xFFFFFFFF);         // SLBA lower 32 bits
    sqe->cdw11 = (uint32_t)((slba >> 32) & 0xFFFFFFFF); // SLBA upper 32 bits
  }

  // Set number of logical blocks if provided
  if (nlb != 0) {
    sqe->cdw12 = nlb - 1;
  }
}

/**
 * Check if NVMe Completion Queue Entry (CQE) indicates successful completion
 *
 * Examines the status field of a CQE to determine if the associated command
 * completed successfully. A command is considered successful if:
 * - Status Code Type (SCT) is NVME_SCT_GENERIC (0x0)
 * - Status Code (SC) is NVME_SC_SUCCESS (0x0)
 *
 * @param cqe Pointer to the volatile CQE to check
 * @return true if the command completed successfully, false otherwise
 *
 * @note This function safely handles volatile pointers and can be called
 *       from both host and device code.
 * @note Returns false for any error condition, including command-specific
 *       errors, media errors, or vendor-specific errors.
 */
__host__ __device__ static inline bool cqeOk(const volatile cqeType* cqe) {
  uint16_t status = cqe->status;

  uint8_t sc = NVME_CQE_STATUS_SC(status);
  uint8_t sct = NVME_CQE_STATUS_SCT(status);

  return (sct == NVME_SCT_GENERIC && sc == NVME_SC_SUCCESS);
}

/**
 * Extract status code from NVMe Completion Queue Entry (CQE)
 *
 * Extracts the Status Code (SC) field from the CQE status register. The
 * status code is an 8-bit value (bits 1-8 of the 16-bit status field) that
 * indicates the specific result of the command execution. Common status codes
 * include:
 * - NVME_SC_SUCCESS (0x0): Command completed successfully
 * - NVME_SC_INVALID_OPCODE (0x1): Invalid command opcode
 * - NVME_SC_INVALID_FIELD (0x2): Invalid field in command
 * - NVME_SC_LBA_RANGE (0x80): LBA out of range
 *
 * The meaning of the status code depends on the Status Code Type (SCT), which
 * can be obtained using cqeStatusType().
 *
 * @param cqe Pointer to the volatile CQE to read from
 * @return 8-bit status code value extracted from the CQE status field
 *
 * @note This function safely handles volatile pointers and can be called
 *       from both host and device code.
 * @note The status code alone does not indicate success/failure - use
 *       cqeOk() to check for successful completion, or combine with
 *       cqeStatusType() for detailed error analysis.
 */
__host__ __device__ static inline uint8_t cqeStatusCode(
  const volatile cqeType* cqe) {
  return NVME_CQE_STATUS_SC(cqe->status);
}

/**
 * Extract status code type from NVMe Completion Queue Entry (CQE)
 *
 * Extracts the Status Code Type (SCT) field from the CQE status register.
 * The status code type is a 3-bit value (bits 9-11 of the 16-bit status
 * field) that categorizes the type of status code reported. Common status
 * code types include:
 * - NVME_SCT_GENERIC (0x0): Generic command status (most common)
 * - NVME_SCT_CMD_SPECIFIC (0x1): Command-specific status
 * - NVME_SCT_MEDIA_ERROR (0x2): Media and data integrity errors
 * - NVME_SCT_VENDOR (0x7): Vendor-specific status
 *
 * The status code type determines how to interpret the status code value
 * returned by cqeStatusCode(). For example, a status code of 0x80 means
 * different things depending on the SCT:
 * - SCT=GENERIC: NVME_SC_LBA_RANGE (LBA out of range)
 * - SCT=MEDIA_ERROR: Media error with vendor-specific details
 *
 * @param cqe Pointer to the volatile CQE to read from
 * @return 3-bit status code type value (0-7) extracted from the CQE status
 *         field
 *
 * @note This function safely handles volatile pointers and can be called
 *       from both host and device code.
 * @note Combine with cqeStatusCode() for complete error analysis, or use
 *       cqeOk() for simple success/failure checking.
 */
__host__ __device__ static inline uint8_t cqeStatusType(
  const volatile cqeType* cqe) {
  return NVME_CQE_STATUS_SCT(cqe->status);
}

/**
 * Calculate Physical Region Page (PRP) entries for NVMe data transfer
 *
 * Computes the PRP1 and PRP2 entries needed for an NVMe read or write
 * command based on the buffer address and size. PRPs are used to describe
 * the physical memory layout of data buffers to the NVMe controller.
 *
 * The function handles three cases:
 * 1. Single page: Buffer fits entirely within one 4KB page. Only PRP1 is
 *    set (PRP2 = 0).
 * 2. Two pages: Buffer spans exactly two pages. PRP1 points to the first
 *    page, PRP2 points to the second page.
 * 3. Multiple pages: Buffer spans more than two pages. PRP1 points to the
 *    first page, PRP2 points to the second page (simplified implementation
 *    - does not create PRP lists for >2 pages).
 *
 * @param bufferAddr Physical/DMA address of the data buffer
 * @param bufferSize Size of the buffer in bytes
 * @param sqe Pointer to the NVMe SQE structure where PRP1 and PRP2 entries
 *            will be written to sqe->dptr.prp.prp1 and sqe->dptr.prp.prp2
 *
 * @note This function safely handles unaligned buffer addresses by calculating
 *       the offset within the first page.
 * @note For buffers spanning more than 2 pages, this is a simplified
 *       implementation that only sets PRP2 to the second page. Full PRP list
 *       support would require additional logic.
 * @note This function can be called from both host and device code.
 * @note The buffer address should be a physical/DMA address, not a virtual
 *       address.
 */
__host__ __device__ static inline void calculatePrps(uint64_t bufferAddr,
                                                     uint32_t bufferSize,
                                                     struct nvme_sqe* sqe) {
  sqe->dptr.prp.prp1 = bufferAddr;
  sqe->dptr.prp.prp2 = 0;

  // Calculate how much data the first page can hold
  uint64_t offset_in_page = bufferAddr & (NVME_PAGE_SIZE - 1);
  uint64_t first_page_size = NVME_PAGE_SIZE - offset_in_page;

  // If buffer fits in first page, we're done
  if (bufferSize <= first_page_size) {
    return;
  }

  // Buffer spans multiple pages - set PRP2 to next page
  // (Simplified: doesn't handle PRP lists for >2 pages)
  sqe->dptr.prp.prp2 = (bufferAddr + first_page_size) & ~(NVME_PAGE_SIZE - 1);
}

/**
 * Data pattern generation parameters
 *
 * POD struct containing all parameters needed for LFSR-based data pattern
 * generation or verification. This struct can be safely passed to GPU device
 * code.
 */
struct dataPatternParams {
  uint8_t* buffer;   // Buffer to generate pattern into or verify against
  size_t size;       // Size of buffer in bytes
  uint64_t offset;   // Byte offset within the data stream (for LBA calculation)
  uint32_t lbaSize;  // Logical block size in bytes (for LBA calculation)
  uint32_t lfsrSeed; // Seed for LFSR pattern (0 = derive from LBA)
  size_t* errorOffset; // Output: Byte offset of first mismatch (verify mode
                       // only, can be nullptr)
};

/**
 * Generate or verify LFSR-based test data pattern
 *
 * Generates or verifies a deterministic pseudo-random data pattern using a
 * Linear Feedback Shift Register (LFSR) algorithm. The pattern is derived
 * from the Logical Block Address (LBA) calculated from the byte offset and
 * LBA size, combined with an optional seed value.
 *
 * In generate mode, the function writes the calculated pattern to the buffer.
 * In verify mode, the function checks that the buffer matches the expected
 * pattern and optionally reports the offset of the first mismatch.
 *
 * The pattern generation algorithm:
 * 1. Calculates LBA from offset and lbaSize
 * 2. Creates base seed from LBA (LBA * 0x12345678)
 * 3. XORs base seed with lfsrSeed
 * 4. For each byte, generates pseudo-random value using hash function
 * 5. Uses MurmurHash3-style mixing for good distribution
 *
 * @param isVerify If true, verifies buffer against expected pattern; if false,
 *                 generates pattern into buffer
 * @param params Pattern generation parameters including buffer, size, offset,
 *               LBA size, seed, and optional error offset output pointer
 * @return true on success (generate always succeeds, verify returns true only
 *         if buffer matches expected pattern)
 *
 * @note This function can be called from both host and device code.
 * @note The pattern is deterministic - the same LBA and seed always produce
 *       the same pattern.
 * @note In verify mode, if errorOffset is provided and a mismatch is found,
 *       it will be set to the byte offset of the first error.
 * @note The buffer must be writable in generate mode, but verify mode only
 *       reads from it (const_cast is used internally for type compatibility).
 */
__host__ __device__ static inline bool dataPattern(bool isVerify,
                                                   dataPatternParams& params) {
  uint64_t lba = params.offset / params.lbaSize;
  uint32_t base_seed = (uint32_t)(lba * 0x12345678);
  uint32_t seed = base_seed ^ params.lfsrSeed;

  for (size_t i = 0; i < params.size; i++) {
    uint32_t rng = (uint32_t)(lba * 0x9e3779b9 + seed + i);
    rng ^= rng >> 16;
    rng *= 0x85ebca6b;
    rng ^= rng >> 13;
    rng *= 0xc2b2ae35;
    rng ^= rng >> 16;
    uint8_t expected = (uint8_t)(rng & 0xFF);

    if (isVerify) {
      if (params.buffer[i] != expected) {
        if (params.errorOffset) {
          *params.errorOffset = i;
        }
        return false;
      }
    } else {
      params.buffer[i] = expected;
    }
  }

  return true;
}

/**
 * Ring NVMe doorbell with support for both PCI MMIO bridge and direct BAR0
 * modes
 *
 * @param value Doorbell value to write (sq_tail for SQ, cq_head for CQ)
 * @param doorbellParams Doorbell configuration parameters
 * @param offset_override Optional offset override (defaults to
 *                        doorbellParams.doorbellOffset). Use this for CQ
 *                        doorbell which is at SQ offset + doorBellStride.
 */
__host__ __device__ void ringDoorbell(uint16_t value,
                                      const nvmeDoorbellParams& doorbellParams,
                                      uint32_t offset_override = UINT32_MAX);

/**
 * GPU kernel entry point for NVMe endpoint operations
 *
 * This kernel function is launched from host code to execute NVMe I/O
 * operations on the GPU. It calls driveEndpoint with the provided struct
 * parameters.
 *
 * @param config Base endpoint configuration (endpointConfig field set to
 * nullptr)
 * @param ioParams NVMe I/O parameters struct
 * @param doorbellParams Doorbell configuration parameters struct
 * @param bufferParams Data buffer parameters struct
 */
__global__ void gpuKernel(XioEndpointConfig config, nvmeIoParams ioParams,
                          nvmeDoorbellParams doorbellParams,
                          nvmeBufferParams bufferParams);

/**
 * NVMe Endpoint Configuration Structure
 *
 * Contains all NVMe-specific configuration options that were previously
 * scattered in the main tester's cmdLineArgs structure. This structure
 * groups related fields using nested structs that mirror the POD structs
 * used in device code.
 */
struct nvmeEpConfig {
  // Device and queue configuration (host-side only)
  std::string controller; // NVMe controller device path
  uint16_t queueId;       // Queue ID to use (0=admin, 1+=IO queues)
  uint16_t queueLength;   // Queue length in entries (must be power of 2)
  bool queuesCreated; // Flag indicating queues have been created (for cleanup)

  // Physical addresses (host-side only)
  uint64_t doorbellAddr; // Physical address of doorbell register
  uint64_t sqBaseAddr;   // Physical base address of submission queue
  uint64_t cqBaseAddr;   // Physical base address of completion queue
  size_t sqSize;         // Size of submission queue in bytes
  size_t cqSize;         // Size of completion queue in bytes

  // I/O operation parameters (mirrors nvmeIoParams POD struct)
  struct {
    std::string accessPattern; // "sequential" or "random" (default: "random")
    unsigned lbaSize;      // LBA size in bytes (default: 512, auto-detected)
    uint64_t baseLba;      // Starting LBA for I/O operations (default: 0)
    uint64_t lbaRangeLbas; // LBA range limit (0 = no limit, default: 0)
    uint32_t lfsrSeed;     // Seed for LFSR pattern (0 = derive from LBA)
    int readIo;    // Number of read I/O operations (negative for sequential)
    int writeIo;   // Number of write I/O operations (negative for sequential)
    uint32_t nsid; // Namespace ID (default: 1, must be > 0)
    uint32_t lbasPerIo; // Number of LBAs per I/O operation (default: 1)
    bool infiniteMode;  // Infinite mode: run forever.
  } ioParams;

  // Data buffer configuration (mirrors nvmeBufferParams POD struct)
  struct {
    size_t bufferSize; // Size of data buffers in bytes
  } bufferParams;

  // Doorbell configuration (mirrors nvmeDoorbellParams POD struct)
  struct {
    bool usePciMmioBridge;  // Use PCI MMIO bridge for doorbell routing
    uint16_t mmioBridgeBdf; // PCI MMIO bridge BDF (0xBBDD format, e.g., 0x0400
                            // for 00:04.0)
    uint16_t nvmeTargetBdf; // NVMe target device BDF (0xBBDD format, e.g.,
                            // 0x0600 for 00:06.0)
    void* shadowBufferVirt; // Virtual address of PCI MMIO bridge shadow buffer
                            // (mapped from GPA)
    void* nvmeBar0Gpu;      // GPU-accessible pointer to NVMe BAR0 (for direct
                            // doorbell)
  } doorbellParams;

  // Default constructor
  // Note: queueId defaults to 0 (invalid) - will be auto-detected in
  // validateConfig
  nvmeEpConfig()
    : controller(""), queueId(0), queueLength(64), queuesCreated(false),
      doorbellAddr(0), sqBaseAddr(0), cqBaseAddr(0), sqSize(0), cqSize(0),
      ioParams{"random", 512, 0, 0, 0, 0, 0, 1, 1, false},
      bufferParams{1024 * 1024},
      doorbellParams{false, 0x0020, 0x0030, nullptr, nullptr} {
  }
};

/**
 * Register NVMe endpoint-specific CLI options
 *
 * This function registers all NVMe-specific command-line options with
 * the CLI11 parser. Options are registered with shorter names (without
 * --nvme- prefix) for cleaner CLI, but backward-compatible aliases
 * are also provided.
 *
 * @param app CLI11 App object to add options to
 * @param config Pointer to nvmeEpConfig structure to populate
 */
__host__ void registerCliOptions(CLI::App& app, nvmeEpConfig* config);

/**
 * Validate NVMe endpoint configuration
 *
 * This function also auto-detects LBA size from the controller.
 * --controller is required and LBA size is always queried from it.
 *
 * @param config Pointer to nvmeEpConfig structure
 * @return Empty string if valid, error message otherwise
 */
__host__ std::string validateConfig(nvmeEpConfig* config);

/**
 * Run NVMe endpoint operations
 *
 * This function sets up queues, allocates buffers, and launches the GPU
 * kernel to execute NVMe I/O operations.
 *
 * @param config Pointer to XioEndpointConfig structure containing queue
 *               pointers and common configuration
 * @return hipSuccess on success, error code on failure
 */
__host__ hipError_t run(XioEndpointConfig* config);

} // namespace nvme_ep

#endif // NVME_EP_H
