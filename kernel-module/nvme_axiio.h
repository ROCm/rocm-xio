/* SPDX-License-Identifier: GPL-2.0 */
/*
 * NVMe AXIIO Kernel Module Header
 *
 * Provides userspace access to NVMe queues and doorbells for direct GPU I/O
 */

#ifndef _NVME_AXIIO_H
#define _NVME_AXIIO_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define NVME_AXIIO_MAGIC 0xAE

/*
 * Structure to request queue creation and get doorbell/queue info
 */
struct nvme_axiio_queue_info {
  __u16 queue_id;   /* IN/OUT: Requested/Assigned queue ID */
  __u16 queue_size; /* IN: Queue size (entries) */
  __u32 nsid;       /* IN: Namespace ID */

  /* IN: User-provided addresses (optional, set to 0 for kernel alloc) */
  __u64 sq_dma_addr_user; /* User-provided SQ physical address */
  __u64 cq_dma_addr_user; /* User-provided CQ physical address */

  /* OUT: Physical addresses for userspace mapping */
  __u64 sq_dma_addr;      /* Submission Queue DMA address */
  __u64 cq_dma_addr;      /* Completion Queue DMA address */
  __u64 sq_doorbell_phys; /* SQ Doorbell physical address */
  __u64 cq_doorbell_phys; /* CQ Doorbell physical address */

  /* OUT: BAR0 info for mapping */
  __u64 bar0_phys;       /* BAR0 base physical address */
  __u64 bar0_size;       /* BAR0 size */
  __u32 doorbell_stride; /* Doorbell stride (4-byte units) */

  /* OUT: Offsets within BAR0 */
  __u32 sq_doorbell_offset;
  __u32 cq_doorbell_offset;
};

/*
 * Structure for DMA buffer allocation
 */
struct nvme_axiio_dma_buffer {
  __u64 size;      /* IN: Size in bytes */
  __u64 dma_addr;  /* OUT: DMA address */
  __u64 virt_addr; /* OUT: Kernel virtual address (for mmap) */
};

/*
 * Structure for GPU-accessible doorbell mapping
 */
struct nvme_axiio_doorbell_mapping {
  __u16 queue_id;          /* IN: Queue ID */
  __u64 doorbell_phys;     /* OUT: Physical address of doorbell */
  __u64 doorbell_bus_addr; /* OUT: Bus address for DMA/GPU access */
  __u32 doorbell_offset;   /* OUT: Offset within BAR0 */
  __u64 bar0_phys;         /* OUT: BAR0 physical start */
  __u64 bar0_bus_addr;     /* OUT: BAR0 bus address for GPU mapping */
  __u64 bar0_size;         /* OUT: BAR0 size */
};

/* IOCTLs */
#define NVME_AXIIO_CREATE_QUEUE                                                \
  _IOWR(NVME_AXIIO_MAGIC, 1, struct nvme_axiio_queue_info)
#define NVME_AXIIO_DELETE_QUEUE _IOW(NVME_AXIIO_MAGIC, 2, __u16)
#define NVME_AXIIO_ALLOC_DMA                                                   \
  _IOWR(NVME_AXIIO_MAGIC, 3, struct nvme_axiio_dma_buffer)
#define NVME_AXIIO_FREE_DMA _IOW(NVME_AXIIO_MAGIC, 4, __u64)
#define NVME_AXIIO_GET_DEVICE_INFO                                             \
  _IOR(NVME_AXIIO_MAGIC, 5, struct nvme_axiio_queue_info)
#define NVME_AXIIO_REGISTER_USER_QUEUE                                         \
  _IOWR(NVME_AXIIO_MAGIC, 6, struct nvme_axiio_queue_info)
#define NVME_AXIIO_MAP_DOORBELL_FOR_GPU                                        \
  _IOWR(NVME_AXIIO_MAGIC, 7, struct nvme_axiio_doorbell_mapping)

/* Ring doorbell request (for exclusive mode - avoid /dev/mem) */
struct nvme_axiio_ring_doorbell {
  __u16 queue_id; /* IN: Queue ID */
  __u8 is_sq;     /* IN: 1=SQ doorbell, 0=CQ doorbell */
  __u32 value;    /* IN: Doorbell value to write */
};

/* GPU doorbell mapping info */
struct nvme_gpu_doorbell_info {
  __u16 queue_id; /* IN: Queue ID */
  __u8 is_sq;     /* IN: 1=SQ doorbell, 0=CQ doorbell */
  __s32 gpu_fd;   /* IN: GPU render node FD (e.g., /dev/dri/renderD128) */

  /* OUT: Physical addresses */
  __u64 doorbell_phys;   /* Physical address of doorbell */
  __u64 bar0_phys;       /* BAR0 base physical address */
  __u32 doorbell_offset; /* Offset within BAR0 */

  /* OUT: For mmap */
  __u64 mmap_offset; /* Offset to use with mmap() (pgoff) */
  __u64 mmap_size;   /* Size to map (page-aligned) */
  __u64 gpu_va;      /* GPU virtual address (after mmap) */
};

/*
 * DMA-BUF export (Standard Linux GPU-Direct!)
 *
 * Export doorbell as dmabuf for GPU import.
 * Userspace passes dmabuf_fd to GPU (via HIP/ROCm).
 * GPU driver maps into GPU address space automatically!
 */
struct nvme_doorbell_dmabuf_export {
  __u16 queue_id;      /* IN: Queue ID */
  __u8 is_sq;          /* IN: 1=SQ doorbell, 0=CQ doorbell */
  __s32 dmabuf_fd;     /* OUT: dmabuf FD to pass to GPU */
  __u64 doorbell_phys; /* OUT: Physical address (for info) */
  __u64 size;          /* OUT: Size (for info) */
};

#define NVME_AXIIO_RING_DOORBELL                                               \
  _IOW(NVME_AXIIO_MAGIC, 8, struct nvme_axiio_ring_doorbell)
#define NVME_AXIIO_GET_GPU_DOORBELL                                            \
  _IOWR(NVME_AXIIO_MAGIC, 9, struct nvme_gpu_doorbell_info)
#define NVME_AXIIO_EXPORT_DOORBELL_DMABUF                                      \
  _IOWR(NVME_AXIIO_MAGIC, 10, struct nvme_doorbell_dmabuf_export)

#endif /* _NVME_AXIIO_H */
