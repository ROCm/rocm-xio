/* SPDX-License-Identifier: GPL-2.0 */
/*
 * NVMe AXIIO Kernel Module
 *
 * Provides userspace access to NVMe queues and doorbells for direct GPU I/O.
 * Creates /dev/nvme-axiio character device with custom ioctls.
 *
 * This module does NOT replace the nvme driver - it works alongside it.
 */

#include "nvme_axiio.h"

#include <linux/blk-mq.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/dma-mapping.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/nvme.h>
#include <linux/pci.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/memremap.h>

#include "nvme_axiio_pci_driver.h"
#include "nvme_doorbell_dmabuf.h" /* dmabuf export for GPU-direct! */
#include "nvme_gpu_doorbell.h"
#include "nvme_gpu_integration.h" /* GPU MMU registration */

#define NVME_AXIIO_NAME "nvme-axiio"
#define NVME_AXIIO_CLASS "nvme_axiio_class"

/* Module parameters */
static int target_nvme_major = 241; /* Default NVMe major number */
module_param(target_nvme_major, int, 0444);
MODULE_PARM_DESC(target_nvme_major, "Target NVMe device major number");

static int target_nvme_minor = 0; /* Default to nvme0 */
module_param(target_nvme_minor, int, 0444);
MODULE_PARM_DESC(target_nvme_minor, "Target NVMe device minor number");

/* Character device state */
static dev_t axiio_dev;
static struct cdev axiio_cdev;
static struct class* axiio_class;
static struct device* axiio_device;

/* DMA buffer tracking */
struct dma_buffer_entry {
  struct list_head list;
  void* virt_addr;
  dma_addr_t dma_addr;
  size_t size;
};

/* Per-open file state */
struct axiio_file_ctx {
  struct pci_dev* pci_dev;   /* Associated PCI device */
  void __iomem* bar0;        /* Mapped BAR0 */
  resource_size_t bar0_phys; /* BAR0 physical address */
  resource_size_t bar0_size; /* BAR0 size */
  u32 doorbell_stride;       /* Doorbell stride from CAP register */

  /* DMA allocations */
  void* sq_virt;
  dma_addr_t sq_dma;
  size_t sq_size;

  void* cq_virt;
  dma_addr_t cq_dma;
  size_t cq_size;

  u16 queue_id;
  bool queue_created;

  /* GPU integration */
  struct nvme_gpu_mapping gpu_mapping; /* GPU doorbell mapping context */

  /* Data buffer allocations */
  struct list_head dma_buffers; /* List of allocated DMA buffers */
  struct mutex dma_lock;        /* Protect DMA buffer list */
};

/*
 * Find NVMe PCI device by major/minor number
 */
static struct pci_dev* find_nvme_pci_device(int major, int minor) {
  struct pci_dev* pdev = NULL;

  /* First, check if we have a PCI-bound device */
  pdev = nvme_axiio_get_bound_device();
  if (pdev) {
    pr_info("nvme_axiio: Using PCI-bound device: %s\n", pci_name(pdev));
    pci_dev_get(pdev); /* Take reference */
    return pdev;
  }

  /* Fallback: search for NVMe devices (original behavior) */
  pr_info(
    "nvme_axiio: No PCI-bound device, searching for NVMe PCI devices...\n");

  /* Iterate over NVMe controllers by PCI class code (01:08:02) */
  /* pci_get_class expects class code in bits [31:8], so 0x0108 becomes
   * 0x01080000 */
  while ((pdev = pci_get_class(0x01080000, pdev)) != NULL) {
    pr_info("nvme_axiio: Found NVMe device: %s (class 0x%08x)\n",
            pci_name(pdev), pdev->class);
    /* Return the first NVMe controller found */
    /* TODO: Match against major/minor to find specific device */
    return pdev;
  }

  pr_info("nvme_axiio: pci_get_class returned NULL\n");

  /* Try alternative: iterate all devices using for_each_pci_dev */
  pr_info("nvme_axiio: Trying for_each_pci_dev scan...\n");
  for_each_pci_dev(pdev) {
    /* Class format in pdev->class: bits [23:16]=class, [15:8]=subclass,
     * [7:0]=prog-if */
    /* NVMe is class 0x01, subclass 0x08, prog-if 0x02 -> 0x00010802 */
    /* Mask out revision, check class+subclass: (class >> 8) == 0x0108 */
    if ((pdev->class >> 8) == 0x0108) {
      pr_info("nvme_axiio: ✓ Found NVMe device: %s (class 0x%08x)\n",
              pci_name(pdev), pdev->class);
      pci_dev_get(pdev); /* Take reference */
      return pdev;
    }
  }

  pr_err("nvme_axiio: No NVMe PCI device found\n");
  return NULL;
}

/*
 * Open device - find and map NVMe controller
 */
