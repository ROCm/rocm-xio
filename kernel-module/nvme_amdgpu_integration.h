/* SPDX-License-Identifier: GPL-2.0 */
/*
 * NVMe + AMDGPU Integration - TRUE GPU-Direct Doorbell
 *
 * This integrates our NVMe driver with AMD's GPU driver to register
 * the NVMe doorbell MMIO region in the GPU's page tables.
 *
 * Based on how rocSHMEM GDA integrates InfiniBand with amdgpu.
 */

#ifndef NVME_AMDGPU_INTEGRATION_H
#define NVME_AMDGPU_INTEGRATION_H

#include <linux/file.h>
#include <linux/mm.h>
#include <linux/pci.h>

/* Try to include amdgpu headers if available */
#ifdef CONFIG_DRM_AMDGPU
#include <drm/drm_device.h>
#include <drm/drm_file.h>

/* AMD GPU driver headers - adjust path as needed */
#define AMDGPU_SRC_PATH "/usr/src/amdgpu-6.16.6-2238411.24.04"

/* These would be the proper includes, but may not be in kernel tree */
/* We'll use function pointers instead for maximum compatibility */
#endif

/*
 * GPU-direct doorbell context with amdgpu integration
 */
struct nvme_amdgpu_doorbell {
  struct file* gpu_file; /* GPU render node file */
  int gpu_fd;            /* GPU FD */

  resource_size_t doorbell_phys; /* Doorbell physical address */
  size_t size;                   /* Mapping size */

  void __user* gpu_va; /* GPU virtual address */
  bool gpu_mapped;     /* GPU MMU registered */

  /* amdgpu objects (if amdgpu integration works) */
  void* amdgpu_bo; /* Buffer object (opaque) */
  void* amdgpu_vm; /* VM context (opaque) */
};

/*
 * Function signatures for amdgpu integration
 * We use function pointers to avoid hard dependencies
 */
struct amdgpu_integration_ops {
  /* Get amdgpu device from DRM file */
  void* (*get_adev_from_drm)(struct drm_device* drm_dev);

  /* Create buffer object for MMIO */
  int (*bo_create_kernel)(void* adev, unsigned long size, int align, int domain,
                          void** bo_ptr, uint64_t* gpu_addr, void** cpu_addr);

  /* Map BO into VM */
  int (*vm_bo_map)(void* adev, void* bo_va, uint64_t addr, uint64_t offset,
                   uint64_t size, uint32_t flags);

  /* Cleanup */
  void (*bo_free)(void* bo);
};

/* Global ops table - will be populated if amdgpu is available */
static struct amdgpu_integration_ops amdgpu_ops = {NULL};

/*
 * Initialize amdgpu integration (try to find symbols)
 *
 * This attempts to dynamically link with amdgpu driver functions.
 * If it fails, we fall back to standard mapping (no GPU MMU registration).
 */
static inline int nvme_amdgpu_init(void) {
  pr_info("nvme_axiio: Attempting to initialize amdgpu integration...\n");

#ifdef CONFIG_DRM_AMDGPU
  /* Try to find amdgpu symbols dynamically */
  /* This would use symbol_get() or similar */

  /*
   * Ideally we would do:
   * amdgpu_ops.get_adev_from_drm = symbol_get(to_amdgpu_device);
   * amdgpu_ops.bo_create_kernel = symbol_get(amdgpu_bo_create_kernel);
   * amdgpu_ops.vm_bo_map = symbol_get(amdgpu_vm_bo_map);
   *
   * But these symbols may not be exported.
   * Alternative: Build as part of amdgpu tree.
   */

  pr_warn("nvme_axiio: amdgpu symbol linking not yet implemented\n");
  pr_warn("  Will use fallback mapping (no GPU MMU registration)\n");
  return -ENOSYS;
#else
  pr_info("nvme_axiio: amdgpu not available in kernel config\n");
  return -ENODEV;
#endif
}

/*
 * Register NVMe doorbell with amdgpu for GPU MMU access
 *
 * This is the KEY function that would enable TRUE GPU-direct!
 */
