/* SPDX-License-Identifier: GPL-2.0 */
/*
 * NVMe AXIIO PCI Driver Registration
 *
 * Registers as a proper PCI driver that can bind to NVMe controllers,
 * allowing exclusive access for GPU-direct I/O.
 */

#ifndef NVME_AXIIO_PCI_DRIVER_H
#define NVME_AXIIO_PCI_DRIVER_H

#include <linux/nvme.h>
#include <linux/pci.h>

#include "nvme_admin_cmd.h"
#include "nvme_controller_init.h"
#include "nvme_p2p_iova.h"

/* Controller context (per bound device) */
struct axiio_controller {
  struct pci_dev* pdev;
  void __iomem* bar0;
  resource_size_t bar0_phys;
  resource_size_t bar0_size;
  struct nvme_admin_queue admin_q;
  u32 doorbell_stride;
  u16 max_queue_entries;
  u32 version;

  /* IOVA support for QEMU P2P */
  bool using_iova;
  struct nvme_p2p_iova_info p2p_iova;
};

/* Global PCI device (set when driver binds) */
static struct pci_dev* axiio_bound_pci_dev = NULL;
static struct axiio_controller* axiio_ctrl = NULL;

/*
 * PCI device ID table - matches all NVMe controllers
 * Class 0x010802: Mass Storage Controller, NVM Express, NVM Express
 */
static const struct pci_device_id nvme_axiio_pci_ids[] = {
  {
    PCI_DEVICE_CLASS(PCI_CLASS_STORAGE_EXPRESS, 0xffffff),
    .driver_data = 0,
  },
  {
    0,
  }};
MODULE_DEVICE_TABLE(pci, nvme_axiio_pci_ids);

/*
 * PCI probe function - called when device is bound to our driver
 */
