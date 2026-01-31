/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * ROCm AxIIO Kernel Module
 *
 * Provides a userspace interface for GPU-initiated I/O:
 * - VRAM physical address translation via dmabuf
 * - Explicit NVMe queue address registration via IOCTL
 * - Automatic PRP injection for NVMe commands via kprobe
 *   * CREATE_SQ/CREATE_CQ: Injects registered queue physical addresses
 *   * READ/WRITE: Injects buffer PRP1/PRP2 addresses from registered buffers
 * - Device information retrieval
 * - High-performance interfaces:
 *   * mmap: For fast address translation (future)
 *   * io_uring_cmd: For async high-performance operations (future)
 *
 * Usage:
 *   1. Userspace allocates GPU VRAM buffers (queues, data buffers etc)
 *   2. Get physical addresses via GET_VRAM_PHYS_ADDR ioctl
 *   3. Register queue addresses via REGISTER_QUEUE_ADDR ioctl
 *   4. Register data buffers via REGISTER_BUFFER ioctl (optional, for I/O)
 *   5. Use normal NVMe driver interface - kprobe automatically injects
 *      physical addresses into PRP1/PRP2 fields
 */

#include <drm/drm_gem.h>
#include <drm/ttm/ttm_bo.h>
#include <drm/ttm/ttm_resource.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/dma-buf.h>
#include <linux/dma-mapping.h>
#include <linux/fs.h>
#include <linux/io_uring.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/nvme.h>
#include <linux/pci.h>
#include <linux/scatterlist.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#include "rocm-axiio.h"

#define DEVICE_NAME ROCM_XIO_DEVICE_NAME
#define CLASS_NAME "rocm_axiio"

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("ROCm AxIIO kernel module for GPU-initiated NVMe I/O");
MODULE_VERSION("1.0");
MODULE_INFO(import_ns, "DMA_BUF");

static int major_number;
static struct class* rocm_xio_class = NULL;
static struct device* rocm_xio_device = NULL;

/* Kprobe for NVMe command injection */
static struct kprobe nvme_kp = {
  .symbol_name = "nvme_submit_user_cmd",
};

/* Enable/disable injection (module parameter) */
static bool inject_enabled = true;
module_param(inject_enabled, bool, 0644);
MODULE_PARM_DESC(inject_enabled,
                 "Enable automatic PRP injection for NVMe commands");

/* Queue address registration for CREATE_SQ/CREATE_CQ injection */
struct queue_addr_entry {
  __u64 virt_addr;
  __u64 phys_addr;
  __u64 size;
  __u8 queue_type; /* 0=SQ, 1=CQ */
  struct list_head list;
};

/* Buffer registration for I/O command injection */
struct vram_buffer_entry {
  __u64 virt_addr;
  __u64 phys_addr;
  __u64 size;
  struct list_head list;
  // For passthrough NVMe - keep attachment alive for P2PDMA
  struct dma_buf* dmabuf;
  struct dma_buf_attachment* attach;
  struct sg_table* sgt;
  struct pci_dev* nvme_pdev; // Keep reference to NVMe device
  bool is_passthrough;       // Track if this needs cleanup
};

static LIST_HEAD(queue_addrs);
static DEFINE_SPINLOCK(queue_addrs_lock);

static LIST_HEAD(vram_buffers);
static DEFINE_SPINLOCK(vram_buffers_lock);

/* PCI MMIO bridge shadow buffer mapping */
static __u64 mmio_bridge_shadow_gpa = 0;
static __u64 mmio_bridge_shadow_size = 0;
static DEFINE_MUTEX(mmio_bridge_lock);

/*
 * DMA-BUF attach ops for P2P support.
 * We pin the buffer, so move_notify should never be called.
 */
static void rocm_xio_move_notify(struct dma_buf_attachment* attach) {
  pr_warn_ratelimited("rocm-axiio: move_notify called on pinned buffer "
                      "(should not happen)\n");
}

static const struct dma_buf_attach_ops rocm_xio_attach_ops = {
  .allow_peer2peer = true,
  .move_notify = rocm_xio_move_notify,
};

/*
 * Extract the actual VRAM offset from AMDGPU's internal buffer object.
 * The dmabuf->priv points to the amdgpu_bo, which contains the TTM resource
 * with the real VRAM page offset.
 */
static int extract_vram_offset_from_amdgpu_bo(struct dma_buf* dmabuf,
                                              resource_size_t bar_start,
                                              resource_size_t bar_size,
                                              __u64* offset) {
  struct drm_gem_object* gem_obj;
  struct ttm_buffer_object* tbo;
  struct ttm_resource* resource;
  unsigned long page_offset;

  if (!dmabuf || !dmabuf->priv) {
    pr_err("rocm-axiio: Invalid dmabuf or missing private data\n");
    return -EINVAL;
  }

  /*
   * For DRM/TTM dmabufs, priv points to drm_gem_object,
   * which is the 'base' field (first field) of ttm_buffer_object.
   * Use container_of to get the ttm_buffer_object.
   */
  gem_obj = (struct drm_gem_object*)dmabuf->priv;
  tbo = container_of(gem_obj, struct ttm_buffer_object, base);

  if (!tbo->resource) {
    pr_err("rocm-axiio: TTM resource not available\n");
    return -EINVAL;
  }

  resource = tbo->resource;

  /* resource->start is the VRAM offset in pages */
  page_offset = resource->start;

  /* Convert page offset to byte offset (assuming 4KB pages) */
  *offset = page_offset << PAGE_SHIFT;

  pr_info("rocm-axiio: Extracted from TTM resource:\n");
  pr_info("  page_offset=0x%lx, byte_offset=0x%llx\n", page_offset, *offset);
  pr_info("  resource.mem_type=%u, size=0x%zx\n", resource->mem_type,
          resource->size);

  /* Verify this is actually VRAM (mem_type should be TTM_PL_VRAM = 2) */
  if (resource->mem_type != 2) {
    pr_err("rocm-axiio: Buffer is not in VRAM (mem_type=%u, expected 2)\n",
           resource->mem_type);
    return -EINVAL;
  }

  /* Sanity check: offset should be within BAR size */
  if (*offset >= bar_size) {
    pr_warn("rocm-axiio: Calculated offset 0x%llx exceeds BAR size 0x%llx\n",
            *offset, (u64)bar_size);
    /* Continue anyway - might be correct for large VRAM BARs */
  }

  return 0;
}