static inline int nvme_register_doorbell_with_amdgpu(
  struct nvme_amdgpu_doorbell* ctx, struct drm_device* drm_dev) {
  void* adev;
  void* doorbell_bo = NULL;
  uint64_t gpu_va = 0;
  int ret;

  pr_info("nvme_axiio: Registering doorbell with amdgpu...\n");

  /* Check if amdgpu ops are available */
  if (!amdgpu_ops.get_adev_from_drm) {
    pr_warn("nvme_axiio: amdgpu integration not available\n");
    pr_warn("  Doorbell will be mapped but NOT registered with GPU MMU\n");
    pr_warn("  This may cause GPU page faults!\n");
    return -ENOSYS;
  }

  /* Get amdgpu device */
  adev = amdgpu_ops.get_adev_from_drm(drm_dev);
  if (!adev) {
    pr_err("nvme_axiio: Could not get amdgpu device\n");
    return -ENODEV;
  }

  pr_info("nvme_axiio: Got amdgpu device\n");

  /*
   * Create kernel buffer object for doorbell MMIO
   *
   * This tells amdgpu about our MMIO region and gets a GPU VA for it.
   */
  ret = amdgpu_ops.bo_create_kernel(adev, ctx->size, PAGE_SIZE,
                                    2, /* AMDGPU_GEM_DOMAIN_GTT */
                                    &doorbell_bo, &gpu_va, NULL);
  if (ret) {
    pr_err("nvme_axiio: amdgpu_bo_create_kernel failed: %d\n", ret);
    return ret;
  }

  pr_info("nvme_axiio: Created amdgpu BO for doorbell\n");
  pr_info("  GPU VA: 0x%llx\n", gpu_va);

  /*
   * Map the physical doorbell address into the BO
   *
   * This is where we tell amdgpu: "This GPU VA maps to this PCIe MMIO address"
   */
  ret = amdgpu_ops.vm_bo_map(adev, doorbell_bo, ctx->doorbell_phys, 0,
                             ctx->size, 0);
  if (ret) {
    pr_err("nvme_axiio: amdgpu_vm_bo_map failed: %d\n", ret);
    amdgpu_ops.bo_free(doorbell_bo);
    return ret;
  }

  pr_info("nvme_axiio: ✓✓✓ Doorbell registered with GPU MMU! ✓✓✓\n");
  pr_info("  Physical: 0x%llx\n", (u64)ctx->doorbell_phys);
  pr_info("  GPU VA:   0x%llx\n", gpu_va);
  pr_info("  GPU can now access doorbell directly!\n");

  /* Store for cleanup */
  ctx->amdgpu_bo = doorbell_bo;
  ctx->gpu_va = (void __user*)gpu_va;
  ctx->gpu_mapped = true;

  return 0;
}

/*
 * Setup GPU-direct doorbell (entry point)
 */
static inline int nvme_setup_gpu_doorbell(struct nvme_amdgpu_doorbell* ctx,
                                          int gpu_fd,
                                          resource_size_t doorbell_phys,
                                          size_t size) {
  struct file* gpu_file;
  struct drm_device* drm_dev = NULL;
  int ret;

  pr_info("nvme_axiio: Setting up GPU-direct doorbell...\n");
  pr_info("  GPU FD: %d\n", gpu_fd);
  pr_info("  Doorbell phys: 0x%llx\n", (u64)doorbell_phys);

  /* Get GPU file */
  gpu_file = fget(gpu_fd);
  if (!gpu_file) {
    pr_err("nvme_axiio: Invalid GPU FD\n");
    return -EBADF;
  }

  pr_info("nvme_axiio: GPU file: %s\n", gpu_file->f_path.dentry->d_name.name);

  /* Initialize context */
  ctx->gpu_file = gpu_file;
  ctx->gpu_fd = gpu_fd;
  ctx->doorbell_phys = doorbell_phys;
  ctx->size = size;
  ctx->gpu_mapped = false;

#ifdef CONFIG_DRM_AMDGPU
  /* Try to get DRM device from file */
  if (gpu_file->f_op && gpu_file->private_data) {
    /* This is where we'd extract drm_device */
    /* For now, skip - will use fallback */
    pr_info("nvme_axiio: GPU file looks like DRM device\n");
  }
#endif

  /* Try amdgpu registration if available */
  if (drm_dev && amdgpu_ops.get_adev_from_drm) {
    ret = nvme_register_doorbell_with_amdgpu(ctx, drm_dev);
    if (ret == 0) {
      pr_info("nvme_axiio: ✓ TRUE GPU-DIRECT enabled!\n");
      return 0;
    }
    pr_warn("nvme_axiio: amdgpu registration failed, using fallback\n");
  }

  /* Fallback: Regular mapping (no GPU MMU registration) */
  pr_info("nvme_axiio: Using fallback mapping\n");
  pr_info("  Will map with GPU-friendly VMA flags\n");
  pr_info("  But GPU MMU will NOT be registered - may cause page faults\n");

  return 0;
}

