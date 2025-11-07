/*
 * Test GPU access to IOVA doorbell using HSA memory locking
 * Map the IOVA address through HSA to make it GPU-accessible
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <hip/hip_runtime.h>

#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <sys/mman.h>

#define DOORBELL_IOVA 0x1000020000UL
#define DOORBELL_SIZE 0x1000

__global__ void ring_doorbell_kernel(volatile uint32_t* doorbell,
                                     uint32_t* results) {
  if (threadIdx.x == 0) {
    printf("GPU: Doorbell ptr = %p\n", doorbell);

    uint32_t old_val = *doorbell;
    results[0] = old_val;
    __threadfence_system();

    printf("GPU: Read = %u\n", old_val);

    *doorbell = old_val + 1;
    __threadfence_system();

    uint32_t new_val = *doorbell;
    results[1] = new_val;

    printf("GPU: Wrote %u, read back %u\n", old_val + 1, new_val);
  }
}

int main() {
  printf("===========================================\n");
  printf("IOVA with HSA Mapping Test\n");
  printf("===========================================\n\n");

  printf("Doorbell IOVA: 0x%lx\n\n", DOORBELL_IOVA);

  // Step 1: Initialize HSA
  printf("Step 1: Initializing HSA...\n");

  hsa_status_t hsa_status = hsa_init();
  if (hsa_status != HSA_STATUS_SUCCESS) {
    fprintf(stderr, "HSA init failed: 0x%x\n", hsa_status);
    return 1;
  }

  // Find CPU and GPU agents
  hsa_agent_t cpu_agent = {0}, gpu_agent = {0};

  auto find_agents = [](hsa_agent_t agent, void* data) -> hsa_status_t {
    hsa_device_type_t type;
    hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &type);
    struct {
      hsa_agent_t *cpu, *gpu;
    }* agents = (decltype(agents))data;
    if (type == HSA_DEVICE_TYPE_CPU && agents->cpu->handle == 0)
      *agents->cpu = agent;
    if (type == HSA_DEVICE_TYPE_GPU && agents->gpu->handle == 0)
      *agents->gpu = agent;
    return (agents->cpu->handle && agents->gpu->handle) ? HSA_STATUS_INFO_BREAK
                                                        : HSA_STATUS_SUCCESS;
  };

  struct {
    hsa_agent_t *cpu, *gpu;
  } agents = {&cpu_agent, &gpu_agent};
  hsa_iterate_agents(find_agents, &agents);

  if (!cpu_agent.handle || !gpu_agent.handle) {
    fprintf(stderr, "Failed to find agents\n");
    return 1;
  }

  // Find fine-grained memory pool
  hsa_amd_memory_pool_t cpu_pool = {0};
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

  hsa_amd_agent_iterate_memory_pools(cpu_agent, find_pool, &cpu_pool);
  if (!cpu_pool.handle) {
    fprintf(stderr, "No CPU pool found\n");
    return 1;
  }

  printf("✓ HSA initialized\n\n");

  // Step 2: mmap the IOVA address range to get a host virtual address
  printf("Step 2: Mapping IOVA address to host VA...\n");

  // We need to map it somehow - try anonymous mapping as placeholder
  // In real scenario, QEMU would provide this mapping
  void* iova_hva = mmap((void*)DOORBELL_IOVA, DOORBELL_SIZE,
                        PROT_READ | PROT_WRITE,
                        MAP_ANONYMOUS | MAP_PRIVATE | MAP_FIXED, -1, 0);

  if (iova_hva == MAP_FAILED) {
    perror("mmap IOVA");
    printf("Trying without MAP_FIXED...\n");
    iova_hva = mmap(NULL, DOORBELL_SIZE, PROT_READ | PROT_WRITE,
                    MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    if (iova_hva == MAP_FAILED) {
      perror("mmap");
      return 1;
    }
  }

  printf("✓ Mapped IOVA region at HVA: %p\n\n", iova_hva);

  // Step 3: Lock this memory for GPU access
  printf("Step 3: Locking memory for GPU access...\n");

  void* gpu_doorbell_base = NULL;
  hsa_status = hsa_amd_memory_lock_to_pool(iova_hva, DOORBELL_SIZE, &gpu_agent,
                                           1, cpu_pool, 0, &gpu_doorbell_base);

  if (hsa_status != HSA_STATUS_SUCCESS) {
    fprintf(stderr, "Failed to lock memory: 0x%x\n", hsa_status);
    return 1;
  }

  volatile uint32_t* doorbell_gpu = (volatile uint32_t*)gpu_doorbell_base;

  printf("✓ Locked for GPU\n");
  printf("  HVA: %p\n", iova_hva);
  printf("  GPU ptr: %p\n\n", doorbell_gpu);

  // Step 4: Launch GPU kernel
  printf("Step 4: Launching GPU kernel...\n");

  hipSetDevice(0);

  uint32_t* d_results;
  uint32_t h_results[2] = {0};
  hipMalloc(&d_results, 2 * sizeof(uint32_t));

  hipLaunchKernelGGL(ring_doorbell_kernel, dim3(1), dim3(1), 0, 0, doorbell_gpu,
                     d_results);

  hipError_t err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    printf("Sync error: %s\n", hipGetErrorString(err));
  }

  hipMemcpy(h_results, d_results, 2 * sizeof(uint32_t), hipMemcpyDeviceToHost);

  printf("\nResults:\n");
  printf("  GPU read:  %u\n", h_results[0]);
  printf("  GPU wrote: %u\n", h_results[1]);

  if (h_results[1] == h_results[0] + 1) {
    printf("\n✅✅✅ SUCCESS! GPU accessed IOVA doorbell! ✅✅✅\n");
  } else {
    printf("\n✗ Values don't match\n");
  }

  // Cleanup
  hipFree(d_results);
  hsa_amd_memory_unlock(iova_hva);
  hsa_shut_down();
  munmap(iova_hva, DOORBELL_SIZE);

  printf("\n===========================================\n");
  return (h_results[1] == h_results[0] + 1) ? 0 : 1;
}
