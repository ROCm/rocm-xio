/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "nvme-ep.h"
#include "xio-endpoint-registry.h"
#include "xio.h"

// PCI MMIO Bridge structures (matching QEMU implementation)
// These must be defined before device code that uses them
struct pci_mmio_bridge_ring_meta {
  uint32_t producer_idx; // Guest/device write index (tail)
  uint32_t consumer_idx; // QEMU read index (head)
  uint32_t queue_depth;  // Total number of command slots
  uint32_t reserved;
} __attribute__((packed));

struct pci_mmio_bridge_command {
  uint16_t target_bdf; // Bus:Device:Function (bus|devfn)
  uint8_t target_bar;  // Which BAR on target device (0-5)
  uint8_t reserved1;
  uint32_t offset; // Offset within BAR
  uint64_t value;  // Value to write, or returned value for read
  uint8_t command; // Command type (WRITE=1, READ=2)
  uint8_t size;    // Transfer size: 1, 2, 4, or 8 bytes
  uint8_t status;  // Status (PENDING=0, COMPLETE=1, ERROR=2)
  uint8_t reserved2;
  uint32_t sequence; // Sequence number for ordering
} __attribute__((packed));

// Command types
#define PCI_MMIO_BRIDGE_CMD_NOP 0
#define PCI_MMIO_BRIDGE_CMD_WRITE 1
#define PCI_MMIO_BRIDGE_CMD_READ 2

// Status codes
#define PCI_MMIO_BRIDGE_STATUS_PENDING 0
#define PCI_MMIO_BRIDGE_STATUS_COMPLETE 1
#define PCI_MMIO_BRIDGE_STATUS_ERROR 2

// Host-only includes for IOCTL and file operations
#ifndef __HIP_DEVICE_COMPILE__
#include <errno.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <drm/amdgpu_drm.h>
#include <drm/drm.h>
#include <fcntl.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <linux/ioctl.h>
#include <linux/nvme_ioctl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

// Device path constant (needed in host code)
#define ROCM_XIO_DEVICE_PATH "/dev/rocm-xio"

// Include kernel module header for IOCTL definitions
// We need to define userspace-compatible structures since the kernel header
// uses kernel-specific types
#define ROCM_XIO_IOC_MAGIC 'R'

// Flags for VRAM physical address request (matching
// kernel/rocm-xio/rocm-xio.h)
#define ROCM_XIO_FLAG_EMULATED (1 << 0)    // Return BAR GPA for emulated NVMe
#define ROCM_XIO_FLAG_PASSTHROUGH (1 << 1) // Return P2PDMA IOVA for passthrough

// Userspace-compatible structures (matching kernel/rocm-xio/rocm-xio.h)
struct rocm_axiio_vram_req {
  int dmabuf_fd;
  uint16_t nvme_bdf;
  uint32_t flags;
  uint64_t phys_addr;
  uint64_t size;
};

struct rocm_axiio_register_queue_addr_req {
  uint64_t virt_addr;
  uint64_t phys_addr;
  uint64_t size;
  uint8_t queue_type;
};

struct rocm_axiio_mmio_bridge_shadow_req {
  uint16_t bridge_bdf;  // Input: PCI MMIO bridge BDF (0xBBDD format)
  uint64_t shadow_gpa;  // Output: Shadow buffer Guest Physical Address
  uint64_t shadow_size; // Output: Shadow buffer size in bytes
};

struct rocm_axiio_register_buffer_req {
  int dmabuf_fd;      // Input: dmabuf file descriptor (-1 if not available)
  uint64_t virt_addr; // Input: Virtual address (userspace pointer)
  uint64_t phys_addr; // Output: Physical address (filled by kernel)
  uint64_t size;      // Input: Buffer size
  uint16_t nvme_bdf;  // Input: NVMe device BDF (0xBBDD format)
  uint32_t flags;     // Input: flags (see ROCM_XIO_FLAG_*)
};

#define ROCM_XIO_GET_VRAM_PHYS_ADDR                                            \
  _IOWR(ROCM_XIO_IOC_MAGIC, 1, struct rocm_axiio_vram_req)
#define ROCM_XIO_REGISTER_QUEUE_ADDR                                           \
  _IOW(ROCM_XIO_IOC_MAGIC, 6, struct rocm_axiio_register_queue_addr_req)
#define ROCM_XIO_REGISTER_BUFFER                                               \
  _IOW(ROCM_XIO_IOC_MAGIC, 8, struct rocm_axiio_register_buffer_req)
#define ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER                                 \
  _IOWR(ROCM_XIO_IOC_MAGIC, 10, struct rocm_axiio_mmio_bridge_shadow_req)
#endif // __HIP_DEVICE_COMPILE__

// Namespace all nvme-ep implementation to avoid conflicts
namespace nvme_ep {

// Use types from nvme-ep.h
typedef struct nvme_sqe sqeType;
typedef struct nvme_cqe cqeType;

// Verify that the queue entry sizes match nvme-ep expectations
static_assert(sizeof(sqeType) == NVME_EP_SQE_SIZE, "nvme-ep SQE size mismatch");
static_assert(sizeof(cqeType) == NVME_EP_CQE_SIZE, "nvme-ep CQE size mismatch");

//
// NVMe-specific helper functions
//

// Compare two NVMe SQEs by command ID
__host__ __device__ bool nvme_sqe_equal(const sqeType* a, const sqeType* b) {
  return (a->command_id == b->command_id && a->opcode == b->opcode);
}

// Compare two NVMe CQEs by command ID
__host__ __device__ bool nvme_cqe_equal(const cqeType* a, const cqeType* b) {
  return (a->command_id == b->command_id);
}

// Read SQE - copies entire NVMe command structure
__host__ __device__ sqeType sqeRead(volatile sqeType* sqeAddress) {
  sqeType result;
  // Copy the entire structure byte-by-byte to handle volatile correctly
  const volatile uint8_t* src = reinterpret_cast<const volatile uint8_t*>(
    sqeAddress);
  uint8_t* dst = reinterpret_cast<uint8_t*>(&result);
  for (size_t i = 0; i < sizeof(sqeType); i++) {
    dst[i] = src[i];
  }
  return result;
}

// Read CQE - copies entire NVMe completion structure
__host__ __device__ cqeType cqeRead(volatile cqeType* cqeAddress) {
  cqeType result;
  // Copy the entire structure byte-by-byte to handle volatile correctly
  const volatile uint8_t* src = reinterpret_cast<const volatile uint8_t*>(
    cqeAddress);
  uint8_t* dst = reinterpret_cast<uint8_t*>(&result);
  for (size_t i = 0; i < sizeof(cqeType); i++) {
    dst[i] = src[i];
  }
  return result;
}

// Write SQE - copies entire NVMe command structure with memory fence
__host__ __device__ void sqeWrite(sqeType sqeData,
                                  volatile sqeType* sqeAddress) {
  // Copy entire structure byte-by-byte to handle volatile correctly
  // Uses volatile pointer to ensure writes are not optimized away and are
  // visible to PCIe devices (critical for GPU-PCIe coherency)
  const uint8_t* src = reinterpret_cast<const uint8_t*>(&sqeData);
  volatile uint8_t* dst = reinterpret_cast<volatile uint8_t*>(sqeAddress);
  for (size_t i = 0; i < sizeof(sqeType); i++) {
    dst[i] = src[i];
  }
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif // __HIP_DEVICE_COMPILE__
}

// Write CQE - copies entire NVMe completion structure with memory fence
// Uses volatile pointer to ensure writes are not optimized away
__host__ __device__ void cqeWrite(cqeType cqeData,
                                  volatile cqeType* cqeAddress) {
  // Copy entire structure byte-by-byte to handle volatile correctly
  const uint8_t* src = reinterpret_cast<const uint8_t*>(&cqeData);
  volatile uint8_t* dst = reinterpret_cast<volatile uint8_t*>(cqeAddress);
  for (size_t i = 0; i < sizeof(cqeType); i++) {
    dst[i] = src[i];
  }
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif // __HIP_DEVICE_COMPILE__
}

// Poll for new SQE - waits for command ID to change
__host__ __device__ sqeType sqePoll(sqeType sqeLast,
                                    volatile sqeType* sqeAddress) {
  sqeType sqeNew;
  while (true) {
    sqeNew = sqeRead(sqeAddress);
    // Check if we got a new command (different command ID or different opcode)
    if (sqeNew.command_id != sqeLast.command_id ||
        sqeNew.opcode != sqeLast.opcode) {
      return sqeNew;
    }
  }
}

// Poll for new CQE - waits for command ID to change
__host__ __device__ cqeType cqePoll(cqeType cqeLast,
                                    volatile cqeType* cqeAddress) {
  cqeType cqeNew;
  while (true) {
    cqeNew = cqeRead(cqeAddress);
    // Check if we got a new completion (different command ID)
    if (cqeNew.command_id != cqeLast.command_id) {
      return cqeNew;
    }
  }
}

// Generate a completion entry from a submission entry
// This simulates NVMe controller behavior for testing
__host__ __device__ cqeType cqeGenFromSqe(const sqeType* sqeData) {
  cqeType result = {}; // Zero initialize

  // Set command ID to match the SQE
  result.command_id = sqeData->command_id;

  // Set result based on command type (simulated behavior)
  switch (sqeData->opcode) {
    case nvme_cmd_read:
    case nvme_cmd_write:
      // For read/write, result could be number of blocks transferred
      result.result = sqeData->cdw12 + 1; // NLB is 0-based
      break;
    case nvme_cmd_flush:
      result.result = 0;
      break;
    default:
      result.result = 0;
      break;
  }

  // Set status to success (Phase=1, SC=0, SCT=0)
  result.status = NVME_STATUS_MAKE(1, NVME_SC_SUCCESS, NVME_SCT_GENERIC);

  // Set SQ head/ID (for testing, just mirror command ID)
  result.sq_head = sqeData->command_id;
  result.sq_id = 0;

  return result;
}

// Use HIP's built-in wall_clock64() function directly - no wrapper needed

} // namespace nvme_ep

