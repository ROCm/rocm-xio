// SPDX-License-Identifier: MIT
/**
 * NVMe GDA Full I/O Test
 *
 * Tests GPU-initiated NVMe read/write operations
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <hip/hip_runtime.h>

#include "../include/nvme_gda.h"

#define CHECK_HIP(cmd)                                                         \
  do {                                                                         \
    hipError_t error = (cmd);                                                  \
    if (error != hipSuccess) {                                                 \
      fprintf(stderr, "HIP error %d at %s:%d: %s\n", error, __FILE__,          \
              __LINE__, hipGetErrorString(error));                             \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)

#define BLOCK_SIZE 512
#define NUM_BLOCKS 8

/**
 * GPU kernel that performs NVMe reads
 */
__global__ void gpu_read_kernel(nvme_gda_queue_userspace* queue, uint32_t nsid,
                                uint64_t start_lba, char* buffers,
                                int* status) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;

  if (tid < NUM_BLOCKS) {
    // Each thread reads one block
    uint64_t lba = start_lba + tid;
    char* my_buffer = buffers + (tid * BLOCK_SIZE);

    printf("GPU thread %d: Reading LBA %lu\n", tid, lba);

    // Build and post read command
    struct nvme_command cmd = nvme_gda_build_read_cmd(nsid, lba,
                                                      1, /* 1 block */
                                                      (uint64_t)my_buffer, 0);

    uint16_t cid = nvme_gda_post_command(queue, &cmd);

    // Wait for completion
    struct nvme_completion cqe = nvme_gda_wait_completion(queue, cid);

    // Check status
    uint16_t cqe_status = (cqe.status >> 1) & 0x7FF;
    status[tid] = cqe_status;

    if (cqe_status == 0) {
      printf("GPU thread %d: Read completed successfully\n", tid);
    } else {
      printf("GPU thread %d: Read failed with status 0x%x\n", tid, cqe_status);
    }
  }
}

/**
 * GPU kernel that performs NVMe writes
 */
__global__ void gpu_write_kernel(nvme_gda_queue_userspace* queue, uint32_t nsid,
                                 uint64_t start_lba, const char* buffers,
                                 int* status) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;

  if (tid < NUM_BLOCKS) {
    // Each thread writes one block
    uint64_t lba = start_lba + tid;
    const char* my_buffer = buffers + (tid * BLOCK_SIZE);

    printf("GPU thread %d: Writing LBA %lu\n", tid, lba);

    // Build and post write command
    struct nvme_command cmd = nvme_gda_build_write_cmd(nsid, lba,
                                                       1, /* 1 block */
                                                       (uint64_t)my_buffer, 0);

    uint16_t cid = nvme_gda_post_command(queue, &cmd);

    // Wait for completion
    struct nvme_completion cqe = nvme_gda_wait_completion(queue, cid);

    // Check status
    uint16_t cqe_status = (cqe.status >> 1) & 0x7FF;
    status[tid] = cqe_status;

    if (cqe_status == 0) {
      printf("GPU thread %d: Write completed successfully\n", tid);
    } else {
      printf("GPU thread %d: Write failed with status 0x%x\n", tid, cqe_status);
    }
  }
}

void fill_test_pattern(char* buffer, int size, int pattern_id) {
  for (int i = 0; i < size; i++) {
    buffer[i] = (char)((pattern_id * 13 + i) & 0xFF);
  }
}

bool verify_test_pattern(const char* buffer, int size, int pattern_id) {
  for (int i = 0; i < size; i++) {
    char expected = (char)((pattern_id * 13 + i) & 0xFF);
    if (buffer[i] != expected) {
      return false;
    }
  }
  return true;
}