static int axiio_open(struct inode* inode, struct file* filp) {
  struct axiio_file_ctx* ctx;
  struct pci_dev* pdev;
  int ret;

  pr_info("nvme_axiio: Device opened\n");

  ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
  if (!ctx)
    return -ENOMEM;

  /* Initialize DMA buffer tracking */
  INIT_LIST_HEAD(&ctx->dma_buffers);
  mutex_init(&ctx->dma_lock);

  /* Find NVMe PCI device */
  pdev = find_nvme_pci_device(target_nvme_major, target_nvme_minor);
  if (!pdev) {
    pr_err("nvme_axiio: Could not find NVMe PCI device\n");
    kfree(ctx);
    return -ENODEV;
  }

  ctx->pci_dev = pdev;

  /* Get BAR0 info */
  ret = pci_enable_device(pdev);
  if (ret) {
    pr_err("nvme_axiio: Failed to enable PCI device\n");
    pci_dev_put(pdev);
    kfree(ctx);
    return ret;
  }

  pci_set_master(pdev);

  ctx->bar0_phys = pci_resource_start(pdev, 0);
  ctx->bar0_size = pci_resource_len(pdev, 0);

  /* Map BAR0 */
  ctx->bar0 = pci_iomap(pdev, 0, 0);
  if (!ctx->bar0) {
    pr_err("nvme_axiio: Failed to map BAR0\n");
    pci_disable_device(pdev);
    pci_dev_put(pdev);
    kfree(ctx);
    return -ENOMEM;
  }

  /* Read doorbell stride from CAP register */
  {
    u64 cap = readq(ctx->bar0 + 0x00);        /* CAP at offset 0x00 */
    ctx->doorbell_stride = (cap >> 32) & 0xF; /* DSTRD in bits 35:32 */
    pr_info("nvme_axiio: CAP register = 0x%016llx\n", cap);
    pr_info("nvme_axiio: DSTRD (bits 35:32) = %u\n", ctx->doorbell_stride);
  }

  pr_info("nvme_axiio: BAR0 mapped at phys=0x%llx size=0x%llx stride=%u\n",
          (u64)ctx->bar0_phys, (u64)ctx->bar0_size, ctx->doorbell_stride);

  filp->private_data = ctx;
  return 0;
}

/*
 * Release device - cleanup resources
 */
static int axiio_release(struct inode* inode, struct file* filp) {
  struct axiio_file_ctx* ctx = filp->private_data;

  pr_info("nvme_axiio: Device closed\n");

  if (ctx) {
    /* Free allocated DMA buffers */
    {
      struct dma_buffer_entry *entry, *tmp;
      mutex_lock(&ctx->dma_lock);
      list_for_each_entry_safe(entry, tmp, &ctx->dma_buffers, list) {
        pr_info("nvme_axiio: Freeing DMA buffer (size=%zu)\n", entry->size);
        dma_free_coherent(&ctx->pci_dev->dev, entry->size, entry->virt_addr,
                          entry->dma_addr);
        list_del(&entry->list);
        kfree(entry);
      }
      mutex_unlock(&ctx->dma_lock);
      mutex_destroy(&ctx->dma_lock);
    }

    /* Free DMA buffers (QEMU GPA buffers don't need freeing) */
    if (ctx->sq_virt) {
      /* Only free if it's DMA-allocated (not QEMU GPA) */
      if (ctx->sq_dma < 0x1000000000ULL) {
        dma_free_coherent(&ctx->pci_dev->dev, ctx->sq_size, ctx->sq_virt,
                          ctx->sq_dma);
      } else {
        pr_info("nvme_axiio: QEMU GPA buffer (SQ GPA=0x%llx) - no cleanup needed\n", ctx->sq_dma);
      }
    }
    if (ctx->cq_virt) {
      /* Only free if it's DMA-allocated (not QEMU GPA) */
      if (ctx->cq_dma < 0x1000000000ULL) {
        dma_free_coherent(&ctx->pci_dev->dev, ctx->cq_size, ctx->cq_virt,
                          ctx->cq_dma);
      } else {
        pr_info("nvme_axiio: QEMU GPA buffer (CQ GPA=0x%llx) - no cleanup needed\n", ctx->cq_dma);
      }
    }

    /* Unmap BAR0 */
    if (ctx->bar0)
      pci_iounmap(ctx->pci_dev, ctx->bar0);

    if (ctx->pci_dev) {
      pci_disable_device(ctx->pci_dev);
      pci_dev_put(ctx->pci_dev);
    }

    /* Clean up GPU mapping */
    if (ctx->gpu_mapping.gpu_file) {
      nvme_unmap_doorbell_from_gpu(&ctx->gpu_mapping);
    }

    kfree(ctx);
  }

  return 0;
}

/*
 * Calculate doorbell offset for a queue
 */
static u32 calc_doorbell_offset(u16 queue_id, bool is_sq, u32 dstrd) {
  u32 stride_bytes = (4 << dstrd); /* Convert 4-byte units to bytes */
  u32 doorbell_base = 0x1000;      /* Doorbells start at 0x1000 */
  u32 index = (queue_id * 2) + (is_sq ? 0 : 1);

  return doorbell_base + (index * stride_bytes);
}

/*
 * IOCTL: Create Queue
 */