//
// Drive Endpoint (with data buffers) - Acts as NVMe host driver
//
// Merged driveEndpoint function - handles both batch and sequential modes
// Sequential mode: if writeIo < 0, issues one SQE at a time waiting for
// completion
//
__device__ void nvme_ep_driveEndpoint(
  const XioEndpointConfig& config, struct nvme_sqe* sqeAddr,
  struct nvme_cqe* cqeAddr, uint32_t lbaSize, uint64_t base_lba,
  bool usePciMmioBridge, void* shadowBufferVirt, uint16_t nvmeTargetBdf,
  uint16_t queueId, uint32_t doorbell_offset, uint8_t* readBuffer,
  uint8_t* writeBuffer, size_t bufferSize, uint64_t readBufferDma,
  uint64_t writeBufferDma, uint32_t lfsrSeed, uint16_t queue_size,
  uint64_t lba_range_lbas, bool use_random_access, void* nvmeBar0Gpu,
  int readIo, int writeIo) {
  // Check if sequential mode (readIo < 0 or writeIo < 0)
  const bool sequential_mode = (readIo < 0 || writeIo < 0);
  // Determine number of operations and command type for sequential mode
  unsigned num_ops;
  bool sequential_is_read = false;
  if (sequential_mode) {
    if (readIo < 0) {
      num_ops = -readIo;
      sequential_is_read = true;
    } else {
      num_ops = -writeIo;
      sequential_is_read = false;
    }
  } else {
    num_ops = config.iterations;
  }

  // Test parameters
  const uint32_t nsid = 1;   // Namespace ID
  const uint32_t blocks = 8; // Number of blocks per operation
  const size_t transfer_size = blocks * lbaSize;

  // Determine operation mode based on buffer availability
  const bool has_write_buffer = (writeBuffer != nullptr && bufferSize > 0);
  const bool has_read_buffer = (readBuffer != nullptr && bufferSize > 0);
  const bool write_only_mode = has_write_buffer && !has_read_buffer;
  const bool read_only_mode = has_read_buffer && !has_write_buffer;
  const bool alternate_mode = has_write_buffer && has_read_buffer;

  // If using write buffer, generate write data upfront
  if (has_write_buffer) {
    nvme_generate_pattern(writeBuffer, bufferSize, 0, lbaSize, lfsrSeed);
  }

  // Initialize phase tracking for completion polling
  uint16_t cq_head = 0;
  volatile struct nvme_cqe* initial_cqe = &cqeAddr[cq_head];
  nvme_ep::cqeType initial_cqe_data = nvme_ep::cqeRead(
    (volatile nvme_ep::cqeType*)initial_cqe);
  uint8_t expected_phase = NVME_CQE_STATUS_PHASE(initial_cqe_data.status) ^ 1;

  // Track submission queue tail
  uint16_t sq_tail = 0;
  uint16_t last_sq_head = 0; // Track last seen sq_head for completion detection

  if (sequential_mode) {
    // Sequential mode: issue one SQE, wait for completion, repeat
    for (unsigned i = 0; i < num_ops; i++) {
      uint16_t cmd_id = (uint16_t)(i + 1);

      // Calculate LBA
      uint64_t lba;
      if (use_random_access && lba_range_lbas > 0) {
        uint64_t seed = (uint64_t)i * 0x9e3779b9 + cmd_id * 0x85ebca6b;
        seed ^= seed >> 16;
        seed *= 0xc2b2ae35;
        seed ^= seed >> 13;
        seed *= 0x9e3779b9;
        seed ^= seed >> 16;
        lba = base_lba + (seed % lba_range_lbas);
      } else {
        if (lba_range_lbas > 0) {
          lba = base_lba + ((i * blocks) % lba_range_lbas);
        } else {
          lba = base_lba + (i * blocks);
        }
      }

      // Calculate PRPs based on command type (read or write)
      uint64_t prp1, prp2;
      if (sequential_is_read && has_read_buffer) {
        // For sequential reads, reuse the same buffer for every I/O
        uint64_t buffer_offset = 0;
        if (buffer_offset + transfer_size <= bufferSize) {
          uint64_t buffer_addr = readBufferDma
                                   ? (readBufferDma + buffer_offset)
                                   : (uint64_t)(readBuffer + buffer_offset);
          nvme_calculate_prps(buffer_addr, transfer_size, &prp1, &prp2);
        } else {
          prp1 = 0xDEADBEEF00000000ULL;
          prp2 = 0xCAFEBABE00000000ULL;
        }
      } else if (!sequential_is_read && has_write_buffer) {
        uint64_t buffer_offset = i * transfer_size;
        if (buffer_offset + transfer_size <= bufferSize) {
          uint64_t buffer_addr = writeBufferDma
                                   ? (writeBufferDma + buffer_offset)
                                   : (uint64_t)(writeBuffer + buffer_offset);
          nvme_calculate_prps(buffer_addr, transfer_size, &prp1, &prp2);
        } else {
          prp1 = 0xDEADBEEF00000000ULL;
          prp2 = 0xCAFEBABE00000000ULL;
        }
      } else {
        prp1 = 0xDEADBEEF00000000ULL;
        prp2 = 0xCAFEBABE00000000ULL;
      }

      // Setup read or write command
      nvme_ep::sqeType sqeLocal = {};
      struct nvme_sqe* sqe = &sqeLocal;
      nvme_sqe_setup_rw(sqe, !sequential_is_read, cmd_id, nsid, lba, blocks,
                        prp1, prp2);

      // Record start time
      if (config.startTimes != nullptr) {
        config.startTimes[i] = wall_clock64();
      }

      // Write SQE
      nvme_ep::sqeWrite(sqeLocal, &sqeAddr[sq_tail]);
      sq_tail = (sq_tail + 1) % queue_size;
      __threadfence_system();

      // Ring doorbell
      if (usePciMmioBridge && shadowBufferVirt != nullptr) {
        volatile struct pci_mmio_bridge_ring_meta* meta =
          static_cast<volatile struct pci_mmio_bridge_ring_meta*>(
            shadowBufferVirt);
        uint32_t slot = meta->producer_idx % meta->queue_depth;
        volatile struct pci_mmio_bridge_command* cmd =
          reinterpret_cast<volatile struct pci_mmio_bridge_command*>(
            static_cast<volatile uint8_t*>(shadowBufferVirt) +
            sizeof(struct pci_mmio_bridge_ring_meta) +
            (slot * sizeof(struct pci_mmio_bridge_command)));
        cmd->target_bdf = nvmeTargetBdf;
        cmd->target_bar = 0;
        cmd->reserved1 = 0;
        cmd->offset = doorbell_offset;
        cmd->value = sq_tail;
        cmd->command = PCI_MMIO_BRIDGE_CMD_WRITE;
        cmd->size = 4;
        cmd->status = PCI_MMIO_BRIDGE_STATUS_PENDING;
        cmd->reserved2 = 0;
        cmd->sequence = slot;
        __threadfence_system();
        meta->producer_idx = meta->producer_idx + 1;
        __threadfence_system();
      } else if (!usePciMmioBridge && nvmeBar0Gpu != nullptr) {
        volatile uint32_t* doorbell_reg = reinterpret_cast<volatile uint32_t*>(
          static_cast<volatile char*>(nvmeBar0Gpu) + doorbell_offset);
        __threadfence_system();
        *doorbell_reg = sq_tail;
        __threadfence_system();
      }

      // Wait for this specific completion
      // In sequential mode, we issue one command at a time, so sq_head should
      // increase by 1 when this command completes
      // Prioritize sq_head increase over phase matching for robustness
      uint32_t poll_count = 0;
      const uint32_t max_polls = 10000000; // Safety limit

      while (poll_count < max_polls) {
        volatile struct nvme_cqe* cqe_entry = &cqeAddr[cq_head];
        nvme_ep::cqeType cqe_new = nvme_ep::cqeRead(
          (volatile nvme_ep::cqeType*)cqe_entry);
        uint8_t phase = NVME_CQE_STATUS_PHASE(cqe_new.status);
        uint16_t sq_head = cqe_new.sq_head;

        // Primary check: sq_head has increased (definitive indicator of
        // completion) In sequential mode, any increase means our command
        // completed
        if (sq_head > last_sq_head) {
          // sq_head increased - command completed
          // Verify phase matches if possible (for correctness), but don't
          // require it
          if (phase == expected_phase) {
            // Phase matches - perfect, this is definitely a new completion
            if (config.endTimes != nullptr && cmd_id >= 1 &&
                cmd_id <= num_ops) {
              unsigned idx = cmd_id - 1;
              config.endTimes[idx] = wall_clock64();
            }
            cq_head = (cq_head + 1) % queue_size;
            expected_phase = expected_phase ^ 1;
            last_sq_head = sq_head;
            break;
          } else {
            // Phase doesn't match but sq_head increased - accept it anyway
            // This handles cases where phase bit logic might be off
            // Update expected_phase based on what we actually saw
            if (config.endTimes != nullptr && cmd_id >= 1 &&
                cmd_id <= num_ops) {
              unsigned idx = cmd_id - 1;
              config.endTimes[idx] = wall_clock64();
            }
            cq_head = (cq_head + 1) % queue_size;
            expected_phase = phase ^ 1; // Toggle based on actual phase seen
            last_sq_head = sq_head;
            break;
          }
        }
        poll_count++;
      }
    }
  } else {
    // Batch mode: issue all SQEs, then ring doorbell, then poll for all
    // completions
    nvme_ep::sqeType sqeLocal = {};
    struct nvme_sqe* sqe = &sqeLocal;

    // Issue all commands
    for (unsigned i = 0; i < num_ops; i++) {
      uint16_t cmd_id = (uint16_t)(i + 1);

      // Calculate LBA
      uint64_t lba;
      if (use_random_access && lba_range_lbas > 0) {
        uint64_t seed = (uint64_t)i * 0x9e3779b9 + cmd_id * 0x85ebca6b;
        seed ^= seed >> 16;
        seed *= 0xc2b2ae35;
        seed ^= seed >> 13;
        seed *= 0x9e3779b9;
        seed ^= seed >> 16;
        lba = base_lba + (seed % lba_range_lbas);
      } else {
        if (lba_range_lbas > 0) {
          lba = base_lba + ((i * blocks) % lba_range_lbas);
        } else {
          lba = base_lba + (i * blocks);
        }
      }

      // Determine command type
      bool is_read_command = false;
      if (write_only_mode) {
        is_read_command = false;
      } else if (read_only_mode) {
        is_read_command = true;
      } else if (alternate_mode) {
        is_read_command = (i % 2 == 0);
      } else {
        is_read_command = (i % 2 == 0);
      }

      // Calculate PRPs
      uint64_t prp1, prp2;
      bool is_write = !is_read_command;
      if (is_read_command && has_read_buffer) {
        uint64_t buffer_offset = read_only_mode ? (i * transfer_size)
                                                : ((i / 2) * transfer_size);
        if (buffer_offset + transfer_size <= bufferSize) {
          uint64_t buffer_addr = readBufferDma
                                   ? (readBufferDma + buffer_offset)
                                   : (uint64_t)(readBuffer + buffer_offset);
          nvme_calculate_prps(buffer_addr, transfer_size, &prp1, &prp2);
        } else {
          prp1 = 0xDEADBEEF00000000ULL;
          prp2 = 0xCAFEBABE00000000ULL;
        }
      } else if (is_write && has_write_buffer) {
        uint64_t buffer_offset = write_only_mode ? (i * transfer_size)
                                                 : ((i / 2) * transfer_size);
        if (buffer_offset + transfer_size <= bufferSize) {
          uint64_t buffer_addr = writeBufferDma
                                   ? (writeBufferDma + buffer_offset)
                                   : (uint64_t)(writeBuffer + buffer_offset);
          nvme_calculate_prps(buffer_addr, transfer_size, &prp1, &prp2);
        } else {
          prp1 = 0xDEADBEEF00000000ULL;
          prp2 = 0xCAFEBABE00000000ULL;
        }
      } else {
        prp1 = 0xDEADBEEF00000000ULL;
        prp2 = 0xCAFEBABE00000000ULL;
      }

      // Setup command
      nvme_sqe_setup_rw(sqe, is_write, cmd_id, nsid, lba, blocks, prp1, prp2);

      // Record start time
      if (config.startTimes != nullptr) {
        config.startTimes[i] = wall_clock64();
      }

      // Write SQE
      nvme_ep::sqeWrite(sqeLocal, &sqeAddr[sq_tail]);
      sq_tail = (sq_tail + 1) % queue_size;
    }

    // Memory fence before doorbell
    __threadfence_system();

    // Ring doorbell once for all commands
    if (usePciMmioBridge && shadowBufferVirt != nullptr) {
      volatile struct pci_mmio_bridge_ring_meta* meta =
        static_cast<volatile struct pci_mmio_bridge_ring_meta*>(
          shadowBufferVirt);
      uint32_t slot = meta->producer_idx % meta->queue_depth;
      volatile struct pci_mmio_bridge_command* cmd =
        reinterpret_cast<volatile struct pci_mmio_bridge_command*>(
          static_cast<volatile uint8_t*>(shadowBufferVirt) +
          sizeof(struct pci_mmio_bridge_ring_meta) +
          (slot * sizeof(struct pci_mmio_bridge_command)));
      cmd->target_bdf = nvmeTargetBdf;
      cmd->target_bar = 0;
      cmd->reserved1 = 0;
      cmd->offset = doorbell_offset;
      cmd->value = sq_tail;
      cmd->command = PCI_MMIO_BRIDGE_CMD_WRITE;
      cmd->size = 4;
      cmd->status = PCI_MMIO_BRIDGE_STATUS_PENDING;
      cmd->reserved2 = 0;
      cmd->sequence = slot;
      __threadfence_system();
      meta->producer_idx = meta->producer_idx + 1;
      __threadfence_system();
    } else if (!usePciMmioBridge && nvmeBar0Gpu != nullptr) {
      volatile uint32_t* doorbell_reg = reinterpret_cast<volatile uint32_t*>(
        static_cast<volatile char*>(nvmeBar0Gpu) + doorbell_offset);
      __threadfence_system();
      *doorbell_reg = sq_tail;
      __threadfence_system();
    }

    // Poll for all completions
    uint16_t completed_count = 0;
    uint32_t poll_count = 0;
    const uint32_t max_polls_before_backoff = 1000;

    while (completed_count < num_ops) {
      volatile struct nvme_cqe* cqe_entry = &cqeAddr[cq_head];
      nvme_ep::cqeType cqe_new = nvme_ep::cqeRead(
        (volatile nvme_ep::cqeType*)cqe_entry);
      uint8_t phase = NVME_CQE_STATUS_PHASE(cqe_new.status);
      if (phase == expected_phase) {
        uint16_t sq_head = cqe_new.sq_head;
        if (sq_head > last_sq_head && sq_head <= num_ops) {
          uint16_t new_completions = sq_head - last_sq_head;
          if (config.endTimes != nullptr) {
            uint64_t end_time = wall_clock64();
            for (uint16_t i = 0; i < new_completions; i++) {
              uint16_t completed_cmd_id = last_sq_head + 1 + i;
              if (completed_cmd_id >= 1 && completed_cmd_id <= num_ops) {
                unsigned idx = completed_cmd_id - 1;
                config.endTimes[idx] = end_time;
              }
            }
          }
          completed_count += new_completions;
          last_sq_head = sq_head;
          poll_count = 0;
          cq_head = (cq_head + 1) % queue_size;
          expected_phase = expected_phase ^ 1;
        }
      }
      poll_count++;
      if (poll_count > max_polls_before_backoff) {
        poll_count = 0;
      }
    }
  }
}

// Wrapper kernel to launch nvme_ep_driveEndpoint
// Follows test-ep pattern: extract values on host, pass as parameters
__global__ void nvme_ep_kernel(
  struct nvme_sqe* sqeAddr, struct nvme_cqe* cqeAddr,
  unsigned long long int* startTimes, unsigned long long int* endTimes,
  unsigned iterations, unsigned numThreads, uint32_t lbaSize, uint64_t base_lba,
  bool usePciMmioBridge, void* shadowBufferVirt, uint16_t nvmeTargetBdf,
  uint16_t queueId, uint32_t doorbell_offset, uint8_t* readBuffer,
  uint8_t* writeBuffer, size_t bufferSize, uint64_t readBufferDma,
  uint64_t writeBufferDma, uint32_t lfsrSeed, uint16_t queue_size,
  uint64_t lba_range_lbas, bool use_random_access, void* nvmeBar0Gpu,
  int readIo, int writeIo) {
  // Reconstruct XioEndpointConfig from parameters
  XioEndpointConfig config;
  config.submissionQueue = sqeAddr;
  config.completionQueue = cqeAddr;
  config.startTimes = startTimes;
  config.endTimes = endTimes;
  config.iterations = iterations;
  config.numThreads = numThreads;
  config.endpointConfig = nullptr; // Don't use endpointConfig pointer

  // Pass values directly to driveEndpoint (no need for full struct)
  nvme_ep_driveEndpoint(config, sqeAddr, cqeAddr, lbaSize, base_lba,
                        usePciMmioBridge, shadowBufferVirt, nvmeTargetBdf,
                        queueId, doorbell_offset, readBuffer, writeBuffer,
                        bufferSize, readBufferDma, writeBufferDma, lfsrSeed,
                        queue_size, lba_range_lbas, use_random_access,
                        nvmeBar0Gpu, readIo, writeIo);
}

//
// Host helper functions for PCI MMIO bridge support
//

#ifndef __HIP_DEVICE_COMPILE__

// Export HSA-allocated VRAM as DMA-BUF and register with kernel module
// Based on QEMU reference code: test-gpu-nvme-write.cpp
// Returns 0 on success, negative error code on failure
// is_emulated: true for emulated NVMe (returns GPU BAR GPA), false for
// passthrough (returns P2PDMA IOVA)
static int export_and_register_vram_buffer(void* vram_ptr, size_t size,
                                           uint16_t nvme_bdf,
                                           const char* kernel_module_device,
                                           uint64_t* phys_addr_out,
                                           bool is_emulated = false) {
  hsa_status_t status;
  hipDeviceptr_t aligned_ptr;
  const size_t host_page_size = sysconf(_SC_PAGESIZE);
  uint64_t dmabuf_offset = 0;
  size_t aligned_size;
  int dmabuf_fd = -1;
  int kmod_fd = -1;
  int ret = 0;

  if (!vram_ptr || !phys_addr_out || size == 0) {
    return -EINVAL;
  }

  // Round down to host page size for dmabuf alignment
  aligned_ptr = (hipDeviceptr_t)((uintptr_t)vram_ptr & ~(host_page_size - 1));
  dmabuf_offset = (uintptr_t)vram_ptr - (uintptr_t)aligned_ptr;
  aligned_size = (size + dmabuf_offset + host_page_size - 1) &
                 ~(host_page_size - 1);

  fprintf(stderr,
          "  Aligning VRAM buffer: ptr=%p -> aligned=%p, "
          "size=%zu -> %zu, offset=%llu\n",
          vram_ptr, (void*)aligned_ptr, size, aligned_size,
          (unsigned long long)dmabuf_offset);

  // Export as DMA-BUF using HSA runtime
  dmabuf_fd = 0;
  status = hsa_amd_portable_export_dmabuf((void*)aligned_ptr, aligned_size,
                                          &dmabuf_fd, &dmabuf_offset);
  if (status != HSA_STATUS_SUCCESS) {
    fprintf(stderr,
            "ERROR: hsa_amd_portable_export_dmabuf failed (status=%d)\n",
            status);
    fprintf(stderr, "  This requires:\n");
    fprintf(stderr, "  - ROCm 5.3+ with dmabuf support\n");
    fprintf(stderr, "  - Kernel CONFIG_DMABUF_MOVE_NOTIFY=y\n");
    fprintf(stderr, "  - Kernel CONFIG_PCI_P2PDMA=y\n");
    return -ENOTSUP;
  }

  fprintf(stderr, "  ✅ Exported dmabuf: fd=%d, offset=0x%llx\n", dmabuf_fd,
          (unsigned long long)dmabuf_offset);

  // Open kernel module device
  kmod_fd = open(kernel_module_device, O_RDWR);
  if (kmod_fd < 0) {
    fprintf(stderr, "ERROR: Failed to open %s: %s\n", kernel_module_device,
            strerror(errno));
    close(dmabuf_fd);
    return -errno;
  }

  // Register buffer with kernel module to get physical address
  struct rocm_axiio_register_buffer_req req = {};
  req.dmabuf_fd = dmabuf_fd;
  req.virt_addr = reinterpret_cast<uint64_t>(vram_ptr);
  req.size = size;
  req.nvme_bdf = nvme_bdf;
  req.flags = is_emulated ? ROCM_XIO_FLAG_EMULATED : ROCM_XIO_FLAG_PASSTHROUGH;

  ret = ioctl(kmod_fd, ROCM_XIO_REGISTER_BUFFER, &req);
  if (ret < 0) {
    fprintf(stderr, "ERROR: ROCM_XIO_REGISTER_BUFFER ioctl failed: %s\n",
            strerror(errno));
    close(dmabuf_fd);
    close(kmod_fd);
    return -errno;
  }

  // Physical address includes the offset within the dmabuf
  *phys_addr_out = req.phys_addr + dmabuf_offset;

  fprintf(stderr,
          "  ✅ Registered buffer: virt=0x%016llx, phys=0x%016llx, "
          "size=%zu\n",
          (unsigned long long)req.virt_addr, (unsigned long long)*phys_addr_out,
          size);

  // Close dmabuf FD - kernel module has the mapping
  close(dmabuf_fd);
  close(kmod_fd);

  return 0;
}