int main(int argc, char** argv) {
  const char* device_path = "/dev/nvme_gda0";
  uint32_t nsid = 1;           /* Namespace ID */
  uint64_t start_lba = 0x1000; /* Start at LBA 4096 */

  printf("NVMe GDA Full I/O Test\n");
  printf("======================\n\n");

  if (argc > 1)
    device_path = argv[1];
  if (argc > 2)
    nsid = atoi(argv[2]);
  if (argc > 3)
    start_lba = strtoull(argv[3], NULL, 0);

  printf("Parameters:\n");
  printf("  Device: %s\n", device_path);
  printf("  Namespace ID: %u\n", nsid);
  printf("  Start LBA: 0x%lx\n", start_lba);
  printf("  Block size: %d bytes\n", BLOCK_SIZE);
  printf("  Number of blocks: %d\n", NUM_BLOCKS);
  printf("\n");

  // Initialize NVMe GDA
  printf("Initializing NVMe GDA...\n");
  nvme_gda_context* ctx = nvme_gda_init(device_path);
  if (!ctx) {
    fprintf(stderr, "Failed to initialize NVMe GDA\n");
    return 1;
  }

  // Create queue
  printf("Creating I/O queue (size 256)...\n");
  nvme_gda_queue_userspace* queue = nvme_gda_create_queue(ctx, 256);
  if (!queue) {
    fprintf(stderr, "Failed to create queue\n");
    nvme_gda_cleanup(ctx);
    return 1;
  }

  // Allocate GPU buffers
  printf("Allocating GPU memory...\n");
  char *d_write_buffers, *d_read_buffers;
  int* d_status;

  CHECK_HIP(hipMalloc(&d_write_buffers, NUM_BLOCKS * BLOCK_SIZE));
  CHECK_HIP(hipMalloc(&d_read_buffers, NUM_BLOCKS * BLOCK_SIZE));
  CHECK_HIP(hipMalloc(&d_status, NUM_BLOCKS * sizeof(int)));

  // Prepare write data on host
  char* h_write_buffers = (char*)malloc(NUM_BLOCKS * BLOCK_SIZE);
  for (int i = 0; i < NUM_BLOCKS; i++) {
    fill_test_pattern(h_write_buffers + i * BLOCK_SIZE, BLOCK_SIZE, i);
  }

  // Copy to GPU
  CHECK_HIP(hipMemcpy(d_write_buffers, h_write_buffers, NUM_BLOCKS * BLOCK_SIZE,
                      hipMemcpyHostToDevice));

  // Copy queue structure to GPU
  nvme_gda_queue_userspace* d_queue;
  CHECK_HIP(hipMalloc(&d_queue, sizeof(nvme_gda_queue_userspace)));
  CHECK_HIP(hipMemcpy(d_queue, queue, sizeof(nvme_gda_queue_userspace),
                      hipMemcpyHostToDevice));

  printf("\n=== GPU Write Test ===\n");
  printf("Launching GPU write kernel...\n");

  hipLaunchKernelGGL(gpu_write_kernel, dim3((NUM_BLOCKS + 255) / 256),
                     dim3(256), 0, 0, d_queue, nsid, start_lba, d_write_buffers,
                     d_status);

  CHECK_HIP(hipGetLastError());
  CHECK_HIP(hipDeviceSynchronize());

  // Check write status
  int h_status[NUM_BLOCKS];
  CHECK_HIP(hipMemcpy(h_status, d_status, NUM_BLOCKS * sizeof(int),
                      hipMemcpyDeviceToHost));

  int write_success = 0;
  for (int i = 0; i < NUM_BLOCKS; i++) {
    if (h_status[i] == 0) {
      write_success++;
    } else {
      printf("  Block %d write failed: status=0x%x\n", i, h_status[i]);
    }
  }
  printf("Write results: %d/%d successful\n", write_success, NUM_BLOCKS);

  printf("\n=== GPU Read Test ===\n");
  printf("Launching GPU read kernel...\n");

  // Zero read buffers
  CHECK_HIP(hipMemset(d_read_buffers, 0, NUM_BLOCKS * BLOCK_SIZE));
  CHECK_HIP(hipMemset(d_status, 0, NUM_BLOCKS * sizeof(int)));

  hipLaunchKernelGGL(gpu_read_kernel, dim3((NUM_BLOCKS + 255) / 256), dim3(256),
                     0, 0, d_queue, nsid, start_lba, d_read_buffers, d_status);

  CHECK_HIP(hipGetLastError());
  CHECK_HIP(hipDeviceSynchronize());

  // Check read status
  CHECK_HIP(hipMemcpy(h_status, d_status, NUM_BLOCKS * sizeof(int),
                      hipMemcpyDeviceToHost));

  int read_success = 0;
  for (int i = 0; i < NUM_BLOCKS; i++) {
    if (h_status[i] == 0) {
      read_success++;
    } else {
      printf("  Block %d read failed: status=0x%x\n", i, h_status[i]);
    }
  }
  printf("Read results: %d/%d successful\n", read_success, NUM_BLOCKS);

  // Verify data
  printf("\n=== Data Verification ===\n");
  char* h_read_buffers = (char*)malloc(NUM_BLOCKS * BLOCK_SIZE);
  CHECK_HIP(hipMemcpy(h_read_buffers, d_read_buffers, NUM_BLOCKS * BLOCK_SIZE,
                      hipMemcpyDeviceToHost));

  int verify_success = 0;
  for (int i = 0; i < NUM_BLOCKS; i++) {
    if (verify_test_pattern(h_read_buffers + i * BLOCK_SIZE, BLOCK_SIZE, i)) {
      verify_success++;
    } else {
      printf("  Block %d: Data mismatch!\n", i);
    }
  }
  printf("Verification: %d/%d blocks correct\n", verify_success, NUM_BLOCKS);

  // Final results
  printf("\n=== FINAL RESULTS ===\n");
  printf("Writes:  %d/%d successful\n", write_success, NUM_BLOCKS);
  printf("Reads:   %d/%d successful\n", read_success, NUM_BLOCKS);
  printf("Verify:  %d/%d correct\n", verify_success, NUM_BLOCKS);

  if (write_success == NUM_BLOCKS && read_success == NUM_BLOCKS &&
      verify_success == NUM_BLOCKS) {
    printf("\n✓ ALL TESTS PASSED!\n");
    printf("GPU successfully performed NVMe I/O operations!\n");
  } else {
    printf("\n✗ SOME TESTS FAILED\n");
  }

  // Cleanup
  free(h_write_buffers);
  free(h_read_buffers);
  CHECK_HIP(hipFree(d_write_buffers));
  CHECK_HIP(hipFree(d_read_buffers));
  CHECK_HIP(hipFree(d_status));
  CHECK_HIP(hipFree(d_queue));

  nvme_gda_destroy_queue(queue);
  nvme_gda_cleanup(ctx);

  printf("\nTest completed\n");
  return (verify_success == NUM_BLOCKS) ? 0 : 1;
}
