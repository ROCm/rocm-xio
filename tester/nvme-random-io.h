#ifndef NVME_RANDOM_IO_H
#define NVME_RANDOM_IO_H

#include <stdint.h>

#include <hip/hip_runtime.h>

#include "../endpoints/nvme-ep/nvme-ep.h" // For struct nvme_sqe and helper functions

// Simple LCG random number generator for GPU
__device__ inline uint64_t gpu_rand(uint64_t* seed) {
  // Linear Congruential Generator (LCG)
  // Constants from Numerical Recipes
  *seed = (*seed * 1664525ULL + 1013904223ULL);
  return *seed;
}

// Generate random LBA within range
__device__ inline uint64_t generate_random_lba(uint64_t* seed,
                                               uint64_t max_lba) {
  uint64_t rand_val = gpu_rand(seed);
  return rand_val % max_lba;
}

// GPU kernel to generate NVMe Read commands with random LBAs
__global__ void nvme_generate_random_reads_kernel(
  struct nvme_sqe* sq,         // Submission queue (array of NVMe SQEs)
  volatile uint32_t* doorbell, // Doorbell register (pass pointer directly like
                               // working test)
  uint32_t nsid,               // Namespace ID
  uint64_t max_lba,            // Maximum LBA (range limit)
  uint32_t num_blocks,         // Number of blocks per transfer
  uint32_t queue_size,         // Queue size
  uint32_t num_commands,       // Number of commands to generate
  uint64_t data_buffer_phys,   // Physical address of data buffer
  uint64_t seed_base,          // Base seed for RNG
  unsigned long long int* start_time, // Timing start
  unsigned long long int* end_time    // Timing end
) {
  int tid = hipThreadIdx_x + hipBlockIdx_x * hipBlockDim_x;

  // Debug: Print from ALL threads to see if kernel launches
  printf("[GPU] Kernel launched! tid=%d, doorbell=%p\n", tid, doorbell);

  if (tid == 0) {
    printf("[GPU] Thread 0 executing! num_commands=%u\n", num_commands);
    // Capture start time
    *start_time = clock64();

    uint64_t seed = seed_base + clock64(); // Initialize RNG with unique seed
    uint32_t sq_tail = 0;

    for (uint32_t cmd_idx = 0; cmd_idx < num_commands; cmd_idx++) {
      // Generate random LBA (ensure it doesn't exceed range minus transfer
      // size)
      uint64_t max_start_lba = max_lba > num_blocks ? (max_lba - num_blocks)
                                                    : 0;
      uint64_t slba = generate_random_lba(&seed, max_start_lba);

      // Get pointer to current SQE
      struct nvme_sqe* sqe = &sq[sq_tail];

      // Use helper function to create properly formatted NVMe Read command
      nvme_sqe_setup_read(sqe, cmd_idx, nsid, slba, num_blocks,
                          data_buffer_phys,
                          0); // prp2=0 for single-page transfers

      // Move to next SQ entry
      sq_tail = (sq_tail + 1) % queue_size;
    }

    // Memory fence to ensure all SQE writes are visible BEFORE doorbell
    __threadfence_system();

    // Debug: Print before doorbell write
    printf("[GPU] About to write doorbell: sq_tail=%u, doorbell ptr=%p\n",
           sq_tail, doorbell);

    // Write doorbell with system-scope atomic (for PCIe ordering)
    // This ensures the GPU write is visible to the NVMe controller
    __hip_atomic_store(doorbell, sq_tail, __ATOMIC_RELEASE,
                       __HIP_MEMORY_SCOPE_SYSTEM);

    // System-wide memory fence (ensures PCIe ordering)
    __threadfence_system();

    printf("[GPU] ✓ Doorbell written with system-scope atomic! (value=%u)\n",
           sq_tail);

    // Capture end time
    *end_time = clock64();
  }
}

// GPU kernel for sequential reads
__global__ void nvme_generate_sequential_reads_kernel(
  struct nvme_sqe* sq,
  volatile uint32_t* doorbell, // Doorbell register (pass pointer directly)
  uint32_t nsid, uint64_t start_lba, uint32_t num_blocks, uint32_t queue_size,
  uint32_t num_commands, uint64_t data_buffer_phys,
  unsigned long long int* start_time, unsigned long long int* end_time) {
  int tid = hipThreadIdx_x + hipBlockIdx_x * hipBlockDim_x;

  if (tid == 0) {
    *start_time = clock64();

    uint32_t sq_tail = 0;
    uint64_t current_lba = start_lba;

    for (uint32_t cmd_idx = 0; cmd_idx < num_commands; cmd_idx++) {
      struct nvme_sqe* sqe = &sq[sq_tail];

      // Use helper function to create properly formatted NVMe Read command
      nvme_sqe_setup_read(sqe, cmd_idx, nsid, current_lba, num_blocks,
                          data_buffer_phys, 0);

      sq_tail = (sq_tail + 1) % queue_size;
      current_lba += num_blocks;
    }

    // Memory fence to ensure all SQE writes are visible BEFORE doorbell
    __atomic_signal_fence(__ATOMIC_SEQ_CST);

    // Ring doorbell using system-scope atomic (rocSHMEM method!)
    __hip_atomic_store(const_cast<uint32_t*>(doorbell), sq_tail,
                       __ATOMIC_SEQ_CST, __HIP_MEMORY_SCOPE_SYSTEM);

    // System memory fence to ensure doorbell write completes
    __threadfence_system();

    *end_time = clock64();
  }
}

#endif // NVME_RANDOM_IO_H
