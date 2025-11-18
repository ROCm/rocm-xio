/* SPDX-License-Identifier: GPL-2.0 */
/*
 * NVMe P2P IOVA Support for QEMU Emulated Devices
 *
 * Adds support for QEMU's vendor-specific admin command (0xC0) to retrieve
 * IOVA addresses for GPU direct access to emulated NVMe devices.
 */

#ifndef NVME_P2P_IOVA_H
#define NVME_P2P_IOVA_H

#include <linux/types.h>

#include "nvme_admin_cmd.h"
#include "nvme_controller_init.h"

/* P2P IOVA Information Structure (matches QEMU nvme-p2p.h) */
struct nvme_p2p_iova_info {
  u64 sqe_iova;
  u64 cqe_iova;
  u64 doorbell_iova;
  u32 sqe_size;
  u32 cqe_size;
  u32 doorbell_size;
  u16 queue_depth;
  u16 reserved;
  /* Guest physical addresses for kernel module to map */
  u64 sqe_gpa;      /* Guest physical address of SQE buffer */
  u64 cqe_gpa;      /* Guest physical address of CQE buffer */
  u64 doorbell_gpa; /* Guest physical address of doorbell buffer */
} __packed;

/* Vendor-specific admin command opcode for P2P IOVA retrieval */
#define NVME_ADMIN_VENDOR_P2P_IOVA 0xC0

/*
 * Issue vendor command 0xC0 to get IOVA addresses from QEMU
 *
 * This triggers QEMU to set up IOVA mappings for GPU direct access.
 * Only works with QEMU emulated NVMe that has p2p-gpu property set.
 *
 * @queue_id: Queue ID to get IOVA info for (0 = admin queue)
 *
 * Returns 0 on success, negative errno on failure.
 * On success, iova_info is filled with IOVA addresses.
 */
static inline int nvme_get_p2p_iova_info(void __iomem* bar0,
                                         struct nvme_admin_queue* admin_q,
                                         struct device* dev,
                                         u16 queue_id,
                                         struct nvme_p2p_iova_info* iova_info) {
  struct nvme_command cmd;
  dma_addr_t dma_addr;
  void* buffer;
  u32 result;
  int ret;

  pr_info("nvme_axiio: Requesting P2P IOVA info for QID %u from QEMU (vendor cmd 0xC0)...\n", 
          queue_id);

  /* Allocate DMA buffer for IOVA info */
  buffer = dma_alloc_coherent(dev, sizeof(*iova_info), &dma_addr, GFP_KERNEL);
  if (!buffer) {
    pr_err("nvme_axiio: Failed to allocate IOVA info buffer\n");
    return -ENOMEM;
  }

  /* Build vendor-specific admin command */
  memset(&cmd, 0, sizeof(cmd));
  cmd.common.opcode = NVME_ADMIN_VENDOR_P2P_IOVA;
  cmd.common.nsid = 0;
  cmd.common.dptr.prp1 = cpu_to_le64(dma_addr);
  cmd.common.cdw10 = cpu_to_le32(sizeof(*iova_info)); /* data length */
  cmd.common.cdw11 = cpu_to_le32(queue_id);           /* queue ID */

  /* Submit command */
  /* Use longer timeout for real hardware (30 seconds) vs QEMU (5 seconds) */
  ret = nvme_submit_admin_cmd_sync(bar0, admin_q, &cmd, &result, 30000);

  if (ret == 0) {
    /* Copy IOVA info from DMA buffer */
    memcpy(iova_info, buffer, sizeof(*iova_info));

    pr_info("nvme_axiio: ✅ P2P IOVA mappings retrieved from QEMU:\n");
    pr_info("  SQE IOVA:      0x%016llx (size: %u bytes)\n",
            iova_info->sqe_iova, iova_info->sqe_size);
    pr_info("  CQE IOVA:      0x%016llx (size: %u bytes)\n",
            iova_info->cqe_iova, iova_info->cqe_size);
    pr_info("  Doorbell IOVA: 0x%016llx (size: %u bytes)\n",
            iova_info->doorbell_iova, iova_info->doorbell_size);
    pr_info("  Queue depth:   %u\n", iova_info->queue_depth);
    pr_info("  🎉 QEMU P2P setup complete - GPU can access these IOVAs!\n");
  } else if (ret == -EIO) {
    pr_warn("nvme_axiio: Vendor command 0xC0 failed (not supported)\n");
    pr_warn("  This is expected for real hardware (not emulated)\n");
    pr_warn("  Will use physical addresses instead of IOVA\n");
  } else {
    pr_err("nvme_axiio: Failed to get P2P IOVA info: %d\n", ret);
  }

  dma_free_coherent(dev, sizeof(*iova_info), buffer, dma_addr);
  return ret;
}

/*
 * Check if this is a QEMU emulated NVMe device
 *
 * QEMU emulated NVMe typically has:
 * - Vendor ID: 0x1b36 (Red Hat / QEMU)
 * - Or subsystem vendor: 0x1af4 (virtio)
 */
static inline bool is_qemu_emulated_nvme(struct pci_dev* pdev) {
  /* Check for QEMU vendor IDs */
  if (pdev->vendor == 0x1b36 || /* Red Hat / QEMU */
      pdev->subsystem_vendor == 0x1af4) { /* virtio */
    pr_info("nvme_axiio: Detected QEMU emulated NVMe device\n");
    return true;
  }

  /* Also check device ID - QEMU often uses specific IDs */
  if (pdev->device == 0x0010 && pdev->vendor == 0x1b36) {
    pr_info("nvme_axiio: Detected QEMU NVMe controller\n");
    return true;
  }

  pr_debug("nvme_axiio: Real hardware NVMe device (vendor=0x%04x)\n",
           pdev->vendor);
  return false;
}

#endif /* NVME_P2P_IOVA_H */





