/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * @file vfu-dma-uapi.h
 * @brief Shared userspace/kernel ioctl definitions for the /dev/vfu-dma
 *        character device.
 *
 * Included from the vfu-ring guest tool and from the out-of-tree kernel
 * module so struct layouts and command numbers stay in lockstep.
 */

#ifndef VFU_DMA_UAPI_H
#define VFU_DMA_UAPI_H

#include <linux/ioctl.h>
#include <linux/types.h>

/** @brief ioctl magic value of the vfu-dma character device. */
#define VFU_DMA_IOC_MAGIC 'x'

/** @brief Bump when a struct or command changes incompatibly. */
#define VFU_DMA_VERSION 1

/**
 * @brief PCI BDF encoding, the same as the rocm-xio UAPI.
 *
 *   bits 31:16  PCI domain
 *   bits 15:8   bus number
 *   bits  7:3   device
 *   bits  2:0   function
 */
#define VFU_DMA_BDF(domain, bus, dev, func)                                    \
  ((((__u32)(domain) & 0xffffu) << 16) | (((__u32)(bus) & 0xffu) << 8) |       \
   (((__u32)(dev) & 0x1fu) << 3) | ((__u32)(func) & 0x7u))

/** @brief struct vfu_dma_info flags. */
#define VFU_DMA_INFO_IOMMU (1u << 0) /* the ringer sits behind an IOMMU */
#define VFU_DMA_INFO_IDENTITY                                                  \
  (1u << 1) /* in an identity (pass-through) domain */

/**
 * @brief VFU_DMA_IOC_GET_INFO: what the driver knows about the DMA device.
 *
 * The device is the ringer the driver is bound to. With no IOMMU, or an
 * identity domain, a bus address equals the physical address.
 */
struct vfu_dma_info {
  __u32 version; /* out: VFU_DMA_VERSION */
  __u32 flags;   /* out: VFU_DMA_INFO_* */
};

/**
 * @brief VFU_DMA_IOC_ALLOC_PAGE: a buffer the device can reach.
 *
 * The kernel allocates coherent memory for the DMA device and returns the bus
 * address a device must use for it (not necessarily its physical address). The
 * caller maps it with mmap(fd, size, ..., mmap_offset).
 */
struct vfu_dma_alloc {
  __u64 size;        /* in: bytes, a multiple of the page size */
  __u64 dma_addr;    /* out: bus address of the start of the buffer */
  __u64 mmap_offset; /* out: offset to pass to mmap() */
  __u32 handle;      /* out: for VFU_DMA_IOC_UNMAP */
  __u32 reserved;
};

/**
 * @brief VFU_DMA_IOC_MAP_PEER: make another device's BAR reachable.
 *
 * Maps the memory BAR of a PCI device into the DMA device's address space with
 * dma_map_resource() and returns the bus address of the start of the BAR. A
 * peer BAR is not reachable by DMA under a translating IOMMU unless it is
 * mapped like this.
 */
struct vfu_dma_peer {
  __u32 bdf;      /* in: VFU_DMA_BDF() of the peer */
  __u32 bar;      /* in: BAR number, 0 to 5 */
  __u64 dma_addr; /* out: bus address of the start of the BAR */
  __u64 size;     /* out: length of the BAR */
  __u32 handle;   /* out: for VFU_DMA_IOC_UNMAP */
  __u32 reserved;
};

struct vfu_dma_unmap {
  __u32 handle; /* in: from ALLOC_PAGE or MAP_PEER */
  __u32 reserved;
};

#define VFU_DMA_IOC_GET_INFO _IOR(VFU_DMA_IOC_MAGIC, 0, struct vfu_dma_info)
#define VFU_DMA_IOC_ALLOC_PAGE _IOWR(VFU_DMA_IOC_MAGIC, 1, struct vfu_dma_alloc)
#define VFU_DMA_IOC_MAP_PEER _IOWR(VFU_DMA_IOC_MAGIC, 2, struct vfu_dma_peer)
#define VFU_DMA_IOC_UNMAP _IOW(VFU_DMA_IOC_MAGIC, 3, struct vfu_dma_unmap)

#endif /* VFU_DMA_UAPI_H */