static int nvme_axiio_pci_probe(struct pci_dev* pdev,
                                const struct pci_device_id* id) {
  int ret;
  resource_size_t bar0_phys, bar0_size;
  void __iomem* bar0;
  u64 cap;
  u32 dstrd;

  pci_info(pdev, "nvme_axiio: PCI probe called\n");

  /* Only allow one device at a time for now */
  if (axiio_bound_pci_dev) {
    pr_err("nvme_axiio: Already bound to device %s\n",
           pci_name(axiio_bound_pci_dev));
    return -EBUSY;
  }

  /* Enable PCI device */
  ret = pci_enable_device_mem(pdev);
  if (ret) {
    pr_err("nvme_axiio: Failed to enable PCI device: %d\n", ret);
    return ret;
  }

  /* Request memory regions */
  ret = pci_request_regions(pdev, "nvme_axiio");
  if (ret) {
    pr_err("nvme_axiio: Failed to request PCI regions: %d\n", ret);
    pci_disable_device(pdev);
    return ret;
  }

  /* Set DMA mask (NVMe supports 64-bit DMA) */
  ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
  if (ret) {
    pr_warn("nvme_axiio: 64-bit DMA not available, trying 32-bit\n");
    ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
    if (ret) {
      pr_err("nvme_axiio: Failed to set DMA mask: %d\n", ret);
      goto release_regions;
    }
  }

  /* Enable bus mastering (required for DMA) */
  pci_set_master(pdev);

  /* Map BAR0 (NVMe register space) */
  bar0_phys = pci_resource_start(pdev, 0);
  bar0_size = pci_resource_len(pdev, 0);

  if (!bar0_phys || !bar0_size) {
    pr_err("nvme_axiio: Invalid BAR0\n");
    ret = -ENXIO;
    goto release_regions;
  }

  bar0 = pci_ioremap_bar(pdev, 0);
  if (!bar0) {
    pr_err("nvme_axiio: Failed to map BAR0\n");
    ret = -ENOMEM;
    goto release_regions;
  }

  /* Allocate controller context */
  axiio_ctrl = kzalloc(sizeof(*axiio_ctrl), GFP_KERNEL);
  if (!axiio_ctrl) {
    pr_err("nvme_axiio: Failed to allocate controller context\n");
    ret = -ENOMEM;
    goto unmap_bar0;
  }

  axiio_ctrl->pdev = pdev;
  axiio_ctrl->bar0 = bar0;
  axiio_ctrl->bar0_phys = bar0_phys;
  axiio_ctrl->bar0_size = bar0_size;

  /* Read controller capabilities */
  cap = nvme_get_cap(bar0);
  axiio_ctrl->version = nvme_get_version(bar0);
  axiio_ctrl->doorbell_stride = nvme_get_doorbell_stride(bar0);
  axiio_ctrl->max_queue_entries = nvme_get_max_queue_entries(bar0);
  dstrd = (cap >> 32) & 0xF;

  pr_info("nvme_axiio: ✓ Successfully bound to NVMe controller\n");
  pr_info("  PCI: %s\n", pci_name(pdev));
  pr_info("  BAR0: phys=0x%llx size=0x%llx\n", (u64)bar0_phys, (u64)bar0_size);
  pr_info("  Version: %u.%u.%u\n", (axiio_ctrl->version >> 16) & 0xFFFF,
          (axiio_ctrl->version >> 8) & 0xFF, axiio_ctrl->version & 0xFF);
  pr_info("  CAP: 0x%016llx (DSTRD=%u, MQES=%u)\n", cap, dstrd,
          axiio_ctrl->max_queue_entries);

  /* Initialize controller and admin queue */
  pr_info("nvme_axiio: Initializing NVMe controller...\n");
  ret = nvme_init_admin_queue(&pdev->dev, bar0, &axiio_ctrl->admin_q, 64);
  if (ret < 0) {
    pr_err("nvme_axiio: Failed to initialize admin queue: %d\n", ret);
    goto free_ctrl;
  }

  /* Identify controller */
  ret = nvme_identify_ctrl(bar0, &axiio_ctrl->admin_q, &pdev->dev, NULL);
  if (ret < 0) {
    pr_warn("nvme_axiio: Failed to identify controller: %d\n", ret);
    /* Continue anyway - not fatal */
  }

  /* Try to get P2P IOVA info (for QEMU emulated devices) */
  axiio_ctrl->using_iova = false;
  if (is_qemu_emulated_nvme(pdev)) {
    /* Get admin queue (QID 0) IOVA info first */
    ret = nvme_get_p2p_iova_info(bar0, &axiio_ctrl->admin_q, &pdev->dev,
                                 0, /* queue_id = 0 (admin) */
                                 &axiio_ctrl->p2p_iova);
    if (ret == 0) {
      axiio_ctrl->using_iova = true;
      pr_info("nvme_axiio: ✅ Using IOVA addresses for GPU access\n");
      pr_info("  Note: These are admin queue IOVAs\n");
      pr_info("  I/O queue IOVAs will be retrieved when queues are created\n");
    } else {
      pr_warn("nvme_axiio: QEMU detected but P2P IOVA unavailable\n");
      pr_warn("  Will fall back to physical addresses\n");
    }
  }

  pr_info("nvme_axiio: ✓ Controller initialized and ready\n");
  pr_info("  Admin queue: SQ/CQ size=64 entries\n");
  pr_info("  Max I/O queue size: %u entries\n", axiio_ctrl->max_queue_entries);
  pr_info("  Controller is now under AXIIO control\n");
  pr_info("  WARNING: Device is no longer accessible via /dev/nvmeX\n");

  /* Store device reference */
  axiio_bound_pci_dev = pdev;
  pci_set_drvdata(pdev, axiio_ctrl);

  return 0;

free_ctrl:
  kfree(axiio_ctrl);
  axiio_ctrl = NULL;
unmap_bar0:
  iounmap(bar0);

release_regions:
  pci_release_regions(pdev);
  pci_disable_device(pdev);
  return ret;
}

/*
 * PCI remove function - called when device is unbound
 */
static void nvme_axiio_pci_remove(struct pci_dev* pdev) {
  struct axiio_controller* ctrl;

  pr_info("nvme_axiio: PCI remove called for device %s\n", pci_name(pdev));

  /* Get controller context from driver data */
  ctrl = pci_get_drvdata(pdev);
  if (ctrl) {
    /* Shutdown admin queue and controller */
    nvme_shutdown_admin_queue(&pdev->dev, ctrl->bar0, &ctrl->admin_q);

    /* Unmap BAR0 */
    if (ctrl->bar0) {
      iounmap(ctrl->bar0);
    }

    /* Free controller context */
    kfree(ctrl);
  }

  /* Release PCI resources */
  pci_release_regions(pdev);
  pci_clear_master(pdev);
  pci_disable_device(pdev);

  /* Clear global references */
  if (axiio_bound_pci_dev == pdev) {
    axiio_bound_pci_dev = NULL;
  }
  axiio_ctrl = NULL;

  pr_info("nvme_axiio: ✓ Device %s released\n", pci_name(pdev));
  pr_info("  Controller shut down cleanly\n");
  pr_info("  Device can now be bound back to kernel nvme driver\n");
}