// Helper to get physical address from virtual address (matching
// test-gpu-nvme-write.cpp)
static uint64_t virt_to_phys(void* virt_addr) {
  int fd;
  uint64_t page_offset = (uint64_t)virt_addr % sysconf(_SC_PAGESIZE);
  uint64_t pfn;
  off_t offset = ((uint64_t)virt_addr / sysconf(_SC_PAGESIZE)) *
                 sizeof(uint64_t);

  fd = open("/proc/self/pagemap", O_RDONLY);
  if (fd < 0) {
    perror("open /proc/self/pagemap");
    return 0;
  }

  if (lseek(fd, offset, SEEK_SET) < 0) {
    perror("lseek");
    close(fd);
    return 0;
  }

  if (read(fd, &pfn, sizeof(pfn)) != sizeof(pfn)) {
    perror("read pagemap");
    close(fd);
    return 0;
  }

  close(fd);

  if (!(pfn & (1ULL << 63))) {
    fprintf(stderr, "Page not present\n");
    return 0;
  }

  return ((pfn & ((1ULL << 55) - 1)) * sysconf(_SC_PAGESIZE)) + page_offset;
}

// Forward declarations
static int map_mmio_bridge_shadow_buffer(uint16_t bridge_bdf, void** virt_addr);
static int map_nvme_bar0(uint16_t nvme_bdf, void** bar0_cpu, void** bar0_gpu);

