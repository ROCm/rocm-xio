/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef ROCM_XIO_KMOD_H
#define ROCM_XIO_KMOD_H

#include <cstdint>

#include <linux/ioctl.h>

// Kernel module IOCTL magic number
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

struct rocm_axiio_register_buffer_req {
  int dmabuf_fd;      // Input: dmabuf file descriptor (-1 if not available)
  uint64_t virt_addr; // Input: Virtual address (userspace pointer)
  uint64_t phys_addr; // Output: Physical address (filled by kernel)
  uint64_t size;      // Input: Buffer size
  uint16_t nvme_bdf;  // Input: NVMe device BDF (0xBBDD format)
  uint32_t flags;     // Input: flags (see ROCM_XIO_FLAG_*)
};

struct rocm_axiio_mmio_bridge_shadow_req {
  uint16_t bridge_bdf;  // Input: PCI MMIO bridge BDF (0xBBDD format)
  uint64_t shadow_gpa;  // Output: Shadow buffer Guest Physical Address
  uint64_t shadow_size; // Output: Shadow buffer size in bytes
};

// IOCTL command definitions
#define ROCM_XIO_GET_VRAM_PHYS_ADDR                                            \
  _IOWR(ROCM_XIO_IOC_MAGIC, 1, struct rocm_axiio_vram_req)
#define ROCM_XIO_REGISTER_QUEUE_ADDR                                           \
  _IOW(ROCM_XIO_IOC_MAGIC, 6, struct rocm_axiio_register_queue_addr_req)
#define ROCM_XIO_REGISTER_BUFFER                                               \
  _IOW(ROCM_XIO_IOC_MAGIC, 8, struct rocm_axiio_register_buffer_req)
#define ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER                                 \
  _IOWR(ROCM_XIO_IOC_MAGIC, 10, struct rocm_axiio_mmio_bridge_shadow_req)

#endif // ROCM_XIO_KMOD_H
