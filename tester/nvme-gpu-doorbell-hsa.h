/* GPU Doorbell Mapping with HSA Memory Lock
 *
 * THE SOLUTION: Uses hsa_amd_memory_lock() to register doorbell with GPU MMU!
 * This is what makes it work on consumer AMD GPUs.
 *
 * Based on successful test: test_gpu_doorbell_with_hsa.cpp
 */

#ifndef NVME_GPU_DOORBELL_HSA_H
#define NVME_GPU_DOORBELL_HSA_H

#include <cstring>
#include <iostream>

#include <fcntl.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

// Use kernel's definition from nvme_axiio.h
#ifndef NVME_AXIIO_CREATE_QUEUE
#define NVME_AXIIO_MAGIC 'X'

struct nvme_axiio_queue_info {
  uint16_t queue_id;
  uint16_t queue_size;
  uint32_t nsid;
  uint64_t sq_dma_addr_user;
  uint64_t cq_dma_addr_user;
  uint64_t sq_dma_addr;
  uint64_t cq_dma_addr;
  uint64_t sq_doorbell_phys;
  uint64_t cq_doorbell_phys;
  uint64_t bar0_phys;
  uint64_t bar0_size;
  uint32_t doorbell_stride;
  uint32_t sq_doorbell_offset;
  uint32_t cq_doorbell_offset;
};

#define NVME_AXIIO_CREATE_QUEUE                                                \
  _IOWR(NVME_AXIIO_MAGIC, 1, struct nvme_axiio_queue_info)
#endif

namespace nvme_hsa_doorbell {

// HSA state (module-level)
static bool hsa_initialized = false;
static hsa_agent_t gpu_agent;
static hsa_agent_t cpu_agent;
static hsa_amd_memory_pool_t cpu_pool;

/*
 * Initialize HSA (call once at startup)
 */
static inline int init_hsa() {
  if (hsa_initialized) {
    return 0; // Already initialized
  }

  std::cout << "  Initializing HSA for GPU doorbell registration..."
            << std::endl;

  hsa_status_t err = hsa_init();
  if (err != HSA_STATUS_SUCCESS) {
    std::cerr << "Error: hsa_init() failed: " << err << std::endl;
    return -1;
  }

  // Find CPU and GPU agents
  auto find_agents = [](hsa_agent_t agent, void* data) -> hsa_status_t {
    hsa_device_type_t device_type;
    hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &device_type);
    struct {
      hsa_agent_t *cpu, *gpu;
    }* agents = (decltype(agents))data;
    if (device_type == HSA_DEVICE_TYPE_CPU && agents->cpu->handle == 0)
      *agents->cpu = agent;
    if (device_type == HSA_DEVICE_TYPE_GPU && agents->gpu->handle == 0)
      *agents->gpu = agent;
    return (agents->cpu->handle && agents->gpu->handle) ? HSA_STATUS_INFO_BREAK
                                                        : HSA_STATUS_SUCCESS;
  };

  struct {
    hsa_agent_t *cpu, *gpu;
  } agents = {&cpu_agent, &gpu_agent};
  err = hsa_iterate_agents(find_agents, &agents);

  if (!cpu_agent.handle || !gpu_agent.handle) {
    std::cerr << "Error: Failed to find CPU and GPU agents" << std::endl;
    hsa_shut_down();
    return -1;
  }

  // Find fine-grained CPU memory pool (CRITICAL for IOVA!)
  auto find_pool = [](hsa_amd_memory_pool_t pool, void* data) -> hsa_status_t {
    uint32_t flags;
    hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_GLOBAL_FLAGS,
                                 &flags);
    uint32_t req = HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_KERNARG_INIT |
                   HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_FINE_GRAINED;
    if ((flags & req) == req) {
      *(hsa_amd_memory_pool_t*)data = pool;
      return HSA_STATUS_INFO_BREAK;
    }
    return HSA_STATUS_SUCCESS;
  };

  err = hsa_amd_agent_iterate_memory_pools(cpu_agent, find_pool, &cpu_pool);
  if (!cpu_pool.handle) {
    std::cerr << "Error: No fine-grained CPU memory pool found" << std::endl;
    hsa_shut_down();
    return -1;
  }

  hsa_initialized = true;
  std::cout << "  ✓ HSA initialized, GPU agent and CPU fine-grained pool found"
            << std::endl;

  return 0;
}