static int axiio_ioctl_create_queue(
  struct axiio_file_ctx* ctx, struct nvme_axiio_queue_info __user* uinfo) {
  struct nvme_axiio_queue_info info;

  if (copy_from_user(&info, uinfo, sizeof(info)))
    return -EFAULT;

  pr_info("nvme_axiio: Creating queue qid=%u size=%u\n", info.queue_id,
          info.queue_size);

  ctx->sq_size = info.queue_size * 64; /* SQE is 64 bytes */
  ctx->cq_size = info.queue_size * 16; /* CQE is 16 bytes */

  /* Check if we should use QEMU's GPA addresses (IOVA mode) */
  if (nvme_axiio_get_controller()) {
    struct axiio_controller* ctrl = nvme_axiio_get_controller();

    if (ctrl->using_iova) {
      struct nvme_p2p_iova_info queue_iova;
      int ret;

      pr_info("nvme_axiio: Requesting IOVA/GPA info for queue %u...\n",
              info.queue_id);

      ret = nvme_get_p2p_iova_info(ctrl->bar0, &ctrl->admin_q,
                                   &ctx->pci_dev->dev,
                                   info.queue_id, &queue_iova);
      if (ret == 0 && queue_iova.sqe_gpa != 0) {
        /* Use QEMU's GPA addresses - these are guest physical addresses */
        pr_info("nvme_axiio: ✅ Using QEMU-provided GPA addresses:\n");
        pr_info("  SQE GPA:      0x%016llx\n", queue_iova.sqe_gpa);
        pr_info("  CQE GPA:      0x%016llx\n", queue_iova.cqe_gpa);
        pr_info("  Doorbell GPA: 0x%016llx\n", queue_iova.doorbell_gpa);

        /* For QEMU GPA addresses, we don't need kernel virtual addresses.
         * We'll map them directly to userspace via mmap using remap_pfn_range.
         * Set virt pointers to NULL to indicate we're using GPA directly. */
        ctx->sq_virt = NULL;  /* Will be mapped via mmap */
        ctx->cq_virt = NULL;  /* Will be mapped via mmap */

        /* Use GPA addresses as DMA addresses */
        ctx->sq_dma = queue_iova.sqe_gpa;
        ctx->cq_dma = queue_iova.cqe_gpa;

        pr_info("nvme_axiio: ✅ Using QEMU GPA buffers (will map via mmap):\n");
        pr_info("  SQE GPA: 0x%llx\n", ctx->sq_dma);
        pr_info("  CQE GPA: 0x%llx\n", ctx->cq_dma);

        /* Skip DMA allocation - we're using QEMU's buffers */
        goto use_qemu_buffers;
      } else {
        pr_warn("nvme_axiio: QEMU GPA addresses not available, using DMA alloc\n");
      }
    }
  }

  /* Fallback: Allocate DMA-coherent memory (for real hardware or if QEMU GPA unavailable) */
  ctx->sq_virt = dma_alloc_coherent(&ctx->pci_dev->dev, ctx->sq_size,
                                    &ctx->sq_dma, GFP_KERNEL);
  if (!ctx->sq_virt) {
    pr_err("nvme_axiio: Failed to allocate SQ DMA memory\n");
    return -ENOMEM;
  }

  ctx->cq_virt = dma_alloc_coherent(&ctx->pci_dev->dev, ctx->cq_size,
                                    &ctx->cq_dma, GFP_KERNEL);
  if (!ctx->cq_virt) {
    pr_err("nvme_axiio: Failed to allocate CQ DMA memory\n");
    dma_free_coherent(&ctx->pci_dev->dev, ctx->sq_size, ctx->sq_virt,
                      ctx->sq_dma);
    ctx->sq_virt = NULL;
    return -ENOMEM;
  }

  /* Zero out the queues */
  memset(ctx->sq_virt, 0, ctx->sq_size);
  memset(ctx->cq_virt, 0, ctx->cq_size);

use_qemu_buffers:

  /* Fill in return values */
  info.sq_dma_addr = ctx->sq_dma;
  info.cq_dma_addr = ctx->cq_dma;
  info.bar0_phys = ctx->bar0_phys;
  info.bar0_size = ctx->bar0_size;
  info.doorbell_stride = ctx->doorbell_stride;

  info.sq_doorbell_offset = calc_doorbell_offset(info.queue_id, true,
                                                 ctx->doorbell_stride);
  info.cq_doorbell_offset = calc_doorbell_offset(info.queue_id, false,
                                                 ctx->doorbell_stride);

  info.sq_doorbell_phys = ctx->bar0_phys + info.sq_doorbell_offset;
  info.cq_doorbell_phys = ctx->bar0_phys + info.cq_doorbell_offset;

  ctx->queue_id = info.queue_id;

  pr_info("nvme_axiio: Queue memory allocated successfully\n");
  pr_info("  SQ DMA: 0x%llx (size %zu)\n", (u64)ctx->sq_dma, ctx->sq_size);
  pr_info("  CQ DMA: 0x%llx (size %zu)\n", (u64)ctx->cq_dma, ctx->cq_size);
  pr_info("  SQ Doorbell: phys=0x%llx offset=0x%x\n", info.sq_doorbell_phys,
          info.sq_doorbell_offset);
  pr_info("  CQ Doorbell: phys=0x%llx offset=0x%x\n", info.cq_doorbell_phys,
          info.cq_doorbell_offset);

  /* If we have exclusive controller access, create queues via admin commands */
  if (nvme_axiio_get_controller()) {
    struct axiio_controller* ctrl = nvme_axiio_get_controller();
    int ret;

    pr_info("nvme_axiio: Creating I/O queues via admin commands...\n");
    ret = nvme_axiio_create_io_queues(info.queue_id, info.queue_size,
                                      ctx->sq_dma, ctx->cq_dma);
    if (ret < 0) {
      pr_err("nvme_axiio: Admin command failed: %d\n", ret);
      /* Clean up based on memory type */
      if (ctx->cq_virt && ctx->cq_dma < 0x1000000000ULL) {
        dma_free_coherent(&ctx->pci_dev->dev, ctx->cq_size, ctx->cq_virt,
                          ctx->cq_dma);
        ctx->cq_virt = NULL;
      }
      if (ctx->sq_virt && ctx->sq_dma < 0x1000000000ULL) {
        dma_free_coherent(&ctx->pci_dev->dev, ctx->sq_size, ctx->sq_virt,
                          ctx->sq_dma);
        ctx->sq_virt = NULL;
      }
      return ret;
    }

    /* If using IOVA mode, get IOVA addresses for this specific queue */
    if (ctrl->using_iova) {
      struct nvme_p2p_iova_info queue_iova;

      pr_info("nvme_axiio: Requesting IOVA info for queue %u...\n",
              info.queue_id);

      ret = nvme_get_p2p_iova_info(ctrl->bar0, &ctrl->admin_q,
                                   &ctx->pci_dev->dev,
                                   info.queue_id, &queue_iova);
      if (ret == 0) {
        pr_info("nvme_axiio: ✅ Got IOVA addresses for QID %u:\n",
                info.queue_id);
        pr_info("  SQE IOVA:      0x%016llx\n", queue_iova.sqe_iova);
        pr_info("  CQE IOVA:      0x%016llx\n", queue_iova.cqe_iova);
        pr_info("  Doorbell IOVA: 0x%016llx\n", queue_iova.doorbell_iova);

        /* Return IOVA addresses to userspace */
        info.sq_dma_addr = queue_iova.sqe_iova;
        info.cq_dma_addr = queue_iova.cqe_iova;
        info.sq_doorbell_phys = queue_iova.doorbell_iova;
        info.cq_doorbell_phys = queue_iova.doorbell_iova + 4;
      } else {
        pr_warn("nvme_axiio: Failed to get IOVA for QID %u, using physical\n",
                info.queue_id);
      }
    }
  } else {
    pr_warn("nvme_axiio: No exclusive controller access\n");
    pr_warn("  Queue memory allocated but not created on controller\n");
    pr_warn("  Userspace must use NVME_IOCTL_ADMIN_CMD to create queues\n");
  }

  ctx->queue_created = true;

  if (copy_to_user(uinfo, &info, sizeof(info)))
    return -EFAULT;

  return 0;
}

