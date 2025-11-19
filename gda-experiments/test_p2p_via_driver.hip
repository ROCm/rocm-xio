/*
 * Test P2P BAR0 access via nvme_axiio driver
 *
 * This test uses the nvme_axiio driver's ioctls to get BAR0 mapping
 * and tests GPU access using QEMU's P2P mapping.
 */

#include <stdint.h>
#include <stdio.h>

#include <hip/hip_runtime.h>

#include <fcntl.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

/* nvme_axiio ioctl definitions */
#define NVME_AXIIO_MAGIC 0xAE

struct nvme_axiio_doorbell_mapping {
  uint16_t queue_id;
  uint64_t doorbell_phys;
  uint64_t doorbell_bus_addr;
  uint32_t doorbell_offset;
  uint64_t bar0_phys;
  uint64_t bar0_bus_addr;
  uint64_t bar0_size;
};

struct nvme_gpu_doorbell_info {
  uint16_t queue_id;
  uint8_t is_sq;
  int32_t gpu_fd;
  uint64_t doorbell_phys;
  uint64_t bar0_phys;
  uint32_t doorbell_offset;
  uint64_t mmap_offset;
  uint64_t mmap_size;
  uint64_t gpu_va;
};

#define NVME_AXIIO_MAP_DOORBELL_FOR_GPU                                        \
  _IOWR(NVME_AXIIO_MAGIC, 7, struct nvme_axiio_doorbell_mapping)
#define NVME_AXIIO_GET_GPU_DOORBELL                                            \
  _IOWR(NVME_AXIIO_MAGIC, 9, struct nvme_gpu_doorbell_info)

#define HIP_CHECK(cmd)                                                         \
  do {                                                                         \
    hipError_t error = (cmd);                                                  \
    if (error != hipSuccess) {                                                 \
      fprintf(stderr, "HIP error: %s (%d) at %s:%d\n",                         \
              hipGetErrorString(error), error, __FILE__, __LINE__);            \
      return -1;                                                               \
    }                                                                          \
  } while (0)

/* GPU kernel to test BAR0 access */
__global__ void test_bar0_read(volatile uint32_t* bar0, uint32_t* result) {
  if (threadIdx.x == 0) {
    // Read CAP register (offset 0x0)
    uint32_t cap_low = bar0[0];
    uint32_t cap_high = bar0[1];
    result[0] = cap_low;
    result[1] = cap_high;
    result[2] = 0xDEADBEEF; // Success marker
  }
}