/*
 * PCI driver structure
 */
static struct pci_driver nvme_axiio_pci_driver = {
  .name = "nvme_axiio",
  .id_table = nvme_axiio_pci_ids,
  .probe = nvme_axiio_pci_probe,
  .remove = nvme_axiio_pci_remove,
};

/*
 * Register PCI driver
 */
static inline int nvme_axiio_register_pci_driver(void) {
  int ret;

  ret = pci_register_driver(&nvme_axiio_pci_driver);
  if (ret) {
    pr_err("nvme_axiio: Failed to register PCI driver: %d\n", ret);
    return ret;
  }

  pr_info("nvme_axiio: PCI driver registered\n");
  pr_info("  Devices can now be bound via sysfs:\n");
  pr_info("    echo 0000:XX:00.0 > /sys/bus/pci/drivers/nvme_axiio/bind\n");

  return 0;
}

/*
 * Unregister PCI driver
 */
static inline void nvme_axiio_unregister_pci_driver(void) {
  pci_unregister_driver(&nvme_axiio_pci_driver);
  pr_info("nvme_axiio: PCI driver unregistered\n");
}

/*
 * Get the bound PCI device (if any)
 */
static inline struct pci_dev* nvme_axiio_get_bound_device(void) {
  return axiio_bound_pci_dev;
}

/*
 * Get the controller context (if bound)
 */
static inline struct axiio_controller* nvme_axiio_get_controller(void) {
  return axiio_ctrl;
}

/*
 * Create I/O queues using admin commands
 */
static inline int nvme_axiio_create_io_queues(u16 qid, u16 qsize,
                                              dma_addr_t sq_dma,
                                              dma_addr_t cq_dma) {
  struct axiio_controller* ctrl = nvme_axiio_get_controller();
  int ret;

  if (!ctrl || !ctrl->admin_q.sq_virt) {
    pci_err(ctrl->pdev, "nvme_axiio: Controller not initialized\n");
    return -ENODEV;
  }

  /* Try to delete existing queues first (in case of previous crash) */
  pci_info(ctrl->pdev,
           "nvme_axiio: Cleaning up any existing queues (qid=%u)...\n", qid);
  nvme_delete_io_sq_cmd(ctrl->bar0, &ctrl->admin_q, qid); // Ignore error
  nvme_delete_io_cq_cmd(ctrl->bar0, &ctrl->admin_q, qid); // Ignore error

  /* Create CQ first */
  ret = nvme_create_io_cq_cmd(ctrl->bar0, &ctrl->admin_q, qid, qsize, cq_dma,
                              0);
  if (ret < 0) {
    pci_err(ctrl->pdev, "nvme_axiio: Failed to create I/O CQ %u: %d\n", qid,
            ret);
    return ret;
  }

  pci_info(ctrl->pdev, "nvme_axiio: ✓ I/O CQ %u created\n", qid);

  /* Create SQ */
  ret = nvme_create_io_sq_cmd(ctrl->bar0, &ctrl->admin_q, qid, qid, qsize,
                              sq_dma);
  if (ret < 0) {
    pci_err(ctrl->pdev, "nvme_axiio: Failed to create I/O SQ %u: %d\n", qid,
            ret);
    /* Try to clean up CQ */
    nvme_delete_io_cq_cmd(ctrl->bar0, &ctrl->admin_q, qid);
    return ret;
  }

  pr_info("nvme_axiio: ✓ I/O SQ %u created\n", qid);
  pr_info("nvme_axiio: ✓ I/O queue pair %u ready for GPU-direct I/O!\n", qid);

  return 0;
}

#endif /* NVME_AXIIO_PCI_DRIVER_H */