/*
 * IOCTL: Register User-Provided Queue Memory
 * Allows userspace to provide GPU-accessible memory (from hipHostMalloc) for
 * queues
 */
static int axiio_ioctl_register_user_queue(
  struct axiio_file_ctx* ctx, struct nvme_axiio_queue_info __user* uinfo) {
  struct nvme_axiio_queue_info info;

  if (copy_from_user(&info, uinfo, sizeof(info)))
    return -EFAULT;

  pr_info("nvme_axiio: Registering user-provided queue memory\n");
  pr_info("  Queue ID: %u\n", info.queue_id);
  pr_info("  User SQ DMA: 0x%llx\n", (unsigned long long)info.sq_dma_addr_user);
  pr_info("  User CQ DMA: 0x%llx\n", (unsigned long long)info.cq_dma_addr_user);

  /* Check if queues are already allocated */
  if (!ctx->queue_created) {
    pr_err("nvme_axiio: No queue exists to update. Create queue first!\n");
    return -EINVAL;
  }

  /* Free kernel-allocated queue memory since we'll use user memory */
  if (ctx->sq_virt) {
    pr_info("nvme_axiio: Freeing kernel-allocated SQ memory\n");
    dma_free_coherent(&ctx->pci_dev->dev, ctx->sq_size, ctx->sq_virt,
                      ctx->sq_dma);
    ctx->sq_virt = NULL;
  }
  if (ctx->cq_virt) {
    pr_info("nvme_axiio: Freeing kernel-allocated CQ memory\n");
    dma_free_coherent(&ctx->pci_dev->dev, ctx->cq_size, ctx->cq_virt,
                      ctx->cq_dma);
    ctx->cq_virt = NULL;
  }

  /* Use user-provided physical addresses */
  ctx->sq_dma = info.sq_dma_addr_user;
  ctx->cq_dma = info.cq_dma_addr_user;

  pr_info("nvme_axiio: Queue memory updated to user-provided addresses\n");
  pr_info("  SQ DMA: 0x%llx\n", (unsigned long long)ctx->sq_dma);
  pr_info("  CQ DMA: 0x%llx\n", (unsigned long long)ctx->cq_dma);

  /* Note: We don't update the NVMe controller here.
   * The controller will be configured with these addresses during next
   * submission. The user must ensure the physical addresses are valid and
   * DMA-accessible.
   */

  return 0;
}

/*
 * IOCTL: Map Doorbell for GPU Access
 * Returns bus addresses that GPU can use for peer-to-peer MMIO
 */
static int axiio_ioctl_map_doorbell_for_gpu(
  struct axiio_file_ctx* ctx, struct nvme_axiio_doorbell_mapping __user* umap) {
  struct nvme_axiio_doorbell_mapping map;
  u32 stride_bytes;
  u32 doorbell_base = 0x1000;

  if (copy_from_user(&map, umap, sizeof(map)))
    return -EFAULT;

  pr_info("nvme_axiio: Mapping doorbell for GPU access (QID %u)\n",
          map.queue_id);

  /* BAR0 bus address - this is what GPU needs for P2P access */
  map.bar0_bus_addr = pci_resource_start(ctx->pci_dev, 0);
  map.bar0_phys = ctx->bar0_phys;
  map.bar0_size = ctx->bar0_size;

  /* Calculate doorbell offset for this queue */
  stride_bytes = (4 << ctx->doorbell_stride);
  map.doorbell_offset = doorbell_base + ((map.queue_id * 2) * stride_bytes);

  /* Bus address = BAR0 bus address + offset */
  map.doorbell_bus_addr = map.bar0_bus_addr + map.doorbell_offset;
  map.doorbell_phys = map.bar0_phys + map.doorbell_offset;

  pr_info("nvme_axiio: Doorbell mapping for QID %u:\n", map.queue_id);
  pr_info("  BAR0 bus address: 0x%llx (for GPU P2P)\n", map.bar0_bus_addr);
  pr_info("  BAR0 physical: 0x%llx (for CPU)\n", map.bar0_phys);
  pr_info("  Doorbell offset: 0x%x\n", map.doorbell_offset);
  pr_info("  Doorbell bus address: 0x%llx (GPU should use this)\n",
          map.doorbell_bus_addr);

  if (copy_to_user(umap, &map, sizeof(map)))
    return -EFAULT;

  return 0;
}

