/* SPDX-License-Identifier: MIT */
/*
 * NVMe GPU Direct Async Driver Header
 * 
 * Exposes NVMe doorbell registers and queues for GPU direct access
 */

#ifndef _NVME_GDA_H
#define _NVME_GDA_H

#include <linux/types.h>
#include <linux/ioctl.h>

#define NVME_GDA_MAGIC 'N'

/* NVMe Queue Entry Sizes */
#define NVME_SQE_SIZE 64  /* Submission Queue Entry: 64 bytes */
#define NVME_CQE_SIZE 16  /* Completion Queue Entry: 16 bytes */

/* Maximum queue sizes */
#define NVME_GDA_MAX_QUEUE_SIZE 4096
#define NVME_GDA_MIN_QUEUE_SIZE 2

/* NVMe Doorbell Stride (typically 4 bytes or 1 DWORD) */
#define NVME_DOORBELL_STRIDE 4

/**
 * struct nvme_gda_queue_info - Information about a created queue
 * @qid: Queue ID
 * @qsize: Queue size (number of entries)
 * @sqe_dma_addr: Physical address of submission queue
 * @cqe_dma_addr: Physical address of completion queue
 * @sq_doorbell_offset: Offset of SQ doorbell in BAR0
 * @cq_doorbell_offset: Offset of CQ doorbell in BAR0
 * @sqe_mmap_offset: Mmap offset for submission queue
 * @cqe_mmap_offset: Mmap offset for completion queue
 * @doorbell_mmap_offset: Mmap offset for doorbell registers
 */
struct nvme_gda_queue_info {
	__u16 qid;
	__u16 qsize;
	__u64 sqe_dma_addr;
	__u64 cqe_dma_addr;
	__u32 sq_doorbell_offset;
	__u32 cq_doorbell_offset;
	__u64 sqe_mmap_offset;
	__u64 cqe_mmap_offset;
	__u64 doorbell_mmap_offset;
};

/**
 * struct nvme_gda_device_info - NVMe controller information
 * @bar0_addr: Physical address of BAR0
 * @bar0_size: Size of BAR0
 * @doorbell_stride: Doorbell stride (in DWORDs)
 * @max_queue_entries: Maximum queue entries supported
 * @vendor_id: PCI vendor ID
 * @device_id: PCI device ID
 * @subsystem_vendor_id: PCI subsystem vendor ID
 * @subsystem_device_id: PCI subsystem device ID
 */
struct nvme_gda_device_info {
	__u64 bar0_addr;
	__u64 bar0_size;
	__u32 doorbell_stride;
	__u32 max_queue_entries;
	__u16 vendor_id;
	__u16 device_id;
	__u16 subsystem_vendor_id;
	__u16 subsystem_device_id;
	__u8 serial_number[20];
	__u8 model_number[40];
	__u8 firmware_rev[8];
};

/**
 * struct nvme_gda_create_queue - Parameters for creating a queue
 * @qsize: Requested queue size (power of 2)
 * @flags: Creation flags
 */
struct nvme_gda_create_queue {
	__u16 qsize;
	__u16 flags;
};

/* IOCTL definitions */
#define NVME_GDA_GET_DEVICE_INFO  _IOR(NVME_GDA_MAGIC, 1, struct nvme_gda_device_info)
#define NVME_GDA_CREATE_QUEUE     _IOWR(NVME_GDA_MAGIC, 2, struct nvme_gda_create_queue)
#define NVME_GDA_GET_QUEUE_INFO   _IOR(NVME_GDA_MAGIC, 3, struct nvme_gda_queue_info)
#define NVME_GDA_DESTROY_QUEUE    _IOW(NVME_GDA_MAGIC, 4, __u16)

/* Mmap regions */
#define NVME_GDA_MMAP_SQE        0
#define NVME_GDA_MMAP_CQE        1
#define NVME_GDA_MMAP_DOORBELL   2

#endif /* _NVME_GDA_H */

