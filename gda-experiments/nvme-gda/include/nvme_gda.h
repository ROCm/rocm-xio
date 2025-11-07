/* SPDX-License-Identifier: MIT */
/**
 * NVMe GPU Direct Async - Userspace Library Header
 *
 * Provides GPU-accessible NVMe queues and doorbell operations
 */

#ifndef NVME_GDA_USERSPACE_H
#define NVME_GDA_USERSPACE_H

#include <stddef.h>
#include <stdint.h>

#include "../nvme_gda_driver/nvme_gda.h"

#ifdef __cplusplus
extern "C" {
#endif

/* NVMe command structures */
struct nvme_command {
  union {
    struct {
      uint8_t opcode;
      uint8_t flags;
      uint16_t command_id;
      uint32_t nsid;
      uint64_t rsvd2;
      uint64_t metadata;
      uint64_t prp1;
      uint64_t prp2;
      uint32_t cdw10;
      uint32_t cdw11;
      uint32_t cdw12;
      uint32_t cdw13;
      uint32_t cdw14;
      uint32_t cdw15;
    } common;

    struct {
      uint8_t opcode;
      uint8_t flags;
      uint16_t command_id;
      uint32_t nsid;
      uint64_t rsvd;
      uint64_t metadata;
      uint64_t prp1;
      uint64_t prp2;
      uint64_t slba;   /* Starting LBA */
      uint16_t length; /* Number of logical blocks */
      uint16_t control;
      uint32_t dsmgmt;
      uint32_t reftag;
      uint16_t apptag;
      uint16_t appmask;
    } rw;

    uint32_t dwords[16];
  };
} __attribute__((packed));

struct nvme_completion {
  uint32_t result;
  uint32_t rsvd;
  uint16_t sq_head;
  uint16_t sq_id;
  uint16_t command_id;
  uint16_t status;
} __attribute__((packed));

/* NVMe opcodes */
#define NVME_CMD_FLUSH 0x00
#define NVME_CMD_WRITE 0x01
#define NVME_CMD_READ 0x02

/* Context and queue structures */
typedef struct nvme_gda_context nvme_gda_context;
typedef struct nvme_gda_queue_userspace nvme_gda_queue_userspace;

/* Userspace queue structure (GPU-accessible) */
struct nvme_gda_queue_userspace {
  uint16_t qid;
  uint16_t qsize;
  uint16_t sq_tail;
  uint16_t cq_head;
  uint16_t cq_phase;

  /* Mapped memory regions (CPU accessible) */
  struct nvme_command* sqes;      /* Submission queue entries */
  struct nvme_completion* cqes;   /* Completion queue entries */
  volatile uint32_t* sq_doorbell; /* SQ doorbell register (CPU) */
  volatile uint32_t* cq_doorbell; /* CQ doorbell register (CPU) */

  /* GPU-accessible pointers (from HSA lock) */
  struct nvme_command* gpu_sqes;      /* SQ entries (GPU) */
  struct nvme_completion* gpu_cqes;   /* CQ entries (GPU) */
  volatile uint32_t* gpu_sq_doorbell; /* SQ doorbell (GPU) */
  volatile uint32_t* gpu_cq_doorbell; /* CQ doorbell (GPU) */

  /* For cleanup */
  int fd;
  size_t sqes_size;
  size_t cqes_size;
  size_t doorbell_size;
};

/**
 * Initialize NVMe GDA context
 * @param device_path Path to device (e.g., "/dev/nvme_gda0")
 * @return Context pointer or NULL on error
 */
nvme_gda_context* nvme_gda_init(const char* device_path);

/**
 * Cleanup NVMe GDA context
 */
void nvme_gda_cleanup(nvme_gda_context* ctx);

/**
 * Create GPU-accessible queue
 * @param ctx Context
 * @param qsize Queue size (must be power of 2)
 * @return Queue pointer or NULL on error
 */
nvme_gda_queue_userspace* nvme_gda_create_queue(nvme_gda_context* ctx,
                                                uint16_t qsize);

/**
 * Destroy queue
 */
void nvme_gda_destroy_queue(nvme_gda_queue_userspace* queue);

/**
 * Get device information
 */
int nvme_gda_get_device_info(nvme_gda_context* ctx,
                             struct nvme_gda_device_info* info);

/**
 * Lock memory for GPU access using HSA
 * Similar to rocSHMEM's rocm_memory_lock_to_fine_grain
 */
int nvme_gda_lock_memory_to_gpu(void* ptr, size_t size, void** gpu_ptr,
                                int gpu_id);

/**
 * Unlock memory
 */
int nvme_gda_unlock_memory(void* gpu_ptr);

/* GPU device functions (implemented in .hip file) */
#ifdef __HIP_PLATFORM_AMD__

/**
 * Ring NVMe doorbell from GPU
 * @param doorbell Pointer to doorbell register
 * @param new_tail New tail value
 */
__device__ void nvme_gda_ring_doorbell(volatile uint32_t* doorbell,
                                       uint32_t new_tail);

/**
 * Post NVMe command to submission queue from GPU
 * @param queue Queue pointer
 * @param cmd Command to post
 * @return Command ID
 */
__device__ uint16_t nvme_gda_post_command(nvme_gda_queue_userspace* queue,
                                          const struct nvme_command* cmd);

/**
 * Wait for completion from GPU
 * @param queue Queue pointer
 * @param command_id Command ID to wait for
 * @return Completion entry
 */
__device__ struct nvme_completion nvme_gda_wait_completion(
  nvme_gda_queue_userspace* queue, uint16_t command_id);

/**
 * Build NVMe read command
 */
__device__ struct nvme_command nvme_gda_build_read_cmd(
  uint32_t nsid, uint64_t slba, uint16_t nlb, uint64_t prp1, uint64_t prp2);

/**
 * Build NVMe write command
 */
__device__ struct nvme_command nvme_gda_build_write_cmd(
  uint32_t nsid, uint64_t slba, uint16_t nlb, uint64_t prp1, uint64_t prp2);

#endif /* __HIP_PLATFORM_AMD__ */

#ifdef __cplusplus
}
#endif

#endif /* NVME_GDA_USERSPACE_H */