// Run endpoint test - launches GPU kernel and waits for completion
__host__ hipError_t nvme_ep_run(XioEndpointConfig* config) {
  if (!config) {
    return hipErrorInvalidValue;
  }

  // HIP initialization: Ensure HIP is initialized (important when running under
  // sudo) Check if HIP is already initialized by trying to get device count
  int device_count = 0;
  hipError_t count_err = hipGetDeviceCount(&device_count);
  if (count_err != hipSuccess || device_count == 0) {
    // HIP not initialized or no devices - try to initialize
    hipError_t hip_init_err = hipInit(0);
    if (hip_init_err != hipSuccess) {
      fprintf(stderr,
              "Warning: hipInit returned: %s (code: %d), continuing anyway\n",
              hipGetErrorString(hip_init_err), hip_init_err);
    }
    // Set device to 0 after initialization
    hipError_t hip_dev_err = hipSetDevice(0);
    if (hip_dev_err != hipSuccess) {
      fprintf(stderr, "Error: Failed to set HIP device 0: %s (code: %d)\n",
              hipGetErrorString(hip_dev_err), hip_dev_err);
      return hip_dev_err;
    }
  } else {
    // HIP is already initialized - verify device is set correctly
    int current_device = -1;
    hipError_t get_dev_err = hipGetDevice(&current_device);
    if (get_dev_err == hipSuccess && current_device != 0) {
      // Device is set but not 0 - set it to 0
      hipError_t set_dev_err = hipSetDevice(0);
      if (set_dev_err != hipSuccess) {
        fprintf(stderr,
                "Warning: Failed to set HIP device to 0: %s (code: %d)\n",
                hipGetErrorString(set_dev_err), set_dev_err);
      }
    }
  }

  // Get nvme-ep specific config (follows test-ep pattern)
  nvme_ep::NvmeEpConfig* nvmeConfig = nullptr;
  if (!config->endpointConfig) {
    fprintf(stderr, "Error: nvme-ep requires endpoint configuration\n");
    return hipErrorInvalidValue;
  }

  nvmeConfig = static_cast<nvme_ep::NvmeEpConfig*>(config->endpointConfig);

  // Queue creation is MANDATORY for nvme-ep - device must be specified
  if (nvmeConfig->device.empty()) {
    fprintf(stderr,
            "Error: NVMe device not specified. --controller is required.\n");
    return hipErrorInvalidValue;
  }

  // Create NVMe queues - MUST succeed before proceeding
  // Use queue length from CLI configuration (default: 64)
  // NVMe queues are circular buffers - commands wrap around, so the queue
  // length must be large enough to handle outstanding commands without
  // overwriting unprocessed ones.
  uint16_t queue_size = nvmeConfig->queueLength;

  fprintf(stderr, "Using queue length: %u entries\n", queue_size);

  struct nvme_queue_info queue_info;
  int ret = nvme_ep_create_queue_via_ioctl(
    nvmeConfig->device.c_str(), ROCM_XIO_DEVICE_PATH, nvmeConfig->queueId,
    queue_size, nvmeConfig->nvmeTargetBdf,
    config->memoryMode, // Respect memory mode like test-ep
    &queue_info);

  if (ret < 0) {
    fprintf(stderr, "Error: Failed to create NVMe queues: %s\n",
            strerror(-ret));
    fprintf(stderr,
            "Queue creation failed - cannot proceed with kernel launch.\n");
    return hipErrorInvalidValue;
  }

  // Update config with created queue addresses
  // Use GPU pointers for kernel launch (obtained via hipHostGetDevicePointer)
  config->submissionQueue = queue_info.sq_gpu ? queue_info.sq_gpu
                                              : queue_info.sq_virt;
  config->completionQueue = queue_info.cq_gpu ? queue_info.cq_gpu
                                              : queue_info.cq_virt;
  nvmeConfig->sqBaseAddr = queue_info.sq_phys;
  nvmeConfig->cqBaseAddr = queue_info.cq_phys;
  nvmeConfig->sqSize = queue_info.sq_size;
  nvmeConfig->cqSize = queue_info.cq_size;

  fprintf(stderr, "NVMe queues created: SQ=0x%llx, CQ=0x%llx, queue_id=%u\n",
          (unsigned long long)queue_info.sq_phys,
          (unsigned long long)queue_info.cq_phys, nvmeConfig->queueId);
  fprintf(stderr, "Queue GPU pointers: SQ=%p (host=%p), CQ=%p (host=%p)\n",
          queue_info.sq_gpu, queue_info.sq_virt, queue_info.cq_gpu,
          queue_info.cq_virt);

  // Verify queues were created successfully
  if (!config->submissionQueue || !config->completionQueue) {
    fprintf(stderr,
            "Error: Queue creation succeeded but queue pointers are null\n");
    return hipErrorInvalidValue;
  }

  // Set up PCI MMIO bridge shadow buffer if enabled
  // Match QEMU guest code pattern: map QEMU's guest RAM shadow buffer via
  // kernel module QEMU allocates shadow buffer as guest RAM using
  // memory_region_init_ram(), which makes it accessible as regular guest
  // memory. We map it via kernel module mmap to get access to the same physical
  // memory that QEMU sees.
  if (nvmeConfig->usePciMmioBridge) {
    void* shadow_virt = nullptr;
    int ret_shadow = map_mmio_bridge_shadow_buffer(nvmeConfig->mmioBridgeBdf,
                                                   &shadow_virt);
    if (ret_shadow < 0) {
      fprintf(stderr, "Failed to map PCI MMIO bridge shadow buffer\n");
      return hipErrorInvalidValue;
    }
    fprintf(stderr, "PCI MMIO bridge shadow buffer mapped at %p\n",
            shadow_virt);

    // Register shadow buffer for GPU access (matching QEMU guest code pattern)
    // Kernel module mmap maps QEMU's guest RAM, which is the same physical
    // memory that QEMU's address_space_read() sees.
    const size_t shadow_size = 8192; // 8KB shadow buffer (matches QEMU default)

    // Step 1: Register with DRM GEM_USERPTR (required for GPU access)
    // This matches the QEMU guest code pattern (test-gpu-nvme-write.cpp lines
    // 933-947)
    int drm_fd = open("/dev/dri/renderD128", O_RDWR);
    if (drm_fd < 0) {
      fprintf(stderr, "Warning: Failed to open DRM device: %s\n",
              strerror(errno));
      fprintf(stderr,
              "Cannot register shadow buffer with GPU via GEM_USERPTR.\n");
      fprintf(
        stderr,
        "Disabling PCI MMIO bridge mode - GPU kernel will skip doorbell.\n");
      munmap(shadow_virt, shadow_size);
      nvmeConfig->shadowBufferVirt = nullptr;
      nvmeConfig->usePciMmioBridge = false;
    } else {
      struct drm_amdgpu_gem_userptr gem_userptr = {};
      gem_userptr.addr = (uint64_t)shadow_virt;
      gem_userptr.size = shadow_size;
      gem_userptr.flags = AMDGPU_GEM_USERPTR_REGISTER;

      if (ioctl(drm_fd, DRM_IOCTL_AMDGPU_GEM_USERPTR, &gem_userptr) < 0) {
        fprintf(stderr, "Warning: DRM_IOCTL_AMDGPU_GEM_USERPTR failed: %s\n",
                strerror(errno));
        fprintf(stderr, "Cannot register shadow buffer with GPU.\n");
        fprintf(
          stderr,
          "Disabling PCI MMIO bridge mode - GPU kernel will skip doorbell.\n");
        close(drm_fd);
        munmap(shadow_virt, shadow_size);
        nvmeConfig->shadowBufferVirt = nullptr;
        nvmeConfig->usePciMmioBridge = false;
      } else {
        fprintf(stderr,
                "Shadow buffer registered with DRM GEM_USERPTR "
                "(handle: %u)\n",
                gem_userptr.handle);

        // Step 2: Register with HIP (matching QEMU guest code pattern)
        hipError_t hip_err = hipHostRegister(shadow_virt, shadow_size,
                                             hipHostRegisterMapped);
        if (hip_err != hipSuccess) {
          fprintf(stderr,
                  "Warning: Failed to register shadow buffer with HIP: "
                  "%s\n",
                  hipGetErrorString(hip_err));
          fprintf(stderr, "Disabling PCI MMIO bridge mode - GPU kernel will "
                          "skip doorbell.\n");
          close(drm_fd);
          munmap(shadow_virt, shadow_size);
          nvmeConfig->shadowBufferVirt = nullptr;
          nvmeConfig->usePciMmioBridge = false;
        } else {
          fprintf(stderr, "Shadow buffer registered with HIP for GPU access\n");

          // Step 3: Get GPU pointer (matching QEMU guest code pattern)
          // After hipHostRegister, we need hipHostGetDevicePointer to get the
          // GPU-accessible pointer
          void* shadow_gpu_ptr = nullptr;
          hipError_t gpu_ptr_err = hipHostGetDevicePointer(&shadow_gpu_ptr,
                                                           shadow_virt, 0);
          if (gpu_ptr_err != hipSuccess) {
            fprintf(stderr, "Warning: hipHostGetDevicePointer failed: %s\n",
                    hipGetErrorString(gpu_ptr_err));
            fprintf(stderr, "Disabling PCI MMIO bridge mode - GPU kernel will "
                            "skip doorbell.\n");
            close(drm_fd);
            munmap(shadow_virt, shadow_size);
            nvmeConfig->shadowBufferVirt = nullptr;
            nvmeConfig->usePciMmioBridge = false;
          } else {
            fprintf(stderr,
                    "Shadow buffer GPU pointer obtained: %p (host: %p)\n",
                    shadow_gpu_ptr, shadow_virt);
            // Store GPU pointer for kernel use
            nvmeConfig->shadowBufferVirt = shadow_gpu_ptr;
          }
          // Note: We keep drm_fd open for the mapping to remain valid
          // In a production system, you might want to track this fd and close
          // it on cleanup
        }
      }
      // Keep drm_fd open - the mapping persists even after close
      // The kernel will clean it up when the process exits
      close(drm_fd);
    }
  } else {
    // PCI MMIO bridge is disabled - set up direct doorbell via BAR0
    void* bar0_cpu = nullptr;
    void* bar0_gpu = nullptr;
    int ret_bar0 = map_nvme_bar0(nvmeConfig->nvmeTargetBdf, &bar0_cpu,
                                 &bar0_gpu);
    if (ret_bar0 < 0) {
      fprintf(stderr,
              "Warning: Failed to map NVMe BAR0 for direct doorbell: %s\n",
              strerror(-ret_bar0));
      fprintf(
        stderr,
        "Direct doorbell mode disabled - GPU kernel will skip doorbell.\n");
      nvmeConfig->nvmeBar0Gpu = nullptr;
    } else {
      fprintf(stderr, "NVMe BAR0 mapped for direct doorbell access\n");
      nvmeConfig->nvmeBar0Gpu = bar0_gpu;
    }
  }

  // Extract values from endpointConfig (follows test-ep pattern)
  // This avoids passing host pointers to GPU kernel
  uint32_t lbaSize = 512;
  bool usePciMmioBridge = false;
  void* shadowBufferVirt = nullptr;
  void* nvmeBar0Gpu = nullptr;
  uint16_t nvmeTargetBdf = 0x0030; // Default: 00:06.0
  uint16_t queueId = 63;
  uint32_t lfsrSeed = 0;
  size_t dataBufferSize = 0;
  int readIo = 0;
  int writeIo = 0;

  uint64_t baseLba = 0;      // Default value
  uint64_t lbaRangeLbas = 0; // 0 means no range limit (use original behavior)
  bool useRandomAccess = false;
  if (nvmeConfig) {
    lbaSize = nvmeConfig->lbaSize;
    baseLba = nvmeConfig->baseLba;
    usePciMmioBridge = nvmeConfig->usePciMmioBridge;
    shadowBufferVirt = nvmeConfig->shadowBufferVirt;
    nvmeBar0Gpu = nvmeConfig->nvmeBar0Gpu;
    nvmeTargetBdf = nvmeConfig->nvmeTargetBdf;
    queueId = nvmeConfig->queueId;
    lfsrSeed = nvmeConfig->lfsrSeed;
    dataBufferSize = nvmeConfig->dataBufferSize;
    readIo = nvmeConfig->readIo;
    writeIo = nvmeConfig->writeIo;

    // Query namespace capacity in LBAs
    uint64_t namespace_capacity = 0;
    int capacity_ret = nvme_ep_query_namespace_capacity(
      nvmeConfig->device.c_str(), 1, &namespace_capacity);
    if (capacity_ret == 0 && namespace_capacity > 0) {
      lbaRangeLbas = namespace_capacity;
      fprintf(stderr, "Using full namespace capacity: %llu LBAs\n",
              (unsigned long long)lbaRangeLbas);
    } else {
      fprintf(stderr, "Warning: Failed to query namespace capacity, "
                      "LBA range will be unlimited\n");
      lbaRangeLbas = 0; // 0 means no limit
    }

    // Determine access pattern
    useRandomAccess = (nvmeConfig->accessPattern == "random");
  }

  // Calculate SQ doorbell offset on host side (matching
  // test-gpu-nvme-write.cpp) Doorbell base is at BAR0 + 0x1000 SQ doorbell
  // offset = 0x1000 + (2 * queue_id * doorbell_stride)
  const uint32_t doorbell_stride = 0; // Usually 0 (4 bytes per doorbell)
  const uint32_t stride_bytes = 4 << doorbell_stride;
  const uint32_t doorbell_base = 0x1000;
  const uint32_t doorbell_offset = doorbell_base + (2 * queueId) * stride_bytes;

  // Allocate data buffers if enabled and needed
  uint8_t* readBuffer = nullptr;
  uint8_t* writeBuffer = nullptr;
  uint8_t* readBufferGpu = nullptr;  // GPU-accessible pointer (may be same as
                                     // readBuffer)
  uint8_t* writeBufferGpu = nullptr; // GPU-accessible pointer (may be same as
                                     // writeBuffer)
  uint64_t readBufferDma = 0;
  uint64_t writeBufferDma = 0;
  bool dataBufferOnDevice = (config->memoryMode & 0x8) != 0; // Bit 3
  bool readBufferActuallyOnDevice = false;  // Track actual allocation type
  bool writeBufferActuallyOnDevice = false; // Track actual allocation type

  // Allocate data buffers if buffer size is specified and I/O is requested
  // Note: readIo and writeIo can be negative for sequential mode, so check != 0
  if (dataBufferSize > 0 && (readIo != 0 || writeIo != 0)) {
    // Allocate read buffer if read I/O is requested (including sequential mode)
    if (readIo != 0) {
      // Try device memory first if requested (matching test-gpu-nvme-write.cpp
      // pattern)
      if (dataBufferOnDevice) {
        // Use hipMalloc for VRAM allocation (matching test code line 792)
        hipError_t buf_err = hipMalloc(&readBuffer, dataBufferSize);
        if (buf_err != hipSuccess) {
          fprintf(stderr, "Error: hipMalloc failed for read buffer: %s\n",
                  hipGetErrorString(buf_err));
          return buf_err;
        }

        fprintf(stderr, "  VRAM buffer virtual: %p\n", readBuffer);
        fprintf(stderr, "  Exporting as DMA-BUF (HSA runtime)...\n");

        // Detect if NVMe is emulated (needed for buffer registration flags)
        bool is_emulated = false;
        (void)xioDetectEmulatedNvme(nvmeConfig->device.c_str(), &is_emulated);

        // Export VRAM as dmabuf and register with kernel module
        int ret = export_and_register_vram_buffer(readBuffer, dataBufferSize,
                                                  nvmeConfig->nvmeTargetBdf,
                                                  ROCM_XIO_DEVICE_PATH,
                                                  &readBufferDma, is_emulated);
        if (ret < 0) {
          fprintf(stderr,
                  "ERROR: DMA-BUF export failed for device memory: %s\n",
                  strerror(-ret));
          fprintf(stderr, "  Device memory was requested but dmabuf export is "
                          "not available\n");
          (void)hipFree(readBuffer);
          readBuffer = nullptr;
          return hipErrorInvalidValue;
        }

        fprintf(stderr, "  Data buffer physical: 0x%016llx (VRAM)\n",
                (unsigned long long)readBufferDma);
        fprintf(stderr, "  GPU writes directly to VRAM\n");
        fprintf(stderr, "  NVMe DMAs from VRAM (P2P)\n");

        // Device memory - GPU pointer is same as host pointer
        readBufferGpu = readBuffer;
        readBufferActuallyOnDevice = true; // Track that we're using device
                                           // memory
      } else {
        // Host memory - use hipHostMalloc (matching test code line 836)
        hipError_t buf_err = hipHostMalloc(&readBuffer, dataBufferSize,
                                           hipHostMallocMapped);
        if (buf_err != hipSuccess) {
          fprintf(stderr, "Error: hipHostMalloc failed for read buffer: %s\n",
                  hipGetErrorString(buf_err));
          return buf_err;
        }

        // Get physical address for host memory using /proc/self/pagemap
        // (matching test code line 842)
        readBufferDma = virt_to_phys(readBuffer);
        if (!readBufferDma) {
          fprintf(stderr,
                  "ERROR: Failed to get read buffer physical address\n");
          (void)hipHostFree(readBuffer);
          readBuffer = nullptr;
          return hipErrorInvalidValue;
        }

        fprintf(stderr, "  Data buffer virtual:  %p\n", readBuffer);
        fprintf(stderr, "  Data buffer physical: 0x%016llx\n",
                (unsigned long long)readBufferDma);
        fprintf(stderr, "  GPU can write directly to this buffer\n");
        fprintf(stderr, "  NVMe can DMA from this buffer\n");
        readBufferActuallyOnDevice = false; // Track that we're using host
                                            // memory
      }

      // Read buffer registration:
      // - Device memory: Already registered via
      // export_and_register_vram_buffer()
      // - Host memory: Physical address obtained from pagemap, kernel module
      // will
      //   use virt_to_phys() fallback if needed for PRP injection

      // Verify read buffer is GPU-accessible and get GPU pointer if needed
      // (matches QEMU guest code pattern - hipHostMallocMapped should be
      // GPU-accessible)
      if (!dataBufferOnDevice) {
        hipPointerAttribute_t attr;
        hipError_t attr_err = hipPointerGetAttributes(&attr, readBuffer);
        if (attr_err != hipSuccess) {
          fprintf(stderr,
                  "Warning: Read buffer may not be GPU-accessible: %s\n",
                  hipGetErrorString(attr_err));
          readBufferGpu = readBuffer; // Fallback to host pointer
        } else {
          fprintf(
            stderr,
            "Read buffer GPU accessibility verified: type=%d, device=%d\n",
            attr.type, attr.device);
          // Get explicit GPU pointer (may be same as host pointer for mapped
          // memory)
          void* gpu_ptr = nullptr;
          hipError_t gpu_ptr_err = hipHostGetDevicePointer(&gpu_ptr, readBuffer,
                                                           0);
          if (gpu_ptr_err == hipSuccess && gpu_ptr != nullptr) {
            // Store GPU pointer for kernel launch (may be same as host pointer)
            readBufferGpu = static_cast<uint8_t*>(gpu_ptr);
            fprintf(stderr, "Read buffer GPU pointer: %p (host: %p)\n",
                    readBufferGpu, readBuffer);
          } else {
            // Fallback: use host pointer (should work for hipHostMallocMapped)
            readBufferGpu = readBuffer;
          }
        }
      } else {
        // Device memory - GPU pointer is same as host pointer
        readBufferGpu = readBuffer;
      }

      fprintf(stderr, "Read buffer allocated: virt=%p, phys=0x%llx, size=%zu\n",
              readBuffer, (unsigned long long)readBufferDma, dataBufferSize);
    }

    // Allocate write buffer if write I/O is requested (including sequential
    // mode)
    if (writeIo != 0) {
      // Try device memory first if requested (matching test-gpu-nvme-write.cpp
      // pattern)
      bool writeBufferOnDevice = dataBufferOnDevice; // Track if we're using
                                                     // device memory

      if (dataBufferOnDevice) {
        // Use hipMalloc for VRAM allocation (matching test code line 792)
        hipError_t buf_err = hipMalloc(&writeBuffer, dataBufferSize);
        if (buf_err != hipSuccess) {
          fprintf(stderr, "Error: hipMalloc failed for write buffer: %s\n",
                  hipGetErrorString(buf_err));
          // Free read buffer on failure
          if (readBuffer) {
            if (dataBufferOnDevice) {
              (void)hipFree(readBuffer);
            } else {
              (void)hipHostFree(readBuffer);
            }
          }
          return buf_err;
        }

        fprintf(stderr, "  VRAM buffer virtual: %p\n", writeBuffer);
        fprintf(stderr, "  Exporting as DMA-BUF (HSA runtime)...\n");

        // Detect if NVMe is emulated (needed for buffer registration flags)
        bool is_emulated = false;
        (void)xioDetectEmulatedNvme(nvmeConfig->device.c_str(), &is_emulated);

        // Export VRAM as dmabuf and register with kernel module
        int ret = export_and_register_vram_buffer(writeBuffer, dataBufferSize,
                                                  nvmeConfig->nvmeTargetBdf,
                                                  ROCM_XIO_DEVICE_PATH,
                                                  &writeBufferDma, is_emulated);
        if (ret < 0) {
          fprintf(stderr,
                  "ERROR: DMA-BUF export failed for device memory: %s\n",
                  strerror(-ret));
          fprintf(stderr, "  Device memory was requested but dmabuf export is "
                          "not available\n");
          (void)hipFree(writeBuffer);
          writeBuffer = nullptr;
          // Free read buffer on failure
          if (readBuffer) {
            if (readBufferActuallyOnDevice) {
              (void)hipFree(readBuffer);
            } else {
              (void)hipHostFree(readBuffer);
            }
          }
          return hipErrorInvalidValue;
        }

        fprintf(stderr, "  Data buffer physical: 0x%016llx (VRAM)\n",
                (unsigned long long)writeBufferDma);
        fprintf(stderr, "  GPU writes directly to VRAM\n");
        fprintf(stderr, "  NVMe DMAs from VRAM (P2P)\n");

        // Device memory - GPU pointer is same as host pointer
        writeBufferGpu = writeBuffer;
        writeBufferActuallyOnDevice = true; // Track that we're using device
                                            // memory
      } else {
        // Host memory - use hipHostMalloc (matching test code line 836)
        hipError_t buf_err = hipHostMalloc(&writeBuffer, dataBufferSize,
                                           hipHostMallocMapped);
        if (buf_err != hipSuccess) {
          fprintf(stderr, "Error: hipHostMalloc failed for write buffer: %s\n",
                  hipGetErrorString(buf_err));
          // Free read buffer on failure
          if (readBuffer) {
            if (readBufferActuallyOnDevice) {
              (void)hipFree(readBuffer);
            } else {
              (void)hipHostFree(readBuffer);
            }
          }
          return buf_err;
        }

        // Get physical address for host memory using /proc/self/pagemap
        // (matching test code line 842)
        writeBufferDma = virt_to_phys(writeBuffer);
        if (!writeBufferDma) {
          fprintf(stderr,
                  "ERROR: Failed to get write buffer physical address\n");
          (void)hipHostFree(writeBuffer);
          writeBuffer = nullptr;
          // Free read buffer on failure
          if (readBuffer) {
            if (readBufferActuallyOnDevice) {
              (void)hipFree(readBuffer);
            } else {
              (void)hipHostFree(readBuffer);
            }
          }
          return hipErrorInvalidValue;
        }

        fprintf(stderr, "  Data buffer virtual:  %p\n", writeBuffer);
        fprintf(stderr, "  Data buffer physical: 0x%016llx\n",
                (unsigned long long)writeBufferDma);
        fprintf(stderr, "  GPU can write directly to this buffer\n");
        fprintf(stderr, "  NVMe can DMA from this buffer\n");
        writeBufferActuallyOnDevice = false; // Track that we're using host
                                             // memory
      }

      // Write buffer registration:
      // - Device memory: Already registered via
      // export_and_register_vram_buffer()
      // - Host memory: Physical address obtained from pagemap, kernel module
      // will
      //   use virt_to_phys() fallback if needed for PRP injection

      // Verify write buffer is GPU-accessible and get GPU pointer if needed
      // (matches QEMU guest code pattern - hipHostMallocMapped should be
      // GPU-accessible)
      if (!writeBufferOnDevice) {
        hipPointerAttribute_t attr;
        hipError_t attr_err = hipPointerGetAttributes(&attr, writeBuffer);
        if (attr_err != hipSuccess) {
          fprintf(stderr,
                  "Warning: Write buffer may not be GPU-accessible: %s\n",
                  hipGetErrorString(attr_err));
          writeBufferGpu = writeBuffer; // Fallback to host pointer
        } else {
          fprintf(
            stderr,
            "Write buffer GPU accessibility verified: type=%d, device=%d\n",
            attr.type, attr.device);
          // Get explicit GPU pointer (may be same as host pointer for mapped
          // memory)
          void* gpu_ptr = nullptr;
          hipError_t gpu_ptr_err = hipHostGetDevicePointer(&gpu_ptr,
                                                           writeBuffer, 0);
          if (gpu_ptr_err == hipSuccess && gpu_ptr != nullptr) {
            // Store GPU pointer for kernel launch (may be same as host pointer)
            writeBufferGpu = static_cast<uint8_t*>(gpu_ptr);
            fprintf(stderr, "Write buffer GPU pointer: %p (host: %p)\n",
                    writeBufferGpu, writeBuffer);
          } else {
            // Fallback: use host pointer (should work for hipHostMallocMapped)
            writeBufferGpu = writeBuffer;
          }
        }
      } else {
        // Device memory - GPU pointer is same as host pointer
        writeBufferGpu = writeBuffer;
      }

      fprintf(stderr,
              "Write buffer allocated: virt=%p, phys=0x%llx, size=%zu\n",
              writeBuffer, (unsigned long long)writeBufferDma, dataBufferSize);
    }
  }

  // Launch GPU kernel with individual parameters (matching test-ep pattern)
  // Note: HIP device should already be set above, before queue creation
  // Verify all pointers are valid and GPU-accessible before launch
  if (!config->submissionQueue || !config->completionQueue) {
    fprintf(stderr, "Error: Invalid queue pointers (sq=%p, cq=%p)\n",
            config->submissionQueue, config->completionQueue);
    return hipErrorInvalidValue;
  }

  // Verify queue pointers are GPU-accessible (like we do for data buffers)
  hipPointerAttribute_t sq_attr, cq_attr;
  hipError_t sq_attr_err = hipPointerGetAttributes(&sq_attr,
                                                   config->submissionQueue);
  hipError_t cq_attr_err = hipPointerGetAttributes(&cq_attr,
                                                   config->completionQueue);

  if (sq_attr_err != hipSuccess) {
    fprintf(stderr,
            "Warning: Failed to get SQ pointer attributes: %s (code: %d)\n",
            hipGetErrorString(sq_attr_err), sq_attr_err);
    fprintf(stderr, "SQ pointer may not be GPU-accessible\n");
  } else {
    fprintf(stderr, "SQ GPU accessibility verified: type=%d, device=%d\n",
            sq_attr.type, sq_attr.device);
  }

  if (cq_attr_err != hipSuccess) {
    fprintf(stderr,
            "Warning: Failed to get CQ pointer attributes: %s (code: %d)\n",
            hipGetErrorString(cq_attr_err), cq_attr_err);
    fprintf(stderr, "CQ pointer may not be GPU-accessible\n");
  } else {
    fprintf(stderr, "CQ GPU accessibility verified: type=%d, device=%d\n",
            cq_attr.type, cq_attr.device);
  }

  // Verify shadowBufferVirt is GPU-accessible if it's non-null (like we do for
  // data buffers)
  if (shadowBufferVirt != nullptr) {
    hipPointerAttribute_t shadow_attr;
    hipError_t shadow_attr_err = hipPointerGetAttributes(&shadow_attr,
                                                         shadowBufferVirt);
    if (shadow_attr_err != hipSuccess) {
      fprintf(stderr,
              "Warning: Failed to get shadow buffer pointer attributes: %s "
              "(code: %d)\n",
              hipGetErrorString(shadow_attr_err), shadow_attr_err);
      fprintf(stderr, "Shadow buffer may not be GPU-accessible - disabling PCI "
                      "MMIO bridge mode\n");
      shadowBufferVirt = nullptr;
      usePciMmioBridge = false;
    } else {
      fprintf(stderr,
              "Shadow buffer GPU accessibility verified: type=%d, device=%d\n",
              shadow_attr.type, shadow_attr.device);
    }
  }

  // Verify nvmeBar0Gpu is GPU-accessible if it's non-null
  if (nvmeBar0Gpu != nullptr) {
    hipPointerAttribute_t bar0_attr;
    hipError_t bar0_attr_err = hipPointerGetAttributes(&bar0_attr, nvmeBar0Gpu);
    if (bar0_attr_err != hipSuccess) {
      fprintf(stderr,
              "Warning: Failed to get BAR0 pointer attributes: %s (code: %d)\n",
              hipGetErrorString(bar0_attr_err), bar0_attr_err);
      fprintf(
        stderr,
        "BAR0 may not be GPU-accessible - disabling direct doorbell mode\n");
      nvmeBar0Gpu = nullptr;
    } else {
      fprintf(stderr, "BAR0 GPU accessibility verified: type=%d, device=%d\n",
              bar0_attr.type, bar0_attr.device);
    }
  }

  // All pointers are GPU-accessible:
  // - Queues: allocated with hipHostMalloc (via
  // xioAllocateSubmissionQueue/CompletionQueue)
  // - startTimes/endTimes: allocated with hipHostMalloc in tester
  // - shadowBufferVirt: GPU pointer (from shadow buffer registration, if
  // enabled) - verified above
  // - readBuffer/writeBuffer: GPU pointers (from hipHostGetDevicePointer, if
  // host memory) Pass all pointers directly like test-ep does (test-ep line
  // 870-873)

  // Note: shadowBufferVirt is from kernel module mmap, which may not be
  // GPU-accessible even after hipHostRegister. If PCI MMIO bridge is enabled
  // but shadow buffer registration failed, disable PCI MMIO bridge mode to
  // avoid kernel launch failure. The GPU kernel handles nullptr
  // shadowBufferVirt gracefully.

  fprintf(stderr,
          "Launching kernel: sq=%p, cq=%p, startTimes=%p, endTimes=%p, "
          "shadowBuffer=%p, usePciMmioBridge=%d, nvmeBar0Gpu=%p\n",
          config->submissionQueue, config->completionQueue, config->startTimes,
          config->endTimes, shadowBufferVirt, usePciMmioBridge, nvmeBar0Gpu);
  fprintf(stderr,
          "Data buffers: readBuffer=%p (dma=0x%llx), writeBuffer=%p "
          "(dma=0x%llx), size=%zu\n",
          readBufferGpu ? readBufferGpu : readBuffer,
          (unsigned long long)readBufferDma,
          writeBufferGpu ? writeBufferGpu : writeBuffer,
          (unsigned long long)writeBufferDma, dataBufferSize);
  fprintf(stderr,
          "Kernel parameters: lbaSize=%u, blocks=8, expected transfer_size=%u, "
          "writeBufferDma=0x%llx\n",
          lbaSize, 8 * lbaSize, (unsigned long long)writeBufferDma);

  // Launch kernel - matching test-ep pattern exactly (line 870-873)
  // queue_size is in entries (calculated above, stored in queue_size variable)

  fprintf(stderr, "Calling hipLaunchKernelGGL...\n");
  fprintf(stderr, "Queue length: %u entries\n", queue_size);

  // Cast void* to typed pointers like test-ep does (test-ep line 778-779)
  // This helps HIP validate the pointers correctly
  struct nvme_sqe* sqePtr = static_cast<struct nvme_sqe*>(
    config->submissionQueue);
  struct nvme_cqe* cqePtr = static_cast<struct nvme_cqe*>(
    config->completionQueue);

  hipLaunchKernelGGL(
    nvme_ep_kernel, dim3(1), dim3(config->numThreads), 0, 0,
    sqePtr,             // Cast to typed pointer like test-ep
    cqePtr,             // Cast to typed pointer like test-ep
    config->startTimes, // GPU-accessible (hipHostMalloc in tester) - pass
                        // directly like test-ep
    config->endTimes,   // GPU-accessible (hipHostMalloc in tester) - pass
                        // directly like test-ep
    config->iterations, config->numThreads, lbaSize, baseLba, usePciMmioBridge,
    shadowBufferVirt, // GPU pointer (from shadow buffer registration, if
                      // enabled)
    nvmeTargetBdf, queueId,
    doorbell_offset, // Doorbell offset calculated on host (matching
                     // test-gpu-nvme-write.cpp)
    readBufferGpu ? readBufferGpu
                  : readBuffer, // GPU pointer if available (host memory)
    writeBufferGpu ? writeBufferGpu
                   : writeBuffer, // GPU pointer if available (host memory)
    dataBufferSize, readBufferDma, writeBufferDma, lfsrSeed, queue_size,
    lbaRangeLbas,    // LBA range in LBAs (0 = no limit)
    useRandomAccess, // true for random access, false for sequential
    nvmeBar0Gpu,     // GPU pointer to NVMe BAR0 (for direct doorbell)
    readIo,          // readIo (negative for sequential mode)
    writeIo);        // writeIo (negative for sequential mode)

  // Check for kernel launch errors immediately
  hipError_t err = hipGetLastError();
  if (err != hipSuccess) {
    fprintf(stderr, "Kernel launch error: %s (code: %d)\n",
            hipGetErrorString(err), err);
    fprintf(stderr,
            "Debug: submissionQueue=%p, completionQueue=%p, "
            "startTimes=%p, endTimes=%p, shadowBuffer=%p\n",
            config->submissionQueue, config->completionQueue,
            config->startTimes, config->endTimes, shadowBufferVirt);

    // Additional diagnostics
    int diag_device = -1;
    hipError_t diag_err = hipGetDevice(&diag_device);
    fprintf(stderr, "HIP device after launch error: device=%d, err=%d\n",
            diag_device, diag_err);

    return err;
  }

  fprintf(stderr, "Kernel launched successfully\n");

  // Wait for GPU kernel to complete (kernel rings doorbell internally)
  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    fprintf(stderr, "Device synchronization error: %s (code: %d)\n",
            hipGetErrorString(err), err);
  }

  // Free data buffers
  // Cleanup buffers using correct free function based on actual allocation type
  // (matching test-gpu-nvme-write.cpp cleanup pattern)
  if (readBuffer) {
    if (readBufferActuallyOnDevice) {
      (void)hipFree(readBuffer);
    } else {
      (void)hipHostFree(readBuffer);
    }
  }
  if (writeBuffer) {
    if (writeBufferActuallyOnDevice) {
      (void)hipFree(writeBuffer);
    } else {
      (void)hipHostFree(writeBuffer);
    }
  }

  return err;
}