/*
 * Extract VRAM physical offset from scatter-gather table
 */
static int extract_vram_offset_from_sg(struct sg_table* sgt,
                                       struct pci_dev* gpu_dev,
                                       resource_size_t bar_start,
                                       resource_size_t bar_size,
                                       struct dma_buf* dmabuf, __u64* offset) {
  struct scatterlist* sg;
  dma_addr_t dma_addr;
  phys_addr_t phys_addr;
  int i;

  if (!sgt || sgt->nents == 0) {
    return -EINVAL;
  }

  /* Log what we see in the scatter-gather table */
  for_each_sg(sgt->sgl, sg, sgt->nents, i) {
    phys_addr = sg_phys(sg);
    dma_addr = sg_dma_address(sg);

    pr_info("rocm-axiio: sg[%d]: phys=0x%llx dma=0x%llx len=%u\n", i,
            (u64)phys_addr, (u64)dma_addr, sg->length);

    /* Check if physical address is within the GPU BAR range */
    if (phys_addr >= bar_start && phys_addr < (bar_start + bar_size)) {
      *offset = phys_addr - bar_start;
      pr_info("rocm-axiio: Found VRAM offset from sg_phys: 0x%llx\n", *offset);
      return 0;
    }
  }

  /*
   * The sg_table doesn't have GPU BAR addresses (as expected for VRAM).
   * Try to extract the real VRAM offset from AMDGPU's TTM resource first.
   */
  pr_info("rocm-axiio: Trying TTM resource extraction...\n");
  if (extract_vram_offset_from_amdgpu_bo(dmabuf, bar_start, bar_size, offset) ==
      0) {
    /* Success! TTM gave us the real offset */
    return 0;
  }

  /*
   * TTM extraction failed. Fallback to DMA address heuristic.
   * For P2PDMA, the DMA address sometimes encodes the offset within the
   * resource.
   */
  sg = sgt->sgl;
  dma_addr = sg_dma_address(sg);

  pr_info("rocm-axiio: TTM failed, trying DMA address as direct offset: "
          "0x%llx\n",
          (u64)dma_addr);

  if (dma_addr > 0 && dma_addr < bar_size) {
    *offset = dma_addr;
    pr_warn("rocm-axiio: Using DMA address as VRAM offset (may be wrong!): "
            "0x%llx\n",
            *offset);
    return 0;
  }

  pr_err("rocm-axiio: Could not extract VRAM offset from sg_table or TTM\n");
  pr_err("rocm-axiio: dma_addr=0x%llx bar_size=0x%llx\n", (u64)dma_addr,
         (u64)bar_size);

  return -EINVAL;
}