/*
 * Cleanup GPU doorbell
 */
static inline void nvme_cleanup_gpu_doorbell(struct nvme_amdgpu_doorbell* ctx) {
  if (ctx->amdgpu_bo && amdgpu_ops.bo_free) {
    amdgpu_ops.bo_free(ctx->amdgpu_bo);
    ctx->amdgpu_bo = NULL;
  }

  if (ctx->gpu_file) {
    fput(ctx->gpu_file);
    ctx->gpu_file = NULL;
  }

  ctx->gpu_mapped = false;

  pr_info("nvme_axiio: GPU doorbell cleaned up\n");
}

/*
 * Enhanced mmap for GPU-aware doorbell
 *
 * Uses VM_MIXEDMAP to allow GPU driver page fault handling
 */
static inline int nvme_mmap_gpu_doorbell(struct vm_area_struct* vma,
                                         struct nvme_amdgpu_doorbell* ctx) {
  unsigned long pfn;
  unsigned long page_base;
  int ret;

  page_base = ctx->doorbell_phys & PAGE_MASK;
  pfn = page_base >> PAGE_SHIFT;

  pr_info("nvme_axiio: mmap GPU doorbell\n");
  pr_info("  PFN: 0x%lx\n", pfn);
  pr_info("  Size: %zu\n", ctx->size);
  pr_info("  GPU mapped: %s\n", ctx->gpu_mapped ? "YES" : "NO");

  /* GPU-friendly page protection */
  vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);

  /*
   * Critical flags:
   * - VM_IO: Device memory
   * - VM_PFNMAP: Direct PFN mapping
   * - VM_MIXEDMAP: Allows GPU driver to insert its own PTEs
   * - VM_DONTEXPAND: Don't grow
   * - VM_DONTDUMP: Don't include in core dumps
   */
  vm_flags_set(vma,
               VM_IO | VM_PFNMAP | VM_MIXEDMAP | VM_DONTEXPAND | VM_DONTDUMP);

  /* Map the physical pages */
  ret = remap_pfn_range(vma, vma->vm_start, pfn, ctx->size, vma->vm_page_prot);
  if (ret) {
    pr_err("nvme_axiio: remap_pfn_range failed: %d\n", ret);
    return ret;
  }

  if (ctx->gpu_mapped) {
    pr_info("nvme_axiio: ✓✓✓ TRUE GPU-DIRECT doorbell mapped! ✓✓✓\n");
    pr_info("  GPU VA: 0x%llx\n", (u64)ctx->gpu_va);
    pr_info("  GPU MMU has this address - no page faults!\n");
  } else {
    pr_info("nvme_axiio: ✓ Doorbell mapped with GPU-friendly flags\n");
    pr_warn("  GPU MMU NOT registered - may cause page faults\n");
    pr_warn("  For TRUE GPU-direct, need amdgpu integration\n");
  }

  return 0;
}

#endif /* NVME_AMDGPU_INTEGRATION_H */
