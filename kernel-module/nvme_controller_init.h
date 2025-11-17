/* SPDX-License-Identifier: GPL-2.0 */
/*
 * NVMe Controller Initialization
 *
 * Initialize NVMe controller when bound to our driver.
 * Based on NVMe 1.4 specification.
 */

#ifndef NVME_CONTROLLER_INIT_H
#define NVME_CONTROLLER_INIT_H

#include <linux/delay.h>
#include <linux/nvme.h>

/* NVMe Controller Registers (relative to BAR0) */
#define NVME_REG_CAP 0x00   /* Controller Capabilities */
#define NVME_REG_VS 0x08    /* Version */
#define NVME_REG_INTMS 0x0c /* Interrupt Mask Set */
#define NVME_REG_INTMC 0x10 /* Interrupt Mask Clear */
#define NVME_REG_CC 0x14    /* Controller Configuration */
#define NVME_REG_CSTS 0x1c  /* Controller Status */
#define NVME_REG_AQA 0x24   /* Admin Queue Attributes */
#define NVME_REG_ASQ 0x28   /* Admin Submission Queue Base Address */
#define NVME_REG_ACQ 0x30   /* Admin Completion Queue Base Address */

/* Controller Configuration (CC) bits */
#define NVME_CC_ENABLE (1 << 0)
#define NVME_CC_CSS_NVM (0 << 4)
#define NVME_CC_MPS_SHIFT 7
#define NVME_CC_AMS_RR (0 << 11)
#define NVME_CC_SHN_NONE (0 << 14)
#define NVME_CC_IOSQES (6 << 16) /* 2^6 = 64 bytes */
#define NVME_CC_IOCQES (4 << 20) /* 2^4 = 16 bytes */

/* Controller Status (CSTS) bits */
#define NVME_CSTS_RDY (1 << 0)
#define NVME_CSTS_CFS (1 << 1)
#define NVME_CSTS_SHST_MASK (3 << 2)
#define NVME_CSTS_SHST_NORMAL (0 << 2)

/* Admin queue structure */
struct nvme_admin_queue {
  void* sq_virt;      /* Admin SQ virtual address */
  dma_addr_t sq_dma;  /* Admin SQ DMA address */
  void* cq_virt;      /* Admin CQ virtual address */
  dma_addr_t cq_dma;  /* Admin CQ DMA address */
  u16 sq_tail;        /* Current SQ tail */
  u16 cq_head;        /* Current CQ head */
  u16 queue_size;     /* Queue depth */
  u8 cq_phase;        /* Current CQ phase bit */
  spinlock_t sq_lock; /* Protects SQ submission */
};

/*
 * Wait for controller status bit
 */
static inline int nvme_wait_csts(void __iomem* bar0, u32 mask, u32 val,
                                 unsigned timeout_ms) {
  unsigned long timeout = jiffies + msecs_to_jiffies(timeout_ms);
  u32 csts;

  while (time_before(jiffies, timeout)) {
    csts = readl(bar0 + NVME_REG_CSTS);
    if ((csts & mask) == val)
      return 0;
    msleep(10);
  }

  pr_err("nvme_axiio: Timeout waiting for CSTS 0x%x (got 0x%x)\n", val, csts);
  return -ETIMEDOUT;
}

/*
 * Disable controller
 */
static inline int nvme_disable_ctrl(void __iomem* bar0) {
  u32 cc;

  pr_info("nvme_axiio: Disabling controller...\n");

  cc = readl(bar0 + NVME_REG_CC);
  cc &= ~NVME_CC_ENABLE;
  writel(cc, bar0 + NVME_REG_CC);

  /* Wait for controller to indicate ready=0 */
  return nvme_wait_csts(bar0, NVME_CSTS_RDY, 0, 5000);
}

/*
 * Enable controller
 */
static inline int nvme_enable_ctrl(void __iomem* bar0, u32 page_size_shift) {
  u32 cc;
  u64 cap;
  u32 mps;

  pr_info("nvme_axiio: Enabling controller...\n");

  /* Read CAP to get page size requirements */
  cap = readq(bar0 + NVME_REG_CAP);

  /* Build CC register value */
  mps = page_size_shift - 12; /* Page size = 2^(12 + MPS) */
  cc = NVME_CC_ENABLE | NVME_CC_CSS_NVM | (mps << NVME_CC_MPS_SHIFT) |
       NVME_CC_AMS_RR | NVME_CC_SHN_NONE | NVME_CC_IOSQES | NVME_CC_IOCQES;

  writel(cc, bar0 + NVME_REG_CC);

  pr_info("nvme_axiio: CC register: 0x%08x\n", cc);

  /* Wait for controller to become ready */
  return nvme_wait_csts(bar0, NVME_CSTS_RDY, NVME_CSTS_RDY, 10000);
}

/*
 * Initialize admin queue
 */