// Read PCI config space register
// Old PCI config reading functions removed - now using kernel module IOCTL

// Map PCI MMIO bridge shadow buffer via kernel module
static int map_mmio_bridge_shadow_buffer(uint16_t bridge_bdf,
                                         void** virt_addr) {
  int kmod_fd = -1;
  int ret = 0;
  struct rocm_axiio_mmio_bridge_shadow_req req;
  void* mapped = MAP_FAILED;

  // Open kernel module device
  kmod_fd = open(ROCM_XIO_DEVICE_PATH, O_RDWR);
  if (kmod_fd < 0) {
    fprintf(stderr, "Failed to open %s: %s\n", ROCM_XIO_DEVICE_PATH,
            strerror(errno));
    fprintf(stderr, "Please ensure the rocm-xio kernel module is loaded\n");
    return -errno;
  }

  // Get shadow buffer info from kernel module
  memset(&req, 0, sizeof(req));
  req.bridge_bdf = bridge_bdf;
  ret = ioctl(kmod_fd, ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER, &req);
  if (ret < 0) {
    fprintf(stderr, "Failed to get PCI MMIO bridge shadow buffer info: %s\n",
            strerror(errno));
    close(kmod_fd);
    return -errno;
  }

  if (req.shadow_gpa == 0) {
    fprintf(stderr, "PCI MMIO bridge shadow GPA is 0 (not configured)\n");
    close(kmod_fd);
    return -EINVAL;
  }

  // Map shadow buffer via kernel module mmap
  mapped = mmap(nullptr, req.shadow_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                kmod_fd, 0);
  if (mapped == MAP_FAILED) {
    fprintf(stderr, "Failed to mmap PCI MMIO bridge shadow buffer: %s\n",
            strerror(errno));
    close(kmod_fd);
    return -errno;
  }

  // Keep kmod_fd open for the mapping to remain valid
  // Note: In a production system, you might want to track this fd
  // and close it on cleanup, but for simplicity we'll leave it open
  // The kernel will clean it up when the process exits

  *virt_addr = mapped;
  fprintf(stderr,
          "PCI MMIO bridge shadow buffer mapped: GPA=0x%llx, "
          "size=%llu, vaddr=%p\n",
          (unsigned long long)req.shadow_gpa,
          (unsigned long long)req.shadow_size, mapped);

  return 0;
}

// Map NVMe BAR0 for direct doorbell access
// Similar to test-gpu-nvme-write.cpp's map_nvme_bar0 function
static int map_nvme_bar0(uint16_t nvme_bdf, void** bar0_cpu, void** bar0_gpu) {
  int bar0_fd = -1;
  int drm_fd = -1;
  void* mapped = MAP_FAILED;
  char resource_path[256];
  size_t bar0_size = 8192; // Map 8KB (enough for doorbell registers)
  hipError_t hip_err = hipSuccess;

  // Convert BDF to format: 00:BB:DD.F
  uint8_t bus = (nvme_bdf >> 8) & 0xFF;
  uint8_t dev = (nvme_bdf >> 3) & 0x1F;
  uint8_t func = nvme_bdf & 0x7;

  // Build resource0 path: /sys/bus/pci/devices/0000:BB:DD.F/resource0
  snprintf(resource_path, sizeof(resource_path),
           "/sys/bus/pci/devices/0000:%02x:%02x.%x/resource0", bus, dev, func);

  // Open BAR0 resource file
  bar0_fd = open(resource_path, O_RDWR);
  if (bar0_fd < 0) {
    fprintf(stderr, "Failed to open NVMe BAR0 resource %s: %s\n", resource_path,
            strerror(errno));
    return -errno;
  }

  // Map BAR0 to userspace
  mapped = mmap(nullptr, bar0_size, PROT_READ | PROT_WRITE, MAP_SHARED, bar0_fd,
                0);
  if (mapped == MAP_FAILED) {
    fprintf(stderr, "Failed to mmap NVMe BAR0: %s\n", strerror(errno));
    close(bar0_fd);
    return -errno;
  }

  fprintf(stderr, "NVMe BAR0 mapped at %p (size=%zu)\n", mapped, bar0_size);

  // Register with DRM GEM_USERPTR (required for GPU access to PCI MMIO)
  drm_fd = open("/dev/dri/renderD128", O_RDWR);
  if (drm_fd < 0) {
    fprintf(stderr, "Warning: Failed to open DRM device: %s\n",
            strerror(errno));
    fprintf(stderr, "Cannot register BAR0 with GPU via GEM_USERPTR.\n");
    munmap(mapped, bar0_size);
    close(bar0_fd);
    return -errno;
  }

  struct drm_amdgpu_gem_userptr gem_userptr = {};
  gem_userptr.addr = (uint64_t)mapped;
  gem_userptr.size = bar0_size;
  gem_userptr.flags = AMDGPU_GEM_USERPTR_REGISTER;

  if (ioctl(drm_fd, DRM_IOCTL_AMDGPU_GEM_USERPTR, &gem_userptr) < 0) {
    fprintf(stderr,
            "Warning: DRM_IOCTL_AMDGPU_GEM_USERPTR failed for BAR0: %s\n",
            strerror(errno));
    fprintf(stderr, "Cannot register BAR0 with GPU.\n");
    close(drm_fd);
    munmap(mapped, bar0_size);
    close(bar0_fd);
    return -errno;
  }

  fprintf(stderr, "NVMe BAR0 registered with DRM GEM_USERPTR (handle: %u)\n",
          gem_userptr.handle);

  // Register with HIP
  hip_err = hipHostRegister(mapped, bar0_size, hipHostRegisterMapped);
  if (hip_err != hipSuccess) {
    fprintf(stderr, "Warning: Failed to register BAR0 with HIP: %s\n",
            hipGetErrorString(hip_err));
    close(drm_fd);
    munmap(mapped, bar0_size);
    close(bar0_fd);
    return -EINVAL;
  }

  fprintf(stderr, "NVMe BAR0 registered with HIP for GPU access\n");

  // Get GPU pointer
  void* gpu_ptr = nullptr;
  hipError_t gpu_ptr_err = hipHostGetDevicePointer(&gpu_ptr, mapped, 0);
  if (gpu_ptr_err != hipSuccess) {
    fprintf(stderr, "Warning: hipHostGetDevicePointer failed for BAR0: %s\n",
            hipGetErrorString(gpu_ptr_err));
    (void)hipHostUnregister(mapped);
    close(drm_fd);
    munmap(mapped, bar0_size);
    close(bar0_fd);
    return -EINVAL;
  }

  fprintf(stderr, "NVMe BAR0 GPU pointer obtained: %p (host: %p)\n", gpu_ptr,
          mapped);

  // Keep bar0_fd and drm_fd open for the mapping to remain valid
  // The kernel will clean them up when the process exits

  *bar0_cpu = mapped;
  *bar0_gpu = gpu_ptr;

  // Note: We keep bar0_fd and drm_fd open - the mappings persist even after
  // close The kernel will clean them up when the process exits

  return 0;
}

//
// Host helper function for NVMe queue creation via IOCTL
//

// Structure for NVMe Identify Namespace response (4096 bytes)
struct nvme_id_ns {
  uint64_t nsze;  // Namespace size
  uint64_t ncap;  // Namespace capacity
  uint64_t nuse;  // Namespace utilization
  uint8_t nsfeat; // Namespace features
  uint8_t nlbaf;  // Number of LBA formats
  uint8_t flbas;  // Formatted LBA size (bits 3:0 = current format index)
  uint8_t mc;     // Metadata capabilities
  uint8_t dpc;    // End-to-end data protection capabilities
  uint8_t dps;    // End-to-end data protection type settings
  uint8_t nmic;   // Namespace multi-path I/O and namespace sharing capabilities
  uint8_t rescap; // Reservation capabilities
  uint8_t fpi;    // Format progress indicator
  uint8_t dlfeat; // Deallocate logical block features
  uint16_t nawun; // Namespace atomic write unit normal
  uint16_t nawupf;    // Namespace atomic write unit power fail
  uint16_t nacwu;     // Namespace atomic compare and write unit
  uint16_t nabsn;     // Namespace atomic boundary size normal
  uint16_t nabo;      // Namespace atomic boundary offset
  uint16_t nabspf;    // Namespace atomic boundary size power fail
  uint16_t noiob;     // Namespace optimal I/O boundary
  uint8_t nvmcap[16]; // NVM capacity
  uint8_t resv[40];   // Reserved
  uint8_t lbaf[64];   // LBA format support (16 formats * 4 bytes each)
};

