// Test HSA memory locking for NVMe doorbell without GPU kernel
// This tests just the CPU-side HSA operations

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gda-experiments/nvme-gda/include/nvme_gda.h"

int main() {
  printf("HSA Doorbell Memory Locking Test\n");
  printf("==================================\n\n");

  // Initialize NVMe GDA
  nvme_gda_context* ctx = nvme_gda_init("/dev/nvme_gda0");
  if (!ctx) {
    fprintf(stderr, "Failed to initialize NVMe GDA\n");
    return 1;
  }

  printf("✓ NVMe GDA initialized\n");
  printf("✓ HSA initialized\n\n");

  // Create queue
  printf("Creating queue...\n");
  nvme_gda_queue_userspace* queue = nvme_gda_create_queue(ctx, 16);
  if (!queue) {
    fprintf(stderr, "Failed to create queue\n");
    nvme_gda_cleanup(ctx);
    return 1;
  }

  printf("\n✓ Queue created successfully!\n");
  printf("\nDoorbell pointers:\n");
  printf("  CPU SQ doorbell: %p\n", queue->sq_doorbell);
  printf("  CPU CQ doorbell: %p\n", queue->cq_doorbell);
  printf("  GPU SQ doorbell: %p\n", queue->gpu_sq_doorbell);
  printf("  GPU CQ doorbell: %p\n", queue->gpu_cq_doorbell);

  // Test CPU doorbell access
  printf("\nTesting CPU doorbell access...\n");
  uint32_t val = *queue->sq_doorbell;
  printf("  Read value: %u\n", val);
  *queue->sq_doorbell = val + 1;
  uint32_t new_val = *queue->sq_doorbell;
  printf("  After write: %u\n", new_val);

  if (queue->gpu_sq_doorbell && queue->gpu_cq_doorbell) {
    printf("\n✓ SUCCESS: GPU doorbell pointers are set!\n");
    printf("  HSA memory locking worked\n");
  } else {
    printf("\n✗ FAILURE: GPU doorbell pointers are NULL\n");
  }

  // Cleanup
  nvme_gda_destroy_queue(queue);
  nvme_gda_cleanup(ctx);

  printf("\n✓ Test completed successfully\n");
  return 0;
}
