/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Direct NVMe Admin Queue Access
 *
 * This module directly accesses the NVMe admin queue to submit
 * CREATE_SQ/CREATE_CQ commands, bypassing the kernel driver's ioctl.
 *
 * WARNING: This is potentially dangerous and may conflict with the
 * kernel's NVMe driver. Use with caution!
 */

#ifndef NVME_ADMIN_DIRECT_H
#define NVME_ADMIN_DIRECT_H

#include <linux/nvme.h>
#include <linux/types.h>

/* Admin queue structure (mapped from BAR0) */
struct nvme_admin_queue {
  void __iomem* sq;                  /* Admin SQ virtual address */
  void __iomem* cq;                  /* Admin CQ virtual address */
  dma_addr_t sq_dma;                 /* Admin SQ DMA address */
  dma_addr_t cq_dma;                 /* Admin CQ DMA address */
  volatile u32 __iomem* sq_doorbell; /* SQ doorbell register */
  volatile u32 __iomem* cq_doorbell; /* CQ doorbell register */
  u16 sq_tail;                       /* Current SQ tail */
  u16 cq_head;                       /* Current CQ head */
  u16 queue_size;                    /* Queue depth */
  u8 cq_phase;                       /* Current phase bit */
};

/* NVMe Admin Command Opcodes */
#define NVME_ADMIN_CREATE_SQ 0x01
#define NVME_ADMIN_CREATE_CQ 0x05
#define NVME_ADMIN_DELETE_SQ 0x00
#define NVME_ADMIN_DELETE_CQ 0x04

/*
 * Initialize admin queue access by reading ASQ/ACQ from controller
 */
static inline int nvme_admin_queue_init(struct nvme_admin_queue* admin,
                                        void __iomem* bar0,
                                        u32 doorbell_stride) {
  u64 asq, acq;
  u32 aqa;

  /* Read Admin Queue Attributes (AQA) at offset 0x24 */
  aqa = readl(bar0 + 0x24);
  admin->queue_size = ((aqa & 0xFFF) + 1); /* ASQS in bits 11:0 */

  /* Read Admin Submission Queue Base Address (ASQ) at offset 0x28 */
  asq = readq(bar0 + 0x28);

  /* Read Admin Completion Queue Base Address (ACQ) at offset 0x30 */
  acq = readq(bar0 + 0x30);

  pr_info("nvme_axiio: Admin queue initialization:\n");
  pr_info("  Queue size: %u entries\n", admin->queue_size);
  pr_info("  ASQ: 0x%llx\n", asq);
  pr_info("  ACQ: 0x%llx\n", acq);

  /* We can't easily map these physical addresses from another driver
   * because they belong to the kernel nvme driver's DMA allocations.
   * Instead, we'll use a different approach: negotiate queue IDs with
   * the kernel driver or use VFIO for exclusive access.
   */

  /* For now, mark this as not implemented */
  pr_warn("nvme_axiio: Direct admin queue access not fully implemented\n");
  pr_warn("  Reason: Cannot safely map kernel driver's admin queue memory\n");
  pr_warn("  Alternative: Use nvme_submit_admin_command() kernel API\n");

  return -ENOTSUPP;
}

/*
 * Submit an admin command directly to the admin queue
 *
 * NOTE: This is dangerous and may conflict with the kernel driver!
 */
static inline int nvme_submit_admin_cmd_direct(struct nvme_admin_queue* admin,
                                               struct nvme_command* cmd) {
  /* This would write to the admin SQ, but we can't safely do this
   * while the kernel driver is also using the admin queue.
   *
   * The kernel driver uses locks and has exclusive access.
   */
  pr_err("nvme_axiio: Direct admin command submission not supported\n");
  pr_err("  Reason: Would conflict with kernel driver's admin queue usage\n");
  return -ENOTSUPP;
}

/*
 * Create I/O Completion Queue via direct admin command
 */
static inline int nvme_create_io_cq_direct(struct nvme_admin_queue* admin,
                                           u16 qid, u16 qsize,
                                           dma_addr_t cq_dma, u16 iv) {
  struct nvme_command cmd;

  memset(&cmd, 0, sizeof(cmd));
  cmd.create_cq.opcode = NVME_ADMIN_CREATE_CQ;
  cmd.create_cq.prp1 = cpu_to_le64(cq_dma);
  cmd.create_cq.cqid = cpu_to_le16(qid);
  cmd.create_cq.qsize = cpu_to_le16(qsize - 1);
  cmd.create_cq.cq_flags = cpu_to_le16(NVME_QUEUE_PHYS_CONTIG |
                                       NVME_CQ_IRQ_ENABLED);
  cmd.create_cq.irq_vector = cpu_to_le16(iv);

  return nvme_submit_admin_cmd_direct(admin, &cmd);
}

/*
 * Create I/O Submission Queue via direct admin command
 */
static inline int nvme_create_io_sq_direct(struct nvme_admin_queue* admin,
                                           u16 qid, u16 cqid, u16 qsize,
                                           dma_addr_t sq_dma) {
  struct nvme_command cmd;

  memset(&cmd, 0, sizeof(cmd));
  cmd.create_sq.opcode = NVME_ADMIN_CREATE_SQ;
  cmd.create_sq.prp1 = cpu_to_le64(sq_dma);
  cmd.create_sq.sqid = cpu_to_le16(qid);
  cmd.create_sq.qsize = cpu_to_le16(qsize - 1);
  cmd.create_sq.sq_flags = cpu_to_le16(NVME_QUEUE_PHYS_CONTIG |
                                       NVME_SQ_PRIO_MEDIUM);
  cmd.create_sq.cqid = cpu_to_le16(cqid);

  return nvme_submit_admin_cmd_direct(admin, &cmd);
}

#endif /* NVME_ADMIN_DIRECT_H */
