/*
 * VM P2P Doorbell Test - Uses IOVA addresses from QEMU P2P mapping
 * Same pattern as bare-metal test but with IOVA addresses
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <hip/hip_runtime.h>

#include <fcntl.h>
#include <linux/nvme_ioctl.h>
#include <sys/ioctl.h>
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

// GPU kernel - same as bare metal but uses IOVA addresses
__global__ void ring_doorbell_kernel(uint64_t doorbell_iova,
                                     uint32_t* results) {
  if (threadIdx.x == 0) {
    // Cast IOVA to pointer (GPU will access via IOMMU)
    volatile uint32_t* sq_doorbell = (volatile uint32_t*)doorbell_iova;

    printf("GPU: Doorbell IOVA = 0x%lx\n", doorbell_iova);

    // Read current value
    uint32_t old_val = *sq_doorbell;
    results[0] = old_val;
    __threadfence_system();

    printf("GPU: Read value = %u\n", old_val);

    // Write new value
    *sq_doorbell = old_val + 1;
    __threadfence_system();

    // Read back
    uint32_t new_val = *sq_doorbell;
    results[1] = new_val;

    printf("GPU: Wrote %u, read back %u\n", old_val + 1, new_val);
  }
}

int main() {
  printf("===========================================\n");
  printf("VM P2P Doorbell Test (IOVA Method)\n");
  printf("===========================================\n\n");

  // Step 1: Get P2P IOVA addresses via vendor command
  printf("Step 1: Getting P2P IOVA addresses...\n");

  int fd = open("/dev/nvme0", O_RDWR);
  if (fd < 0) {
    perror("open /dev/nvme0");
    return 1;
  }

  struct p2p_iova_info info;
  memset(&info, 0, sizeof(info));

  struct nvme_admin_cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = 0xC0; // Our P2P vendor command
  cmd.addr = (uint64_t)&info;
  cmd.data_len = sizeof(info);

  if (ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd) < 0) {
    perror("P2P vendor command");
    close(fd);
    return 1;
  }
  close(fd);

  printf("✓ Got P2P IOVA addresses:\n");
  printf("  SQE IOVA:      0x%016lx (size: 0x%x)\n", info.sqe_iova,
         info.sqe_size);
  printf("  CQE IOVA:      0x%016lx (size: 0x%x)\n", info.cqe_iova,
         info.cqe_size);
  printf("  Doorbell IOVA: 0x%016lx (size: 0x%x)\n", info.doorbell_iova,
         info.doorbell_size);
  printf("  Queue Depth:   %u\n\n", info.queue_depth);

  // Step 2: Initialize HIP
  printf("Step 2: Initializing HIP...\n");
  CHECK_HIP(hipSetDevice(0));
  printf("✓ HIP initialized\n\n");

  // Allocate results buffer
  uint32_t* d_results;
  uint32_t h_results[2] = {0};
  CHECK_HIP(hipMalloc(&d_results, 2 * sizeof(uint32_t)));

  // Step 3: Launch GPU kernel with doorbell IOVA
  printf("Step 3: Launching GPU kernel to ring doorbell via IOVA...\n");

  hipLaunchKernelGGL(ring_doorbell_kernel, dim3(1), dim3(1), 0, 0,
                     info.doorbell_iova, d_results);

  CHECK_HIP(hipDeviceSynchronize());

  // Get results
  CHECK_HIP(hipMemcpy(h_results, d_results, 2 * sizeof(uint32_t),
                      hipMemcpyDeviceToHost));

  printf("\nResults:\n");
  printf("  GPU read:  %u\n", h_results[0]);
  printf("  GPU wrote: %u\n", h_results[1]);

  if (h_results[1] == h_results[0] + 1) {
    printf("\n");
    printf("✅✅✅ SUCCESS! GPU RANG THE DOORBELL VIA IOVA! ✅✅✅\n");
    printf("\n");
    printf("The GPU successfully accessed the emulated NVMe doorbell\n");
    printf("through the QEMU P2P IOVA mapping!\n");
  } else {
    printf("\n✗ FAILURE: Values don't match\n");
  }

  // Cleanup
  CHECK_HIP(hipFree(d_results));

  printf("\n===========================================\n");
  printf("Test Complete\n");
  printf("===========================================\n");

  return (h_results[1] == h_results[0] + 1) ? 0 : 1;
}