/* Get GPU BAR GPA for emulated NVMe (returns guest-visible BAR address) */
static int get_dmabuf_bar_gpa(int dmabuf_fd, __u64* bar_gpa, __u64* size) {
  struct dma_buf* dmabuf;
  struct pci_dev* gpu_dev = NULL;
  struct sg_table* sgt = NULL;
  struct dma_buf_attachment* attach = NULL;
  resource_size_t bar_start, bar_size;
  int ret = 0;
  int i;

  /* Get dmabuf */
  dmabuf = dma_buf_get(dmabuf_fd);
  if (IS_ERR(dmabuf)) {
    pr_err("rocm-axiio: dma_buf_get failed: %ld\n", PTR_ERR(dmabuf));
    return PTR_ERR(dmabuf);
  }

  *size = dmabuf->size;

  /* Find AMD GPU by scanning PCI devices */
  gpu_dev = pci_get_device(PCI_VENDOR_ID_ATI, PCI_ANY_ID, NULL);
  if (!gpu_dev) {
    pr_err("rocm-axiio: AMD GPU not found\n");
    ret = -ENODEV;
    goto cleanup_no_attach;
  }

  /*
   * Use dynamic attach with P2P support.
   * This tells AMDGPU we support peer-to-peer DMA, so it will
   * keep the buffer in VRAM instead of forcing it to GTT.
   * We pin the buffer immediately after attach, so move_notify
   * should never be called (buffer is pinned and can't move).
   */
  attach = dma_buf_dynamic_attach(dmabuf, &gpu_dev->dev, &rocm_xio_attach_ops,
                                  NULL);
  if (IS_ERR(attach)) {
    pr_err("rocm-axiio: dma_buf_dynamic_attach failed: %ld\n", PTR_ERR(attach));
    ret = PTR_ERR(attach);
    goto cleanup_no_attach;
  }

  /* Pin the buffer so it doesn't move */
  ret = dma_buf_pin(attach);
  if (ret) {
    pr_err("rocm-axiio: dma_buf_pin failed: %d\n", ret);
    goto cleanup_detach;
  }

  sgt = dma_buf_map_attachment(attach, DMA_BIDIRECTIONAL);
  if (IS_ERR(sgt)) {
    pr_err("rocm-axiio: dma_buf_map_attachment failed: %ld\n", PTR_ERR(sgt));
    ret = PTR_ERR(sgt);
    goto cleanup;
  }

  pr_info("rocm-axiio: dmabuf mapped: nents=%u\n", sgt->nents);

  /* Find the GPU VRAM BAR */
  for (i = 0; i < PCI_STD_NUM_BARS; i++) {
    if (!(pci_resource_flags(gpu_dev, i) & IORESOURCE_MEM))
      continue;

    bar_start = pci_resource_start(gpu_dev, i);
    bar_size = pci_resource_len(gpu_dev, i);

    /* Use BAR 0 for VRAM (typical for AMD GPUs) */
    if (i == 0 && (pci_resource_flags(gpu_dev, i) & IORESOURCE_PREFETCH)) {
      pr_info("rocm-axiio: Found GPU VRAM BAR%d: GPA=0x%llx size=0x%llx\n", i,
              (u64)bar_start, (u64)bar_size);

      /*
       * Extract the actual VRAM offset from the scatter-gather table
       * This should give us the physical offset within the GPU's VRAM BAR
       */
      __u64 vram_offset = 0;
      if (extract_vram_offset_from_sg(sgt, gpu_dev, bar_start, bar_size, dmabuf,
                                      &vram_offset) == 0) {
        *bar_gpa = bar_start + vram_offset;
        pr_info("rocm-axiio: BAR GPA=0x%llx (base=0x%llx + offset=0x%llx)\n",
                *bar_gpa, (u64)bar_start, vram_offset);
      } else {
        /* Fallback: return BAR base (will be wrong but better than crashing) */
        *bar_gpa = bar_start;
        pr_warn("rocm-axiio: Failed to extract offset, using BAR base\n");
      }

      ret = 0;
      goto cleanup;
    }
  }

  pr_err("rocm-axiio: No suitable GPU VRAM BAR found\n");
  ret = -EINVAL;

cleanup:
  if (sgt && !IS_ERR(sgt))
    dma_buf_unmap_attachment(attach, sgt, DMA_BIDIRECTIONAL);
  if (attach && !IS_ERR(attach)) {
    dma_buf_unpin(attach);
  cleanup_detach:
    dma_buf_detach(dmabuf, attach);
  }
cleanup_no_attach:
  if (gpu_dev)
    pci_dev_put(gpu_dev);
  dma_buf_put(dmabuf);
  return ret;
}

/* Get physical address from dmabuf using DMA API (for passthrough NVMe)
 * Attaches dmabuf to NVMe device and returns P2PDMA IOVA
 * Returns attachment info via output parameters - caller must keep alive
 */
static int get_dmabuf_phys_addr(int dmabuf_fd, __u16 nvme_bdf, __u64* phys_addr,
                                __u64* size, struct dma_buf** dmabuf_out,
                                struct dma_buf_attachment** attach_out,
                                struct sg_table** sgt_out,
                                struct pci_dev** pdev_out) {
  struct dma_buf* dmabuf;
  struct dma_buf_attachment* attach;
  struct sg_table* sgt;
  struct pci_dev* pdev = NULL;
  struct device* dev;
  dma_addr_t dma_addr;
  int ret = 0;
  unsigned int domain, bus, devfn;

  /* Decode BDF: format is 0x0BDF (bus=B, dev=D, func=F) */
  bus = (nvme_bdf >> 8) & 0xFF;
  devfn = nvme_bdf & 0xFF;
  domain = 0; /* Assume domain 0 for now */

  /* Find the NVMe PCI device */
  pdev = pci_get_domain_bus_and_slot(domain, bus, devfn);
  if (!pdev) {
    pr_err("rocm-axiio: NVMe device not found (BDF: 0x%04x)\n", nvme_bdf);
    return -ENODEV;
  }
  dev = &pdev->dev;

  pr_info("rocm-axiio: Using NVMe device %s (BDF: 0x%04x) for P2PDMA\n",
          pci_name(pdev), nvme_bdf);

  /* Get dmabuf from fd */
  dmabuf = dma_buf_get(dmabuf_fd);
  if (IS_ERR(dmabuf)) {
    pr_err("rocm-axiio: dma_buf_get failed: %ld\n", PTR_ERR(dmabuf));
    ret = PTR_ERR(dmabuf);
    goto err_put_pci;
  }

  *size = dmabuf->size;

  /* Attach to NVMe device */
  attach = dma_buf_attach(dmabuf, dev);
  if (IS_ERR(attach)) {
    pr_err("rocm-axiio: dma_buf_attach failed: %ld\n", PTR_ERR(attach));
    ret = PTR_ERR(attach);
    goto err_put_dmabuf;
  }

  /* Map for DMA - this is where P2PDMA magic happens */
  sgt = dma_buf_map_attachment(attach, DMA_BIDIRECTIONAL);
  if (IS_ERR(sgt)) {
    pr_err("rocm-axiio: dma_buf_map_attachment failed: %ld\n", PTR_ERR(sgt));
    ret = PTR_ERR(sgt);
    goto err_detach;
  }

  /* Get DMA address from scatter-gather list */
  if (sgt->nents > 0) {
    dma_addr = sg_dma_address(sgt->sgl);
    *phys_addr = (__u64)dma_addr;
    pr_info("rocm-axiio: ✅ P2PDMA address: 0x%llx (size: %llu)\n", *phys_addr,
            *size);
  } else {
    pr_err("rocm-axiio: No DMA segments\n");
    ret = -EINVAL;
    goto err_unmap;
  }

  /* Return attachment info - caller must keep alive */
  *dmabuf_out = dmabuf;
  *attach_out = attach;
  *sgt_out = sgt;
  *pdev_out = pdev; // Caller gets reference

  return 0;

err_unmap:
  dma_buf_unmap_attachment(attach, sgt, DMA_BIDIRECTIONAL);
err_detach:
  dma_buf_detach(dmabuf, attach);
err_put_dmabuf:
  dma_buf_put(dmabuf);
err_put_pci:
  pci_dev_put(pdev);

  return ret;
}

