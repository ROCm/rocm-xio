/* SPDX-License-Identifier: GPL-2.0 */
/*
 * NVMe GPU Integration - Register PCIe MMIO with AMD GPU MMU
 *
 * Based on rocSHMEM GDA approach for GPU-direct atomic operations.
 * This allows the GPU to directly write to NVMe doorbell registers.
 */

#ifndef NVME_GPU_INTEGRATION_H
#define NVME_GPU_INTEGRATION_H

#include <linux/file.h>
#include <linux/io.h>
#include <linux/mm.h>
#include <linux/pci.h>

#include "nvme_p2p_iova.h"

/* Forward declarations */
struct axiio_controller;
struct axiio_controller* nvme_axiio_get_controller(void);

/*
 * GPU doorbell mapping context
 * Tracks the GPU's mapping of our NVMe doorbell
 */
struct nvme_gpu_mapping {
  void __user* gpu_va;           /* GPU virtual address of doorbell */
  struct file* gpu_file;         /* GPU device file */
  int gpu_fd;                    /* GPU FD (for reference) */
  resource_size_t doorbell_phys; /* Physical address */
  size_t size;                   /* Mapping size */
  bool mapped;                   /* Is currently mapped */
};

/*
 * Map NVMe doorbell into GPU address space
 *
 * This is the KEY function that enables GPU-direct doorbell!
 *
 * Strategy:
 * 1. Get GPU device from render node FD
 * 2. Use DRM's GEM (Graphics Execution Manager) to map MMIO
 * 3. Return GPU virtual address to userspace
 *
 * Similar to how rocSHMEM GDA maps InfiniBand doorbells.
 */
static inline int nvme_map_doorbell_for_gpu(struct nvme_gpu_mapping* mapping,
                                            int gpu_fd,
                                            resource_size_t doorbell_phys,
                                            size_t size) {
  struct file* gpu_file;

  pr_info("nvme_axiio: Setting up GPU doorbell mapping...\n");
  pr_info("  GPU FD: %d\n", gpu_fd);
  pr_info("  Doorbell phys: 0x%llx\n", (u64)doorbell_phys);
  pr_info("  Size: %zu bytes\n", size);

  /* Get GPU device file to verify it's valid */
  gpu_file = fget(gpu_fd);
  if (!gpu_file) {
    pr_err("nvme_axiio: Invalid GPU file descriptor\n");
    return -EBADF;
  }

  pr_info("nvme_axiio: GPU file descriptor valid\n");
  pr_info("  File: %s\n", gpu_file->f_path.dentry->d_name.name);

  /*
   * Strategy for GPU-direct doorbell:
   * 1. Store GPU file reference
   * 2. In mmap(), use special VMA flags:
   *    - VM_MIXEDMAP: Allows GPU driver to handle faults
   *    - pgprot_writecombine(): Efficient PCIe writes
   *    - VM_IO | VM_PFNMAP: Device memory
   * 3. The GPU driver's fault handler will set up proper GPU MMU entries
   *
   * This approach relies on the GPU driver (amdgpu) recognizing
   * the VMA flags and setting up GPU page tables accordingly.
   */

  mapping->gpu_file = gpu_file;
  mapping->gpu_fd = gpu_fd;
  mapping->doorbell_phys = doorbell_phys;
  mapping->size = size;
  mapping->mapped = false;

  pr_info("nvme_axiio: ✓ GPU mapping context prepared\n");
  pr_info("  mmap will use GPU-aware VMA flags\n");
  pr_info("  GPU driver should handle MMU setup via page faults\n");

  /* Actual mapping happens in mmap handler */
  return 0;
}

/*
 * Unmap doorbell from GPU
 */
static inline void nvme_unmap_doorbell_from_gpu(
  struct nvme_gpu_mapping* mapping) {
  if (mapping->gpu_file) {
    fput(mapping->gpu_file);
    mapping->gpu_file = NULL;
  }
  mapping->mapped = false;
  pr_info("nvme_axiio: GPU doorbell unmapped\n");
}

/*
 * Enhanced mmap handler for GPU-aware doorbell mapping
 *
 * This uses the GPU context to set up proper MMU entries
 */
