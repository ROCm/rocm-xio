/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * @file rocm-xio-uapi.h
 * @brief Shared userspace/kernel ioctl definitions for the
 *        /dev/rocm-xio character device.
 *
 * Included from HIP/C++ userspace and from the out-of-tree
 * kernel module so struct layouts and command numbers stay in
 * lockstep.
 */

#ifndef ROCM_XIO_UAPI_H
#define ROCM_XIO_UAPI_H

#ifdef __cplusplus
extern "C" {
#endif

#include <linux/ioctl.h>
#include <linux/types.h>

/** @brief ioctl magic value reserved for the rocm-xio character device. */
#define ROCM_XIO_IOC_MAGIC 'R'

/** @brief Resolve a VRAM DMA-BUF to a device-usable physical or DMA address. */
#define ROCM_XIO_GET_VRAM_PHYS_ADDR                                            \
  _IOWR(ROCM_XIO_IOC_MAGIC, 1, struct rocm_xio_vram_req)
/** @brief Create an NVMe queue using caller-supplied queue memory. */
#define ROCM_XIO_CREATE_QUEUE                                                  \
  _IOWR(ROCM_XIO_IOC_MAGIC, 2, struct rocm_xio_create_queue_req)
/** @brief Delete an NVMe queue previously created by the kernel helper. */
#define ROCM_XIO_DELETE_QUEUE                                                  \
  _IOW(ROCM_XIO_IOC_MAGIC, 3, struct rocm_xio_delete_queue_req)
/** @brief Query bound-device BAR and queue capability information. */
#define ROCM_XIO_GET_DEVICE_INFO                                               \
  _IOWR(ROCM_XIO_IOC_MAGIC, 4, struct rocm_xio_device_info)
/** @brief Bind the character-device session to an NVMe PCI function. */
#define ROCM_XIO_BIND_DEVICE                                                   \
  _IOW(ROCM_XIO_IOC_MAGIC, 5, struct rocm_xio_bind_device_req)
/** @brief Register a queue virtual-to-physical mapping for kprobe injection. */
#define ROCM_XIO_REGISTER_QUEUE_ADDR                                           \
  _IOW(ROCM_XIO_IOC_MAGIC, 6, struct rocm_xio_register_queue_addr_req)
/** @brief Remove a queue mapping from the kernel helper. */
#define ROCM_XIO_UNREGISTER_QUEUE_ADDR                                         \
  _IOW(ROCM_XIO_IOC_MAGIC, 7, struct rocm_xio_unregister_queue_addr_req)
/** @brief Register a data buffer used by NVMe PRP injection. */
#define ROCM_XIO_REGISTER_BUFFER                                               \
  _IOW(ROCM_XIO_IOC_MAGIC, 8, struct rocm_xio_register_buffer_req)
/** @brief Remove a registered data-buffer mapping. */
#define ROCM_XIO_UNREGISTER_BUFFER                                             \
  _IOW(ROCM_XIO_IOC_MAGIC, 9, struct rocm_xio_unregister_buffer_req)
/** @brief Map the PCI MMIO bridge shadow buffer into userspace. */
#define ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER                                 \
  _IOWR(ROCM_XIO_IOC_MAGIC, 10, struct rocm_xio_mmio_bridge_shadow_req)
/** @brief Allocate physically contiguous coherent queue memory. */
#define ROCM_XIO_ALLOC_CONTIG_QUEUE                                            \
  _IOWR(ROCM_XIO_IOC_MAGIC, 11, struct rocm_xio_alloc_contig_req)
/** @brief Free contiguous queue memory allocated by the kernel helper. */
#define ROCM_XIO_FREE_CONTIG_QUEUE                                             \
  _IOW(ROCM_XIO_IOC_MAGIC, 12, struct rocm_xio_free_contig_req)
/** @brief Per-NVMe-page DMA addresses for a registered VRAM buffer (SG). */
#define ROCM_XIO_GET_BUFFER_DMA_PAGES                                          \
  _IOWR(ROCM_XIO_IOC_MAGIC, 13, struct rocm_xio_buffer_dma_pages_req)

/** @brief Return the emulated BAR guest-physical address. */
#define ROCM_XIO_FLAG_EMULATED (1 << 0)
/** @brief Return a P2PDMA IOVA for passthrough hardware. */
#define ROCM_XIO_FLAG_PASSTHROUGH (1 << 1)

/** @brief VRAM physical address resolution request (GET_VRAM_PHYS_ADDR). */
struct rocm_xio_vram_req {
  int dmabuf_fd;   /**< DMA-BUF fd exported from a VRAM allocation. */
  __u16 nvme_bdf;  /**< Target NVMe device in 0xBBDD form. */
  __u32 flags;     /**< ROCM_XIO_FLAG_* address selection flags. */
  __u64 phys_addr; /**< Output physical address, IOVA, or emulated GPA. */
  __u64 size;      /**< Output mapped buffer size in bytes. */
};

/** @brief NVMe queue creation request (CREATE_QUEUE). */
struct rocm_xio_create_queue_req {
  __u16 queue_id;        /**< NVMe queue identifier to create. */
  __u16 queue_size;      /**< Queue depth in entries. */
  __u32 cq_vector;       /**< Interrupt vector for completion queues. */
  __u64 sq_phys_addr;    /**< Submission queue base physical address. */
  __u64 cq_phys_addr;    /**< Completion queue base physical address. */
  __u64 doorbell_addr;   /**< Output doorbell register physical address. */
  __u32 doorbell_offset; /**< Output doorbell offset within BAR0. */
};

/** @brief NVMe queue deletion request (DELETE_QUEUE). */
struct rocm_xio_delete_queue_req {
  __u16 queue_id;  /**< NVMe queue identifier to delete. */
  __u8 queue_type; /**< Queue type: 0 for SQ, 1 for CQ. */
};

/** @brief Bound NVMe device information returned by GET_DEVICE_INFO. */
struct rocm_xio_device_info {
  __u16 bdf;             /**< Bound NVMe device in 0xBBDD form. */
  __u64 bar0_addr;       /**< BAR0 physical base address. */
  __u64 bar0_size;       /**< BAR0 mapping size in bytes. */
  __u32 doorbell_stride; /**< NVMe doorbell stride in bytes. */
  __u32 max_queues;      /**< Maximum queue count reported by device. */
};

/** @brief Bind request selecting the NVMe PCI function for later ioctls. */
struct rocm_xio_bind_device_req {
  __u16 bdf; /**< NVMe device in 0xBBDD form. */
};

/** @brief Register queue virtual/physical mapping (REGISTER_QUEUE_ADDR). */
struct rocm_xio_register_queue_addr_req {
  __u64 virt_addr;  /**< Userspace virtual queue base address. */
  __u64 phys_addr;  /**< Physical or DMA queue base address. */
  __u64 size;       /**< Queue allocation size in bytes. */
  __u64 prp2;       /**< PRP2 value for multi-page queue commands. */
  __u16 nvme_bdf;   /**< Target NVMe device in 0xBBDD form. */
  __u8 queue_type;  /**< Queue type: 0 for SQ, 1 for CQ. */
  __u8 reserved[5]; /**< Reserved for ABI alignment; must be zero. */
};

/** @brief Unregister a queue mapping by userspace virtual address. */
struct rocm_xio_unregister_queue_addr_req {
  __u64 virt_addr; /**< Userspace virtual queue base address. */
};

/** @brief Register data buffer for PRP injection (REGISTER_BUFFER). */
struct rocm_xio_register_buffer_req {
  int dmabuf_fd; /**< DMA-BUF fd for VRAM, or -1 for host memory. */
  __u64 virt_addr; /**< Userspace virtual buffer base address. */
  __u64 phys_addr; /**< Physical address, IOVA, or emulated GPA. */
  __u64 size; /**< Buffer size in bytes. */
  /**
   * Byte offset from the start of the DMA-BUF object to virt_addr (export
   * often rounds the GPU pointer down to a page boundary). Use 0 when the
   * buffer base matches the DMA-BUF base.
   */
  __u64 dmabuf_linear_off;
  __u16 nvme_bdf; /**< Target NVMe device in 0xBBDD form. */
  __u32 flags; /**< ROCM_XIO_FLAG_* address selection flags. */
};

/** @brief Unregister a data buffer by userspace virtual address. */
struct rocm_xio_unregister_buffer_req {
  __u64 virt_addr; /**< Userspace virtual buffer base address. */
};

/** @brief Per-page DMA/IOVA list for a REGISTER_BUFFER VRAM mapping (ioctl 13). */
struct rocm_xio_buffer_dma_pages_req {
  __u64 virt_addr; /**< GPU virtual base passed to REGISTER_BUFFER. */
  __u64 user_addrs_ptr; /**< Userspace output array of \a max_pages \c __u64. */
  __u32 max_pages; /**< Capacity of \a user_addrs_ptr (must cover buffer). */
  __u32 num_pages_out; /**< Kernel: NVMe 4K pages copied (equals expected). */
};

/** @brief MMIO bridge shadow buffer mapping (GET_MMIO_BRIDGE_SHADOW_BUFFER). */
struct rocm_xio_mmio_bridge_shadow_req {
  __u16 bridge_bdf;  /**< PCI MMIO bridge device in 0xBBDD form. */
  __u64 shadow_gpa;  /**< Output guest-physical shadow buffer address. */
  __u64 shadow_size; /**< Output shadow buffer size in bytes. */
};

/** @brief Contiguous queue allocation (ALLOC_CONTIG_QUEUE). */
struct rocm_xio_alloc_contig_req {
  __u64 size;        /**< Requested queue allocation size in bytes. */
  __u16 nvme_bdf;    /**< Target NVMe device in 0xBBDD form. */
  __u64 phys_addr;   /**< Output physical address of allocation. */
  __u32 mmap_offset; /**< Output mmap offset used as allocation handle. */
};

/** @brief Free contiguous queue allocation (FREE_CONTIG_QUEUE). */
struct rocm_xio_free_contig_req {
  __u32 mmap_offset; /**< mmap offset returned by allocation ioctl. */
};

#ifdef __cplusplus
}
#endif

#endif /* ROCM_XIO_UAPI_H */