/* Get NVMe device info */
static int get_nvme_device_info(__u16 bdf, struct rocm_xio_device_info* info) {
  struct pci_dev* nvme_dev = NULL;
  unsigned int domain, bus, devfn;
  resource_size_t bar0_start, bar0_size;

  /* Decode BDF: format is 0x0BDF (bus=B, dev=D, func=F) */
  bus = (bdf >> 8) & 0xFF;
  devfn = bdf & 0xFF;
  domain = 0; /* Assume domain 0 for now */

  /* Find the NVMe PCI device */
  nvme_dev = pci_get_domain_bus_and_slot(domain, bus, devfn);
  if (!nvme_dev) {
    pr_err("rocm-axiio: NVMe device not found (BDF: 0x%04x)\n", bdf);
    return -ENODEV;
  }

  info->bdf = bdf;

  /* Get BAR0 information */
  bar0_start = pci_resource_start(nvme_dev, 0);
  bar0_size = pci_resource_len(nvme_dev, 0);
  info->bar0_addr = bar0_start;
  info->bar0_size = bar0_size;

  /* Doorbell stride is typically 4 bytes (32-bit registers) */
  info->doorbell_stride = 4;

  /* Maximum queues: typically 65535 for NVMe 1.4+ */
  info->max_queues = 65535;

  pr_info("rocm-axiio: Device info for BDF 0x%04x:\n", bdf);
  pr_info("  BAR0: 0x%llx (size: 0x%llx)\n", (u64)info->bar0_addr,
          (u64)info->bar0_size);
  pr_info("  Doorbell stride: %u bytes\n", info->doorbell_stride);
  pr_info("  Max queues: %u\n", info->max_queues);

  pci_dev_put(nvme_dev);
  return 0;
}

/* Get PCI MMIO bridge shadow buffer GPA from PCI config space */
static int get_mmio_bridge_shadow_buffer(
  __u16 bridge_bdf, struct rocm_xio_mmio_bridge_shadow_req* req) {
  struct pci_dev* bridge_dev = NULL;
  unsigned int domain, bus, devfn;
  __u32 gpa_low = 0, gpa_high = 0;
  __u64 shadow_gpa = 0;

  /* Decode BDF: format is 0xBBDD (bus=B, dev=D, func=F) */
  bus = (bridge_bdf >> 8) & 0xFF;
  devfn = bridge_bdf & 0xFF;
  domain = 0; /* Assume domain 0 for now */

  /* Find the PCI MMIO bridge device */
  bridge_dev = pci_get_domain_bus_and_slot(domain, bus, devfn);
  if (!bridge_dev) {
    pr_err("rocm-axiio: PCI MMIO bridge device not found (BDF: 0x%04x)\n",
           bridge_bdf);
    return -ENODEV;
  }

  /* Read shadow buffer GPA from PCI config space (offsets 0x40 and 0x44) */
  pci_read_config_dword(bridge_dev, 0x40, &gpa_low);
  pci_read_config_dword(bridge_dev, 0x44, &gpa_high);

  shadow_gpa = ((__u64)gpa_high << 32) | gpa_low;

  if (shadow_gpa == 0) {
    pr_err("rocm-axiio: PCI MMIO bridge shadow GPA is 0 (not configured)\n");
    pci_dev_put(bridge_dev);
    return -EINVAL;
  }

  req->bridge_bdf = bridge_bdf;
  req->shadow_gpa = shadow_gpa;
  req->shadow_size = 8192; /* 8KB shadow buffer (typical size) */

  pr_info("rocm-axiio: PCI MMIO bridge shadow buffer: GPA=0x%llx, size=%llu\n",
          (unsigned long long)shadow_gpa, (unsigned long long)req->shadow_size);

  pci_dev_put(bridge_dev);
  return 0;
}

/*
 * Look up physical address for queue (CREATE_SQ/CREATE_CQ).
 * Returns physical address if found, 0 otherwise.
 */
