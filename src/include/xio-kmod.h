/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef XIO_KMOD_H
#define XIO_KMOD_H

#include <cstdint>

#include <linux/ioctl.h>

#include "xio.h" // For ROCM_XIO_DEVICE_PATH

// Host-only code - kernel module interface is only used on host
#ifndef __HIP_DEVICE_COMPILE__

// IOCTL magic number (matching kernel/rocm-xio/rocm-xio.h)
#define ROCM_XIO_IOC_MAGIC 'R'

// Flags for VRAM physical address request (matching
// kernel/rocm-xio/rocm-xio.h)
#define ROCM_XIO_FLAG_EMULATED (1 << 0)    // Return BAR GPA for emulated NVMe
#define ROCM_XIO_FLAG_PASSTHROUGH (1 << 1) // Return P2PDMA IOVA for passthrough

// Userspace-compatible structures (matching kernel/rocm-xio/rocm-xio.h)
// Note: Kernel header uses __u64, __u16, etc. We use standard types for
// userspace compatibility

struct rocm_xio_vram_req {
  int dmabuf_fd;
  uint16_t nvme_bdf;
  uint32_t flags;
  uint64_t phys_addr;
  uint64_t size;
};

struct rocm_xio_register_queue_addr_req {
  uint64_t virt_addr;
  uint64_t phys_addr;
  uint64_t size;
  uint8_t queue_type;
};

struct rocm_xio_unregister_queue_addr_req {
  uint64_t virt_addr; // Virtual address to unregister
};

struct rocm_xio_unregister_buffer_req {
  uint64_t virt_addr; // Virtual address to unregister
};

struct rocm_xio_register_buffer_req {
  int dmabuf_fd;      // Input: dmabuf file descriptor (-1 if not available)
  uint64_t virt_addr; // Input: Virtual address (userspace pointer)
  uint64_t phys_addr; // Output: Physical address (filled by kernel)
  uint64_t size;      // Input: Buffer size
  uint16_t nvme_bdf;  // Input: NVMe device BDF (0xBBDD format)
  uint32_t flags;     // Input: flags (see ROCM_XIO_FLAG_*)
};

struct rocm_xio_alloc_contig_mem_req {
  uint64_t size;      // Input: Size in bytes
  uint64_t virt_addr; // Output: Kernel virtual address (handle for mmap)
  uint64_t phys_addr; // Output: Physical address
};

struct rocm_xio_free_contig_mem_req {
  uint64_t virt_addr; // Input: Kernel virtual address to free
};

// IOCTL command definitions
#define ROCM_XIO_GET_VRAM_PHYS_ADDR                                            \
  _IOWR(ROCM_XIO_IOC_MAGIC, 1, struct rocm_xio_vram_req)
#define ROCM_XIO_REGISTER_QUEUE_ADDR                                           \
  _IOW(ROCM_XIO_IOC_MAGIC, 6, struct rocm_xio_register_queue_addr_req)
#define ROCM_XIO_UNREGISTER_QUEUE_ADDR                                         \
  _IOW(ROCM_XIO_IOC_MAGIC, 7, struct rocm_xio_unregister_queue_addr_req)
#define ROCM_XIO_REGISTER_BUFFER                                               \
  _IOW(ROCM_XIO_IOC_MAGIC, 8, struct rocm_xio_register_buffer_req)
#define ROCM_XIO_UNREGISTER_BUFFER                                             \
  _IOW(ROCM_XIO_IOC_MAGIC, 9, struct rocm_xio_unregister_buffer_req)
#define ROCM_XIO_ALLOC_CONTIG_MEM                                              \
  _IOWR(ROCM_XIO_IOC_MAGIC, 11, struct rocm_xio_alloc_contig_mem_req)
#define ROCM_XIO_FREE_CONTIG_MEM                                               \
  _IOW(ROCM_XIO_IOC_MAGIC, 12, struct rocm_xio_free_contig_mem_req)

// Backward compatibility: old naming convention used in nvme-ep
// TODO: Migrate nvme-ep to use rocm_xio_* naming
typedef struct rocm_xio_vram_req rocm_axiio_vram_req;
typedef struct rocm_xio_register_queue_addr_req
  rocm_axiio_register_queue_addr_req;
typedef struct rocm_xio_unregister_queue_addr_req
  rocm_axiio_unregister_queue_addr_req;
typedef struct rocm_xio_unregister_buffer_req
  rocm_axiio_unregister_buffer_req;
typedef struct rocm_xio_register_buffer_req rocm_axiio_register_buffer_req;
typedef struct rocm_xio_alloc_contig_mem_req rocm_axiio_alloc_contig_mem_req;
typedef struct rocm_xio_free_contig_mem_req rocm_axiio_free_contig_mem_req;

#endif // __HIP_DEVICE_COMPILE__

#endif // XIO_KMOD_H
