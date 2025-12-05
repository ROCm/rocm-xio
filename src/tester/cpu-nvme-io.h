#pragma once

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "nvme-ep.h"

namespace nvme_axiio {

// CPU-based NVMe random I/O generation
// This is a fallback mode that doesn't require GPU compute or PCIe atomics
inline int cpu_generate_random_reads(struct nvme_sqe* sq_base,
                                     uint32_t num_commands, uint32_t nsid,
                                     uint64_t lba_start, uint64_t lba_count,
                                     uint32_t transfer_size_blocks,
                                     void* prp_buffer_base, uint32_t block_size,
                                     volatile uint32_t* sq_doorbell,
                                     uint16_t* sq_tail) {
  if (!sq_base || !sq_doorbell || !sq_tail) {
    fprintf(stderr, "Error: Invalid parameters to cpu_generate_random_reads\n");
    return -1;
  }

  printf("\n=== CPU-Based NVMe Command Generation ===\n");
  printf("Generating %u random read commands\n", num_commands);
  printf("NSID: %u, LBA range: %lu-%lu\n", nsid, lba_start,
         lba_start + lba_count);
  printf("Transfer size: %u blocks (%u bytes)\n", transfer_size_blocks,
         transfer_size_blocks * block_size);

  // Seed random number generator
  srand(time(NULL));

  uint16_t current_tail = *sq_tail;

  for (uint32_t i = 0; i < num_commands; i++) {
    // Generate random LBA within range
    uint64_t random_lba = lba_start + (rand() % lba_count);

    // Get pointer to SQE
    struct nvme_sqe* sqe = &sq_base[current_tail];

    // Clear the SQE
    memset(sqe, 0, sizeof(struct nvme_sqe));

    // Build NVMe Read command
    sqe->opcode = NVME_CMD_READ;  // 0x02
    sqe->command_id = i & 0xFFFF; // Command ID
    sqe->nsid = nsid;

    // Set SLBA (Starting LBA)
    sqe->cdw10 = random_lba & 0xFFFFFFFF;
    sqe->cdw11 = (random_lba >> 32) & 0xFFFFFFFF;

    // Set NLB (Number of Logical Blocks - 1)
    sqe->cdw12 = (transfer_size_blocks - 1) & 0xFFFF;

    // Calculate PRP (Physical Region Page) pointer
    // Each command gets its own buffer region
    uint64_t prp_addr = (uint64_t)prp_buffer_base +
                        (i * transfer_size_blocks * block_size);
    sqe->dptr.prp.prp1 = prp_addr;

    // If transfer > 1 page, we'd need PRP2, but for 4KiB we're fine
    if (transfer_size_blocks * block_size > 4096) {
      sqe->dptr.prp.prp2 = prp_addr + 4096;
    }

    // Debug: Print first few commands
    if (i < 3) {
      printf("  SQE[%u]: opc=0x%02x cid=%u nsid=%u lba=%lu nlb=%u prp1=0x%lx\n",
             current_tail, sqe->opcode, sqe->command_id, sqe->nsid, random_lba,
             transfer_size_blocks, sqe->dptr.prp.prp1);
    }

    // Advance tail
    current_tail++;
    // Note: In real implementation, this should wrap based on queue size
    // For now, assume queue is large enough
  }

  // Update tail pointer
  *sq_tail = current_tail;

  // Ring the doorbell (CPU write)
  printf("\nRinging doorbell: writing tail=%u to doorbell register\n",
         current_tail);
  *sq_doorbell = current_tail;

  printf("✅ CPU generated and submitted %u commands\n", num_commands);

  return 0;
}

// CPU-based sequential reads
inline int cpu_generate_sequential_reads(
  struct nvme_sqe* sq_base, uint32_t num_commands, uint32_t nsid,
  uint64_t lba_start, uint32_t transfer_size_blocks, void* prp_buffer_base,
  uint32_t block_size, volatile uint32_t* sq_doorbell, uint16_t* sq_tail) {
  if (!sq_base || !sq_doorbell || !sq_tail) {
    fprintf(stderr,
            "Error: Invalid parameters to cpu_generate_sequential_reads\n");
    return -1;
  }

  printf("\n=== CPU-Based NVMe Command Generation (Sequential) ===\n");
  printf("Generating %u sequential read commands\n", num_commands);
  printf("NSID: %u, Starting LBA: %lu\n", nsid, lba_start);
  printf("Transfer size: %u blocks (%u bytes)\n", transfer_size_blocks,
         transfer_size_blocks * block_size);

  uint16_t current_tail = *sq_tail;
  uint64_t current_lba = lba_start;

  for (uint32_t i = 0; i < num_commands; i++) {
    // Get pointer to SQE
    struct nvme_sqe* sqe = &sq_base[current_tail];

    // Clear the SQE
    memset(sqe, 0, sizeof(struct nvme_sqe));

    // Build NVMe Read command
    sqe->opcode = NVME_CMD_READ;  // 0x02
    sqe->command_id = i & 0xFFFF; // Command ID
    sqe->nsid = nsid;

    // Set SLBA (Starting LBA)
    sqe->cdw10 = current_lba & 0xFFFFFFFF;
    sqe->cdw11 = (current_lba >> 32) & 0xFFFFFFFF;

    // Set NLB (Number of Logical Blocks - 1)
    sqe->cdw12 = (transfer_size_blocks - 1) & 0xFFFF;

    // Calculate PRP pointer
    uint64_t prp_addr = (uint64_t)prp_buffer_base +
                        (i * transfer_size_blocks * block_size);
    sqe->dptr.prp.prp1 = prp_addr;

    if (transfer_size_blocks * block_size > 4096) {
      sqe->dptr.prp.prp2 = prp_addr + 4096;
    }

    // Debug: Print first few commands
    if (i < 3) {
      printf("  SQE[%u]: opc=0x%02x cid=%u nsid=%u lba=%lu nlb=%u prp1=0x%lx\n",
             current_tail, sqe->opcode, sqe->command_id, sqe->nsid, current_lba,
             transfer_size_blocks, sqe->dptr.prp.prp1);
    }

    // Advance to next LBA
    current_lba += transfer_size_blocks;

    // Advance tail
    current_tail++;
  }

  // Update tail pointer
  *sq_tail = current_tail;

  // Ring the doorbell (CPU write)
  printf("\nRinging doorbell: writing tail=%u to doorbell register\n",
         current_tail);
  *sq_doorbell = current_tail;

  printf("✅ CPU generated and submitted %u commands\n", num_commands);

  return 0;
}

// Poll completion queue for results
inline int cpu_poll_completions(struct nvme_cqe* cq_base,
                                uint32_t expected_completions,
                                uint16_t* cq_head,
                                volatile uint32_t* cq_doorbell,
                                uint8_t* phase_bit,
                                uint32_t timeout_ms = 5000) {
  if (!cq_base || !cq_head || !cq_doorbell || !phase_bit) {
    fprintf(stderr, "Error: Invalid parameters to cpu_poll_completions\n");
    return -1;
  }

  printf("\n=== CPU Polling for Completions ===\n");
  printf("Waiting for %u completions (timeout: %u ms)\n", expected_completions,
         timeout_ms);

  uint32_t completions_found = 0;
  uint16_t current_head = *cq_head;
  uint8_t expected_phase = *phase_bit;

  // Simple timeout mechanism
  struct timespec start, now;
  clock_gettime(CLOCK_MONOTONIC, &start);

  while (completions_found < expected_completions) {
    struct nvme_cqe* cqe = &cq_base[current_head];

    // Check if entry is valid (phase bit matches)
    if ((cqe->status & 0x1) == expected_phase) {
      // Found a completion
      uint16_t status_field = cqe->status >> 1;
      uint16_t cid = cqe->command_id;

      if (completions_found < 3) {
        printf("  CQE[%u]: cid=%u status=0x%04x sqhd=%u\n", current_head, cid,
               status_field, cqe->sq_head);
      }

      // Check for errors
      if (status_field != 0) {
        fprintf(stderr,
                "⚠️  Warning: Command %u completed with error status 0x%04x\n",
                cid, status_field);
      }

      completions_found++;

      // Advance head
      current_head++;
      // TODO: Handle queue wrapping

      // Update phase bit if we wrapped
      if (current_head == 0) {
        expected_phase = !expected_phase;
      }
    }

    // Check timeout
    clock_gettime(CLOCK_MONOTONIC, &now);
    uint64_t elapsed_ms = (now.tv_sec - start.tv_sec) * 1000 +
                          (now.tv_nsec - start.tv_nsec) / 1000000;
    if (elapsed_ms > timeout_ms) {
      fprintf(stderr, "⚠️  Timeout: Only %u/%u completions received\n",
              completions_found, expected_completions);
      break;
    }

    // Small delay to avoid busy-waiting too aggressively
    if ((cqe->status & 0x1) != expected_phase) {
      usleep(10); // 10 microseconds
    }
  }

  // Update head pointer and ring doorbell
  *cq_head = current_head;
  *phase_bit = expected_phase;
  *cq_doorbell = current_head;

  printf("✅ Received %u/%u completions\n", completions_found,
         expected_completions);

  return completions_found == expected_completions ? 0 : -1;
}

} // namespace nvme_axiio