/*
 * IOCTL: Get GPU Doorbell Mapping Info
 *
 * NOW WITH GPU FD SUPPORT!
 * Registers the doorbell with GPU MMU for true GPU-direct access.
 */
static int axiio_ioctl_get_gpu_doorbell(
  struct axiio_file_ctx* ctx, struct nvme_gpu_doorbell_info __user* uinfo) {
  struct axiio_controller* ctrl = nvme_axiio_get_controller();
  struct nvme_gpu_doorbell_info info;
  int ret;

  if (copy_from_user(&info, uinfo, sizeof(info)))
    return -EFAULT;

  if (!ctrl || !ctrl->bar0) {
    pr_err("nvme_axiio: No exclusive controller access\n");
    return -ENODEV;
  }

  /* Calculate doorbell physical address */
  info.doorbell_phys = nvme_get_doorbell_phys(ctrl->bar0_phys, info.queue_id,
                                              info.is_sq,
                                              ctrl->doorbell_stride);
  info.bar0_phys = ctrl->bar0_phys;
  info.doorbell_offset = info.doorbell_phys - ctrl->bar0_phys;

  /* For mmap: use pgoff=3 for GPU doorbell */
  info.mmap_offset = 3; /* pgoff */
  info.mmap_size = PAGE_SIZE;

  pr_info("nvme_axiio: GPU doorbell setup for QID %u (%s):\n", info.queue_id,
          info.is_sq ? "SQ" : "CQ");
  pr_info("  Doorbell phys: 0x%llx\n", info.doorbell_phys);
  pr_info("  GPU FD: %d\n", info.gpu_fd);

  /* If GPU FD provided, set up GPU integration */
  if (info.gpu_fd >= 0) {
    pr_info("nvme_axiio: 🚀 Setting up GPU-direct doorbell...\n");

    ret = nvme_map_doorbell_for_gpu(&ctx->gpu_mapping, info.gpu_fd,
                                    info.doorbell_phys, info.mmap_size);
    if (ret < 0) {
      pr_err("nvme_axiio: GPU mapping setup failed: %d\n", ret);
      /* Continue anyway - fallback to regular mapping */
    } else {
      pr_info("nvme_axiio: ✓ GPU context prepared for doorbell\n");
    }
  }

  pr_info("  Use mmap(fd, PAGE_SIZE, offset=%llu*PAGE_SIZE)\n",
          info.mmap_offset);

  if (copy_to_user(uinfo, &info, sizeof(info)))
    return -EFAULT;

  return 0;
}

/*
 * IOCTL: Allocate DMA buffer
 * Allocates DMA-coherent memory for data transfers
 */
static int axiio_ioctl_alloc_dma(struct axiio_file_ctx* ctx,
                                 struct nvme_axiio_dma_buffer __user* uinfo) {
  struct nvme_axiio_dma_buffer info;
  void* virt_addr;
  dma_addr_t dma_addr;

  if (copy_from_user(&info, uinfo, sizeof(info)))
    return -EFAULT;

  if (!ctx->pci_dev) {
    pr_err("nvme_axiio: No PCI device for DMA allocation\n");
    return -ENODEV;
  }

  pr_info("nvme_axiio: Allocating DMA buffer (size=%llu bytes)\n", info.size);

  /* Allocate DMA-coherent memory */
  virt_addr = dma_alloc_coherent(&ctx->pci_dev->dev, info.size, &dma_addr,
                                 GFP_KERNEL);
  if (!virt_addr) {
    pr_err("nvme_axiio: Failed to allocate DMA buffer\n");
    return -ENOMEM;
  }

  /* Zero out the buffer */
  memset(virt_addr, 0, info.size);

  /* Track this buffer for cleanup */
  {
    struct dma_buffer_entry* entry = kmalloc(sizeof(*entry), GFP_KERNEL);
    if (entry) {
      entry->virt_addr = virt_addr;
      entry->dma_addr = dma_addr;
      entry->size = info.size;

      mutex_lock(&ctx->dma_lock);
      list_add_tail(&entry->list, &ctx->dma_buffers);
      mutex_unlock(&ctx->dma_lock);
    }
  }

  pr_info("nvme_axiio: ✓ DMA buffer allocated\n");
  pr_info("  Virtual: %p\n", virt_addr);
  pr_info("  DMA:     0x%llx\n", (u64)dma_addr);

  /* Return addresses to userspace */
  info.dma_addr = dma_addr;
  info.virt_addr = (u64)virt_addr;

  if (copy_to_user(uinfo, &info, sizeof(info)))
    return -EFAULT;

  return 0;
}

/*
 * Export doorbell as dmabuf (Standard Linux GPU-Direct!)
 */