int main(int argc, char** argv) {
  int fd;
  struct nvme_axiio_doorbell_mapping db_map = {0};
  void* bar0_mapped = NULL;
  uint32_t* d_result = NULL;
  uint32_t h_result[3] = {0};

  printf("===========================================\n");
  printf("P2P BAR0 Test via nvme_axiio Driver\n");
  printf("===========================================\n\n");

  /* Step 1: Open device */
  printf("Step 1: Opening /dev/nvme-axiio...\n");
  fd = open("/dev/nvme-axiio", O_RDWR);
  if (fd < 0) {
    perror("Failed to open /dev/nvme-axiio");
    return 1;
  }
  printf("✓ Device opened\n\n");

  /* Step 2: Get doorbell mapping info (this gives us BAR0 info) */
  printf("Step 2: Getting doorbell mapping info...\n");
  db_map.queue_id = 0; // Admin queue

  if (ioctl(fd, NVME_AXIIO_MAP_DOORBELL_FOR_GPU, &db_map) < 0) {
    perror("NVME_AXIIO_MAP_DOORBELL_FOR_GPU failed");
    close(fd);
    return 1;
  }

  printf("✓ Got mapping info:\n");
  printf("  BAR0 physical: 0x%016llx\n", (unsigned long long)db_map.bar0_phys);
  printf("  BAR0 bus addr:  0x%016llx\n",
         (unsigned long long)db_map.bar0_bus_addr);
  printf("  BAR0 size:     0x%016llx\n", (unsigned long long)db_map.bar0_size);
  printf("  Doorbell phys:  0x%016llx\n",
         (unsigned long long)db_map.doorbell_phys);
  printf("\n");

  /* Step 3: Map BAR0 via /dev/mem */
  printf("Step 3: Mapping BAR0 via /dev/mem...\n");
  printf("  Using BAR0 physical address: 0x%016llx\n",
         (unsigned long long)db_map.bar0_phys);
  printf("  Size: 0x%016llx\n", (unsigned long long)db_map.bar0_size);
  printf("  Note: QEMU mapped this at host physical 0xdbe00000\n");
  printf("        Inside VM it appears at guest physical 0x%016llx\n",
         (unsigned long long)db_map.bar0_phys);

  /* Map BAR0 using /dev/mem (like gpu-doorbell-map.h does) */
  int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
  if (mem_fd < 0) {
    perror("Failed to open /dev/mem");
    close(fd);
    return 1;
  }

  size_t page_size = sysconf(_SC_PAGE_SIZE);
  uint64_t page_base = db_map.bar0_phys & ~(page_size - 1);
  size_t page_offset = db_map.bar0_phys - page_base;

  void* mapped = mmap(NULL, db_map.bar0_size + page_offset,
                      PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, page_base);
  if (mapped == MAP_FAILED) {
    perror("mmap BAR0 via /dev/mem failed");
    close(mem_fd);
    close(fd);
    return 1;
  }

  bar0_mapped = (char*)mapped + page_offset;
  printf("✓ Mapped BAR0 at %p (page_base=0x%016llx, offset=0x%zx)\n",
         bar0_mapped, (unsigned long long)page_base, page_offset);

  close(mem_fd); /* Keep mapping, close fd */

  /* Step 4: Verify CPU can read BAR0 */
  printf("\nStep 4: Verifying CPU can read BAR0...\n");
  volatile uint32_t* bar0_cpu = (volatile uint32_t*)bar0_mapped;
  uint32_t cap_low = bar0_cpu[0];
  uint32_t cap_high = bar0_cpu[1];
  printf("  CAP register: 0x%08x%08x\n", cap_high, cap_low);
  printf("✓ CPU read successful\n\n");

  /* Step 5: Initialize HSA for GPU MMU registration */
  printf("Step 5: Initializing HSA...\n");
  hsa_status_t hsa_status = hsa_init();
  if (hsa_status != HSA_STATUS_SUCCESS &&
      hsa_status != HSA_STATUS_ERROR_REFCOUNT_OVERFLOW) {
    fprintf(stderr, "hsa_init failed: 0x%x\n", hsa_status);
    munmap(bar0_mapped, db_map.bar0_size);
    close(fd);
    return 1;
  }
  printf("✓ HSA initialized\n");

  /* Find GPU agent */
  hsa_agent_t gpu_agent = {0};
  hsa_status_t find_status = hsa_iterate_agents(
    [](hsa_agent_t agent, void* data) -> hsa_status_t {
      hsa_device_type_t type;
      hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &type);
      if (type == HSA_DEVICE_TYPE_GPU) {
        *(hsa_agent_t*)data = agent;
        return HSA_STATUS_INFO_BREAK;
      }
      return HSA_STATUS_SUCCESS;
    },
    &gpu_agent);

  if (gpu_agent.handle == 0) {
    fprintf(stderr, "No GPU agent found\n");
    hsa_shut_down();
    munmap(bar0_mapped, db_map.bar0_size);
    close(fd);
    return 1;
  }
  printf("✓ Found GPU agent\n\n");

  /* Step 6: Lock BAR0 with HSA for GPU MMU registration */
  printf("Step 6: Locking BAR0 with HSA for GPU access...\n");
  printf("  This registers the memory region with GPU MMU\n");
  printf("  QEMU mapped BAR0 at physical 0x%016llx\n",
         (unsigned long long)db_map.bar0_phys);

  void* hsa_locked_bar0 = NULL;
  hsa_status = hsa_amd_memory_lock(bar0_mapped, db_map.bar0_size, &gpu_agent, 1,
                                   &hsa_locked_bar0);
  if (hsa_status != HSA_STATUS_SUCCESS) {
    fprintf(stderr, "hsa_amd_memory_lock failed: 0x%x\n", hsa_status);
    hsa_shut_down();
    munmap(bar0_mapped, db_map.bar0_size);
    close(fd);
    return 1;
  }

  printf("✓ BAR0 locked with HSA\n");
  printf("  Original mapping: %p\n", bar0_mapped);
  printf("  HSA-locked ptr:  %p\n", hsa_locked_bar0);
  printf("  GPU MMU registered!\n\n");

  /* Step 7: Initialize HIP and launch GPU kernel */
  printf("Step 7: Initializing HIP...\n");
  HIP_CHECK(hipInit(0));
  HIP_CHECK(hipSetDevice(0));
  printf("✓ HIP initialized\n\n");

  printf("Step 8: Launching GPU kernel to read BAR0...\n");
  HIP_CHECK(hipMalloc(&d_result, 3 * sizeof(uint32_t)));

  /* Use HSA-locked pointer for GPU access */
  test_bar0_read<<<1, 1>>>((volatile uint32_t*)hsa_locked_bar0, d_result);

  hipError_t err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    printf("✗ Kernel failed: %s\n", hipGetErrorString(err));
  } else {
    printf("✓ Kernel executed\n");

    HIP_CHECK(hipMemcpy(h_result, d_result, 3 * sizeof(uint32_t),
                        hipMemcpyDeviceToHost));

    printf("\nResults:\n");
    printf("  GPU read CAP: 0x%08x%08x\n", h_result[1], h_result[0]);
    printf("  Success marker: 0x%08x\n", h_result[2]);

    if (h_result[2] == 0xDEADBEEF && h_result[0] == cap_low &&
        h_result[1] == cap_high) {
      printf("\n✅✅✅ SUCCESS! GPU accessed BAR0 via P2P! ✅✅✅\n");
      printf("QEMU's P2P mapping + HSA locking is working correctly!\n");
    } else {
      printf("\n⚠ GPU read differs from CPU\n");
      printf("  CPU: 0x%08x%08x\n", cap_high, cap_low);
      printf("  GPU: 0x%08x%08x\n", h_result[1], h_result[0]);
    }
  }

  HIP_CHECK(hipFree(d_result));

  /* Cleanup HSA */
  hsa_amd_memory_unlock(bar0_mapped);
  hsa_shut_down();

  /* Cleanup */
  if (bar0_mapped != NULL && bar0_mapped != MAP_FAILED) {
    munmap(bar0_mapped, db_map.bar0_size);
  }
  close(fd);

  printf("\n===========================================\n");
  printf("Test Complete\n");
  printf("===========================================\n");

  return 0;
}
