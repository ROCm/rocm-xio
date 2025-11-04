/*
 * GPU Doorbell Mapping Helper
 *
 * Uses kernel module + HSA APIs to map NVMe doorbell for GPU peer-to-peer
 * access
 */

#ifndef GPU_DOORBELL_MAP_H
#define GPU_DOORBELL_MAP_H

#include <cstring>
#include <iostream>

#include <fcntl.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <linux/kfd_ioctl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "../kernel-module/nvme_axiio.h"

namespace gpu_doorbell {

struct DoorbellMapping {
  void* cpu_ptr;       // CPU-accessible pointer (via /dev/mem)
  void* gpu_ptr;       // GPU-accessible pointer (KFD mapped)
  uint64_t bus_addr;   // Bus address for P2P
  uint64_t phys_addr;  // Physical address
  uint32_t offset;     // Offset in BAR0
  int mem_fd;          // /dev/mem fd
  int kfd_fd;          // /dev/kfd fd for GPU mapping
  uint64_t kfd_handle; // KFD memory handle
  uint32_t gpu_id;     // KFD GPU ID
  void* bar0_mapped;   // mmap'd BAR0 region
  size_t bar0_size;    // BAR0 size
};

/*
 * Map NVMe doorbell for both CPU and GPU access
 */
static inline int map_doorbell_for_gpu(int axiio_fd, uint16_t queue_id,
                                       DoorbellMapping* mapping) {
  int ret;
  hsa_status_t status;

  std::cout << "\n=== Mapping NVMe Doorbell for GPU Access ===" << std::endl;
  std::cout << "  Queue ID: " << queue_id << std::endl;

  if (axiio_fd < 0) {
    std::cerr << "Error: Invalid axiio_fd" << std::endl;
    return -1;
  }

  // Get doorbell mapping info from kernel
  struct nvme_axiio_doorbell_mapping map;
  memset(&map, 0, sizeof(map));
  map.queue_id = queue_id;

  ret = ioctl(axiio_fd, NVME_AXIIO_MAP_DOORBELL_FOR_GPU, &map);

  if (ret < 0) {
    perror("Error: NVME_AXIIO_MAP_DOORBELL_FOR_GPU ioctl failed");
    return -1;
  }

  std::cout << "✓ Got doorbell mapping from kernel:" << std::endl;
  std::cout << "    BAR0 bus address: 0x" << std::hex << map.bar0_bus_addr
            << std::dec << std::endl;
  std::cout << "    BAR0 physical: 0x" << std::hex << map.bar0_phys << std::dec
            << std::endl;
  std::cout << "    Doorbell offset: 0x" << std::hex << map.doorbell_offset
            << std::dec << std::endl;
  std::cout << "    Doorbell bus address: 0x" << std::hex
            << map.doorbell_bus_addr << std::dec << " (for GPU)" << std::endl;

  // Store info
  mapping->bus_addr = map.doorbell_bus_addr;
  mapping->phys_addr = map.doorbell_phys;
  mapping->offset = map.doorbell_offset;
  mapping->bar0_size = map.bar0_size;
  mapping->mem_fd = -1;
  mapping->bar0_mapped = nullptr;

  // Step 1: Map for CPU access via /dev/mem
  std::cout << "\n  Step 1: Mapping for CPU access via /dev/mem..."
            << std::endl;

  mapping->mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
  if (mapping->mem_fd < 0) {
    perror("Error: Failed to open /dev/mem");
    return -1;
  }

  size_t page_size = sysconf(_SC_PAGE_SIZE);
  uint64_t page_base = map.doorbell_phys & ~(page_size - 1);
  size_t page_offset = map.doorbell_phys - page_base;

  void* mapped = mmap(NULL, page_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                      mapping->mem_fd, page_base);
  if (mapped == MAP_FAILED) {
    perror("Error: mmap failed");
    close(mapping->mem_fd);
    return -1;
  }

  mapping->cpu_ptr = (char*)mapped + page_offset;
  mapping->bar0_mapped = mapped;
  mapping->bar0_size = page_size;
  std::cout << "  ✓ CPU ptr: " << mapping->cpu_ptr << std::endl;

  // Step 2: Register MMIO region with KFD for GPU access
  std::cout << "\n  Step 2: Registering MMIO with KFD for GPU access..."
            << std::endl;

  mapping->kfd_fd = open("/dev/kfd", O_RDWR);
  if (mapping->kfd_fd < 0) {
    perror("Error: Failed to open /dev/kfd");
    std::cout
      << "  GPU doorbell mapping failed - falling back to CPU-hybrid mode"
      << std::endl;
    mapping->gpu_ptr = nullptr;
    mapping->kfd_handle = 0;
    return 0; // Not fatal, just means no GPU-direct
  }

  // Get GPU ID from HSA
  hsa_status_t hsa_status = hsa_init();
  if (hsa_status != HSA_STATUS_SUCCESS &&
      hsa_status != HSA_STATUS_ERROR_REFCOUNT_OVERFLOW) {
    std::cerr << "  Warning: HSA init failed" << std::endl;
    close(mapping->kfd_fd);
    mapping->kfd_fd = -1;
    mapping->gpu_ptr = nullptr;
    return 0;
  }

  // Find first GPU
  struct gpu_data {
    hsa_agent_t agent;
    uint32_t gpu_id;
    bool found;
  };
  struct gpu_data gdata = {{0}, 0, false};

  hsa_iterate_agents(
    [](hsa_agent_t agent, void* data) -> hsa_status_t {
      hsa_device_type_t type;
      hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &type);
      if (type == HSA_DEVICE_TYPE_GPU) {
        struct gpu_data* gd = (struct gpu_data*)data;
        // Get GPU ID (node ID)
        hsa_agent_get_info(agent,
                           (hsa_agent_info_t)HSA_AMD_AGENT_INFO_DRIVER_NODE_ID,
                           &gd->gpu_id);
        gd->agent = agent;
        gd->found = true;
        return HSA_STATUS_INFO_BREAK;
      }
      return HSA_STATUS_SUCCESS;
    },
    &gdata);