static __u64 lookup_queue_phys_addr(__u64 virt_addr) {
  struct queue_addr_entry* entry;
  __u64 phys_addr = 0;

  spin_lock(&queue_addrs_lock);
  list_for_each_entry(entry, &queue_addrs, list) {
    if (virt_addr >= entry->virt_addr &&
        virt_addr < (entry->virt_addr + entry->size)) {
      phys_addr = entry->phys_addr + (virt_addr - entry->virt_addr);
      break;
    }
  }
  spin_unlock(&queue_addrs_lock);

  return phys_addr;
}

/*
 * Look up physical address for data buffer (I/O commands).
 * First checks registered VRAM buffers, then falls back to virt_to_phys.
 */
static __u64 lookup_buffer_phys_addr(__u64 virt_addr) {
  struct vram_buffer_entry* entry;
  __u64 phys_addr = 0;

  /* First check registered VRAM buffers */
  spin_lock(&vram_buffers_lock);
  list_for_each_entry(entry, &vram_buffers, list) {
    if (virt_addr >= entry->virt_addr &&
        virt_addr < (entry->virt_addr + entry->size)) {
      phys_addr = entry->phys_addr + (virt_addr - entry->virt_addr);
      break;
    }
  }
  spin_unlock(&vram_buffers_lock);

  if (phys_addr)
    return phys_addr;

  /* Fallback: try virt_to_phys (works for kernel memory) */
  if (virt_addr_valid((void*)virt_addr)) {
    return virt_to_phys((void*)virt_addr);
  }

  return 0;
}

/*
 * Kprobe pre-handler for nvme_submit_user_cmd.
 * Injects physical addresses into PRP1/PRP2 for NVMe commands.
 */
static int nvme_submit_user_cmd_pre(struct kprobe* p, struct pt_regs* regs) {
  struct nvme_command* cmd;
  u64 ubuffer;
  unsigned int bufflen;
  u8 opcode;
  __u64 phys_addr;

  if (!inject_enabled)
    return 0;

    /*
     * Function signature:
     * nvme_submit_user_cmd(struct request_queue *q,
     *                      struct nvme_command *cmd,
     *                      u64 ubuffer,
     *                      unsigned bufflen, ...)
     *
     * x86_64 calling convention:
     * RDI = arg0 (q)
     * RSI = arg1 (cmd)
     * RDX = arg2 (ubuffer)
     * RCX = arg3 (bufflen)
     */
#ifdef CONFIG_X86_64
  cmd = (struct nvme_command*)regs->si;
  ubuffer = regs->dx;
  bufflen = (unsigned int)regs->cx;
#else
  /* For non-x86_64, we'd need architecture-specific register access */
  return 0;
#endif

  if (!cmd)
    return 0;

  opcode = cmd->common.opcode;

  /* Handle CREATE_CQ (0x05) and CREATE_SQ (0x01) */
  if ((opcode == 0x05 || opcode == 0x01) && bufflen == 0 && ubuffer != 0) {
    pr_info("rocm-axiio: Intercepted %s command\n",
            opcode == 0x05 ? "CREATE_CQ" : "CREATE_SQ");
    pr_info("  Original PRP1: 0x%016llx\n",
            (unsigned long long)le64_to_cpu(cmd->common.dptr.prp1));
    pr_info("  ubuffer: 0x%016llx\n", (unsigned long long)ubuffer);

    /* Look up physical address from registered queue addresses */
    phys_addr = lookup_queue_phys_addr(ubuffer);
    if (phys_addr) {
      cmd->common.dptr.prp1 = cpu_to_le64(phys_addr);
      pr_info("  ✅ Injected PRP1: 0x%016llx\n", (unsigned long long)phys_addr);
    } else {
      /* If not found, use ubuffer directly (assume it's already physical,
       * as userspace may have gotten it via GET_VRAM_PHYS_ADDR) */
      pr_info("rocm-axiio: Queue not registered, using ubuffer directly\n");
      cmd->common.dptr.prp1 = cpu_to_le64(ubuffer);
    }
  }

  /* Handle I/O commands (READ=0x02, WRITE=0x01) - inject buffer addresses */
  if (opcode == 0x01 || opcode == 0x02) {
    __u64 prp1_val = le64_to_cpu(cmd->common.dptr.prp1);
    __u64 prp2_val = le64_to_cpu(cmd->common.dptr.prp2);

    /* If PRP1 looks like a virtual address (not a high physical address),
     * try to convert it */
    if (prp1_val && prp1_val < 0x100000000ULL) {
      phys_addr = lookup_buffer_phys_addr(prp1_val);
      if (phys_addr) {
        pr_debug("rocm-axiio: Injecting PRP1 for I/O: 0x%016llx\n",
                 (unsigned long long)phys_addr);
        cmd->common.dptr.prp1 = cpu_to_le64(phys_addr);
      }
    }

    /* Same for PRP2 if present */
    if (prp2_val && prp2_val < 0x100000000ULL) {
      phys_addr = lookup_buffer_phys_addr(prp2_val);
      if (phys_addr) {
        pr_debug("rocm-axiio: Injecting PRP2 for I/O: 0x%016llx\n",
                 (unsigned long long)phys_addr);
        cmd->common.dptr.prp2 = cpu_to_le64(phys_addr);
      }
    }
  }

  return 0; /* Continue with original function */
}