__host__ int nvme_ep_query_lba_size(const char* nvme_device, uint32_t nsid,
                                    unsigned* lba_size) {
  // Declare all variables at the top to avoid goto scoping issues
  int nvme_fd = -1;
  int ret = 0;
  struct nvme_passthru_cmd cmd;
  struct nvme_id_ns* id_ns = nullptr;
  uint8_t flbas = 0;
  uint8_t lba_format_idx = 0;
  uint8_t* lbaf_ptr = nullptr;
  uint8_t lbads = 0;
  uint16_t status = 0;
  uint8_t* response_base = nullptr; // Base pointer for accessing lbaf array

  if (!nvme_device || !lba_size) {
    return -EINVAL;
  }

  // Allocate buffer for Identify Namespace response (4096 bytes)
  id_ns = static_cast<struct nvme_id_ns*>(malloc(4096));
  if (!id_ns) {
    return -ENOMEM;
  }
  memset(id_ns, 0, 4096);

  // Open NVMe device
  nvme_fd = open(nvme_device, O_RDONLY);
  if (nvme_fd < 0) {
    fprintf(stderr, "Failed to open NVMe device %s: %s\n", nvme_device,
            strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Send Identify Namespace command
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_identify;
  cmd.nsid = nsid;
  cmd.cdw10 = 0; // CNS=0 (Identify Namespace)
  cmd.addr = reinterpret_cast<uint64_t>(id_ns);
  cmd.data_len = 4096;
  cmd.timeout_ms = 0; // Use default timeout

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    fprintf(stderr, "Failed to identify namespace: %s\n", strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Check completion status
  if (cmd.result & 0xFFFE) {
    status = (cmd.result >> 1) & 0xFF;
    fprintf(stderr, "Identify Namespace failed with status 0x%02x\n", status);
    ret = -EIO;
    goto cleanup;
  }

  // Extract FLBAS (Formatted LBA and Metadata Size)
  // Bits 3:0 contain the current LBA format index
  flbas = id_ns->flbas;
  lba_format_idx = flbas & 0x0F;

  // Validate LBA format index
  // nlbaf indicates the number of LBA formats supported (0-indexed)
  // Valid format indices are 0 through nlbaf (inclusive)
  // So if nlbaf=7, formats 0-7 are supported (8 formats total)
  if (lba_format_idx > id_ns->nlbaf) {
    fprintf(stderr, "Invalid LBA format index %u (max supported: %u)\n",
            lba_format_idx, id_ns->nlbaf);
    ret = -EINVAL;
    goto cleanup;
  }

  // Extract LBADS (LBA Data Size) from LBA Format structure
  // LBA Format structures start at offset 128 (after header) in the NVMe
  // response According to Linux kernel struct nvme_lbaf:
  //   struct nvme_lbaf {
  //     __le16  ms;    // Metadata size (bytes 0-1, little-endian)
  //     __u8    ds;    // LBA Data Size - LBADS (byte 2)
  //     __u8    rp;    // Relative Performance (byte 3)
  //   };
  // So LBADS is in byte 2 of each 4-byte structure, not byte 0!
  //
  // IMPORTANT: Access lbaf array using byte offset from start of buffer
  // to avoid structure padding/alignment issues. The lbaf array starts at
  // offset 128 bytes from the start of the Identify Namespace response.
  response_base = reinterpret_cast<uint8_t*>(id_ns);
  lbaf_ptr = response_base + 128 + (lba_format_idx * 4);

  // Debug: Print raw bytes for format 0 to diagnose parsing issues
  if (lba_format_idx == 0) {
    uint8_t* lbaf0_raw = response_base + 128;
    fprintf(stderr,
            "Debug: Format 0 raw bytes at offset 128: "
            "[0]=0x%02x [1]=0x%02x [2]=0x%02x [3]=0x%02x\n",
            lbaf0_raw[0], lbaf0_raw[1], lbaf0_raw[2], lbaf0_raw[3]);
    // Also check as 32-bit little-endian value
    uint32_t lbaf0_u32 = *reinterpret_cast<uint32_t*>(lbaf0_raw);
    fprintf(stderr, "Debug: Format 0 as uint32 (little-endian): 0x%08x\n",
            lbaf0_u32);
    fprintf(
      stderr,
      "Debug: Extracting bits - [0-7]=%u [8-15]=%u [16-23]=%u [24-31]=%u\n",
      (lbaf0_u32 >> 0) & 0xFF, (lbaf0_u32 >> 8) & 0xFF,
      (lbaf0_u32 >> 16) & 0xFF, (lbaf0_u32 >> 24) & 0xFF);
  }

  // LBADS (ds field) is in byte 2 according to struct nvme_lbaf
  // Structure layout: bytes[0-1]=ms (little-endian), byte[2]=ds (LBADS),
  // byte[3]=rp
  lbads = lbaf_ptr[2] & 0xFF;

  // Debug: If byte 0 is 0, check if the value is in byte 2 (might indicate
  // alignment issue)
  if (lbads == 0 && lbaf_ptr[2] != 0) {
    fprintf(stderr,
            "Debug: Byte 0 is 0, but byte 2 has value 0x%02x - "
            "possible structure alignment issue\n",
            lbaf_ptr[2]);
    // Try reading from byte 2 as a workaround (this shouldn't be necessary if
    // structure is correct) But for now, let's see what the actual layout is
  }

  // Debug output - show all supported formats
  // nlbaf indicates number of formats supported, valid indices are 0 through
  // nlbaf
  fprintf(stderr,
          "LBA size detection: nlbaf=%u (supports formats 0-%u), "
          "flbas=0x%02x, lba_format_idx=%u\n",
          id_ns->nlbaf, id_ns->nlbaf, flbas, lba_format_idx);
  fprintf(stderr, "Supported LBA formats:\n");
  for (uint8_t i = 0; i <= id_ns->nlbaf && i < 16; i++) {
    // Access lbaf using byte offset from start of buffer (offset 128)
    // Structure: bytes[0-1]=ms (little-endian), byte[2]=ds (LBADS), byte[3]=rp
    uint8_t* lbaf_i_ptr = response_base + 128 + (i * 4);
    uint16_t ms_i = lbaf_i_ptr[0] | (lbaf_i_ptr[1] << 8); // Little-endian
    uint8_t lbads_i = lbaf_i_ptr[2] & 0xFF;               // LBADS is in byte 2
    uint32_t lba_size_i = (lbads_i > 0) ? (1U << lbads_i) : 0;
    fprintf(stderr, "  Format %u: lbads=%u, ms=%u, lba_size=%u bytes%s\n", i,
            lbads_i, ms_i, lba_size_i,
            (i == lba_format_idx) ? " (current)" : "");
  }

  // Validate LBADS value
  // LBADS=0 indicates unformatted namespace or invalid format
  // Standard LBA sizes: lbads=9 (512B), lbads=12 (4KB)
  // Some devices may support lbads=8 (256B) or other values
  if (lbads == 0) {
    fprintf(stderr,
            "Warning: Invalid LBADS value (0) in format %u, "
            "namespace may be unformatted\n",
            lba_format_idx);

    // Try to find a valid format by checking other supported indices
    // Only check formats 0 through nlbaf (as indicated by nlbaf)
    bool found_valid = false;
    for (uint8_t i = 0; i <= id_ns->nlbaf && i < 16; i++) {
      // Access lbaf using byte offset from start of buffer (offset 128)
      // Structure: bytes[0-1]=ms (little-endian), byte[2]=ds (LBADS),
      // byte[3]=rp
      uint8_t* lbaf_i_ptr = response_base + 128 + (i * 4);
      uint8_t lbads_i = lbaf_i_ptr[2] & 0xFF; // LBADS is in byte 2
      if (lbads_i > 0) {
        uint32_t lba_size_i = 1U << lbads_i;
        fprintf(stderr,
                "Found format %u with lbads=%u (lba_size=%u bytes), "
                "using it instead\n",
                i, lbads_i, lba_size_i);
        if (lbads_i < 9) {
          fprintf(stderr,
                  "Warning: Unusual LBA size (%u bytes), "
                  "standard sizes are 512B (lbads=9) or 4KB (lbads=12)\n",
                  lba_size_i);
        }
        lbads = lbads_i;
        found_valid = true;
        break;
      }
    }

    if (!found_valid) {
      fprintf(stderr, "No valid LBA format found, will fall back to default\n");
      // Return error so caller can use fallback
      ret = -EINVAL;
      goto cleanup;
    }
  } else if (lbads < 9) {
    // Valid but unusual LBA size
    fprintf(stderr,
            "Warning: Unusual LBA size (%u bytes, lbads=%u), "
            "standard sizes are 512B (lbads=9) or 4KB (lbads=12)\n",
            1U << lbads, lbads);
  }

  // LBA size = 2^LBADS bytes
  *lba_size = 1U << lbads;
  fprintf(stderr, "Selected LBA size: %u bytes (lbads=%u)\n", *lba_size, lbads);

  ret = 0;

cleanup:
  if (nvme_fd >= 0) {
    close(nvme_fd);
  }
  if (id_ns) {
    free(id_ns);
  }
  return ret;
}

__host__ int nvme_ep_query_namespace_capacity(const char* nvme_device,
                                              uint32_t nsid,
                                              uint64_t* capacity_lbas) {
  int nvme_fd = -1;
  int ret = 0;
  struct nvme_passthru_cmd cmd;
  struct nvme_id_ns* id_ns = nullptr;
  uint16_t status = 0;

  if (!nvme_device || !capacity_lbas) {
    return -EINVAL;
  }

  // Allocate buffer for Identify Namespace response (4096 bytes)
  id_ns = static_cast<struct nvme_id_ns*>(malloc(4096));
  if (!id_ns) {
    return -ENOMEM;
  }
  memset(id_ns, 0, 4096);

  // Open NVMe device
  nvme_fd = open(nvme_device, O_RDONLY);
  if (nvme_fd < 0) {
    fprintf(stderr, "Failed to open NVMe device %s: %s\n", nvme_device,
            strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Send Identify Namespace command
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_identify;
  cmd.nsid = nsid;
  cmd.cdw10 = 0; // CNS=0 (Identify Namespace)
  cmd.addr = reinterpret_cast<uint64_t>(id_ns);
  cmd.data_len = 4096;
  cmd.timeout_ms = 0; // Use default timeout

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    fprintf(stderr, "Failed to identify namespace: %s\n", strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Check completion status
  if (cmd.result & 0xFFFE) {
    status = (cmd.result >> 1) & 0xFF;
    fprintf(stderr, "Identify Namespace failed with status 0x%02x\n", status);
    ret = -EIO;
    goto cleanup;
  }

  // Extract NSZE (Namespace Size) - capacity in LBAs
  // NSZE is little-endian 64-bit value at offset 0
  *capacity_lbas = id_ns->nsze;
  fprintf(stderr, "Namespace capacity: %llu LBAs\n",
          (unsigned long long)*capacity_lbas);

  ret = 0;

cleanup:
  if (nvme_fd >= 0) {
    close(nvme_fd);
  }
  if (id_ns) {
    free(id_ns);
  }
  return ret;
}

__host__ int nvme_ep_create_queue_via_ioctl(
  const char* nvme_device, const char* kernel_module_device, uint16_t queue_id,
  uint16_t queue_size, uint16_t nvme_bdf, unsigned memory_mode,
  struct nvme_queue_info* info) {
  // Declare all variables at the top to avoid goto scoping issues
  int kmod_fd = -1;
  int nvme_fd = -1;
  int drm_fd = -1;
  int ret = 0;
  hipError_t sqe_err = hipSuccess;
  hipError_t cqe_err = hipSuccess;
  hipError_t sq_hip_err = hipSuccess;
  hipError_t cq_hip_err = hipSuccess;
  hipError_t sq_gpu_ptr_err = hipSuccess;
  hipError_t cq_gpu_ptr_err = hipSuccess;
  void* sq_virt = nullptr;
  void* cq_virt = nullptr;
  void* sq_gpu = nullptr;
  void* cq_gpu = nullptr;
  bool sq_uses_coherent = false; // Track if SQ was reallocated with coherent
  bool cq_uses_coherent = false; // Track if CQ was reallocated with coherent
  bool sq_is_device = (memory_mode & 0x1) != 0; // Bit 0: GPU write location
  bool cq_is_device = (memory_mode & 0x2) != 0; // Bit 1: CPU write location
  int sq_dmabuf_fd = -1; // Not currently used, but kept for struct
                         // compatibility
  int cq_dmabuf_fd = -1; // Not currently used, but kept for struct
                         // compatibility
  uint64_t sq_phys = 0;
  uint64_t cq_phys = 0;
  struct nvme_passthru_cmd cmd;
  struct drm_amdgpu_gem_userptr sq_userptr = {};
  struct drm_amdgpu_gem_userptr cq_userptr = {};
  bool gpuWriteToDevice = (memory_mode & 0x1) != 0;
  bool cpuWriteToDevice = (memory_mode & 0x2) != 0;
  size_t page_size = 0;
  size_t sq_size_aligned = 0;
  size_t cq_size_aligned = 0;

  if (!nvme_device || !kernel_module_device || !info) {
    return -EINVAL;
  }

  // Validate queue_size is power of 2 and non-zero
  // Note: uint16_t max is 65535, so no need to check upper bound
  if (queue_size == 0 || (queue_size & (queue_size - 1)) != 0) {
    return -EINVAL;
  }

  // Calculate queue sizes in bytes
  const size_t sq_size_bytes = queue_size * NVME_EP_SQE_SIZE;
  const size_t cq_size_bytes = queue_size * NVME_EP_CQE_SIZE;

  // Calculate page-aligned sizes for GEM_USERPTR (required for GPU access)
  page_size = sysconf(_SC_PAGESIZE);
  sq_size_aligned = ((sq_size_bytes + page_size - 1) / page_size) * page_size;
  cq_size_aligned = ((cq_size_bytes + page_size - 1) / page_size) * page_size;

  // Zero-initialize output structure
  memset(info, 0, sizeof(*info));
  info->sq_size = sq_size_bytes;
  info->cq_size = cq_size_bytes;

  // Open kernel module device
  kmod_fd = open(kernel_module_device, O_RDWR);
  if (kmod_fd < 0) {
    fprintf(stderr, "Failed to open kernel module device %s: %s\n",
            kernel_module_device, strerror(errno));
    return -errno;
  }

  // Detect if NVMe device is emulated (QEMU) or passthrough
  bool is_emulated = false;
  int detect_ret = xioDetectEmulatedNvme(nvme_device, &is_emulated);
  if (detect_ret != 0) {
    fprintf(stderr, "Warning: Failed to detect NVMe type for %s: %s\n",
            nvme_device, strerror(-detect_ret));
    fprintf(stderr, "Defaulting to passthrough mode\n");
    is_emulated = false;
  }
  fprintf(stderr, "NVMe device %s detected as: %s\n", nvme_device,
          is_emulated ? "EMULATED" : "PASSTHROUGH");

  // Open NVMe device (requires root permissions)
  nvme_fd = open(nvme_device, O_RDWR);
  if (nvme_fd < 0) {
    if (errno == EACCES || errno == EPERM) {
      fprintf(stderr, "Failed to open NVMe device %s: %s\n", nvme_device,
              strerror(errno));
      fprintf(stderr, "Note: NVMe device access requires root permissions.\n");
      fprintf(stderr,
              "Please run with sudo or ensure your user has access to %s\n",
              nvme_device);
    } else {
      fprintf(stderr, "Failed to open NVMe device %s: %s\n", nvme_device,
              strerror(errno));
    }
    close(kmod_fd);
    return -errno;
  }

  // Allocate SQ buffer based on memory mode (like test-ep)
  // Bit 0 (LSB): GPU write location (SQE) - 0=host, 1=device
  sqe_err = xioAllocateSubmissionQueue(sq_size_bytes, memory_mode, &sq_virt);
  if (sqe_err != hipSuccess) {
    fprintf(stderr, "Failed to allocate SQ buffer: %s\n",
            hipGetErrorString(sqe_err));
    ret = -ENOMEM;
    goto cleanup;
  }

  // Allocate CQ buffer based on memory mode (like test-ep)
  // Bit 1: CPU write location (CQE) - 0=host, 1=device
  cqe_err = xioAllocateCompletionQueue(cq_size_bytes, memory_mode, &cq_virt);
  if (cqe_err != hipSuccess) {
    fprintf(stderr, "Failed to allocate CQ buffer: %s\n",
            hipGetErrorString(cqe_err));
    // Free SQ on failure
    xioFreeSubmissionQueue(sq_virt, memory_mode);
    ret = -ENOMEM;
    goto cleanup;
  }

  // Zero-initialize queues
  // For host memory (mmap), use memset directly
  // For device memory (HSA), we need to use hipMemset or
  // hsa_memory_assign_agent
  if (gpuWriteToDevice) {
    // Device memory allocated via HSA - use hipMemset if pointer is
    // GPU-accessible Note: HSA-allocated memory may need special handling
    memset(sq_virt, 0,
           sq_size_bytes); // HSA fine-grained memory is host-accessible
  } else {
    // Host memory (malloc) - use memset
    memset(sq_virt, 0, sq_size_bytes);
  }

  if (cpuWriteToDevice) {
    // Device memory allocated via HSA
    memset(cq_virt, 0,
           cq_size_bytes); // HSA fine-grained memory is host-accessible
  } else {
    // Host memory (malloc) - use memset
    memset(cq_virt, 0, cq_size_bytes);
  }

  // Reallocate host memory queues with hipHostMallocCoherent for GPU-PCIe
  // coherency This is critical for gfx900 (MI250) where GPU writes must be
  // immediately visible to PCIe devices like NVMe controllers
  if (!gpuWriteToDevice) {
    void* sq_virt_coherent = nullptr;
    hipError_t sq_coherent_err = hipHostMalloc(&sq_virt_coherent, sq_size_bytes,
                                               hipHostMallocMapped |
                                                 hipHostMallocCoherent);
    if (sq_coherent_err != hipSuccess) {
      fprintf(stderr, "Warning: hipHostMallocCoherent failed for SQ: %s\n",
              hipGetErrorString(sq_coherent_err));
      fprintf(stderr, "Falling back to regular allocation (may not work on "
                      "gfx900)\n");
    } else {
      // Copy zeroed data to coherent memory
      memcpy(sq_virt_coherent, sq_virt, sq_size_bytes);
      // Free original allocation (may be hipHostMalloc or malloc)
      hipError_t freeErr = hipHostFree(sq_virt);
      if (freeErr != hipSuccess) {
        // Not HIP-allocated, use regular free
        free(sq_virt);
      }
      sq_virt = sq_virt_coherent;
      sq_uses_coherent = true; // Mark that SQ uses coherent allocation
    }
  }

  if (!cpuWriteToDevice) {
    void* cq_virt_coherent = nullptr;
    hipError_t cq_coherent_err = hipHostMalloc(&cq_virt_coherent, cq_size_bytes,
                                               hipHostMallocMapped |
                                                 hipHostMallocCoherent);
    if (cq_coherent_err != hipSuccess) {
      fprintf(stderr, "Warning: hipHostMallocCoherent failed for CQ: %s\n",
              hipGetErrorString(cq_coherent_err));
      fprintf(stderr, "Falling back to regular allocation (may not work on "
                      "gfx900)\n");
    } else {
      // Copy zeroed data to coherent memory
      memcpy(cq_virt_coherent, cq_virt, cq_size_bytes);
      // Free original allocation (may be hipHostMalloc or malloc)
      hipError_t freeErr = hipHostFree(cq_virt);
      if (freeErr != hipSuccess) {
        // Not HIP-allocated, use regular free
        free(cq_virt);
      }
      cq_virt = cq_virt_coherent;
      cq_uses_coherent = true; // Mark that CQ uses coherent allocation
    }
  }

  // Register queues with GPU (matching test-gpu-nvme-write.cpp pattern)
  // Step 1: DRM GEM_USERPTR registration (required for GPU access to host
  // memory)
  // Note: For device memory (hipMalloc), queues are already GPU-accessible,
  // so GEM_USERPTR is optional but we do it anyway for consistency
  // GEM_USERPTR requires page-aligned sizes (already calculated above)

  drm_fd = open("/dev/dri/renderD128", O_RDWR);
  if (drm_fd < 0) {
    fprintf(stderr, "Warning: Failed to open DRM device: %s\n",
            strerror(errno));
    fprintf(stderr, "Cannot register queues with GPU via GEM_USERPTR.\n");
    // For device memory, this is not fatal - queues are already GPU-accessible
    if (sq_is_device && cq_is_device) {
      fprintf(stderr, "Note: Device memory queues are already GPU-accessible, "
                      "continuing without GEM_USERPTR\n");
      drm_fd = -1; // Mark as not opened
    } else {
      ret = -errno;
      goto cleanup;
    }
  } else {
    // Register SQ with DRM GEM_USERPTR (if DRM fd opened successfully)
    sq_userptr.addr = (uint64_t)sq_virt;
    sq_userptr.size = sq_size_aligned; // Use page-aligned size
    sq_userptr.flags = AMDGPU_GEM_USERPTR_REGISTER;

    if (ioctl(drm_fd, DRM_IOCTL_AMDGPU_GEM_USERPTR, &sq_userptr) < 0) {
      fprintf(stderr,
              "Warning: DRM_IOCTL_AMDGPU_GEM_USERPTR failed for SQ: %s\n",
              strerror(errno));
      // For device memory, this is not fatal
      if (sq_is_device) {
        fprintf(stderr, "Note: SQ is device memory (already GPU-accessible), "
                        "continuing without GEM_USERPTR\n");
      } else {
        fprintf(stderr, "Cannot register SQ with GPU.\n");
        close(drm_fd);
        ret = -errno;
        goto cleanup;
      }
    } else {
      fprintf(stderr, "SQ registered with DRM GEM_USERPTR (handle: %u)\n",
              sq_userptr.handle);
    }

    // Register CQ with DRM GEM_USERPTR
    cq_userptr.addr = (uint64_t)cq_virt;
    cq_userptr.size = cq_size_aligned; // Use page-aligned size
    cq_userptr.flags = AMDGPU_GEM_USERPTR_REGISTER;

    if (ioctl(drm_fd, DRM_IOCTL_AMDGPU_GEM_USERPTR, &cq_userptr) < 0) {
      fprintf(stderr,
              "Warning: DRM_IOCTL_AMDGPU_GEM_USERPTR failed for CQ: %s\n",
              strerror(errno));
      // For device memory, this is not fatal
      if (cq_is_device) {
        fprintf(stderr, "Note: CQ is device memory (already GPU-accessible), "
                        "continuing without GEM_USERPTR\n");
      } else {
        fprintf(stderr, "Cannot register CQ with GPU.\n");
        if (sq_userptr.handle != 0) {
          // Try to unregister SQ if it was registered
          // (Note: There's no unregister call, but closing drm_fd should handle
          // it)
        }
        close(drm_fd);
        ret = -errno;
        goto cleanup;
      }
    } else {
      fprintf(stderr, "CQ registered with DRM GEM_USERPTR (handle: %u)\n",
              cq_userptr.handle);
    }
  }

  // Step 2: Register with HIP (matching test-gpu-nvme-write.cpp pattern)
  // Skip hipHostRegister if:
  // 1. Memory was allocated with hipHostMallocCoherent (already registered)
  // 2. Memory is device memory (allocated via HSA, already GPU-accessible)
  if (!sq_uses_coherent && !sq_is_device) {
    sq_hip_err = hipHostRegister(sq_virt, sq_size_bytes, hipHostRegisterMapped);
    if (sq_hip_err != hipSuccess) {
      fprintf(stderr, "Warning: Failed to register SQ with HIP: %s\n",
              hipGetErrorString(sq_hip_err));
      close(drm_fd);
      ret = -EIO;
      goto cleanup;
    }
  }

  if (!cq_uses_coherent && !cq_is_device) {
    cq_hip_err = hipHostRegister(cq_virt, cq_size_bytes, hipHostRegisterMapped);
    if (cq_hip_err != hipSuccess) {
      fprintf(stderr, "Warning: Failed to register CQ with HIP: %s\n",
              hipGetErrorString(cq_hip_err));
      if (!sq_uses_coherent && !sq_is_device) {
        (void)hipHostUnregister(sq_virt); // Ignore return value in cleanup
      }
      close(drm_fd);
      ret = -EIO;
      goto cleanup;
    }
  }

  // Step 3: Get GPU pointers (matching test-gpu-nvme-write.cpp pattern)
  // For device memory (hipMalloc), GPU pointer is same as host pointer
  // For host memory (hipHostMalloc), need hipHostGetDevicePointer
  if (sq_is_device) {
    // Device memory - GPU pointer is same as host pointer
    sq_gpu = sq_virt;
    sq_gpu_ptr_err = hipSuccess;
  } else {
    // Host memory - get GPU pointer via hipHostGetDevicePointer
    sq_gpu_ptr_err = hipHostGetDevicePointer(&sq_gpu, sq_virt, 0);
    if (sq_gpu_ptr_err != hipSuccess) {
      fprintf(stderr, "Warning: hipHostGetDevicePointer failed for SQ: %s\n",
              hipGetErrorString(sq_gpu_ptr_err));
      if (!sq_uses_coherent) {
        (void)hipHostUnregister(sq_virt); // Ignore return value in cleanup
      }
      if (!cq_uses_coherent && !cq_is_device) {
        (void)hipHostUnregister(cq_virt); // Ignore return value in cleanup
      }
      close(drm_fd);
      ret = -EIO;
      goto cleanup;
    }
  }

  if (cq_is_device) {
    // Device memory - GPU pointer is same as host pointer
    cq_gpu = cq_virt;
    cq_gpu_ptr_err = hipSuccess;
  } else {
    // Host memory - get GPU pointer via hipHostGetDevicePointer
    cq_gpu_ptr_err = hipHostGetDevicePointer(&cq_gpu, cq_virt, 0);
    if (cq_gpu_ptr_err != hipSuccess) {
      fprintf(stderr, "Warning: hipHostGetDevicePointer failed for CQ: %s\n",
              hipGetErrorString(cq_gpu_ptr_err));
      if (!sq_uses_coherent && !sq_is_device) {
        (void)hipHostUnregister(sq_virt); // Ignore return value in cleanup
      }
      if (!cq_uses_coherent) {
        (void)hipHostUnregister(cq_virt); // Ignore return value in cleanup
      }
      close(drm_fd);
      ret = -EIO;
      goto cleanup;
    }
  }

  fprintf(stderr,
          "Queues registered with GPU: SQ=%p (host=%p), CQ=%p (host=%p)\n",
          sq_gpu, sq_virt, cq_gpu, cq_virt);

  // Keep drm_fd open for the mappings to remain valid
  // Note: In a production system, you might want to track this fd
  // The kernel will clean it up when the process exits
  // We close it here but set to -1 so cleanup doesn't try to close again
  close(drm_fd);
  drm_fd = -1;

  // Get dmabuf file descriptors for the buffers
  // Note: This requires HIP extension or manual dmabuf export
  // For now, we'll use a placeholder approach - in practice, you may need
  // to use hipMemGetInfo or a HIP extension to get dmabuf FDs
  // TODO: Get actual dmabuf FDs from HIP buffers
  // This is platform-specific and may require HIP extensions
  // For now, we'll assume the kernel module can handle virtual addresses
  // directly, or we need to implement dmabuf export separately

  // Get physical addresses based on memory mode
  // Memory mode 0 (host memory): Use /proc/self/pagemap (like QEMU guest code)
  // Memory mode with bits set (device memory): Use dmabuf FDs and kernel module
  // IOCTL

  if (gpuWriteToDevice) {
    // Device memory (HSA) - export as DMA-BUF and get physical address
    // Similar to VRAM buffer export - need page alignment
    const size_t host_page_size = sysconf(_SC_PAGESIZE);
    void* aligned_sq_ptr = (void*)((uintptr_t)sq_virt & ~(host_page_size - 1));
    uint64_t sq_dmabuf_offset = (uintptr_t)sq_virt - (uintptr_t)aligned_sq_ptr;
    size_t aligned_sq_size = (sq_size_bytes + sq_dmabuf_offset +
                              host_page_size - 1) &
                             ~(host_page_size - 1);

    int sq_dmabuf_fd = -1;
    hsa_status_t sq_dmabuf_status = hsa_amd_portable_export_dmabuf(
      aligned_sq_ptr, aligned_sq_size, &sq_dmabuf_fd, &sq_dmabuf_offset);
    if (sq_dmabuf_status != HSA_STATUS_SUCCESS) {
      fprintf(stderr, "ERROR: Failed to export SQ as DMA-BUF (status=%d): %s\n",
              sq_dmabuf_status,
              (sq_dmabuf_status == HSA_STATUS_ERROR_INVALID_ARGUMENT)
                ? "Invalid argument"
                : "Unknown error");
      fprintf(stderr, "Device memory queues require DMA-BUF export support.\n");
      ret = -ENOTSUP;
      goto cleanup;
    }

    // Get physical address via kernel module
    struct rocm_axiio_register_buffer_req buf_req = {};
    buf_req.dmabuf_fd = sq_dmabuf_fd;
    buf_req.virt_addr = reinterpret_cast<uint64_t>(sq_virt);
    buf_req.size = sq_size_bytes;
    buf_req.nvme_bdf = nvme_bdf;
    buf_req.flags = is_emulated ? ROCM_XIO_FLAG_EMULATED
                                : ROCM_XIO_FLAG_PASSTHROUGH;
    fprintf(stderr, "SQ registration: is_emulated=%d, flags=0x%x\n",
            is_emulated, buf_req.flags);

    ret = ioctl(kmod_fd, ROCM_XIO_REGISTER_BUFFER, &buf_req);
    close(sq_dmabuf_fd); // Close FD after kernel module has it
    if (ret < 0) {
      fprintf(stderr,
              "ERROR: Failed to get SQ physical address via kernel module: "
              "%s\n",
              strerror(errno));
      ret = -errno;
      goto cleanup;
    }
    sq_phys = buf_req.phys_addr + sq_dmabuf_offset;
    fprintf(stderr,
            "SQ device memory: virt=0x%016llx, phys=0x%016llx (via DMA-BUF)\n",
            (unsigned long long)reinterpret_cast<uint64_t>(sq_virt),
            (unsigned long long)sq_phys);
  } else {
    // Host memory (mmap) - use /proc/self/pagemap to get physical address
    // This matches QEMU guest code pattern (test-gpu-nvme-write.cpp)
    int pagemap_fd = open("/proc/self/pagemap", O_RDONLY);
    if (pagemap_fd < 0) {
      fprintf(stderr, "Warning: Failed to open /proc/self/pagemap: %s\n",
              strerror(errno));
      fprintf(stderr, "Using virtual address as physical address for SQ\n");
      sq_phys = reinterpret_cast<uint64_t>(sq_virt);
    } else {
      uint64_t page_offset = reinterpret_cast<uint64_t>(sq_virt) %
                             sysconf(_SC_PAGESIZE);
      uint64_t pfn;
      off_t offset = (reinterpret_cast<uint64_t>(sq_virt) /
                      sysconf(_SC_PAGESIZE)) *
                     sizeof(uint64_t);

      if (lseek(pagemap_fd, offset, SEEK_SET) >= 0 &&
          read(pagemap_fd, &pfn, sizeof(pfn)) == sizeof(pfn)) {
        if (pfn & (1ULL << 63)) {
          sq_phys = ((pfn & ((1ULL << 55) - 1)) * sysconf(_SC_PAGESIZE)) +
                    page_offset;
        } else {
          fprintf(
            stderr,
            "Warning: SQ page not present in pagemap, using virtual address\n");
          sq_phys = reinterpret_cast<uint64_t>(sq_virt);
        }
      } else {
        fprintf(
          stderr,
          "Warning: Failed to read pagemap for SQ, using virtual address\n");
        sq_phys = reinterpret_cast<uint64_t>(sq_virt);
      }
      close(pagemap_fd);
    }
  }

  if (cpuWriteToDevice) {
    // Device memory (HSA) - export as DMA-BUF and get physical address
    // Similar to VRAM buffer export - need page alignment
    const size_t host_page_size = sysconf(_SC_PAGESIZE);
    void* aligned_cq_ptr = (void*)((uintptr_t)cq_virt & ~(host_page_size - 1));
    uint64_t cq_dmabuf_offset = (uintptr_t)cq_virt - (uintptr_t)aligned_cq_ptr;
    size_t aligned_cq_size = (cq_size_bytes + cq_dmabuf_offset +
                              host_page_size - 1) &
                             ~(host_page_size - 1);

    int cq_dmabuf_fd = -1;
    hsa_status_t cq_dmabuf_status = hsa_amd_portable_export_dmabuf(
      aligned_cq_ptr, aligned_cq_size, &cq_dmabuf_fd, &cq_dmabuf_offset);
    if (cq_dmabuf_status != HSA_STATUS_SUCCESS) {
      fprintf(stderr, "ERROR: Failed to export CQ as DMA-BUF (status=%d): %s\n",
              cq_dmabuf_status,
              (cq_dmabuf_status == HSA_STATUS_ERROR_INVALID_ARGUMENT)
                ? "Invalid argument"
                : "Unknown error");
      fprintf(stderr, "Device memory queues require DMA-BUF export support.\n");
      ret = -ENOTSUP;
      goto cleanup;
    }

    // Get physical address via kernel module
    struct rocm_axiio_register_buffer_req buf_req = {};
    buf_req.dmabuf_fd = cq_dmabuf_fd;
    buf_req.virt_addr = reinterpret_cast<uint64_t>(cq_virt);
    buf_req.size = cq_size_bytes;
    buf_req.nvme_bdf = nvme_bdf;
    buf_req.flags = is_emulated ? ROCM_XIO_FLAG_EMULATED
                                : ROCM_XIO_FLAG_PASSTHROUGH;
    fprintf(stderr, "CQ registration: is_emulated=%d, flags=0x%x\n",
            is_emulated, buf_req.flags);

    ret = ioctl(kmod_fd, ROCM_XIO_REGISTER_BUFFER, &buf_req);
    close(cq_dmabuf_fd); // Close FD after kernel module has it
    if (ret < 0) {
      fprintf(stderr,
              "ERROR: Failed to get CQ physical address via kernel module: "
              "%s\n",
              strerror(errno));
      ret = -errno;
      goto cleanup;
    }
    cq_phys = buf_req.phys_addr + cq_dmabuf_offset;
    fprintf(stderr,
            "CQ device memory: virt=0x%016llx, phys=0x%016llx (via DMA-BUF)\n",
            (unsigned long long)reinterpret_cast<uint64_t>(cq_virt),
            (unsigned long long)cq_phys);
  } else {
    // Host memory (mmap) - use /proc/self/pagemap
    int pagemap_fd = open("/proc/self/pagemap", O_RDONLY);
    if (pagemap_fd < 0) {
      fprintf(stderr, "Warning: Failed to open /proc/self/pagemap: %s\n",
              strerror(errno));
      fprintf(stderr, "Using virtual address as physical address for CQ\n");
      cq_phys = reinterpret_cast<uint64_t>(cq_virt);
    } else {
      uint64_t page_offset = reinterpret_cast<uint64_t>(cq_virt) %
                             sysconf(_SC_PAGESIZE);
      uint64_t pfn;
      off_t offset = (reinterpret_cast<uint64_t>(cq_virt) /
                      sysconf(_SC_PAGESIZE)) *
                     sizeof(uint64_t);

      if (lseek(pagemap_fd, offset, SEEK_SET) >= 0 &&
          read(pagemap_fd, &pfn, sizeof(pfn)) == sizeof(pfn)) {
        if (pfn & (1ULL << 63)) {
          cq_phys = ((pfn & ((1ULL << 55) - 1)) * sysconf(_SC_PAGESIZE)) +
                    page_offset;
        } else {
          fprintf(
            stderr,
            "Warning: CQ page not present in pagemap, using virtual address\n");
          cq_phys = reinterpret_cast<uint64_t>(cq_virt);
        }
      } else {
        fprintf(
          stderr,
          "Warning: Failed to read pagemap for CQ, using virtual address\n");
        cq_phys = reinterpret_cast<uint64_t>(cq_virt);
      }
      close(pagemap_fd);
    }
  }

  // Register queue addresses with kernel module for kprobe injection
  // Note: For device memory queues, ROCM_XIO_REGISTER_BUFFER was already
  // called above to map the DMA-BUF. This registration is for kprobe tracking
  // and works for both host and device memory queues.
  struct rocm_axiio_register_queue_addr_req reg_req;

  // Register SQ
  memset(&reg_req, 0, sizeof(reg_req));
  reg_req.virt_addr = reinterpret_cast<uint64_t>(sq_virt);
  reg_req.phys_addr = sq_phys;
  reg_req.size = sq_size_bytes;
  reg_req.queue_type = 0; // SQ

  ret = ioctl(kmod_fd, ROCM_XIO_REGISTER_QUEUE_ADDR, &reg_req);
  if (ret < 0) {
    fprintf(stderr, "Failed to register SQ address: %s\n", strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Register CQ
  memset(&reg_req, 0, sizeof(reg_req));
  reg_req.virt_addr = reinterpret_cast<uint64_t>(cq_virt);
  reg_req.phys_addr = cq_phys;
  reg_req.size = cq_size_bytes;
  reg_req.queue_type = 1; // CQ

  ret = ioctl(kmod_fd, ROCM_XIO_REGISTER_QUEUE_ADDR, &reg_req);
  if (ret < 0) {
    fprintf(stderr, "Failed to register CQ address: %s\n", strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Delete existing queues if they exist (ignore errors - queue may not exist)
  // Delete SQ first, then CQ (NVMe spec requirement: CQ cannot be deleted
  // while associated SQ exists)

  // Delete Submission Queue (DELETE_SQ)
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_delete_sq;
  cmd.nsid = 0;         // Admin commands use NSID 0
  cmd.cdw10 = queue_id; // QID
  cmd.data_len = 0;     // No data transfer for DELETE_SQ

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    // Ignore errors - queue may not exist
    fprintf(stderr, "Note: DELETE_SQ failed (queue may not exist): %s\n",
            strerror(errno));
  } else if (cmd.result & 0xFFFE) {
    // Check status code, but don't fail - queue may not exist
    uint16_t status_field = cmd.result & 0xFFFF;
    uint8_t sc = NVME_CQE_STATUS_SC(status_field);
    // Ignore errors - queue may not exist or may have already been deleted
    fprintf(
      stderr,
      "Note: DELETE_SQ returned status code 0x%02x (queue may not exist)\n",
      sc);
  }

  // Delete Completion Queue (DELETE_CQ)
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_delete_cq;
  cmd.nsid = 0;         // Admin commands use NSID 0
  cmd.cdw10 = queue_id; // QID
  cmd.data_len = 0;     // No data transfer for DELETE_CQ

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    // Ignore errors - queue may not exist
    fprintf(stderr, "Note: DELETE_CQ failed (queue may not exist): %s\n",
            strerror(errno));
  } else if (cmd.result & 0xFFFE) {
    // Check status code, but don't fail - queue may not exist
    uint16_t status_field = cmd.result & 0xFFFF;
    uint8_t sc = NVME_CQE_STATUS_SC(status_field);
    // Ignore errors - queue may not exist or may have already been deleted
    fprintf(
      stderr,
      "Note: DELETE_CQ returned status code 0x%02x (queue may not exist)\n",
      sc);
  }

  // Create Completion Queue first (CREATE_CQ)
  memset(&cmd, 0, sizeof(cmd));

  cmd.opcode = nvme_admin_create_cq;
  cmd.nsid = 0;                                  // Admin commands use NSID 0
  cmd.cdw10 = (queue_size - 1) << 16 | queue_id; // QSIZE | QID
  cmd.cdw11 = 0x00000001; // PC=1 (physically contiguous), IEN=0, IV=0
  // PRP1 will be injected by kprobe - pass virtual address as ubuffer
  // Note: nvme_passthru_cmd uses __u64 for addr, which is uint64_t in userspace
  cmd.addr = reinterpret_cast<uint64_t>(cq_virt);
  cmd.data_len = 0; // No data transfer for CREATE_CQ

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    if (errno == EACCES || errno == EPERM) {
      fprintf(stderr, "ERROR: Failed to create completion queue: %s\n",
              strerror(errno));
      fprintf(stderr, "Note: CREATE_CQ IOCTL requires root permissions.\n");
      fprintf(
        stderr,
        "Please ensure you have CAP_SYS_ADMIN capability or run with sudo.\n");
    } else {
      fprintf(stderr, "ERROR: Failed to create completion queue: %s\n",
              strerror(errno));
    }
    fprintf(stderr, "ERROR: Cannot proceed - queue creation failed.\n");
    ret = -errno;
    goto cleanup;
  }

  // Check completion status
  // result field contains NVMe status code in lower 16 bits:
  //   Bits 15:1 = Status Code (SC)
  //   Bit 0 = Phase Tag (P)
  // Check if status code is non-zero (any error)
  if (cmd.result & 0xFFFE) {
    uint16_t status_field = cmd.result & 0xFFFF;
    uint8_t sc = NVME_CQE_STATUS_SC(status_field);
    uint8_t sct = NVME_CQE_STATUS_SCT(status_field);
    fprintf(stderr,
            "ERROR: CREATE_CQ failed with status code 0x%02x (SCT=%u)\n", sc,
            sct);
    if (sc == NVME_SC_INVALID_FIELD) {
      fprintf(
        stderr,
        "  Error: Invalid field in command (queue_id=%u, queue_size=%u)\n",
        queue_id, queue_size);
    } else if (sc == NVME_SC_CAP_EXCEEDED) {
      fprintf(
        stderr,
        "  Error: Queue size exceeds controller capabilities (queue_size=%u)\n",
        queue_size);
    }
    fprintf(stderr, "ERROR: Cannot proceed - queue creation failed.\n");
    ret = -EIO;
    goto cleanup;
  }

  fprintf(stderr,
          "Successfully created completion queue (queue_id=%u, size=%u)\n",
          queue_id, queue_size);

  // Create Submission Queue (CREATE_SQ)
  memset(&cmd, 0, sizeof(cmd));

  cmd.opcode = nvme_admin_create_sq;
  cmd.nsid = 0;                                  // Admin commands use NSID 0
  cmd.cdw10 = (queue_size - 1) << 16 | queue_id; // QSIZE | QID
  cmd.cdw11 = (queue_id << 16) | 0x0001;         // CQID | QPRIO=0, PC=1
  // PRP1 will be injected by kprobe - pass virtual address as ubuffer
  cmd.addr = reinterpret_cast<uint64_t>(sq_virt);
  cmd.data_len = 0; // No data transfer for CREATE_SQ

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    fprintf(stderr, "ERROR: Failed to create submission queue: %s\n",
            strerror(errno));
    fprintf(stderr, "ERROR: Cannot proceed - queue creation failed.\n");
    ret = -errno;
    goto cleanup;
  }

  // Check completion status
  // result field contains NVMe status code in lower 16 bits:
  //   Bits 15:1 = Status Code (SC)
  //   Bit 0 = Phase Tag (P)
  // Check if status code is non-zero (any error)
  if (cmd.result & 0xFFFE) {
    uint16_t status_field = cmd.result & 0xFFFF;
    uint8_t sc = NVME_CQE_STATUS_SC(status_field);
    uint8_t sct = NVME_CQE_STATUS_SCT(status_field);
    fprintf(stderr,
            "ERROR: CREATE_SQ failed with status code 0x%02x (SCT=%u)\n", sc,
            sct);
    if (sc == NVME_SC_INVALID_FIELD) {
      fprintf(stderr,
              "  Error: Invalid field in command (queue_id=%u, queue_size=%u, "
              "CQID=%u)\n",
              queue_id, queue_size, queue_id);
    } else if (sc == NVME_SC_CAP_EXCEEDED) {
      fprintf(
        stderr,
        "  Error: Queue size exceeds controller capabilities (queue_size=%u)\n",
        queue_size);
    }
    fprintf(stderr, "ERROR: Cannot proceed - queue creation failed.\n");
    ret = -EIO;
    goto cleanup;
  }

  fprintf(stderr,
          "Successfully created submission queue (queue_id=%u, size=%u)\n",
          queue_id, queue_size);

  // Calculate doorbell address
  // Doorbell base is typically at BAR0 + 0x1000
  // SQ doorbell: DB_BASE + (2 * qid * doorbell_stride)
  // For now, we'll set a placeholder - caller should get this from device info
  info->doorbell = 0; // TODO: Get from device info

  // Fill output structure
  info->sq_virt = sq_virt;
  info->cq_virt = cq_virt;
  info->sq_gpu = sq_gpu; // GPU-accessible pointer for kernel launch
  info->cq_gpu = cq_gpu; // GPU-accessible pointer for kernel launch
  info->sq_phys = sq_phys;
  info->cq_phys = cq_phys;
  info->sq_dmabuf_fd = sq_dmabuf_fd;
  info->cq_dmabuf_fd = cq_dmabuf_fd;

  close(nvme_fd);
  close(kmod_fd);
  return 0;

cleanup:
  // Close DRM fd if opened
  if (drm_fd >= 0) {
    close(drm_fd);
  }

  // Unregister from HIP if we registered (non-coherent, non-device
  // allocations)
  if (sq_virt && !sq_uses_coherent && !sq_is_device &&
      sq_hip_err == hipSuccess) {
    (void)hipHostUnregister(sq_virt); // Ignore return value in cleanup
  }
  if (cq_virt && !cq_uses_coherent && !cq_is_device &&
      cq_hip_err == hipSuccess) {
    (void)hipHostUnregister(cq_virt); // Ignore return value in cleanup
  }

  // Free queues - handle coherent allocation separately
  if (sq_virt) {
    if (sq_uses_coherent) {
      // Free HIP coherent memory
      (void)hipHostFree(sq_virt);
    } else {
      // Free using standard free function
      xioFreeSubmissionQueue(sq_virt, memory_mode);
    }
  }
  if (cq_virt) {
    if (cq_uses_coherent) {
      // Free HIP coherent memory
      (void)hipHostFree(cq_virt);
    } else {
      // Free using standard free function
      xioFreeCompletionQueue(cq_virt, memory_mode);
    }
  }
  if (nvme_fd >= 0) {
    close(nvme_fd);
  }
  if (kmod_fd >= 0) {
    close(kmod_fd);
  }
  return ret;
}

#endif // __HIP_DEVICE_COMPILE__