  if (!gdata.found) {
    std::cerr << "  Error: No GPU found" << std::endl;
    close(mapping->kfd_fd);
    mapping->kfd_fd = -1;
    mapping->gpu_ptr = nullptr;
    return 0;
  }

  mapping->gpu_id = gdata.gpu_id;
  std::cout << "  ✓ Found GPU ID: " << mapping->gpu_id << std::endl;

  // Allocate MMIO region via KFD
  struct kfd_ioctl_alloc_memory_of_gpu_args alloc_args = {};
  alloc_args.va_addr = mapping->bus_addr; // Use bus address
  alloc_args.size = page_size;
  alloc_args.gpu_id = mapping->gpu_id;
  alloc_args.flags = KFD_IOC_ALLOC_MEM_FLAGS_MMIO_REMAP |
                     KFD_IOC_ALLOC_MEM_FLAGS_WRITABLE |
                     KFD_IOC_ALLOC_MEM_FLAGS_PUBLIC;

  std::cout << "  Calling AMDKFD_IOC_ALLOC_MEMORY_OF_GPU..." << std::endl;
  std::cout << "    VA: 0x" << std::hex << alloc_args.va_addr << std::dec
            << std::endl;
  std::cout << "    Size: " << alloc_args.size << std::endl;
  std::cout << "    Flags: 0x" << std::hex << alloc_args.flags << std::dec
            << " (MMIO_REMAP)" << std::endl;

  if (ioctl(mapping->kfd_fd, AMDKFD_IOC_ALLOC_MEMORY_OF_GPU, &alloc_args) < 0) {
    perror("  Error: AMDKFD_IOC_ALLOC_MEMORY_OF_GPU failed");
    close(mapping->kfd_fd);
    mapping->kfd_fd = -1;
    mapping->gpu_ptr = nullptr;
    return 0; // Not fatal
  }

  mapping->kfd_handle = alloc_args.handle;
  std::cout << "  ✓ KFD handle: 0x" << std::hex << mapping->kfd_handle
            << std::dec << std::endl;

  // Map to GPU
  struct kfd_ioctl_map_memory_to_gpu_args map_args = {};
  map_args.handle = mapping->kfd_handle;
  map_args.device_ids_array_ptr = (__u64)&mapping->gpu_id;
  map_args.n_devices = 1;

  std::cout << "  Calling AMDKFD_IOC_MAP_MEMORY_TO_GPU..." << std::endl;

  if (ioctl(mapping->kfd_fd, AMDKFD_IOC_MAP_MEMORY_TO_GPU, &map_args) < 0) {
    perror("  Error: AMDKFD_IOC_MAP_MEMORY_TO_GPU failed");
    // Clean up
    struct kfd_ioctl_free_memory_of_gpu_args free_args = {};
    free_args.handle = mapping->kfd_handle;
    ioctl(mapping->kfd_fd, AMDKFD_IOC_FREE_MEMORY_OF_GPU, &free_args);
    close(mapping->kfd_fd);
    mapping->kfd_fd = -1;
    mapping->gpu_ptr = nullptr;
    return 0;
  }

  // GPU pointer is the VA we specified
  mapping->gpu_ptr = (void*)alloc_args.va_addr;

  std::cout << "✅ GPU-DIRECT doorbell mapping complete via KFD!" << std::endl;
  std::cout << "    GPU ptr (KFD mapped): 0x" << std::hex
            << (uint64_t)mapping->gpu_ptr << std::dec << std::endl;
  std::cout << "    CPU ptr (/dev/mem): " << mapping->cpu_ptr << std::endl;
  std::cout << "    KFD handle: 0x" << std::hex << mapping->kfd_handle
            << std::dec << std::endl;

  return 0;
}

/*
 * Cleanup doorbell mapping
 */
static inline void unmap_doorbell(DoorbellMapping* mapping) {
  // Clean up KFD mapping
  if (mapping->kfd_fd >= 0 && mapping->kfd_handle != 0) {
    // Unmap from GPU
    struct kfd_ioctl_unmap_memory_from_gpu_args unmap_args = {};
    unmap_args.handle = mapping->kfd_handle;
    unmap_args.device_ids_array_ptr = (__u64)&mapping->gpu_id;
    unmap_args.n_devices = 1;
    ioctl(mapping->kfd_fd, AMDKFD_IOC_UNMAP_MEMORY_FROM_GPU, &unmap_args);

    // Free KFD memory
    struct kfd_ioctl_free_memory_of_gpu_args free_args = {};
    free_args.handle = mapping->kfd_handle;
    ioctl(mapping->kfd_fd, AMDKFD_IOC_FREE_MEMORY_OF_GPU, &free_args);
  }
  if (mapping->kfd_fd >= 0) {
    close(mapping->kfd_fd);
  }

  // Clean up /dev/mem mapping
  if (mapping->bar0_mapped && mapping->bar0_mapped != MAP_FAILED) {
    munmap(mapping->bar0_mapped, mapping->bar0_size);
  }
  if (mapping->mem_fd >= 0) {
    close(mapping->mem_fd);
  }
}

} // namespace gpu_doorbell

#endif // GPU_DOORBELL_MAP_H