static inline int nvme_init_admin_queue(struct device* dev, void __iomem* bar0,
                                        struct nvme_admin_queue* admin_q,
                                        u16 queue_size) {
  u32 aqa;
  int ret;

  pr_info("nvme_axiio: Initializing admin queue (size=%u)...\n", queue_size);

  /* Allocate admin submission queue */
  admin_q->queue_size = queue_size;
  admin_q->sq_virt = dma_alloc_coherent(dev, queue_size * 64, &admin_q->sq_dma,
                                        GFP_KERNEL);
  if (!admin_q->sq_virt) {
    pr_err("nvme_axiio: Failed to allocate admin SQ\n");
    return -ENOMEM;
  }
  memset(admin_q->sq_virt, 0, queue_size * 64);

  /* Allocate admin completion queue */
  admin_q->cq_virt = dma_alloc_coherent(dev, queue_size * 16, &admin_q->cq_dma,
                                        GFP_KERNEL);
  if (!admin_q->cq_virt) {
    pr_err("nvme_axiio: Failed to allocate admin CQ\n");
    dma_free_coherent(dev, queue_size * 64, admin_q->sq_virt, admin_q->sq_dma);
    return -ENOMEM;
  }
  memset(admin_q->cq_virt, 0, queue_size * 16);

  admin_q->sq_tail = 0;
  admin_q->cq_head = 0;
  admin_q->cq_phase = 1;
  spin_lock_init(&admin_q->sq_lock);

  pr_info("nvme_axiio: Admin queues allocated:\n");
  pr_info("  ASQ: virt=%p dma=0x%llx\n", admin_q->sq_virt,
          (u64)admin_q->sq_dma);
  pr_info("  ACQ: virt=%p dma=0x%llx\n", admin_q->cq_virt,
          (u64)admin_q->cq_dma);

  /* Disable controller first */
  ret = nvme_disable_ctrl(bar0);
  if (ret < 0) {
    pr_err("nvme_axiio: Failed to disable controller\n");
    goto free_queues;
  }

  /* Configure admin queue attributes */
  aqa = ((queue_size - 1) << 16) | (queue_size - 1); /* ACQS | ASQS */
  writel(aqa, bar0 + NVME_REG_AQA);

  /* Set admin queue base addresses */
  writeq(admin_q->sq_dma, bar0 + NVME_REG_ASQ);
  writeq(admin_q->cq_dma, bar0 + NVME_REG_ACQ);

  pr_info("nvme_axiio: Admin queue registers configured:\n");
  pr_info("  AQA: 0x%08x\n", aqa);
  pr_info("  ASQ: 0x%016llx\n", admin_q->sq_dma);
  pr_info("  ACQ: 0x%016llx\n", admin_q->cq_dma);

  /* Enable controller */
  ret = nvme_enable_ctrl(bar0, PAGE_SHIFT);
  if (ret < 0) {
    pr_err("nvme_axiio: Failed to enable controller\n");
    goto free_queues;
  }

  pr_info("nvme_axiio: ✓ Controller enabled, admin queue ready\n");
  return 0;

free_queues:
  dma_free_coherent(dev, queue_size * 16, admin_q->cq_virt, admin_q->cq_dma);
  dma_free_coherent(dev, queue_size * 64, admin_q->sq_virt, admin_q->sq_dma);
  return ret;
}

/*
 * Shutdown admin queue
 */
static inline void nvme_shutdown_admin_queue(struct device* dev,
                                             void __iomem* bar0,
                                             struct nvme_admin_queue* admin_q) {
  pr_info("nvme_axiio: Shutting down admin queue...\n");

  /* Disable controller */
  nvme_disable_ctrl(bar0);

  /* Free admin queues */
  if (admin_q->cq_virt) {
    dma_free_coherent(dev, admin_q->queue_size * 16, admin_q->cq_virt,
                      admin_q->cq_dma);
    admin_q->cq_virt = NULL;
  }

  if (admin_q->sq_virt) {
    dma_free_coherent(dev, admin_q->queue_size * 64, admin_q->sq_virt,
                      admin_q->sq_dma);
    admin_q->sq_virt = NULL;
  }

  pr_info("nvme_axiio: ✓ Admin queue shut down\n");
}

/*
 * Get controller version
 */
static inline u32 nvme_get_version(void __iomem* bar0) {
  return readl(bar0 + NVME_REG_VS);
}

/*
 * Get controller capabilities
 */
static inline u64 nvme_get_cap(void __iomem* bar0) {
  return readq(bar0 + NVME_REG_CAP);
}

/*
 * Get maximum queue entries supported
 */
static inline u16 nvme_get_max_queue_entries(void __iomem* bar0) {
  u64 cap = nvme_get_cap(bar0);
  return ((cap & 0xFFFF) + 1); /* MQES in bits 15:0 */
}

/*
 * Get doorbell stride
 */
static inline u32 nvme_get_doorbell_stride(void __iomem* bar0) {
  u64 cap = nvme_get_cap(bar0);
  return (4 << ((cap >> 32) & 0xF)); /* DSTRD in bits 35:32, stride = 4 *
                                        2^DSTRD */
}

#endif /* NVME_CONTROLLER_INIT_H */
