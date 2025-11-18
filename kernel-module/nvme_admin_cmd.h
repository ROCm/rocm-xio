/* SPDX-License-Identifier: GPL-2.0 */
/*
 * NVMe Admin Command Submission
 *
 * Submit admin commands and poll for completions.
 */

#ifndef NVME_ADMIN_CMD_H
#define NVME_ADMIN_CMD_H

#include <linux/nvme.h>

#include "nvme_controller_init.h"

/*
 * Submit admin command and wait for completion
 */
static inline int nvme_submit_admin_cmd_sync(void __iomem* bar0,
                                             struct nvme_admin_queue* admin_q,
                                             struct nvme_command* cmd,
                                             u32* result, unsigned timeout_ms) {
  struct nvme_command* sq_entry;
  struct nvme_completion* cq_entry;
  u16 sq_tail, cq_head;
  u8 expected_phase;
  unsigned long timeout;
  u16 status;
  unsigned long flags;
  u32 doorbell_stride;
  volatile u32 __iomem* sq_doorbell;

  pr_debug("nvme_axiio: Submitting admin command opcode=0x%02x\n",
           cmd->common.opcode);

  spin_lock_irqsave(&admin_q->sq_lock, flags);

  /* Get current SQ tail */
  sq_tail = admin_q->sq_tail;

  /* Write command to SQ */
  sq_entry = (struct nvme_command*)admin_q->sq_virt + sq_tail;
  memcpy(sq_entry, cmd, sizeof(*cmd));
  sq_entry->common.command_id = sq_tail; /* Use tail as command ID */

  /* Advance tail */
  sq_tail++;
  if (sq_tail >= admin_q->queue_size)
    sq_tail = 0;
  admin_q->sq_tail = sq_tail;

  /* Ring doorbell (offset 0x1000 for admin SQ) */
  doorbell_stride = nvme_get_doorbell_stride(bar0);
  sq_doorbell = (volatile u32 __iomem*)(bar0 + 0x1000);
  writel(sq_tail, sq_doorbell);

  pr_debug("nvme_axiio: Rang admin SQ doorbell (tail=%u)\n", sq_tail);

  spin_unlock_irqrestore(&admin_q->sq_lock, flags);

  /* Poll for completion */
  cq_head = admin_q->cq_head;
  expected_phase = admin_q->cq_phase;
  timeout = jiffies + msecs_to_jiffies(timeout_ms);

  while (time_before(jiffies, timeout)) {
    cq_entry = (struct nvme_completion*)admin_q->cq_virt + cq_head;

    /* Check phase bit */
    if ((le16_to_cpu(cq_entry->status) & 1) == expected_phase) {
      /* Got completion! */
      status = le16_to_cpu(cq_entry->status) >> 1;

      if (result)
        *result = le32_to_cpu(cq_entry->result.u32);

      pr_debug(
        "nvme_axiio: Admin command completed: status=0x%04x result=0x%08x\n",
        status, *result);

      /* Advance CQ head */
      cq_head++;
      if (cq_head >= admin_q->queue_size) {
        cq_head = 0;
        admin_q->cq_phase = !admin_q->cq_phase;
      }
      admin_q->cq_head = cq_head;

      /* Ring CQ doorbell (offset 0x1000 + doorbell_stride for admin CQ) */
      {
        volatile u32 __iomem* cq_doorbell;
        cq_doorbell = (volatile u32 __iomem*)(bar0 + 0x1000 + doorbell_stride);
        writel(cq_head, cq_doorbell);
      }

      /* Check status */
      if (status != 0) {
        pr_err("nvme_axiio: Admin command failed: status=0x%04x\n", status);
        return -EIO;
      }

      return 0;
    }

    cpu_relax();
    usleep_range(10, 100);
  }

  pr_err("nvme_axiio: Timeout waiting for admin command completion\n");
  return -ETIMEDOUT;
}

/*
 * Identify Controller
 */
static inline int nvme_identify_ctrl(void __iomem* bar0,
                                     struct nvme_admin_queue* admin_q,
                                     struct device* dev, void* identify_data) {
  struct nvme_command cmd;
  dma_addr_t dma_addr;
  void* buffer;
  u32 result;
  int ret;

  pr_info("nvme_axiio: Identifying controller...\n");

  /* Allocate DMA buffer for identify data */
  buffer = dma_alloc_coherent(dev, 4096, &dma_addr, GFP_KERNEL);
  if (!buffer) {
    pr_err("nvme_axiio: Failed to allocate identify buffer\n");
    return -ENOMEM;
  }

  /* Build identify command */
  memset(&cmd, 0, sizeof(cmd));
  cmd.identify.opcode = nvme_admin_identify;
  cmd.identify.nsid = 0;
  cmd.common.dptr.prp1 = cpu_to_le64(dma_addr);
  cmd.identify.cns = NVME_ID_CNS_CTRL;

  /* Submit command - use longer timeout for real hardware (30 seconds) */
  ret = nvme_submit_admin_cmd_sync(bar0, admin_q, &cmd, &result, 30000);

  if (ret == 0 && identify_data) {
    memcpy(identify_data, buffer, 4096);
    pr_info("nvme_axiio: ✓ Controller identified\n");
  }

  dma_free_coherent(dev, 4096, buffer, dma_addr);
  return ret;
}

