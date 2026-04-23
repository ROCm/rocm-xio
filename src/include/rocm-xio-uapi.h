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

#define ROCM_XIO_IOC_MAGIC 'R'

#define ROCM_XIO_GET_VRAM_PHYS_ADDR                                            \
  _IOWR(ROCM_XIO_IOC_MAGIC, 1, struct rocm_xio_vram_req)
#define ROCM_XIO_CREATE_QUEUE                                                  \
  _IOWR(ROCM_XIO_IOC_MAGIC, 2, struct rocm_xio_create_queue_req)
#define ROCM_XIO_DELETE_QUEUE                                                  \
  _IOW(ROCM_XIO_IOC_MAGIC, 3, struct rocm_xio_delete_queue_req)
#define ROCM_XIO_GET_DEVICE_INFO                                               \
  _IOWR(ROCM_XIO_IOC_MAGIC, 4, struct rocm_xio_device_info)
#define ROCM_XIO_BIND_DEVICE                                                   \
  _IOW(ROCM_XIO_IOC_MAGIC, 5, struct rocm_xio_bind_device_req)
#define ROCM_XIO_REGISTER_QUEUE_ADDR                                           \
  _IOW(ROCM_XIO_IOC_MAGIC, 6, struct rocm_xio_register_queue_addr_req)
#define ROCM_XIO_UNREGISTER_QUEUE_ADDR                                         \
  _IOW(ROCM_XIO_IOC_MAGIC, 7, struct rocm_xio_unregister_queue_addr_req)
#define ROCM_XIO_REGISTER_BUFFER                                               \
  _IOW(ROCM_XIO_IOC_MAGIC, 8, struct rocm_xio_register_buffer_req)
#define ROCM_XIO_UNREGISTER_BUFFER                                             \
  _IOW(ROCM_XIO_IOC_MAGIC, 9, struct rocm_xio_unregister_buffer_req)
#define ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER                                 \
  _IOWR(ROCM_XIO_IOC_MAGIC, 10, struct rocm_xio_mmio_bridge_shadow_req)
#define ROCM_XIO_ALLOC_CONTIG_QUEUE                                            \
  _IOWR(ROCM_XIO_IOC_MAGIC, 11, struct rocm_xio_alloc_contig_req)
#define ROCM_XIO_FREE_CONTIG_QUEUE                                             \
  _IOW(ROCM_XIO_IOC_MAGIC, 12, struct rocm_xio_free_contig_req)

#define ROCM_XIO_FLAG_EMULATED                                                 \
  (1 << 0) /* Return BAR GPA for emulated NVMe */
#define ROCM_XIO_FLAG_PASSTHROUGH                                              \
  (1 << 1) /* Return P2PDMA IOVA for passthrough */

/** @brief VRAM physical address resolution request (GET_VRAM_PHYS_ADDR). */
struct rocm_xio_vram_req {
  int dmabuf_fd;
  __u16 nvme_bdf;
  __u32 flags;
  __u64 phys_addr;
  __u64 size;
};

struct rocm_xio_create_queue_req {
  __u16 queue_id;
  __u16 queue_size;
  __u32 cq_vector;
  __u64 sq_phys_addr;
  __u64 cq_phys_addr;
  __u64 doorbell_addr;
  __u32 doorbell_offset;
};

struct rocm_xio_delete_queue_req {
  __u16 queue_id;
  __u8 queue_type;
};

struct rocm_xio_device_info {
  __u16 bdf;
  __u64 bar0_addr;
  __u64 bar0_size;
  __u32 doorbell_stride;
  __u32 max_queues;
};

struct rocm_xio_bind_device_req {
  __u16 bdf;
};

/** @brief Register queue virtual/physical mapping (REGISTER_QUEUE_ADDR). */
struct rocm_xio_register_queue_addr_req {
  __u64 virt_addr;
  __u64 phys_addr;
  __u64 size;
  __u64 prp2;
  __u16 nvme_bdf;
  __u8 queue_type;
  __u8 reserved[5];
};

struct rocm_xio_unregister_queue_addr_req {
  __u64 virt_addr;
};

/** @brief Register data buffer for PRP injection (REGISTER_BUFFER). */
struct rocm_xio_register_buffer_req {
  int dmabuf_fd;
  __u64 virt_addr;
  __u64 phys_addr;
  __u64 size;
  __u16 nvme_bdf;
  __u32 flags;
};

struct rocm_xio_unregister_buffer_req {
  __u64 virt_addr;
};

/** @brief MMIO bridge shadow buffer mapping (GET_MMIO_BRIDGE_SHADOW_BUFFER). */
struct rocm_xio_mmio_bridge_shadow_req {
  __u16 bridge_bdf;
  __u64 shadow_gpa;
  __u64 shadow_size;
};

/** @brief Contiguous queue allocation (ALLOC_CONTIG_QUEUE). */
struct rocm_xio_alloc_contig_req {
  __u64 size;
  __u16 nvme_bdf;
  __u64 phys_addr;
  __u32 mmap_offset;
};

/** @brief Free contiguous queue allocation (FREE_CONTIG_QUEUE). */
struct rocm_xio_free_contig_req {
  __u32 mmap_offset;
};

#ifdef __cplusplus
}
#endif

#endif /* ROCM_XIO_UAPI_H */
