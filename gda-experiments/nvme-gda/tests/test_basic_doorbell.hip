// SPDX-License-Identifier: MIT
/**
 * NVMe GDA Basic Doorbell Test
 *
 * Tests basic doorbell ringing from GPU without actual NVMe I/O
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <hip/hip_runtime.h>

#include "../include/nvme_gda.h"

#define CHECK_HIP(cmd)                                                         \
  do {                                                                         \
    hipError_t error = (cmd);                                                  \
    if (error != hipSuccess) {                                                 \
      fprintf(stderr, "HIP error %d at %s:%d\n", error, __FILE__, __LINE__);   \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)

/**
 * Simple GPU kernel to ring doorbell
 * Following rocSHMEM pattern: use GPU-accessible doorbell pointers
 */
__global__ void test_doorbell_kernel(nvme_gda_queue_userspace* queue,
                                     int* results) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;

  // Each thread writes a unique value to the doorbell
  // This tests that GPU can access the MMIO region
  if (tid == 0) {
    // Use GPU doorbell pointer (from HSA memory lock)
    volatile uint32_t* doorbell = queue->gpu_sq_doorbell;

    if (!doorbell) {
      printf("GPU: ERROR - gpu_sq_doorbell is NULL!\n");
      results[0] = -1;
      results[1] = -1;
      return;
    }

    // Read current doorbell value
    uint32_t old_val = *doorbell;
    results[0] = old_val;

    printf("GPU: Doorbell at %p, old value: %u\n", doorbell, old_val);

    // Ring doorbell with new value using our device function
    nvme_gda_ring_doorbell(doorbell, old_val + 1);

    // Verify write happened
    uint32_t new_val = *doorbell;
    results[1] = new_val;

    printf("GPU: New doorbell value: %u\n", new_val);
  }
}

int main(int argc, char** argv) {
  const char* device_path = "/dev/nvme_gda0";

  if (argc > 1) {
    device_path = argv[1];
  }

  printf("NVMe GDA Basic Doorbell Test\n");
  printf("=============================\n\n");

  // Initialize NVMe GDA
  nvme_gda_context* ctx = nvme_gda_init(device_path);
  if (!ctx) {
    fprintf(stderr, "Failed to initialize NVMe GDA\n");
    return 1;
  }

  // Get device info
  struct nvme_gda_device_info dev_info;
  nvme_gda_get_device_info(ctx, &dev_info);

  printf("\nNVMe Device Information:\n");
  printf("  Vendor ID: 0x%04x\n", dev_info.vendor_id);
  printf("  Device ID: 0x%04x\n", dev_info.device_id);
  printf("  BAR0: 0x%lx (size: %lu bytes)\n", dev_info.bar0_addr,
         dev_info.bar0_size);
  printf("  Doorbell stride: %u DWORDs\n", dev_info.doorbell_stride);
  printf("  Max queue entries: %u\n", dev_info.max_queue_entries);
  printf("\n");

  // Create queue
  printf("Creating queue with size 16...\n");
  nvme_gda_queue_userspace* queue = nvme_gda_create_queue(ctx, 16);
  if (!queue) {
    fprintf(stderr, "Failed to create queue\n");
    nvme_gda_cleanup(ctx);
    return 1;
  }

  printf("Queue created successfully\n");
  printf("  Queue ID: %u\n", queue->qid);
  printf("  Queue size: %u\n", queue->qsize);
  printf("  SQ entries: %p\n", queue->sqes);
  printf("  CQ entries: %p\n", queue->cqes);
  printf("  SQ doorbell: %p\n", queue->sq_doorbell);
  printf("  CQ doorbell: %p\n", queue->cq_doorbell);
  printf("\n");

  // Allocate result buffer on GPU
  int* d_results;
  int h_results[2] = {0};
  CHECK_HIP(hipMalloc(&d_results, 2 * sizeof(int)));
  CHECK_HIP(
    hipMemcpy(d_results, h_results, 2 * sizeof(int), hipMemcpyHostToDevice));

  // Copy queue structure to GPU
  nvme_gda_queue_userspace* d_queue;
  CHECK_HIP(hipMalloc(&d_queue, sizeof(nvme_gda_queue_userspace)));
  CHECK_HIP(hipMemcpy(d_queue, queue, sizeof(nvme_gda_queue_userspace),
                      hipMemcpyHostToDevice));

  printf("Testing doorbell ring from GPU...\n");

  // Launch kernel
  hipLaunchKernelGGL(test_doorbell_kernel, dim3(1), dim3(1), 0, 0, d_queue,
                     d_results);
  CHECK_HIP(hipGetLastError());
  CHECK_HIP(hipDeviceSynchronize());

  // Get results
  CHECK_HIP(
    hipMemcpy(h_results, d_results, 2 * sizeof(int), hipMemcpyDeviceToHost));

  printf("\nResults:\n");
  printf("  Before: %d\n", h_results[0]);
  printf("  After: %d\n", h_results[1]);

  if (h_results[1] == h_results[0] + 1) {
    printf("\n✓ SUCCESS: GPU successfully rang the doorbell!\n");
  } else {
    printf("\n✗ FAILURE: Doorbell value did not increment as expected\n");
  }

  // Cleanup
  CHECK_HIP(hipFree(d_results));
  CHECK_HIP(hipFree(d_queue));

  nvme_gda_destroy_queue(queue);
  nvme_gda_cleanup(ctx);

  printf("\nTest completed\n");
  return 0;
}
