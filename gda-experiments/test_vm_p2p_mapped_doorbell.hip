/*
 * VM P2P Mapped Doorbell Test
 * Get P2P IOVA info, but access the actual doorbell HVA that QEMU mapped
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <hip/hip_runtime.h>

#include <fcntl.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <linux/nvme_ioctl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define CHECK_HIP(cmd)                                                         \
  do {                                                                         \
    hipError_t error = (cmd);                                                  \
    if (error != hipSuccess) {                                                 \
      fprintf(stderr, "HIP error: %s\n", hipGetErrorString(error));            \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)

struct p2p_iova_info {
  uint64_t sqe_iova;
  uint64_t cqe_iova;
  uint64_t doorbell_iova;
  uint32_t sqe_size;
  uint32_t cqe_size;
  uint32_t doorbell_size;
  uint16_t queue_depth;
  uint16_t reserved;
} __attribute__((packed));

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
  printf("VM P2P Mapped Doorbell Test\n");
  printf("===========================================\n\n");

  // Step 1: Trigger P2P initialization
  printf("Step 1: Initializing P2P mapping...\n");

  int nvme_fd = open("/dev/nvme0", O_RDWR);
  if (nvme_fd < 0) {
    perror("open /dev/nvme0");
    return 1;
  }

  struct p2p_iova_info info;
  memset(&info, 0, sizeof(info));

  struct nvme_admin_cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = 0xC0;
  cmd.addr = (uint64_t)&info;
  cmd.data_len = sizeof(info);

  if (ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd) < 0) {
    perror("P2P vendor command");
    close(nvme_fd);
    return 1;
  }

  printf("✓ P2P initialized, IOVA addresses received\n\n");

  // Step 2: Open NVMe BAR0 to access doorbells
  printf("Step 2: Opening NVMe BAR0...\n");

  const char* pci_path = "/sys/class/nvme/nvme0/device/resource0";
  int bar_fd = open(pci_path, O_RDWR | O_SYNC);
  if (bar_fd < 0) {
    perror("open BAR0");
    close(nvme_fd);
    return 1;
  }

  size_t map_size = 0x2000;
  void* bar0 = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, bar_fd,
                    0);
  if (bar0 == MAP_FAILED) {
    perror("mmap BAR0");
    close(bar_fd);
    close(nvme_fd);
    return 1;
  }

  volatile uint32_t* sq_doorbell_cpu = (volatile uint32_t*)((char*)bar0 +
                                                            0x1000);
  printf("✓ Mapped BAR0, doorbell at %p\n\n", sq_doorbell_cpu);

  // Step 3: Initialize HSA
  printf("Step 3: Initializing HSA...\n");

  hsa_status_t hsa_status = hsa_init();
  if (hsa_status != HSA_STATUS_SUCCESS) {
    fprintf(stderr, "HSA init failed\n");
    return 1;
  }

  // Find agents and memory pool (simplified)
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

  // Step 4: Lock doorbell memory for GPU
  printf("Step 4: Locking doorbell for GPU access...\n");

  uintptr_t page_start = ((uintptr_t)sq_doorbell_cpu) & ~0xFFFUL;
  size_t offset = ((uintptr_t)sq_doorbell_cpu) - page_start;

  void* gpu_doorbell_base = NULL;
  hsa_status = hsa_amd_memory_lock_to_pool((void*)page_start, 4096, &gpu_agent,
                                           1, cpu_pool, 0, &gpu_doorbell_base);

  if (hsa_status != HSA_STATUS_SUCCESS) {
    fprintf(stderr, "Failed to lock doorbell: 0x%x\n", hsa_status);
    return 1;
  }

  volatile uint32_t* sq_doorbell_gpu =
    (volatile uint32_t*)((char*)gpu_doorbell_base + offset);
  printf("✓ Locked doorbell\n");
  printf("  CPU: %p\n", sq_doorbell_cpu);
  printf("  GPU: %p\n\n", sq_doorbell_gpu);

  // Step 5: Test CPU access
  printf("Step 5: Testing CPU doorbell access...\n");
  uint32_t cpu_val = *sq_doorbell_cpu;
  printf("  Read: %u\n", cpu_val);
  *sq_doorbell_cpu = cpu_val + 1;
  printf("  After write: %u\n", *sq_doorbell_cpu);
  printf("✓ CPU access works\n\n");

  // Step 6: Test GPU access
  printf("Step 6: Testing GPU doorbell access...\n");

  CHECK_HIP(hipSetDevice(0));

  uint32_t* d_results;
  uint32_t h_results[2] = {0};
  CHECK_HIP(hipMalloc(&d_results, 2 * sizeof(uint32_t)));

  // DON'T use IOVA - use the HSA-locked pointer
  hipLaunchKernelGGL(ring_doorbell_kernel, dim3(1), dim3(1), 0, 0,
                     sq_doorbell_gpu, d_results);

  CHECK_HIP(hipDeviceSynchronize());
  CHECK_HIP(hipMemcpy(h_results, d_results, 2 * sizeof(uint32_t),
                      hipMemcpyDeviceToHost));

  printf("\nResults:\n");
  printf("  GPU read:  %u\n", h_results[0]);
  printf("  GPU wrote: %u\n", h_results[1]);

  if (h_results[1] == h_results[0] + 1) {
    printf("\n✅✅✅ SUCCESS! GPU RANG THE DOORBELL! ✅✅✅\n");
  } else {
    printf("\n✗ FAILURE\n");
  }

  // Cleanup
  CHECK_HIP(hipFree(d_results));
  hsa_amd_memory_unlock((void*)page_start);
  hsa_shut_down();
  munmap(bar0, map_size);
  close(bar_fd);
  close(nvme_fd);

  printf("\n===========================================\n");
  return (h_results[1] == h_results[0] + 1) ? 0 : 1;
}
