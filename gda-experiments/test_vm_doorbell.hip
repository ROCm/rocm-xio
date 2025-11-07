/*
 * VM NVMe Doorbell Test with GPU
 *
 * Same pattern as bare metal test, but accesses emulated NVMe device
 * via PCI BAR0 mmap instead of /dev/nvme_gda0
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <hip/hip_runtime.h>

#include <fcntl.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <sys/mman.h>
#include <unistd.h>

#define CHECK_HIP(cmd)                                                         \
  do {                                                                         \
    hipError_t error = (cmd);                                                  \
    if (error != hipSuccess) {                                                 \
      fprintf(stderr, "HIP error at %s:%d: %s\n", __FILE__, __LINE__,          \
              hipGetErrorString(error));                                       \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)

// GPU kernel to ring doorbell (same as this morning)
__global__ void ring_doorbell_kernel(volatile uint32_t* doorbell,
                                     uint32_t* results) {
  if (threadIdx.x == 0 && blockIdx.x == 0) {
    // First write magic to show kernel started
    results[0] = 0xDEADBEEF;
    results[1] = 0xCAFEBABE;
    __threadfence_system();

    printf("GPU: Kernel started! Doorbell at %p\n", doorbell);

    // Read current value
    uint32_t old_val = *doorbell;
    results[0] = old_val;

    printf("GPU: Read value %u\n", old_val);

    // Write new value
    *doorbell = old_val + 1;
    __threadfence_system();

    // Read back
    uint32_t new_val = *doorbell;
    results[1] = new_val;

    printf("GPU: Wrote %u, read back %u\n", old_val + 1, new_val);
  }
}

int main() {
  printf("=========================================\n");
  printf("VM NVMe Doorbell Test with GPU\n");
  printf("=========================================\n\n");

  // Find NVMe device - it should be nvme0
  const char* pci_path = "/sys/class/nvme/nvme0/device/resource0";

  printf("Step 1: Opening NVMe BAR0...\n");
  int fd = open(pci_path, O_RDWR | O_SYNC);
  if (fd < 0) {
    perror("Failed to open NVMe resource0");
    printf("\nTrying alternative path...\n");

    // Try finding via PCI bus
    fd = open("/sys/bus/pci/devices/0000:00:04.0/resource0", O_RDWR | O_SYNC);
    if (fd < 0) {
      perror("Failed to open PCI resource");
      return 1;
    }
  }
  printf("✓ Opened NVMe BAR0\n");

  // Map doorbell registers (starts at offset 0x1000 in BAR0)
  // Map enough space for admin queue doorbells
  size_t map_size = 0x2000; // 8KB should be enough
  void* bar0 = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (bar0 == MAP_FAILED) {
    perror("mmap failed");
    close(fd);
    return 1;
  }
  printf("✓ Mapped BAR0 at %p\n", bar0);

  // Doorbell registers start at 0x1000 (4KB offset)
  // Admin SQ doorbell is at 0x1000, Admin CQ doorbell at 0x1004
  volatile uint32_t* sq_doorbell_cpu = (volatile uint32_t*)((char*)bar0 +
                                                            0x1000);

  printf("✓ Admin SQ doorbell at %p\n\n", sq_doorbell_cpu);

  // Step 2: Initialize HSA (same as this morning)
  printf("Step 2: Initializing HSA...\n");

  hsa_status_t hsa_status = hsa_init();
  if (hsa_status != HSA_STATUS_SUCCESS) {
    fprintf(stderr, "Failed to initialize HSA: 0x%x\n", hsa_status);
    munmap(bar0, map_size);
    close(fd);
    return 1;
  }
  printf("✓ HSA initialized\n");

  // Find CPU and GPU agents
  hsa_agent_t cpu_agent = {0};
  hsa_agent_t gpu_agent = {0};

  auto find_agents = [](hsa_agent_t agent, void* data) -> hsa_status_t {
    hsa_device_type_t device_type;
    hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &device_type);

    struct agents_t {
      hsa_agent_t* cpu;
      hsa_agent_t* gpu;
    };
    agents_t* agents = (agents_t*)data;

    if (device_type == HSA_DEVICE_TYPE_CPU && agents->cpu->handle == 0) {
      *agents->cpu = agent;
    } else if (device_type == HSA_DEVICE_TYPE_GPU && agents->gpu->handle == 0) {
      *agents->gpu = agent;
    }

    return (agents->cpu->handle != 0 && agents->gpu->handle != 0)
             ? HSA_STATUS_INFO_BREAK
             : HSA_STATUS_SUCCESS;
  };

  struct agents_t {
    hsa_agent_t* cpu;
    hsa_agent_t* gpu;
  } agents = {&cpu_agent, &gpu_agent};
  hsa_iterate_agents(find_agents, &agents);

  if (cpu_agent.handle == 0) {
    fprintf(stderr, "No CPU agent found\n");
    hsa_shut_down();
    munmap(bar0, map_size);
    close(fd);
    return 1;
  }

  if (gpu_agent.handle == 0) {
    fprintf(stderr, "No GPU agent found\n");
    hsa_shut_down();
    munmap(bar0, map_size);
    close(fd);
    return 1;
  }
  printf("✓ Found CPU and GPU agents\n");

  // Find fine-grained memory pool
  printf("Searching for CPU memory pools...\n");
  hsa_amd_memory_pool_t cpu_pool = {0};
  auto find_cpu_pool = [](hsa_amd_memory_pool_t pool,
                          void* data) -> hsa_status_t {
    uint32_t flags;
    hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_GLOBAL_FLAGS,
                                 &flags);

    hsa_amd_segment_t segment;
    hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_SEGMENT,
                                 &segment);

    printf("  Pool: flags=0x%x segment=%d ", flags, segment);
    if (flags & HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_KERNARG_INIT)
      printf("KERNARG ");
    if (flags & HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_FINE_GRAINED)
      printf("FINE_GRAINED ");
    if (flags & HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_COARSE_GRAINED)
      printf("COARSE_GRAINED ");
    printf("\n");

    const uint32_t required_flags =
      HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_KERNARG_INIT |
      HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_FINE_GRAINED;
    // Use bitwise AND to check for required flags
    if ((flags & required_flags) == required_flags) {
      *(hsa_amd_memory_pool_t*)data = pool;
      printf("  ✓ Selected this pool\n");
      return HSA_STATUS_INFO_BREAK;
    }
    return HSA_STATUS_SUCCESS;
  };

  hsa_amd_agent_iterate_memory_pools(cpu_agent, find_cpu_pool, &cpu_pool);
  if (cpu_pool.handle == 0) {
    fprintf(stderr, "No suitable CPU memory pool found\n");
    hsa_shut_down();
    munmap(bar0, map_size);
    close(fd);
    return 1;
  }
  printf("✓ Found CPU memory pool\n\n");

  // Step 3: Lock doorbell memory for GPU access (CRITICAL STEP from this
  // morning!)
  printf("Step 3: Locking doorbell for GPU access...\n");

  // We need to lock the whole page starting at the page boundary
  // because hsa_amd_memory_lock_to_pool locks at page granularity
  uintptr_t page_start = ((uintptr_t)sq_doorbell_cpu) & ~0xFFFUL;
  size_t offset = ((uintptr_t)sq_doorbell_cpu) - page_start;

  printf("  Page-aligning doorbell lock: page_start=0x%lx, offset=0x%zx\n",
         page_start, offset);

  void* gpu_doorbell_base = NULL;
  hsa_status = hsa_amd_memory_lock_to_pool((void*)page_start,
                                           4096, // Lock page-aligned address
                                           &gpu_agent, 1, cpu_pool, 0,
                                           &gpu_doorbell_base);

  if (hsa_status != HSA_STATUS_SUCCESS) {
    fprintf(stderr, "Failed to lock doorbell memory: 0x%x\n", hsa_status);
    hsa_shut_down();
    munmap(bar0, map_size);
    close(fd);
    return 1;
  }

  // Add offset back to get the actual doorbell address
  volatile uint32_t* sq_doorbell_gpu =
    (volatile uint32_t*)((char*)gpu_doorbell_base + offset);
  printf("✓ Locked doorbell for GPU\n");
  printf("  CPU pointer: %p\n", sq_doorbell_cpu);
  printf("  GPU pointer: %p\n\n", sq_doorbell_gpu);

  // Step 4: Test from CPU first
  printf("Step 4: Testing CPU doorbell access...\n");
  uint32_t cpu_val = *sq_doorbell_cpu;
  printf("  Read value: %u\n", cpu_val);
  *sq_doorbell_cpu = cpu_val + 1;
  uint32_t cpu_new_val = *sq_doorbell_cpu;
  printf("  After write: %u\n", cpu_new_val);
  printf("✓ CPU can access doorbell\n\n");

  // Step 5: Initialize HIP (HSA is already initialized, just set device)
  printf("Step 5: Initializing HIP...\n");
  CHECK_HIP(hipSetDevice(0));
  printf("✓ HIP initialized\n\n");

  // Allocate results buffer
  uint32_t* d_results;
  uint32_t h_results[2] = {0};
  CHECK_HIP(hipMalloc(&d_results, 2 * sizeof(uint32_t)));

  // Step 6: Launch GPU kernel
  printf("Step 6: Launching GPU kernel to ring doorbell...\n");

  hipLaunchKernelGGL(ring_doorbell_kernel, dim3(1), dim3(1), 0, 0,
                     sq_doorbell_gpu, d_results);

  hipError_t err = hipGetLastError();
  if (err != hipSuccess) {
    fprintf(stderr, "Warning: hipGetLastError returned: %s\n",
            hipGetErrorString(err));
  }

  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    fprintf(stderr, "Warning: hipDeviceSynchronize returned: %s\n",
            hipGetErrorString(err));
  }

  // Get results
  CHECK_HIP(hipMemcpy(h_results, d_results, 2 * sizeof(uint32_t),
                      hipMemcpyDeviceToHost));

  printf("\nResults:\n");
  printf("  GPU read:  %u\n", h_results[0]);
  printf("  GPU wrote: %u\n", h_results[1]);

  if (h_results[1] == h_results[0] + 1) {
    printf("\n✅✅✅ SUCCESS: GPU RANG THE DOORBELL! ✅✅✅\n");
    printf("\nThe GPU successfully accessed the emulated NVMe\n");
    printf("doorbell registers through the IOMMU!\n");
  } else {
    printf("\n✗ FAILURE: Doorbell values don't match\n");
  }

  // Cleanup
  CHECK_HIP(hipFree(d_results));
  hsa_amd_memory_unlock((void*)sq_doorbell_cpu);
  hsa_shut_down();
  munmap(bar0, map_size);
  close(fd);

  printf("\n=========================================\n");
  printf("Test Complete\n");
  printf("=========================================\n");

  return 0;
}