static int axiio_ioctl_export_doorbell_dmabuf(
  struct axiio_file_ctx* ctx,
  struct nvme_doorbell_dmabuf_export __user* uinfo) {
  struct axiio_controller* ctrl = nvme_axiio_get_controller();
  struct nvme_doorbell_dmabuf_export info;
  resource_size_t doorbell_phys;
  int ret;

  if (copy_from_user(&info, uinfo, sizeof(info)))
    return -EFAULT;

  if (!ctrl || !ctrl->bar0) {
    pr_err("nvme_axiio: No exclusive controller access\n");
    return -ENODEV;
  }

  /* Calculate doorbell physical address */
  doorbell_phys = nvme_get_doorbell_phys(ctrl->bar0_phys, info.queue_id,
                                         info.is_sq, ctrl->doorbell_stride);

  pr_info("nvme_axiio: 🚀🚀🚀 EXPORTING DOORBELL AS DMABUF! 🚀🚀🚀\n");
  pr_info("  QID %u (%s)\n", info.queue_id, info.is_sq ? "SQ" : "CQ");
  pr_info("  Doorbell phys: 0x%llx\n", (u64)doorbell_phys);

  /* Export as dmabuf! */
  ret = nvme_export_doorbell_dmabuf(ctrl->pdev, doorbell_phys, PAGE_SIZE,
                                    &info.dmabuf_fd);
  if (ret < 0) {
    pci_err(ctrl->pdev, "nvme_axiio: dmabuf export failed: %d\n", ret);
    return ret;
  }

  info.doorbell_phys = doorbell_phys;
  info.size = PAGE_SIZE;

  pci_info(ctrl->pdev, "nvme_axiio: ✓✓✓ SUCCESS! dmabuf FD = %d ✓✓✓\n",
           info.dmabuf_fd);
  pci_info(ctrl->pdev, "  Userspace can now pass this FD to GPU!\n");
  pci_info(ctrl->pdev, "  GPU driver will map into GPU address space!\n");
  pci_info(ctrl->pdev, "  TRUE GPU-DIRECT ACHIEVED! 🎉\n");

  if (copy_to_user(uinfo, &info, sizeof(info)))
    return -EFAULT;

  return 0;
}

/*
 * IOCTL handler
 */
static long axiio_ioctl(struct file* filp, unsigned int cmd,
                        unsigned long arg) {
  struct axiio_file_ctx* ctx = filp->private_data;

  if (!ctx)
    return -EINVAL;

  switch (cmd) {
    case NVME_AXIIO_CREATE_QUEUE:
      return axiio_ioctl_create_queue(
        ctx, (struct nvme_axiio_queue_info __user*)arg);

    case NVME_AXIIO_DELETE_QUEUE:
      /* TODO: Implement queue deletion */
      return -ENOTTY;

    case NVME_AXIIO_ALLOC_DMA:
      return axiio_ioctl_alloc_dma(ctx,
                                   (struct nvme_axiio_dma_buffer __user*)arg);

    case NVME_AXIIO_GET_DEVICE_INFO:
      /* TODO: Implement device info query */
      return -ENOTTY;

    case NVME_AXIIO_REGISTER_USER_QUEUE:
      return axiio_ioctl_register_user_queue(
        ctx, (struct nvme_axiio_queue_info __user*)arg);

    case NVME_AXIIO_MAP_DOORBELL_FOR_GPU:
      return axiio_ioctl_map_doorbell_for_gpu(
        ctx, (struct nvme_axiio_doorbell_mapping __user*)arg);

    case NVME_AXIIO_GET_GPU_DOORBELL:
      return axiio_ioctl_get_gpu_doorbell(
        ctx, (struct nvme_gpu_doorbell_info __user*)arg);

    case NVME_AXIIO_EXPORT_DOORBELL_DMABUF:
      /* TODO: dmabuf export requires DMA_BUF namespace */
      return -ENOTTY;

    default:
      return -ENOTTY;
  }
}

/*
 * mmap handler - allow userspace to map queue memory
 */
