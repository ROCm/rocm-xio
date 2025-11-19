/* SPDX-License-Identifier: GPL-2.0 */
/*
 * GPU-Accessible NVMe Doorbell Mapping
 *
 * Provide GPU-accessible doorbell mappings similar to rocSHMEM GDA.
 * The kernel module exposes its BAR0 mapping to GPU via special mmap.
 */

#ifndef NVME_GPU_DOORBELL_H
#define NVME_GPU_DOORBELL_H

#include <linux/mm.h>
#include <linux/pci.h>

/*
 * Map doorbell for GPU access via mmap
 *
 * Strategy: Use remap_pfn_range with GPU-compatible flags
 * - Write-combining (pgprot_writecombine)
 * - I/O mapping (VM_IO | VM_PFNMAP)
 * - Don't expand/dump (VM_DONTEXPAND | VM_DONTDUMP)
 *
 * The GPU can then use this mapping with __hip_atomic_store and
 * __HIP_MEMORY_SCOPE_SYSTEM for proper PCIe ordering.
 */

/*
 * Setup VMA for GPU-accessible doorbell mapping
 */
static inline int nvme_setup_gpu_doorbell_vma(struct device* dev,
                                              struct vm_area_struct* vma,
                                              resource_size_t doorbell_phys,
                                              size_t size) {
  unsigned long pfn;
  int ret;

  /* Align to page boundary */
  unsigned long page_base = doorbell_phys & PAGE_MASK;
  pfn = page_base >> PAGE_SHIFT;

  dev_info(dev, "nvme_axiio: Setting up GPU doorbell mapping\n");
  dev_info(dev, "  Physical address: 0x%llx\n", (u64)doorbell_phys);
  dev_info(dev, "  PFN: 0x%lx\n", pfn);
  dev_info(dev, "  Size: %zu bytes\n", size);

  /* Set GPU-compatible page protection */
  vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);

  /* Mark as device I/O memory (required for GPU access) */
  vm_flags_set(vma, VM_IO | VM_PFNMAP | VM_DONTEXPAND | VM_DONTDUMP);

  /* Map physical pages to userspace */
  ret = remap_pfn_range(vma, vma->vm_start, pfn, size, vma->vm_page_prot);
  if (ret < 0) {
    dev_err(dev, "nvme_axiio: remap_pfn_range failed: %d\n", ret);
    return ret;
  }

  dev_info(dev, "nvme_axiio: ✓ GPU doorbell mapped with WC+IO flags\n");
  dev_info(dev, "  Userspace VA: 0x%lx\n", vma->vm_start);
  dev_info(dev, "  GPU can now write with system-scope atomics!\n");

  return 0;
}

/*
 * Calculate doorbell physical address for a queue
 */
static inline resource_size_t nvme_get_doorbell_phys(resource_size_t bar0_phys,
                                                     u16 queue_id, bool is_sq,
                                                     u32 doorbell_stride) {
  /* Base doorbell offset is 0x1000 */
  u32 offset = 0x1000;

  /* Each queue pair takes 2 * doorbell_stride bytes */
  offset += (2 * queue_id * doorbell_stride);

  /* CQ doorbell is +doorbell_stride from SQ doorbell */
  if (!is_sq)
    offset += doorbell_stride;

  return bar0_phys + offset;
}

/* struct nvme_gpu_doorbell_info is defined in nvme_axiio.h */

#endif /* NVME_GPU_DOORBELL_H */
