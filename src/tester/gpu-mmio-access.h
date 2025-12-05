/*
 * GPU MMIO Access Helper
 *
 * Enables AMD GPU to write to PCIe device MMIO regions (like NVMe doorbells)
 * using HSA memory pool APIs and peer-to-peer access.
 */

#ifndef GPU_MMIO_ACCESS_H
#define GPU_MMIO_ACCESS_H

#include <cstring>
#include <iostream>

#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>

namespace gpu_mmio {

/*
 * Register external PCIe MMIO region for GPU access
 */
static inline int register_mmio_for_gpu(void* mmio_ptr, size_t size,
                                        void** gpu_accessible_ptr) {
  hsa_status_t status;

  std::cout << "\n=== Registering MMIO Region for GPU Access ===" << std::endl;
  std::cout << "  MMIO CPU pointer: " << mmio_ptr << std::endl;
  std::cout << "  Size: " << size << " bytes" << std::endl;

  // Initialize HSA if not already done
  status = hsa_init();
  if (status != HSA_STATUS_SUCCESS &&
      status != HSA_STATUS_ERROR_REFCOUNT_OVERFLOW) {
    std::cerr << "Error: HSA init failed: " << status << std::endl;
    return -1;
  }

  // Find GPU agent
  hsa_agent_t gpu_agent;
  bool found_gpu = false;

  auto find_gpu = [](hsa_agent_t agent, void* data) -> hsa_status_t {
    hsa_device_type_t type;
    hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &type);

    if (type == HSA_DEVICE_TYPE_GPU) {
      *((hsa_agent_t*)data) = agent;
      *((bool*)((char*)data + sizeof(hsa_agent_t))) = true;
      return HSA_STATUS_INFO_BREAK;
    }
    return HSA_STATUS_SUCCESS;
  };

  struct {
    hsa_agent_t agent;
    bool found;
  } gpu_data = {0};

  status = hsa_iterate_agents(
    [](hsa_agent_t agent, void* data) -> hsa_status_t {
      hsa_device_type_t type;
      hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &type);

      if (type == HSA_DEVICE_TYPE_GPU) {
        auto* gpu_data = (struct {
          hsa_agent_t agent;
          bool found;
        }*)data;
        gpu_data->agent = agent;
        gpu_data->found = true;
        return HSA_STATUS_INFO_BREAK;
      }
      return HSA_STATUS_SUCCESS;
    },
    &gpu_data);

  if (!gpu_data.found) {
    std::cerr << "Error: No GPU agent found" << std::endl;
    return -1;
  }

  gpu_agent = gpu_data.agent;
  std::cout << "✓ Found GPU agent" << std::endl;

  // Try method 1: hsa_amd_agents_allow_access
  std::cout << "\nAttempting hsa_amd_agents_allow_access..." << std::endl;

  hsa_agent_t agents[] = {gpu_agent};
  status = hsa_amd_agents_allow_access(1, agents, nullptr, mmio_ptr);

  if (status == HSA_STATUS_SUCCESS) {
    std::cout << "✓ MMIO region registered for GPU access via "
                 "hsa_amd_agents_allow_access"
              << std::endl;
    *gpu_accessible_ptr = mmio_ptr;
    return 0;
  } else {
    std::cout << "  hsa_amd_agents_allow_access failed: " << status
              << std::endl;
  }

  // Try method 2: hsa_amd_memory_lock with HSA_AMD_MEMORY_LOCK_UNCACHED
  std::cout << "\nAttempting hsa_amd_memory_lock..." << std::endl;

  void* locked_ptr = nullptr;
  status = hsa_amd_memory_lock(mmio_ptr, size, agents, 1, &locked_ptr);

  if (status == HSA_STATUS_SUCCESS) {
    std::cout << "✓ MMIO region locked for GPU access" << std::endl;
    std::cout << "  Locked pointer: " << locked_ptr << std::endl;
    *gpu_accessible_ptr = locked_ptr;
    return 0;
  } else {
    std::cout << "  hsa_amd_memory_lock failed: " << status << std::endl;
  }

  // Try method 3: hsa_amd_interop_map_buffer
  std::cout << "\nAttempting hsa_amd_interop_map_buffer..." << std::endl;

  void* mapped_ptr = nullptr;
  size_t mapped_size = 0;
  status = hsa_amd_interop_map_buffer(1, agents, -1, mmio_ptr, size,
                                      &mapped_ptr, &mapped_size);

  if (status == HSA_STATUS_SUCCESS) {
    std::cout << "✓ MMIO region mapped for GPU access via interop" << std::endl;
    std::cout << "  Mapped pointer: " << mapped_ptr << std::endl;
    std::cout << "  Mapped size: " << mapped_size << std::endl;
    *gpu_accessible_ptr = mapped_ptr;
    return 0;
  } else {
    std::cout << "  hsa_amd_interop_map_buffer failed: " << status << std::endl;
  }

  std::cerr << "\n❌ All methods failed to register MMIO for GPU access"
            << std::endl;
  std::cerr << "   This may require:" << std::endl;
  std::cerr << "   1. Enabling PCIe peer-to-peer in BIOS" << std::endl;
  std::cerr << "   2. Using large BAR (Resizable BAR) support" << std::endl;
  std::cerr << "   3. Specific GPU model support (e.g., MI series)"
            << std::endl;

  return -1;
}

/*
 * Check if GPU can access a specific address
 */
static inline bool can_gpu_access(void* ptr) {
  hsa_status_t status;
  hsa_amd_pointer_info_t info;
  info.size = sizeof(info);

  status = hsa_amd_pointer_info(ptr, &info, nullptr, nullptr, nullptr);
  if (status != HSA_STATUS_SUCCESS) {
    return false;
  }

  // Check if pointer is accessible by GPU
  // info.type will indicate the memory type
  std::cout << "Pointer info for " << ptr << ":" << std::endl;
  std::cout << "  Type: " << info.type << std::endl;
  std::cout << "  Global flags: " << info.global_flags << std::endl;

  return (info.global_flags & HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_KERNARG_INIT) ||
         (info.global_flags & HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_FINE_GRAINED);
}

} // namespace gpu_mmio

#endif // GPU_MMIO_ACCESS_H