static int axiio_mmap(struct file* filp, struct vm_area_struct* vma) {
  struct axiio_file_ctx* ctx = filp->private_data;
  unsigned long size = vma->vm_end - vma->vm_start;
  int ret;

  if (!ctx || !ctx->queue_created)
    return -EINVAL;

  /* Determine what to map based on offset (vm_pgoff is in page units) */
  if (vma->vm_pgoff == 0) {
    /* Map SQ */
    if (size > ctx->sq_size)
      return -EINVAL;

    pr_info("nvme_axiio: mmap SQ (size=%lu)\n", size);

    /* Check if we're using QEMU's GPA addresses */
    if (nvme_axiio_get_controller() &&
        nvme_axiio_get_controller()->using_iova &&
        (ctx->sq_dma >= 0x1000000000ULL)) {
      /* Using QEMU GPA - map directly using remap_pfn_range */
      /* GPA is already a guest physical address, convert to PFN */
      unsigned long pfn = ctx->sq_dma >> PAGE_SHIFT;
      pr_info("nvme_axiio: Mapping QEMU GPA buffer (GPA=0x%llx, pfn=0x%lx)\n",
              ctx->sq_dma, pfn);

      /* Use normal page protection (not write-combine) for RAM */
      vm_flags_set(vma, VM_PFNMAP | VM_DONTEXPAND | VM_DONTDUMP);

      ret = remap_pfn_range(vma, vma->vm_start, pfn, size, vma->vm_page_prot);
      if (ret < 0) {
        pr_err("nvme_axiio: remap_pfn_range failed for SQ: %d\n", ret);
        return ret;
      }
      pr_info("nvme_axiio: ✅ SQ mapped from QEMU GPA\n");
    } else {
      /* Use dma_mmap_coherent for DMA-allocated memory */
      vma->vm_pgoff = 0; /* dma_mmap_coherent expects this to be 0 */
      ret = dma_mmap_coherent(&ctx->pci_dev->dev, vma, ctx->sq_virt, ctx->sq_dma,
                              ctx->sq_size);
      if (ret < 0) {
        pr_err("nvme_axiio: dma_mmap_coherent failed for SQ: %d\n", ret);
        return ret;
      }
    }

  } else if (vma->vm_pgoff == 1) {
    /* Map CQ */
    if (size > ctx->cq_size)
      return -EINVAL;

    pr_info("nvme_axiio: mmap CQ (size=%lu)\n", size);

    /* Check if we're using QEMU's GPA addresses */
    if (nvme_axiio_get_controller() &&
        nvme_axiio_get_controller()->using_iova &&
        (ctx->cq_dma >= 0x1000000000ULL)) {
      /* Using QEMU GPA - map directly using remap_pfn_range */
      /* GPA is already a guest physical address, convert to PFN */
      unsigned long pfn = ctx->cq_dma >> PAGE_SHIFT;
      pr_info("nvme_axiio: Mapping QEMU GPA buffer (GPA=0x%llx, pfn=0x%lx)\n",
              ctx->cq_dma, pfn);

      /* Use normal page protection (not write-combine) for RAM */
      vm_flags_set(vma, VM_PFNMAP | VM_DONTEXPAND | VM_DONTDUMP);

      ret = remap_pfn_range(vma, vma->vm_start, pfn, size, vma->vm_page_prot);
      if (ret < 0) {
        pr_err("nvme_axiio: remap_pfn_range failed for CQ: %d\n", ret);
        return ret;
      }
      pr_info("nvme_axiio: ✅ CQ mapped from QEMU GPA\n");
    } else {
      /* Use dma_mmap_coherent for DMA-allocated memory */
      vma->vm_pgoff = 0; /* dma_mmap_coherent expects this to be 0 */
      ret = dma_mmap_coherent(&ctx->pci_dev->dev, vma, ctx->cq_virt, ctx->cq_dma,
                              ctx->cq_size);
      if (ret < 0) {
        pr_err("nvme_axiio: dma_mmap_coherent failed for CQ: %d\n", ret);
        return ret;
      }
    }

  } else if (vma->vm_pgoff == 2) {
    /* Map doorbell BAR region for GPU access */
    struct axiio_controller* ctrl = nvme_axiio_get_controller();
    unsigned long pfn;
    unsigned long doorbell_offset;

    /* In QEMU P2P/IOVA mode, we need to use io_remap_pfn_range with the
     * IOVA address so the GPU can access it. QEMU maps these IOVAs in the
     * IOMMU for GPU P2P access. */
    if (ctrl && ctrl->using_iova) {
      /* QEMU P2P: Use IOVA address (page-aligned) */
      pfn = ctrl->p2p_iova.doorbell_iova >> PAGE_SHIFT;
      pr_info(
        "nvme_axiio: mmap IOVA doorbell for GPU (queue_id=%u, "
        "iova=0x%llx, pfn=0x%lx)\n",
        ctx->queue_id, ctrl->p2p_iova.doorbell_iova, pfn);
    } else {
      /* Physical hardware: Use normal BAR0 address */
      doorbell_offset = 0x1000 + (ctx->queue_id * 2 * ctx->doorbell_stride);
      unsigned long page_offset = doorbell_offset & PAGE_MASK;
      pfn = (ctx->bar0_phys + page_offset) >> PAGE_SHIFT;
      pr_info(
        "nvme_axiio: mmap doorbell BAR (queue_id=%u, phys=0x%llx, "
        "pfn=0x%lx)\n",
        ctx->queue_id, ctx->bar0_phys + doorbell_offset, pfn);
    }

    /* Set GPU-compatible page protection flags */
    /* Write-combine: Allows GPU to write efficiently to PCIe MMIO */
    vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);

    /* Mark as device I/O memory (use vm_flags_set for kernel 5.19+) */
    vm_flags_set(vma, VM_IO | VM_PFNMAP | VM_DONTEXPAND | VM_DONTDUMP);

    /* Map physical doorbell pages to userspace */
    /* This mapping will be GPU-accessible! */
    ret = remap_pfn_range(vma, vma->vm_start, pfn, size, vma->vm_page_prot);
    if (ret < 0) {
      pr_err("nvme_axiio: remap_pfn_range failed for doorbell: %d\n", ret);
      return ret;
    }

    pr_info(
      "nvme_axiio: ✓ Doorbell mapped with GPU-compatible flags (WC + IO)\n");

  } else if (vma->vm_pgoff == 3) {
    /* Map GPU doorbell with GPU MMU registration! */

    pr_info("nvme_axiio: mmap GPU doorbell (GPU-DIRECT mode)\n");
    pr_info("  Queue ID: %u\n", ctx->queue_id);

    /* Check if GPU context was set up via IOCTL */
    if (ctx->gpu_mapping.gpu_file) {
      pr_info("nvme_axiio: 🚀 Using GPU-aware mapping!\n");
      pr_info("  GPU file present - doorbell will be GPU-accessible\n");

      /* Use GPU-aware mmap - pass queue ID and PCI device for IOVA lookup */
      ret = nvme_mmap_doorbell_for_gpu(vma, &ctx->gpu_mapping,
                                      ctx->queue_id, ctx->pci_dev);
      if (ret < 0) {
        pr_err("nvme_axiio: GPU-aware mmap failed: %d\n", ret);
        /* Fall through to regular mapping */
      } else {
        pr_info("nvme_axiio: ✓ TRUE GPU-DIRECT doorbell mapped!\n");
        pr_info("  GPU VA: 0x%lx\n", vma->vm_start);
        pr_info("  GPU can now write directly to NVMe doorbell!\n");
        return 0;
      }
    }

    /* Fallback: Regular mapping (no GPU MMU registration) */
    pr_info("nvme_axiio: Using standard mapping (no GPU FD provided)\n");

    struct axiio_controller* ctrl = nvme_axiio_get_controller();
    resource_size_t doorbell_phys;

    if (!ctrl || !ctrl->bar0) {
      pr_err("nvme_axiio: No exclusive controller for doorbell mapping\n");
      return -ENODEV;
    }

    /* Calculate doorbell physical address */
    doorbell_phys = nvme_get_doorbell_phys(ctrl->bar0_phys, ctx->queue_id,
                                           true, /* SQ doorbell */
                                           ctrl->doorbell_stride);

    pr_info("  Doorbell phys: 0x%llx\n", (u64)doorbell_phys);

    /* Setup standard doorbell mapping */
    ret = nvme_setup_gpu_doorbell_vma(vma, doorbell_phys, size);
    if (ret < 0) {
      pr_err("nvme_axiio: Failed to setup doorbell VMA: %d\n", ret);
      return ret;
    }

    pr_info("nvme_axiio: ✓ Standard doorbell mapped\n");

  } else if (vma->vm_pgoff >= 4) {
    /* Map DMA buffers (offset 4+)
     * Offset 4 = first DMA buffer (read buffer)
     * Offset 5 = second DMA buffer (write buffer)
     * etc.
     */
    struct dma_buffer_entry* entry = NULL;
    int buffer_index = vma->vm_pgoff - 4;
    int found_index = 0;

    pr_info("nvme_axiio: mmap DMA buffer (index=%d, size=%lu)\n", buffer_index,
            size);

    /* Find the DMA buffer at the requested index */
    mutex_lock(&ctx->dma_lock);
    list_for_each_entry(entry, &ctx->dma_buffers, list) {
      if (found_index == buffer_index) {
        break;
      }
      found_index++;
    }
    mutex_unlock(&ctx->dma_lock);

    if (!entry || found_index != buffer_index) {
      pr_err("nvme_axiio: DMA buffer index %d not found\n", buffer_index);
      return -EINVAL;
    }

    if (size > entry->size) {
      pr_err("nvme_axiio: Requested size %lu exceeds buffer size %zu\n", size,
             entry->size);
      return -EINVAL;
    }

    /* Use dma_mmap_coherent for DMA-allocated memory */
    vma->vm_pgoff = 0; /* dma_mmap_coherent expects this to be 0 */
    ret = dma_mmap_coherent(&ctx->pci_dev->dev, vma, entry->virt_addr,
                            entry->dma_addr, size);
    if (ret < 0) {
      pr_err("nvme_axiio: dma_mmap_coherent failed for DMA buffer: %d\n", ret);
      return ret;
    }

    pr_info("nvme_axiio: ✓ DMA buffer mapped (index=%d, DMA=0x%llx)\n",
            buffer_index, (u64)entry->dma_addr);

  } else {
    return -EINVAL;
  }

  return 0;
}