/* IOCTL handler */
static long rocm_xio_ioctl(struct file* file, unsigned int cmd,
                           unsigned long arg) {
  int ret = 0;

  switch (cmd) {
    case ROCM_XIO_GET_VRAM_PHYS_ADDR: {
      struct rocm_xio_vram_req req;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      pr_info("rocm-axiio: Getting VRAM physical address for NVMe BDF 0x%04x\n",
              req.nvme_bdf);

      /*
       * Always return GPU BAR GPA (works for both emulated and passthrough
       * NVMe in VM environments)
       */
      ret = get_dmabuf_bar_gpa(req.dmabuf_fd, &req.phys_addr, &req.size);

      if (ret < 0)
        return ret;

      if (copy_to_user((void __user*)arg, &req, sizeof(req)))
        return -EFAULT;

      return 0;
    }

    case ROCM_XIO_GET_DEVICE_INFO: {
      struct rocm_xio_device_info info;

      if (copy_from_user(&info, (void __user*)arg, sizeof(info)))
        return -EFAULT;

      ret = get_nvme_device_info(info.bdf, &info);
      if (ret < 0)
        return ret;

      if (copy_to_user((void __user*)arg, &info, sizeof(info)))
        return -EFAULT;

      return 0;
    }

    case ROCM_XIO_CREATE_QUEUE:
    case ROCM_XIO_DELETE_QUEUE:
      /*
       * Queue creation/deletion is handled via kprobe injection.
       * Userspace allocates queues in VRAM, gets physical addresses via
       * GET_VRAM_PHYS_ADDR, then uses normal NVMe driver interface.
       * The kprobe automatically injects physical addresses.
       */
      pr_info("rocm-axiio: Queue management handled via kprobe injection\n");
      return -EOPNOTSUPP;

    case ROCM_XIO_BIND_DEVICE: {
      struct rocm_xio_bind_device_req req;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      /* Device binding is optional - just log it for now */
      pr_info("rocm-axiio: Device binding requested for BDF 0x%04x\n", req.bdf);
      return 0;
    }

    case ROCM_XIO_REGISTER_QUEUE_ADDR: {
      struct rocm_xio_register_queue_addr_req req;
      struct queue_addr_entry* entry;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      /* Allocate and register queue address entry */
      entry = kmalloc(sizeof(*entry), GFP_KERNEL);
      if (!entry)
        return -ENOMEM;

      entry->virt_addr = req.virt_addr;
      entry->phys_addr = req.phys_addr;
      entry->size = req.size;
      entry->queue_type = req.queue_type;

      spin_lock(&queue_addrs_lock);
      list_add(&entry->list, &queue_addrs);
      spin_unlock(&queue_addrs_lock);

      pr_info("rocm-axiio: Registered queue address: virt=0x%016llx "
              "phys=0x%016llx size=0x%llx type=%u\n",
              (unsigned long long)req.virt_addr,
              (unsigned long long)req.phys_addr, (unsigned long long)req.size,
              req.queue_type);

      return 0;
    }

    case ROCM_XIO_UNREGISTER_QUEUE_ADDR: {
      struct rocm_xio_unregister_queue_addr_req req;
      struct queue_addr_entry *entry, *tmp;
      bool found = false;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      spin_lock(&queue_addrs_lock);
      list_for_each_entry_safe(entry, tmp, &queue_addrs, list) {
        if (entry->virt_addr == req.virt_addr) {
          list_del(&entry->list);
          kfree(entry);
          found = true;
          break;
        }
      }
      spin_unlock(&queue_addrs_lock);

      if (!found) {
        pr_warn("rocm-axiio: Queue address 0x%016llx not found\n",
                (unsigned long long)req.virt_addr);
        return -ENOENT;
      }

      pr_info("rocm-axiio: Unregistered queue address: virt=0x%016llx\n",
              (unsigned long long)req.virt_addr);
      return 0;
    }

    case ROCM_XIO_REGISTER_BUFFER: {
      struct rocm_xio_register_buffer_req req;
      struct vram_buffer_entry* entry;
      __u64 phys_addr;
      bool is_emulated = false;
      struct dma_buf* dmabuf = NULL;
      struct dma_buf_attachment* attach = NULL;
      struct sg_table* sgt = NULL;
      struct pci_dev* nvme_pdev = NULL;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      /* Determine if this is emulated NVMe based on flags field */
      if (req.flags & ROCM_XIO_FLAG_EMULATED) {
        is_emulated = true;
      } else if (req.flags & ROCM_XIO_FLAG_PASSTHROUGH) {
        is_emulated = false;
      }
      /* Default to passthrough if no flags set */

      /* Get physical address from dmabuf - choose method based on NVMe type */
      if (is_emulated) {
        /* Emulated NVMe: Return GPU BAR GPA */
        pr_info("rocm-axiio: Emulated NVMe (BDF 0x%04x) - using GPU BAR GPA\n",
                req.nvme_bdf);
        ret = get_dmabuf_bar_gpa(req.dmabuf_fd, &phys_addr, &req.size);
        if (ret < 0)
          return ret;
      } else {
        /* Passthrough NVMe: Return P2PDMA IOVA - keep attachment alive */
        pr_info(
          "rocm-axiio: Passthrough NVMe (BDF 0x%04x) - using P2PDMA IOVA\n",
          req.nvme_bdf);
        ret = get_dmabuf_phys_addr(req.dmabuf_fd, req.nvme_bdf, &phys_addr,
                                   &req.size, &dmabuf, &attach, &sgt,
                                   &nvme_pdev);
        if (ret < 0)
          return ret;
      }

      /* Allocate and register buffer entry */
      entry = kmalloc(sizeof(*entry), GFP_KERNEL);
      if (!entry) {
        /* Cleanup passthrough attachment if allocated */
        if (!is_emulated && sgt && attach && dmabuf) {
          dma_buf_unmap_attachment(attach, sgt, DMA_BIDIRECTIONAL);
          dma_buf_detach(dmabuf, attach);
          dma_buf_put(dmabuf);
          if (nvme_pdev)
            pci_dev_put(nvme_pdev);
        }
        return -ENOMEM;
      }

      /* Store userspace virtual address */
      entry->virt_addr = (__u64)req.virt_addr;
      entry->phys_addr = phys_addr;
      entry->size = req.size;
      entry->is_passthrough = !is_emulated;

      /* Store attachment info for passthrough (keep alive) */
      if (!is_emulated) {
        entry->dmabuf = dmabuf;
        entry->attach = attach;
        entry->sgt = sgt;
        entry->nvme_pdev = nvme_pdev;
      } else {
        entry->dmabuf = NULL;
        entry->attach = NULL;
        entry->sgt = NULL;
        entry->nvme_pdev = NULL;
      }

      spin_lock(&vram_buffers_lock);
      list_add(&entry->list, &vram_buffers);
      spin_unlock(&vram_buffers_lock);

      req.phys_addr = phys_addr;

      pr_info("rocm-axiio: Registered buffer: virt=0x%016llx "
              "phys=0x%016llx size=0x%llx%s\n",
              (unsigned long long)entry->virt_addr,
              (unsigned long long)phys_addr, (unsigned long long)req.size,
              entry->is_passthrough ? " (P2PDMA attachment kept alive)" : "");

      if (copy_to_user((void __user*)arg, &req, sizeof(req))) {
        /* Unregister on copy failure */
        spin_lock(&vram_buffers_lock);
        list_del(&entry->list);
        spin_unlock(&vram_buffers_lock);
        /* Cleanup passthrough attachment */
        if (entry->is_passthrough && entry->sgt && entry->attach &&
            entry->dmabuf) {
          dma_buf_unmap_attachment(entry->attach, entry->sgt,
                                   DMA_BIDIRECTIONAL);
          dma_buf_detach(entry->dmabuf, entry->attach);
          dma_buf_put(entry->dmabuf);
          if (entry->nvme_pdev)
            pci_dev_put(entry->nvme_pdev);
        }
        kfree(entry);
        return -EFAULT;
      }

      return 0;
    }

    case ROCM_XIO_UNREGISTER_BUFFER: {
      struct rocm_xio_unregister_buffer_req req;
      struct vram_buffer_entry *entry, *tmp;
      bool found = false;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      spin_lock(&vram_buffers_lock);
      list_for_each_entry_safe(entry, tmp, &vram_buffers, list) {
        if (entry->virt_addr == req.virt_addr) {
          list_del(&entry->list);
          found = true;
          break;
        }
      }
      spin_unlock(&vram_buffers_lock);

      if (!found) {
        pr_warn("rocm-axiio: Buffer 0x%016llx not found\n",
                (unsigned long long)req.virt_addr);
        return -ENOENT;
      }

      /* Cleanup passthrough attachment if needed */
      if (entry->is_passthrough && entry->sgt && entry->attach &&
          entry->dmabuf) {
        pr_info(
          "rocm-axiio: Cleaning up P2PDMA attachment for buffer 0x%016llx\n",
          (unsigned long long)entry->virt_addr);
        dma_buf_unmap_attachment(entry->attach, entry->sgt, DMA_BIDIRECTIONAL);
        dma_buf_detach(entry->dmabuf, entry->attach);
        dma_buf_put(entry->dmabuf);
        if (entry->nvme_pdev)
          pci_dev_put(entry->nvme_pdev);
      }

      pr_info("rocm-axiio: Unregistered buffer: virt=0x%016llx\n",
              (unsigned long long)req.virt_addr);
      kfree(entry);
      return 0;
    }

    case ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER: {
      struct rocm_xio_mmio_bridge_shadow_req req;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      ret = get_mmio_bridge_shadow_buffer(req.bridge_bdf, &req);
      if (ret < 0)
        return ret;

      /* Store shadow buffer info for mmap */
      mutex_lock(&mmio_bridge_lock);
      mmio_bridge_shadow_gpa = req.shadow_gpa;
      mmio_bridge_shadow_size = req.shadow_size;
      mutex_unlock(&mmio_bridge_lock);

      if (copy_to_user((void __user*)arg, &req, sizeof(req)))
        return -EFAULT;

      return 0;
    }

    default:
      return -ENOTTY;
  }
}

