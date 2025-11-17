// Test HSA memory locking for emulated NVMe doorbell in VM
// Adapted from test_hsa_doorbell.cpp but accesses emulated NVMe BAR0 directly

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fcntl.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <sys/mman.h>
#include <unistd.h>

int main() {
  printf("=========================================\n");
  printf("VM HSA Doorbell Test (CPU-side only)\n");
  printf("=========================================\n\n");

  // Step 1: Open emulated NVMe BAR0
  printf("Step 1: Opening NVMe BAR0...\n");
  const char* pci_path = "/sys/class/nvme/nvme0/device/resource0";

  int fd = open(pci_path, O_RDWR | O_SYNC);
  if (fd < 0) {
    perror("Failed to open NVMe resource0");
    printf("Trying alternative path...\n");
    fd = open("/sys/bus/pci/devices/0000:00:04.0/resource0", O_RDWR | O_SYNC);
    if (fd < 0) {
      perror("Failed to open PCI resource");
      return 1;
    }
  }
  printf("✓ Opened NVMe BAR0\n");

  // Map doorbell registers
  size_t map_size = 0x2000; // 8KB
  void* bar0 = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (bar0 == MAP_FAILED) {
    perror("mmap failed");
    close(fd);
    return 1;
  }
  printf("✓ Mapped BAR0 at %p\n", bar0);

  // Admin SQ doorbell at offset 0x1000
  volatile uint32_t* sq_doorbell_cpu = (volatile uint32_t*)((char*)bar0 +
                                                            0x1000);
  printf("✓ Admin SQ doorbell at %p\n\n", sq_doorbell_cpu);

  // Step 2: Initialize HSA
  printf("Step 2: Initializing HSA...\n");
  hsa_status_t status = hsa_init();
  if (status != HSA_STATUS_SUCCESS) {
    fprintf(stderr, "Failed to initialize HSA: 0x%x\n", status);
    munmap(bar0, map_size);
    close(fd);
    return 1;
  }
  printf("✓ HSA initialized\n");

  // Find CPU agent
  hsa_agent_t cpu_agent = {0};
  auto find_cpu = [](hsa_agent_t agent, void* data) -> hsa_status_t {
    hsa_device_type_t device_type;
    hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &device_type);
    if (device_type == HSA_DEVICE_TYPE_CPU) {
      *(hsa_agent_t*)data = agent;
      return HSA_STATUS_INFO_BREAK;
    }
    return HSA_STATUS_SUCCESS;
  };

  hsa_iterate_agents(find_cpu, &cpu_agent);
  if (cpu_agent.handle == 0) {
    fprintf(stderr, "No CPU agent found\n");
    hsa_shut_down();
    munmap(bar0, map_size);
    close(fd);
    return 1;
  }
  printf("✓ Found CPU agent\n");

  // Find GPU agent (needed for lock_to_pool)
  hsa_agent_t gpu_agent = {0};
  auto find_gpu = [](hsa_agent_t agent, void* data) -> hsa_status_t {
    hsa_device_type_t device_type;
    hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &device_type);
    if (device_type == HSA_DEVICE_TYPE_GPU) {
      *(hsa_agent_t*)data = agent;
      return HSA_STATUS_INFO_BREAK;
    }
    return HSA_STATUS_SUCCESS;
  };

  hsa_iterate_agents(find_gpu, &gpu_agent);
  if (gpu_agent.handle == 0) {
    fprintf(stderr, "No GPU agent found\n");
    hsa_shut_down();
    munmap(bar0, map_size);
    close(fd);
    return 1;
  }
  printf("✓ Found GPU agent\n");

  // Find fine-grained memory pool on CPU agent
  hsa_amd_memory_pool_t cpu_pool = {0};
  auto find_pool = [](hsa_amd_memory_pool_t pool, void* data) -> hsa_status_t {
    uint32_t flags;
    hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_GLOBAL_FLAGS,
                                 &flags);
    const uint32_t required = HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_KERNARG_INIT |
                              HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_FINE_GRAINED;
    if ((flags & required) == required) {
      *(hsa_amd_memory_pool_t*)data = pool;
      return HSA_STATUS_INFO_BREAK;
    }
    return HSA_STATUS_SUCCESS;
  };

  hsa_amd_agent_iterate_memory_pools(cpu_agent, find_pool, &cpu_pool);
  if (cpu_pool.handle == 0) {
    fprintf(stderr, "No suitable CPU memory pool found\n");
    hsa_shut_down();
    munmap(bar0, map_size);
    close(fd);
    return 1;
  }
  printf("✓ Found fine-grained CPU memory pool\n\n");

  // Step 3: Lock doorbell memory for GPU access
  printf("Step 3: Locking doorbell memory with HSA...\n");

  // Page-align the doorbell address
  uintptr_t page_start = ((uintptr_t)sq_doorbell_cpu) & ~0xFFFUL;
  size_t offset = ((uintptr_t)sq_doorbell_cpu) - page_start;

  printf("  Page-aligned address: 0x%lx (offset: 0x%zx)\n", page_start, offset);

  void* gpu_doorbell_base = NULL;
  status = hsa_amd_memory_lock_to_pool((void*)page_start, 4096, &gpu_agent, 1,
                                       cpu_pool, 0, &gpu_doorbell_base);

  if (status != HSA_STATUS_SUCCESS) {
    fprintf(stderr, "Failed to lock doorbell memory: 0x%x\n", status);
    hsa_shut_down();
    munmap(bar0, map_size);
    close(fd);
    return 1;
  }

  volatile uint32_t* sq_doorbell_gpu =
    (volatile uint32_t*)((char*)gpu_doorbell_base + offset);

  printf("✓ Locked doorbell memory\n");
  printf("  CPU doorbell pointer: %p\n", sq_doorbell_cpu);
  printf("  GPU doorbell pointer: %p\n\n", sq_doorbell_gpu);

  // Step 4: Test CPU doorbell access
  printf("Step 4: Testing CPU doorbell access...\n");

  uint32_t val1 = *sq_doorbell_cpu;
  printf("  Initial read: %u\n", val1);

  printf("  Writing value: %u\n", val1 + 1);
  *sq_doorbell_cpu = val1 + 1;

  uint32_t val2 = *sq_doorbell_cpu;
  printf("  Read back: %u\n", val2);

  if (val2 == val1 + 1) {
    printf("✓ CPU doorbell access works!\n\n");
  } else {
    printf("✗ CPU doorbell read/write mismatch\n\n");
  }

  // Test a few more writes to generate trace activity
  printf("Step 5: Generating doorbell activity for QEMU trace...\n");
  for (int i = 0; i < 5; i++) {
    uint32_t old_val = *sq_doorbell_cpu;
    *sq_doorbell_cpu = old_val + 1;
    printf("  Write #%d: %u -> %u\n", i + 1, old_val, old_val + 1);
    usleep(100000); // 100ms delay
  }
  printf("✓ Generated doorbell writes\n\n");

  // Cleanup
  printf("Step 6: Cleanup...\n");
  hsa_amd_memory_unlock((void*)page_start);
  hsa_shut_down();
  munmap(bar0, map_size);
  close(fd);

  printf("✓ Cleanup complete\n\n");
  printf("=========================================\n");
  printf("SUCCESS: HSA doorbell test completed!\n");
  printf("=========================================\n");
  printf("\nCheck QEMU trace for doorbell MMIO writes\n");
  printf("Look for: pci_nvme_mmio_doorbell_sq\n\n");

  return 0;
}