/* File operations */
static const struct file_operations axiio_fops = {
  .owner = THIS_MODULE,
  .open = axiio_open,
  .release = axiio_release,
  .unlocked_ioctl = axiio_ioctl,
  .mmap = axiio_mmap,
};

/*
 * Module initialization
 */
static int __init nvme_axiio_init(void) {
  int ret;

  pr_info("nvme_axiio: Initializing NVMe AXIIO kernel module\n");

  /* Allocate character device number */
  ret = alloc_chrdev_region(&axiio_dev, 0, 1, NVME_AXIIO_NAME);
  if (ret < 0) {
    pr_err("nvme_axiio: Failed to allocate device number\n");
    return ret;
  }

  /* Initialize character device */
  cdev_init(&axiio_cdev, &axiio_fops);
  axiio_cdev.owner = THIS_MODULE;

  ret = cdev_add(&axiio_cdev, axiio_dev, 1);
  if (ret < 0) {
    pr_err("nvme_axiio: Failed to add character device\n");
    unregister_chrdev_region(axiio_dev, 1);
    return ret;
  }

  /* Create device class */
  axiio_class = class_create(NVME_AXIIO_CLASS);
  if (IS_ERR(axiio_class)) {
    pr_err("nvme_axiio: Failed to create device class\n");
    cdev_del(&axiio_cdev);
    unregister_chrdev_region(axiio_dev, 1);
    return PTR_ERR(axiio_class);
  }

  /* Create device node */
  axiio_device = device_create(axiio_class, NULL, axiio_dev, NULL,
                               NVME_AXIIO_NAME);
  if (IS_ERR(axiio_device)) {
    pr_err("nvme_axiio: Failed to create device\n");
    class_destroy(axiio_class);
    cdev_del(&axiio_cdev);
    unregister_chrdev_region(axiio_dev, 1);
    return PTR_ERR(axiio_device);
  }

  pr_info("nvme_axiio: Module loaded successfully, device /dev/%s created\n",
          NVME_AXIIO_NAME);

  /* Register as PCI driver for device binding */
  ret = nvme_axiio_register_pci_driver();
  if (ret < 0) {
    pr_warn("nvme_axiio: PCI driver registration failed: %d\n", ret);
    pr_warn(
      "  Character device still available, but cannot bind to PCI devices\n");
    /* Don't fail module load - character device still works */
  }

  return 0;
}

/*
 * Module cleanup
 */
static void __exit nvme_axiio_exit(void) {
  pr_info("nvme_axiio: Unloading NVMe AXIIO kernel module\n");

  /* Unregister PCI driver first (unbind any bound devices) */
  nvme_axiio_unregister_pci_driver();

  /* Then cleanup character device */
  device_destroy(axiio_class, axiio_dev);
  class_destroy(axiio_class);
  cdev_del(&axiio_cdev);
  unregister_chrdev_region(axiio_dev, 1);

  pr_info("nvme_axiio: Module unloaded\n");
}

module_init(nvme_axiio_init);
module_exit(nvme_axiio_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("ROCm AXIIO Team");
MODULE_DESCRIPTION(
  "NVMe AXIIO - Userspace NVMe queue and doorbell access for GPU I/O");
MODULE_VERSION("0.1");