/*
 * Create I/O Completion Queue
 */
static inline int nvme_create_io_cq_cmd(void __iomem* bar0,
                                        struct nvme_admin_queue* admin_q,
                                        u16 qid, u16 qsize, dma_addr_t cq_dma,
                                        u16 iv) {
  struct nvme_command cmd;
  u32 result;

  pr_info("nvme_axiio: Creating I/O CQ (qid=%u, size=%u)...\n", qid, qsize);

  memset(&cmd, 0, sizeof(cmd));
  cmd.create_cq.opcode = nvme_admin_create_cq;
  cmd.common.dptr.prp1 = cpu_to_le64(cq_dma);
  cmd.create_cq.cqid = cpu_to_le16(qid);
  cmd.create_cq.qsize = cpu_to_le16(qsize - 1); /* 0-based */
  cmd.create_cq.cq_flags = cpu_to_le16(NVME_QUEUE_PHYS_CONTIG |
                                       NVME_CQ_IRQ_ENABLED);
  cmd.create_cq.irq_vector = cpu_to_le16(iv);

  /* Use longer timeout for real hardware (30 seconds) vs QEMU (5 seconds) */
  return nvme_submit_admin_cmd_sync(bar0, admin_q, &cmd, &result, 30000);
}

/*
 * Create I/O Submission Queue
 */
static inline int nvme_create_io_sq_cmd(void __iomem* bar0,
                                        struct nvme_admin_queue* admin_q,
                                        u16 qid, u16 cqid, u16 qsize,
                                        dma_addr_t sq_dma) {
  struct nvme_command cmd;
  u32 result;

  pr_info("nvme_axiio: Creating I/O SQ (qid=%u, cqid=%u, size=%u)...\n", qid,
          cqid, qsize);

  memset(&cmd, 0, sizeof(cmd));
  cmd.create_sq.opcode = nvme_admin_create_sq;
  cmd.common.dptr.prp1 = cpu_to_le64(sq_dma);
  cmd.create_sq.sqid = cpu_to_le16(qid);
  cmd.create_sq.qsize = cpu_to_le16(qsize - 1); /* 0-based */
  cmd.create_sq.sq_flags = cpu_to_le16(NVME_QUEUE_PHYS_CONTIG |
                                       NVME_SQ_PRIO_MEDIUM);
  cmd.create_sq.cqid = cpu_to_le16(cqid);

  /* Use longer timeout for real hardware (30 seconds) vs QEMU (5 seconds) */
  return nvme_submit_admin_cmd_sync(bar0, admin_q, &cmd, &result, 30000);
}

/*
 * Delete I/O Submission Queue
 */
static inline int nvme_delete_io_sq_cmd(void __iomem* bar0,
                                        struct nvme_admin_queue* admin_q,
                                        u16 qid) {
  struct nvme_command cmd;
  u32 result;

  pr_info("nvme_axiio: Deleting I/O SQ (qid=%u)...\n", qid);

  memset(&cmd, 0, sizeof(cmd));
  cmd.delete_queue.opcode = nvme_admin_delete_sq;
  cmd.delete_queue.qid = cpu_to_le16(qid);

  /* Use longer timeout for real hardware (30 seconds) vs QEMU (5 seconds) */
  return nvme_submit_admin_cmd_sync(bar0, admin_q, &cmd, &result, 30000);
}

/*
 * Delete I/O Completion Queue
 */
static inline int nvme_delete_io_cq_cmd(void __iomem* bar0,
                                        struct nvme_admin_queue* admin_q,
                                        u16 qid) {
  struct nvme_command cmd;
  u32 result;

  pr_info("nvme_axiio: Deleting I/O CQ (qid=%u)...\n", qid);

  memset(&cmd, 0, sizeof(cmd));
  cmd.delete_queue.opcode = nvme_admin_delete_cq;
  cmd.delete_queue.qid = cpu_to_le16(qid);

  /* Use longer timeout for real hardware (30 seconds) vs QEMU (5 seconds) */
  return nvme_submit_admin_cmd_sync(bar0, admin_q, &cmd, &result, 30000);
}

#endif /* NVME_ADMIN_CMD_H */
