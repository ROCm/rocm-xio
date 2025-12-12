/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Userspace header for rocm-axiio kernel module
 * Shared between kernel module and userspace code
 */

#ifndef ROCM_AXIIO_H
#define ROCM_AXIIO_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define ROCM_AXIIO_DEVICE_NAME "rocm-axiio"
#define ROCM_AXIIO_DEVICE_PATH "/dev/rocm-axiio"

/* IOCTL magic number */
#define ROCM_AXIIO_IOC_MAGIC 'R'

/* IOCTL commands */
#define ROCM_AXIIO_GET_VRAM_PHYS_ADDR                                          \
  _IOWR(ROCM_AXIIO_IOC_MAGIC, 1, struct rocm_axiio_vram_req)
#define ROCM_AXIIO_CREATE_QUEUE                                                \
  _IOWR(ROCM_AXIIO_IOC_MAGIC, 2, struct rocm_axiio_create_queue_req)
#define ROCM_AXIIO_DELETE_QUEUE                                                \
  _IOW(ROCM_AXIIO_IOC_MAGIC, 3, struct rocm_axiio_delete_queue_req)
#define ROCM_AXIIO_GET_DEVICE_INFO                                             \
  _IOWR(ROCM_AXIIO_IOC_MAGIC, 4, struct rocm_axiio_device_info)
#define ROCM_AXIIO_BIND_DEVICE                                                 \
  _IOW(ROCM_AXIIO_IOC_MAGIC, 5, struct rocm_axiio_bind_device_req)
#define ROCM_AXIIO_REGISTER_QUEUE_ADDR                                         \
  _IOW(ROCM_AXIIO_IOC_MAGIC, 6, struct rocm_axiio_register_queue_addr_req)
#define ROCM_AXIIO_UNREGISTER_QUEUE_ADDR                                       \
  _IOW(ROCM_AXIIO_IOC_MAGIC, 7, struct rocm_axiio_unregister_queue_addr_req)
#define ROCM_AXIIO_REGISTER_BUFFER                                             \
  _IOW(ROCM_AXIIO_IOC_MAGIC, 8, struct rocm_axiio_register_buffer_req)
#define ROCM_AXIIO_UNREGISTER_BUFFER                                           \
  _IOW(ROCM_AXIIO_IOC_MAGIC, 9, struct rocm_axiio_unregister_buffer_req)

/* Flags for VRAM physical address request */
#define ROCM_AXIIO_FLAG_EMULATED                                               \
  (1 << 0) /* Return BAR GPA for emulated NVMe                                 \
            */
#define ROCM_AXIIO_FLAG_PASSTHROUGH                                            \
  (1 << 1) /* Return P2PDMA IOVA for passthrough */

/* Get VRAM physical address from dmabuf */
struct rocm_axiio_vram_req {
  int dmabuf_fd;   /* Input: dmabuf file descriptor */
  __u16 nvme_bdf;  /* Input: NVMe device BDF (0xBBDD format) */
  __u32 flags;     /* Input: flags (see ROCM_AXIIO_FLAG_*) */
  __u64 phys_addr; /* Output: Physical address */
  __u64 size;      /* Output: Buffer size */
};

/* Create NVMe queue pair */
struct rocm_axiio_create_queue_req {
  __u16 queue_id;        /* Input: Queue ID (0=admin, 1+=IO queues) */
  __u16 queue_size;      /* Input: Queue size in entries */
  __u32 cq_vector;       /* Input: Completion queue interrupt vector */
  __u64 sq_phys_addr;    /* Output: SQ physical address */
  __u64 cq_phys_addr;    /* Output: CQ physical address */
  __u64 doorbell_addr;   /* Output: Doorbell physical address */
  __u32 doorbell_offset; /* Output: Doorbell register offset */
};

/* Delete NVMe queue pair */
struct rocm_axiio_delete_queue_req {
  __u16 queue_id;  /* Input: Queue ID to delete */
  __u8 queue_type; /* Input: 0=SQ, 1=CQ */
};

/* Get device info */
struct rocm_axiio_device_info {
  __u16 bdf;             /* Input: Device BDF (0xBBDD format) */
  __u64 bar0_addr;       /* Output: BAR0 base address */
  __u64 bar0_size;       /* Output: BAR0 size */
  __u32 doorbell_stride; /* Output: Doorbell stride (bytes between doorbells) */
  __u32 max_queues;      /* Output: Maximum number of queues */
};

/* Bind device to module */
struct rocm_axiio_bind_device_req {
  __u16 bdf; /* Input: Device BDF (0xBBDD format) */
};

/* Register queue address for injection (explicit virt->phys mapping) */
struct rocm_axiio_register_queue_addr_req {
  __u64 virt_addr; /* Input: Virtual address (userspace pointer) */
  __u64 phys_addr; /* Input: Physical address (from GET_VRAM_PHYS_ADDR) */
  __u64 size;      /* Input: Queue size in bytes */
  __u8 queue_type; /* Input: 0=SQ, 1=CQ, 2=both */
};

/* Unregister queue address */
struct rocm_axiio_unregister_queue_addr_req {
  __u64 virt_addr; /* Input: Virtual address to unregister */
};

/* Register VRAM buffer for data buffer address translation */
struct rocm_axiio_register_buffer_req {
  int dmabuf_fd;   /* Input: dmabuf file descriptor */
  __u64 virt_addr; /* Input: Virtual address (userspace pointer) */
  __u64 phys_addr; /* Output: Physical address (filled by kernel) */
  __u64 size;      /* Input: Buffer size */
};

/* Unregister VRAM buffer */
struct rocm_axiio_unregister_buffer_req {
  __u64 virt_addr; /* Input: Virtual address to unregister */
};

#endif /* ROCM_AXIIO_H */