/* MMAP implementation for high-performance address translation */
static int rocm_xio_mmap(struct file* file, struct vm_area_struct* vma) {
  unsigned long pfn;
  int ret;

  mutex_lock(&mmio_bridge_lock);

  /* Check if shadow buffer is configured */
  if (mmio_bridge_shadow_gpa == 0) {
    mutex_unlock(&mmio_bridge_lock);
    pr_err("rocm-axiio: PCI MMIO bridge shadow buffer not configured\n");
    return -EINVAL;
  }

  /* Map the shadow buffer physical address */
  pfn = mmio_bridge_shadow_gpa >> PAGE_SHIFT;

  /* Remap the physical pages to userspace */
  ret = remap_pfn_range(vma, vma->vm_start, pfn, mmio_bridge_shadow_size,
                        vma->vm_page_prot);
  if (ret < 0) {
    mutex_unlock(&mmio_bridge_lock);
    pr_err("rocm-axiio: Failed to remap shadow buffer: %d\n", ret);
    return ret;
  }

  pr_info("rocm-axiio: Mapped PCI MMIO bridge shadow buffer: GPA=0x%llx, "
          "size=%llu, vaddr=0x%lx\n",
          (unsigned long long)mmio_bridge_shadow_gpa,
          (unsigned long long)mmio_bridge_shadow_size, vma->vm_start);

  mutex_unlock(&mmio_bridge_lock);
  return 0;
}