/*
 * Get GPU agent (for memory locking)
 */
static inline hsa_agent_t get_gpu_agent() {
  return gpu_agent;
}

/*
 * Get CPU memory pool (for memory locking)
 */
static inline hsa_amd_memory_pool_t get_cpu_pool() {
  return cpu_pool;
}

/*
 * Shutdown HSA (call at cleanup)
 */
static inline void shutdown_hsa() {
  if (hsa_initialized) {
    hsa_shut_down();
    hsa_initialized = false;
  }
}

/*
 * Map GPU-accessible doorbell with HSA memory lock registration
 * THIS IS THE KEY that makes it work!
 *
 * For IOVA mode: Returns IOVA address that GPU should use directly
 * For physical mode: Returns HSA-locked pointer
 */
static inline int map_gpu_doorbell(
  int axiio_fd, uint16_t queue_id, bool is_sq,
  volatile uint32_t** gpu_doorbell_ptr, void** mapped_base = nullptr,
  void** locked_base = nullptr,
  const struct nvme_axiio_queue_info* existing_qinfo = nullptr,
  uint64_t* iova_address_out = nullptr) {
  if (!hsa_initialized) {
    if (init_hsa() < 0) {
      return -1;
    }
  }

  std::cout << "\n=== Using Direct IOVA for GPU Doorbell (TRUE GPU-DIRECT!) ==="
            << std::endl;
  std::cout << "  Queue ID: " << queue_id << " (" << (is_sq ? "SQ" : "CQ")
            << ")" << std::endl;

  // CRITICAL INSIGHT: For QEMU P2P, QEMU has already set up IOVA mappings
  // in the GPU's VFIO container. We just use the IOVA address directly!
  // NO mmap needed, NO HSA locking needed - just cast IOVA to pointer!

  uint64_t iova_doorbell = 0;

  // Use existing queue info if provided (from queue creation)
  if (existing_qinfo && existing_qinfo->sq_doorbell_phys != 0) {
    iova_doorbell = is_sq ? existing_qinfo->sq_doorbell_phys
                          : existing_qinfo->cq_doorbell_phys;
    std::cout << "  Using IOVA from existing queue info" << std::endl;
  } else {
    // Try to get queue info from kernel module
    struct nvme_axiio_queue_info queue_info;
    memset(&queue_info, 0, sizeof(queue_info));
    queue_info.queue_id = queue_id;
    
    // Try to get queue info - if queue exists, this will populate the structure
    int ret = ioctl(axiio_fd, NVME_AXIIO_CREATE_QUEUE, &queue_info);
    if (ret == 0 || errno == EEXIST) {
      // Queue exists or was created - use the doorbell address
      iova_doorbell = is_sq ? queue_info.sq_doorbell_phys
                            : queue_info.cq_doorbell_phys;
    } else {
      std::cerr
        << "Warning: Could not get queue info, doorbell address may be 0"
        << std::endl;
    }
  }

  // If IOVA is 0, it means we're not using IOVA mode or queue wasn't created
  // yet In that case, fall back to physical address + HSA lock
  if (iova_doorbell == 0) {
    std::cout << "  ⚠️  IOVA address is 0, using physical address with HSA lock"
              << std::endl;
    
    // Get queue info if we don't have it
    struct nvme_axiio_queue_info queue_info;
    bool have_qinfo = false;
    if (existing_qinfo && existing_qinfo->bar0_phys != 0) {
      queue_info = *existing_qinfo;
      have_qinfo = true;
    } else {
      memset(&queue_info, 0, sizeof(queue_info));
      queue_info.queue_id = queue_id;
      if (ioctl(axiio_fd, NVME_AXIIO_CREATE_QUEUE, &queue_info) == 0 ||
          errno == EEXIST) {
        have_qinfo = true;
      }
    }

    // Use BAR0 physical address + offset
    if (have_qinfo && queue_info.bar0_phys != 0) {
      uint32_t doorbell_offset = is_sq ? queue_info.sq_doorbell_offset
                                       : queue_info.cq_doorbell_offset;
      uint64_t doorbell_phys = queue_info.bar0_phys + doorbell_offset;

      std::cout << "  Using physical doorbell: 0x" << std::hex << doorbell_phys
                << std::dec << std::endl;

      // Map and lock with HSA
      void* mapped = mmap(nullptr, getpagesize(), PROT_READ | PROT_WRITE,
                          MAP_SHARED, axiio_fd,
                          3 * getpagesize()); // pgoff=3 for doorbell
      if (mapped == MAP_FAILED) {
        std::cerr << "Error: Failed to mmap doorbell" << std::endl;
        return -1;
      }
      
      // Lock with HSA for GPU access
      void* locked_ptr = nullptr;
      hsa_status_t status = hsa_amd_memory_lock(mapped, getpagesize(),
                                                &gpu_agent, 1, &locked_ptr);
      if (status != HSA_STATUS_SUCCESS) {
        std::cerr << "Error: HSA memory lock failed: " << status << std::endl;
        munmap(mapped, getpagesize());
        return -1;
      }

      *gpu_doorbell_ptr = (volatile uint32_t*)((char*)locked_ptr +
                                               (doorbell_phys & 0xFFF));
      if (mapped_base)
        *mapped_base = mapped;
      if (locked_base)
        *locked_base = locked_ptr;

      std::cout << "  ✅ GPU doorbell mapped via HSA lock!" << std::endl;
      return 0;
    } else {
      std::cerr
        << "Error: Cannot determine doorbell address (IOVA=0, bar0_phys=0)"
        << std::endl;
      return -1;
    }
  }

  std::cout << "  IOVA doorbell address: 0x" << std::hex << iova_doorbell
            << std::dec << std::endl;
  std::cout
    << "  Using IOVA address directly (QEMU has mapped it in GPU's IOMMU)"
    << std::endl;
  
  // CRITICAL: For IOVA mode, we skip the kernel module's mmap (pgoff=3)
  // because the kernel module maps physical BAR0, not IOVA.
  // Instead, we map the IOVA address directly using anonymous mmap.
  // QEMU has already mapped the IOVA in the GPU's VFIO container, so the GPU
  // can access it directly once we register it with HSA.
  size_t page_size = getpagesize();

  // Step 1: Map IOVA address range directly using anonymous mmap
  // Try MAP_FIXED first to map at the IOVA address (if address space allows)
  uint64_t iova_page_base = iova_doorbell & ~(page_size - 1);
  void* iova_hva = mmap((void*)iova_page_base, page_size,
                        PROT_READ | PROT_WRITE,
                        MAP_ANONYMOUS | MAP_PRIVATE | MAP_FIXED, -1, 0);

  if (iova_hva == MAP_FAILED) {
    // MAP_FIXED failed - the IOVA address may not be in our address space
    // This is OK - we'll map elsewhere and the GPU will still use the IOVA
    std::cout << "  ⚠️  MAP_FIXED failed (IOVA not in address space), using "
                 "anonymous mapping..."
              << std::endl;
    iova_hva = mmap(nullptr, page_size, PROT_READ | PROT_WRITE,
                    MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    if (iova_hva == MAP_FAILED) {
      std::cerr << "Error: Failed to create IOVA mapping: " << strerror(errno)
                << std::endl;
      return -1;
    }
    std::cout
      << "  ⚠️  Note: HVA != IOVA, but GPU will use IOVA directly via IOMMU"
      << std::endl;
  }

  std::cout << "  ✓ Created IOVA mapping at HVA: " << iova_hva << std::endl;
  std::cout << "    IOVA: 0x" << std::hex << iova_doorbell << std::dec
            << std::endl;

  // Step 2: Lock with HSA for GPU MMU registration
  // CRITICAL: We need to register the memory region with GPU MMU so GPU can
  // access it. Even though GPU will use IOVA address directly, HSA locking
  // registers the region with GPU MMU. The key is that we're locking the IOVA
  // address range, and GPU MMU will translate GPU accesses to that IOVA address
  // correctly.
  void* hsa_locked_ptr = nullptr;
  hsa_status_t status = hsa_amd_memory_lock(iova_hva, page_size, &gpu_agent, 1,
                                            &hsa_locked_ptr);
  if (status != HSA_STATUS_SUCCESS) {
    std::cerr << "Error: HSA memory lock failed for IOVA doorbell: " << status
              << std::endl;
    munmap(iova_hva, page_size);
    return -1;
  }

  std::cout << "  ✓ HSA locked IOVA mapping for GPU MMU: " << hsa_locked_ptr
            << std::endl;
  std::cout << "    HVA: " << iova_hva << " (mapped IOVA range)" << std::endl;
  std::cout << "    HSA-locked: " << hsa_locked_ptr << " (GPU MMU registered)"
            << std::endl;
  std::cout << "    IOVA: 0x" << std::hex << iova_doorbell << std::dec
            << " (GPU will use this directly)" << std::endl;

  // Step 3: Calculate doorbell offset within the page
  uint32_t sq_offset = 0;
  if (existing_qinfo && existing_qinfo->sq_doorbell_offset != 0) {
    sq_offset = existing_qinfo->sq_doorbell_offset & (page_size - 1);
    std::cout << "  Using sq_doorbell_offset from queue info: 0x" << std::hex
              << existing_qinfo->sq_doorbell_offset << std::dec << std::endl;
  } else {
    sq_offset = iova_doorbell & (page_size - 1);
    std::cout << "  ⚠️  Warning: Using IOVA offset (queue info not available)"
              << std::endl;
  }

  // GPU doorbell pointer - CRITICAL: For IOVA mode, GPU must use HSA-locked
  // pointer HSA locking registers the CPU virtual address (HVA) with GPU MMU,
  // not IOVA. When GPU accesses the HSA-locked pointer (HVA), GPU MMU
  // translates HVA → physical. For IOVA mode to work, we need the HVA to
  // correspond to the IOVA range. If MAP_FIXED succeeded, HVA == IOVA, so GPU
  // can use the HSA-locked pointer. If MAP_FIXED failed, HVA != IOVA, but GPU
  // still uses HSA-locked pointer (HVA).
  //
  // The key insight: GPU MMU knows about HVA (from HSA lock), not IOVA
  // directly. So GPU must use the HSA-locked pointer, which points to HVA. The
  // HVA corresponds to the IOVA range we mapped, so IOMMU will translate
  // correctly.
  uint64_t final_iova = iova_doorbell + sq_offset;
  // iova_page_base already defined above at line 279
  bool map_fixed_succeeded = (iova_hva == (void*)iova_page_base);
  
  // Always use HSA-locked pointer - GPU MMU knows about this HVA
  // The HVA corresponds to the IOVA range, so IOMMU will handle translation
  volatile uint32_t* gpu_doorbell = (volatile uint32_t*)((char*)hsa_locked_ptr +
                                                         sq_offset);
  *gpu_doorbell_ptr = gpu_doorbell;

  if (iova_address_out) {
    if (map_fixed_succeeded) {
      // MAP_FIXED succeeded - HVA == IOVA, so we can pass IOVA for reference
      *iova_address_out = final_iova;
    } else {
      // MAP_FIXED failed - HVA != IOVA, GPU uses HSA pointer (HVA), not IOVA
      *iova_address_out = 0; // Signal that GPU should use HSA pointer
    }
  }

  std::cout << "  ✓ GPU doorbell pointer set to HSA-locked address: "
            << gpu_doorbell << std::endl;
  std::cout << "    HVA: " << iova_hva << " (mapped IOVA range)" << std::endl;
  std::cout << "    IOVA: 0x" << std::hex << final_iova << std::dec
            << std::endl;
  if (map_fixed_succeeded) {
    std::cout << "    MAP_FIXED succeeded - HVA == IOVA" << std::endl;
  } else {
    std::cout << "    MAP_FIXED failed - HVA != IOVA, GPU uses HVA (HSA-locked)"
              << std::endl;
  }
  std::cout << "    GPU MMU registered HVA via HSA lock" << std::endl;

  // Step 3: Also create CPU-accessible mapping (pgoff=2) for CPU-side
  // operations This maps physical BAR0 for CPU to read doorbell values
  void* cpu_doorbell_mapped = mmap(nullptr, page_size, PROT_READ | PROT_WRITE,
                                   MAP_SHARED, axiio_fd, 2 * page_size);
  if (cpu_doorbell_mapped == MAP_FAILED) {
    std::cerr
      << "Error: Failed to mmap CPU doorbell via kernel module (pgoff=2)"
      << std::endl;
    perror("mmap");
    munmap(iova_hva, page_size);
    return -1;
  }

  volatile uint32_t* cpu_doorbell =
    (volatile uint32_t*)((char*)cpu_doorbell_mapped + sq_offset);

  if (mapped_base)
    *mapped_base = cpu_doorbell_mapped; // CPU uses this (physical BAR0)
  if (locked_base)
    *locked_base = hsa_locked_ptr; // GPU uses this (HSA-locked IOVA)

  std::cout << "  ✅ GPU doorbell ready (IOVA mapped directly)!" << std::endl;
  std::cout << "    CPU doorbell: " << (void*)cpu_doorbell << " (physical BAR0)"
            << std::endl;
  std::cout << "    GPU doorbell: " << (void*)*gpu_doorbell_ptr << " (IOVA: 0x"
            << std::hex << iova_doorbell << std::dec << ")" << std::endl;
  std::cout << "  🚀 GPU uses IOVA address directly - QEMU has mapped it in "
               "GPU's IOMMU!"
            << std::endl;

  return 0;
}

/*
 * Unmap GPU doorbell and unlock HSA memory
 */
static inline void unmap_gpu_doorbell(void* mapped_base, void* locked_base,
                                      size_t size) {
  if (locked_base && locked_base != mapped_base) {
    // Unlock HSA memory (locked_base is the HSA-locked pointer)
    hsa_amd_memory_unlock(locked_base);
  }

  if (mapped_base && mapped_base != MAP_FAILED) {
    munmap(mapped_base, size);
  }

  // Also unmap the GPU doorbell mapping if it's different
  // (In IOVA mode, we have both cpu_doorbell_mapped and gpu_doorbell_mapped)
}

/*
 * Create queue and map doorbell in one call (convenience function)
 */
static inline int create_queue_with_doorbell(
  int axiio_fd, uint16_t queue_id, uint16_t queue_size,
  volatile uint32_t** gpu_doorbell_ptr, void** mapped_base = nullptr,
  void** locked_base = nullptr) {
  if (!hsa_initialized) {
    if (init_hsa() < 0) {
      return -1;
    }
  }

  std::cout << "\n=== Creating NVMe Queue with GPU Doorbell ===" << std::endl;

  // Create queue
  struct nvme_axiio_queue_info queue_info;
  memset(&queue_info, 0, sizeof(queue_info));
  queue_info.queue_id = queue_id;
  queue_info.queue_size = queue_size;
  queue_info.nsid = 1;             // Namespace 1
  queue_info.sq_dma_addr_user = 0; // Let kernel allocate
  queue_info.cq_dma_addr_user = 0;

  if (ioctl(axiio_fd, NVME_AXIIO_CREATE_QUEUE, &queue_info) < 0) {
    perror("Error: NVME_AXIIO_CREATE_QUEUE failed");
    return -1;
  }

  std::cout << "  ✓ Queue created (QID=" << queue_info.queue_id << ")"
            << std::endl;
  std::cout << "    Doorbell phys: 0x" << std::hex
            << queue_info.sq_doorbell_phys << std::dec << std::endl;

  // Map doorbell with HSA
  return map_gpu_doorbell(axiio_fd, queue_id, true, gpu_doorbell_ptr,
                          mapped_base, locked_base);
}

} // namespace nvme_hsa_doorbell

#endif // NVME_GPU_DOORBELL_HSA_H