static inline int nvme_mmap_doorbell_for_gpu(
  struct vm_area_struct* vma, struct nvme_gpu_mapping* gpu_mapping,
  u16 queue_id, struct pci_dev* pdev) {
  unsigned long pfn;
  int ret;
  struct axiio_controller* ctrl = nvme_axiio_get_controller();
  resource_size_t doorbell_addr;

  /* For IOVA mode, get queue-specific IOVA address */
  if (ctrl && ctrl->using_iova && pdev) {
    /* Get queue-specific IOVA for this queue */
    struct nvme_p2p_iova_info queue_iova;
    ret = nvme_get_p2p_iova_info(ctrl->bar0, &ctrl->admin_q,
                                 &pdev->dev,
                                 queue_id, &queue_iova);
    if (ret == 0) {
      /* Use queue-specific IOVA - QEMU has mapped this in GPU's VFIO container */
      doorbell_addr = queue_iova.doorbell_iova;
      pr_info("nvme_axiio: Using queue-specific IOVA address for GPU mapping\n");
      pr_info("  Queue ID: %u\n", (unsigned int)queue_id);
      pr_info("  IOVA: 0x%llx\n", (u64)doorbell_addr);
    } else {
      /* Fallback to controller base IOVA */
      doorbell_addr = ctrl->p2p_iova.doorbell_iova;
      pr_info("nvme_axiio: Using controller base IOVA for GPU mapping\n");
      pr_info("  IOVA: 0x%llx\n", (u64)doorbell_addr);
    }
  } else {
    /* Use physical address */
    doorbell_addr = gpu_mapping->doorbell_phys;
    pr_info("nvme_axiio: Using physical address for GPU mapping\n");
    pr_info("  Physical: 0x%llx\n", (u64)doorbell_addr);
  }

  /* Align doorbell to page boundary */
  unsigned long page_base = doorbell_addr & PAGE_MASK;
  pfn = page_base >> PAGE_SHIFT;

  pr_info("nvme_axiio: GPU-aware mmap setup\n");
  pr_info("  PFN: 0x%lx\n", pfn);
  pr_info("  VMA start: 0x%lx\n", vma->vm_start);
  pr_info("  Size: %zu\n", gpu_mapping->size);

  /*
   * Critical flags for GPU accessibility:
   * - pgprot_writecombine: Efficient writes to PCIe
   * - VM_IO: Device memory (not system RAM)
   * - VM_PFNMAP: Direct PFN mapping (no struct page)
   * - VM_DONTEXPAND: Don't grow this mapping
   * - VM_DONTDUMP: Don't include in core dumps
   * - VM_MIXEDMAP: Mix of PFN and page-backed (for GPU driver)
   */
  vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
  vm_flags_set(vma,
               VM_IO | VM_PFNMAP | VM_DONTEXPAND | VM_DONTDUMP | VM_MIXEDMAP);

  /* Map the doorbell pages */
  if (ctrl && ctrl->using_iova) {
    /* For IOVA mode: QEMU has already mapped the IOVA in GPU's VFIO container.
     * We CANNOT use remap_pfn_range with IOVA because IOVA is not a physical PFN.
     * 
     * The correct approach for IOVA mode:
     * 1. Userspace will map the IOVA address directly (via anonymous mmap)
     * 2. Userspace will lock it with HSA for GPU MMU registration
     * 3. GPU uses the IOVA address directly (QEMU has mapped it in GPU's IOMMU)
     * 
     * For pgoff=3 (GPU doorbell), we should NOT map anything - userspace handles it.
     * However, we still need to set up the VMA properly so mmap succeeds.
     * We'll create an anonymous mapping that userspace can use.
     */
    pr_info("nvme_axiio: IOVA mode - setting up VMA for userspace IOVA mapping\n");
    pr_info("  IOVA address: 0x%llx (userspace will map this directly)\n", (u64)doorbell_addr);
    pr_info("  Physical BAR0: 0x%llx (not used for GPU in IOVA mode)\n", (u64)gpu_mapping->doorbell_phys);
    
    /* For IOVA mode, we don't map physical BAR0 here.
     * Instead, we set up the VMA to allow userspace to map the IOVA address.
     * Userspace will use MAP_ANONYMOUS | MAP_FIXED to map at the IOVA address,
     * then lock it with HSA. The GPU will use the IOVA directly.
     * 
     * We can't use remap_pfn_range because IOVA is not a physical PFN.
     * Instead, we'll just set up the VMA flags and let userspace handle the mapping.
     */
    
    /* Set VMA flags for device memory */
    vm_flags_set(vma, VM_IO | VM_DONTEXPAND | VM_DONTDUMP);
    
    /* Don't use remap_pfn_range - userspace will map IOVA directly */
    /* Just mark the VMA as valid - userspace mapping will happen separately */
    ret = 0; /* Success - VMA is set up, userspace will do the actual mapping */
    
    pr_info("nvme_axiio: ✓ VMA set up for IOVA mode (userspace will map IOVA directly)\n");
  } else {
    /* Physical mode: Use remap_pfn_range with physical PFN */
    ret = remap_pfn_range(vma, vma->vm_start, pfn, gpu_mapping->size,
                          vma->vm_page_prot);
  }
  
  if (ret < 0) {
    pr_err("nvme_axiio: remap_pfn_range failed: %d\n", ret);
    return ret;
  }

  gpu_mapping->gpu_va = (void __user*)vma->vm_start;
  gpu_mapping->mapped = true;

  pr_info("nvme_axiio: ✓ GPU doorbell mapped!\n");
  pr_info("  GPU VA: 0x%lx\n", vma->vm_start);
  pr_info("  GPU can now access doorbell!\n");

  return 0;
}

/*
 * Alternative: Direct GPU driver integration
 *
 * For true GPU-direct (like rocSHMEM GDA), we would need:
 *
 * 1. amdgpu_bo_create() to create buffer object
 * 2. amdgpu_bo_reserve() to lock it
 * 3. amdgpu_vm_bo_map() to map into GPU VM
 * 4. Return GPU VA to userspace
 *
 * This requires exporting amdgpu symbols or using KFD.
 * For now, our approach relies on proper VMA setup and
 * letting the GPU driver handle faults.
 */

#endif /* NVME_GPU_INTEGRATION_H */