/* io_uring_cmd handler for high-performance async operations */
static int rocm_xio_uring_cmd(struct io_uring_cmd* ioucmd,
                              unsigned int issue_flags) {
  /* io_uring_cmd support for async high-performance buffer address
   * translation. This allows userspace to submit async requests for
   * address translation without blocking.
   *
   * For now, return -ENOSYS to indicate not yet implemented.
   * Future implementation could:
   *   - Accept virt_addr in ioucmd->cmd
   *   - Look up phys_addr from registered buffers
   *   - Return result via io_uring_cmd_done()
   */
  pr_debug("rocm-axiio: io_uring_cmd not yet implemented\n");
  return -ENOSYS;
}

/* File operations */
static struct file_operations fops = {
  .owner = THIS_MODULE,
  .unlocked_ioctl = rocm_xio_ioctl,
  .mmap = rocm_xio_mmap,
  .uring_cmd = rocm_xio_uring_cmd, /* For io_uring async operations */
};

static int __init rocm_xio_init(void) {
  int ret;

  /* Register character device */
  major_number = register_chrdev(0, DEVICE_NAME, &fops);
  if (major_number < 0) {
    pr_err("rocm-axiio: Failed to register device: %d\n", major_number);
    return major_number;
  }

  /* Create device class */
  rocm_xio_class = class_create(CLASS_NAME);
  if (IS_ERR(rocm_xio_class)) {
    unregister_chrdev(major_number, DEVICE_NAME);
    return PTR_ERR(rocm_xio_class);
  }

  /* Create device */
  rocm_xio_device = device_create(rocm_xio_class, NULL, MKDEV(major_number, 0),
                                  NULL, DEVICE_NAME);
  if (IS_ERR(rocm_xio_device)) {
    class_destroy(rocm_xio_class);
    unregister_chrdev(major_number, DEVICE_NAME);
    return PTR_ERR(rocm_xio_device);
  }

  /* Register kprobe for NVMe command injection */
  if (inject_enabled) {
    nvme_kp.pre_handler = nvme_submit_user_cmd_pre;
    ret = register_kprobe(&nvme_kp);
    if (ret < 0) {
      pr_warn("rocm-axiio: Failed to register kprobe: %d\n", ret);
      pr_warn("  Injection disabled - module will work in ioctl-only mode\n");
      inject_enabled = false;
    } else {
      pr_info("rocm-axiio: Kprobe registered successfully\n");
      pr_info("  Hooked: %s at %p\n", nvme_kp.symbol_name, nvme_kp.addr);
      pr_info("  Monitoring for CREATE_CQ/CREATE_SQ and I/O commands\n");
    }
  }

  pr_info("rocm-axiio: Module loaded\n");
  pr_info("  Device: /dev/%s\n", DEVICE_NAME);
  pr_info("  Major number: %d\n", major_number);
  pr_info("  Injection: %s\n", inject_enabled ? "enabled" : "disabled");

  return 0;
}

static void __exit rocm_xio_exit(void) {
  struct queue_addr_entry *qentry, *qtmp;
  struct vram_buffer_entry *entry, *tmp;

  /* Unregister kprobe */
  if (inject_enabled) {
    unregister_kprobe(&nvme_kp);
  }

  /* Clean up registered queue addresses */
  spin_lock(&queue_addrs_lock);
  list_for_each_entry_safe(qentry, qtmp, &queue_addrs, list) {
    list_del(&qentry->list);
    kfree(qentry);
  }
  spin_unlock(&queue_addrs_lock);

  /* Clean up registered buffers */
  spin_lock(&vram_buffers_lock);
  list_for_each_entry_safe(entry, tmp, &vram_buffers, list) {
    list_del(&entry->list);
    /* Cleanup passthrough attachment if needed */
    if (entry->is_passthrough && entry->sgt && entry->attach && entry->dmabuf) {
      dma_buf_unmap_attachment(entry->attach, entry->sgt, DMA_BIDIRECTIONAL);
      dma_buf_detach(entry->dmabuf, entry->attach);
      dma_buf_put(entry->dmabuf);
      if (entry->nvme_pdev)
        pci_dev_put(entry->nvme_pdev);
    }
    kfree(entry);
  }
  spin_unlock(&vram_buffers_lock);

  device_destroy(rocm_xio_class, MKDEV(major_number, 0));
  class_destroy(rocm_xio_class);
  unregister_chrdev(major_number, DEVICE_NAME);

  pr_info("rocm-axiio: Module unloaded\n");
}

module_init(rocm_xio_init);
module_exit(rocm_xio_exit);
