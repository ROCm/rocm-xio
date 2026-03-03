/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <hip/hip_runtime.h>

#include "nvme-ep.h"
#include "xio.h"

// Simple GPU kernel for single NVMe write operation
__global__ void test_simple_write_kernel(
  struct nvme_sqe* sqe, struct nvme_cqe* cqe, uint64_t write_buffer_dma,
  uint32_t nsid, uint64_t slba, uint32_t nlb, uint32_t lba_size,
  uint32_t doorbell_offset, void* nvme_bar0_gpu, uint16_t cid,
  uint16_t queue_size, uint16_t cq_head_start, uint16_t last_sq_head_start,
  uint16_t sq_tail_start) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid != 0)
    return; // Only thread 0 performs the operation

  // Setup write command at SQ tail
  // sq_tail wraps modulo queue_size independently of sq_head
  // This matches the pattern in nvme-ep.hip sequential mode
  uint16_t sq_tail = sq_tail_start;
  nvme_ep::sqeType sqe_local = {};

  // Calculate PRP entries from buffer address
  uint64_t prp1 = 0;
  uint64_t prp2 = 0;
  uint32_t transfer_size = nlb * lba_size;
  nvme_ep::nvme_calculate_prps(write_buffer_dma, transfer_size, &prp1, &prp2);

  // Setup write command in local SQE
  nvme_ep::nvme_sqe_setup_write(reinterpret_cast<struct nvme_sqe*>(&sqe_local),
                                cid, nsid, slba, nlb, prp1, prp2);

  // Write SQE to queue (includes memory fence)
  nvme_ep::sqeWrite(sqe_local, &sqe[sq_tail]);
  sq_tail = (sq_tail + 1) % queue_size;

  // Ring doorbell
  nvme_ep::ringDoorbell(sq_tail, doorbell_offset, false, nullptr, 0,
                        nvme_bar0_gpu);

  // Poll for completion - match sequential mode pattern from nvme-ep.hip
  // Directly check sq_head progression instead of using cqePoll to avoid
  // issues with zeroed CQE entries
  uint16_t cq_head = cq_head_start;
  uint16_t last_sq_head = last_sq_head_start;
  const uint32_t max_polls = 10000000; // Safety limit
  uint32_t poll_count = 0;

  while (poll_count < max_polls) {
    volatile struct nvme_cqe* cqe_entry = &cqe[cq_head];
    nvme_ep::cqeType cqe_data = nvme_ep::cqeRead(
      reinterpret_cast<volatile nvme_ep::cqeType*>(cqe_entry));
    uint16_t sq_head = cqe_data.sq_head;

    // Primary check: sq_head has increased (definitive indicator of completion)
    // In sequential mode, any increase means our command completed
    if (sq_head > last_sq_head) {
      // sq_head increased - command completed
      // Verify command ID matches (should be our command in sequential mode)
      if (cqe_data.command_id == cid) {
        // Our command completed - break
        last_sq_head = sq_head;
        break;
      } else {
        // Command ID doesn't match - this might be a completion from a
        // previous command. Advance cq_head and continue polling
        cq_head = (cq_head + 1) % queue_size;
        last_sq_head = sq_head;
        poll_count = 0; // Reset poll count when we find progress
        continue;
      }
    }
    poll_count++;
  }

  // Our command completed - advance cq_head for next operation
  cq_head = (cq_head + 1) % queue_size;
}

// Simple GPU kernel for single NVMe read operation
__global__ void test_simple_read_kernel(
  struct nvme_sqe* sqe, struct nvme_cqe* cqe, uint64_t read_buffer_dma,
  uint32_t nsid, uint64_t slba, uint32_t nlb, uint32_t lba_size,
  uint32_t doorbell_offset, void* nvme_bar0_gpu, uint16_t cid,
  uint16_t queue_size, uint16_t cq_head_start, uint16_t last_sq_head_start,
  uint16_t sq_tail_start) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid != 0)
    return; // Only thread 0 performs the operation

  // Setup read command at SQ tail
  // sq_tail wraps modulo queue_size independently of sq_head
  // This matches the pattern in nvme-ep.hip sequential mode
  uint16_t sq_tail = sq_tail_start;
  nvme_ep::sqeType sqe_local = {};

  // Calculate PRP entries from buffer address
  uint64_t prp1 = 0;
  uint64_t prp2 = 0;
  uint32_t transfer_size = nlb * lba_size;
  nvme_ep::nvme_calculate_prps(read_buffer_dma, transfer_size, &prp1, &prp2);

  // Setup read command in local SQE
  nvme_ep::nvme_sqe_setup_read(reinterpret_cast<struct nvme_sqe*>(&sqe_local),
                               cid, nsid, slba, nlb, prp1, prp2);

  // Write SQE to queue (includes memory fence)
  nvme_ep::sqeWrite(sqe_local, &sqe[sq_tail]);
  sq_tail = (sq_tail + 1) % queue_size;

  // Ring doorbell with tail pointer (BAR0 must be mapped)
  nvme_ep::ringDoorbell(sq_tail, doorbell_offset, false, nullptr, 0,
                        nvme_bar0_gpu);

  // Poll for completion - match sequential mode pattern from nvme-ep.hip
  // Directly check sq_head progression instead of using cqePoll to avoid
  // issues with zeroed CQE entries
  uint16_t cq_head = cq_head_start;
  uint16_t last_sq_head = last_sq_head_start;
  const uint32_t max_polls = 10000000; // Safety limit
  uint32_t poll_count = 0;

  while (poll_count < max_polls) {
    volatile struct nvme_cqe* cqe_entry = &cqe[cq_head];
    nvme_ep::cqeType cqe_data = nvme_ep::cqeRead(
      reinterpret_cast<volatile nvme_ep::cqeType*>(cqe_entry));
    uint16_t sq_head = cqe_data.sq_head;

    // Primary check: sq_head has increased (definitive indicator of completion)
    // In sequential mode, any increase means our command completed
    if (sq_head > last_sq_head) {
      // sq_head increased - command completed
      // Verify command ID matches (should be our command in sequential mode)
      if (cqe_data.command_id == cid) {
        // Our command completed - break
        last_sq_head = sq_head;
        break;
      } else {
        // Command ID doesn't match - this might be a completion from a
        // previous command. Advance cq_head and continue polling
        cq_head = (cq_head + 1) % queue_size;
        last_sq_head = sq_head;
        poll_count = 0; // Reset poll count when we find progress
        continue;
      }
    }
    poll_count++;
  }

  // Our command completed - advance cq_head for next operation
  cq_head = (cq_head + 1) % queue_size;
}

// Test simple write operation
static int test_simple_write(const char* /* nvme_device */, uint32_t nsid,
                             uint32_t lba_size, uint64_t base_lba,
                             uint32_t blocks, struct nvme_queue_info* queue_info,
                             void* nvme_bar0_gpu, uint16_t* cq_head_inout,
                             uint16_t* last_sq_head_inout,
                             uint16_t* sq_tail_inout, uint16_t cid,
                             uint16_t queue_size) {
  hipError_t err;
  const uint32_t transfer_size = blocks * lba_size;
  const uint16_t queue_id = 1;

  // Doorbell offset: base (0x1000) + (2 * queue_id) * stride (4 bytes)
  const uint32_t doorbell_offset = 0x1000 + (2 * queue_id) * 4;

  // Allocate write buffer with coherent memory for GPU access
  uint8_t* write_buffer = nullptr;
  err = hipHostMalloc(&write_buffer, transfer_size,
                      hipHostMallocMapped | hipHostMallocCoherent);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to allocate write buffer: %s\n",
            hipGetErrorString(err));
    return -1;
  }

  // Get GPU pointer
  uint8_t* write_buffer_gpu = nullptr;
  err = hipHostGetDevicePointer(reinterpret_cast<void**>(&write_buffer_gpu),
                                write_buffer, 0);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to get GPU pointer: %s\n", hipGetErrorString(err));
    HIP_CHECK(hipHostFree(write_buffer));
    return -1;
  }

  // Get DMA address using xioGetPhysAddr for host-allocated coherent memory
  uint64_t write_buffer_dma = xioGetPhysAddr(write_buffer);
  if (write_buffer_dma == 0) {
    fprintf(stderr,
            "Warning: Failed to get physical address for write buffer\n");
    fprintf(stderr, "Falling back to virtual address (may not work)\n");
    write_buffer_dma = reinterpret_cast<uint64_t>(write_buffer);
  }

  // Generate test pattern using library function
  nvme_ep::nvme_generate_pattern(write_buffer, transfer_size,
                                 base_lba * lba_size, lba_size, 0);

  // Get queue pointers
  struct nvme_sqe* sqe =
    static_cast<struct nvme_sqe*>(queue_info->sq_gpu
                                     ? queue_info->sq_gpu
                                     : queue_info->sq_virt);
  struct nvme_cqe* cqe =
    static_cast<struct nvme_cqe*>(queue_info->cq_gpu
                                     ? queue_info->cq_gpu
                                     : queue_info->cq_virt);

  // Don't zero SQ - we write to sequential slots matching the controller's head
  // Don't zero CQ - it may contain previous completions that we need to skip

  // Initialize queue state tracking
  uint16_t cq_head_start = (cq_head_inout != nullptr) ? *cq_head_inout : 0;
  uint16_t last_sq_head_start = (last_sq_head_inout != nullptr)
                                  ? *last_sq_head_inout
                                  : 0;
  uint16_t sq_tail_start = (sq_tail_inout != nullptr) ? *sq_tail_inout : 0;
  uint16_t cid_to_use = (cid != 0) ? cid : 1;

  // Debug: Print SQE details before launch
  fprintf(stderr,
          "Write test: cid=%u, nsid=%u, slba=%llu, nlb=%u, "
          "dma_addr=0x%016llx, doorbell_offset=0x%x, "
          "cq_head_start=%u, last_sq_head_start=%u, sq_tail_start=%u, "
          "queue_size=%u\n",
          cid_to_use, nsid, (unsigned long long)base_lba, blocks,
          (unsigned long long)write_buffer_dma, doorbell_offset, cq_head_start,
          last_sq_head_start, sq_tail_start, queue_size);

  // Launch kernel
  hipLaunchKernelGGL(test_simple_write_kernel, dim3(1), dim3(1), 0, 0, sqe, cqe,
                     write_buffer_dma, nsid, base_lba, blocks, lba_size,
                     doorbell_offset, nvme_bar0_gpu, cid_to_use, queue_size,
                     cq_head_start, last_sq_head_start, sq_tail_start);

  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    fprintf(stderr, "Kernel launch failed: %s\n", hipGetErrorString(err));
    HIP_CHECK(hipHostFree(write_buffer));
    return -1;
  }

  // Kernel already polled and verified the completion with matching command_id
  // Just read from cq_head_start to get status and sq_head for tracking
  volatile struct nvme_cqe* completion = &cqe[cq_head_start];
  nvme_ep::cqeType cqe_data = nvme_ep::cqeRead(
    reinterpret_cast<volatile nvme_ep::cqeType*>(completion));
  uint16_t cmd_id = cqe_data.command_id;
  uint16_t sq_head = cqe_data.sq_head;
  uint8_t phase = NVME_CQE_STATUS_PHASE(cqe_data.status);

  // Debug output
  fprintf(stderr,
          "Write completion: cmd_id=%u (expected %u), sq_head=%u "
          "(last=%u), phase=%u, cq_head=%u\n",
          cmd_id, cid_to_use, sq_head, last_sq_head_start, phase,
          cq_head_start);

  if (!nvme_ep::nvme_cqe_ok(completion)) {
    uint8_t sc = nvme_ep::nvme_cqe_status_code(completion);
    uint8_t sct = nvme_ep::nvme_cqe_status_type(completion);
    fprintf(stderr, "ERROR: Write command failed: SC=0x%02x, SCT=0x%x\n", sc,
            sct);
    fprintf(stderr, "  Status indicates command was processed but failed\n");
    HIP_CHECK(hipHostFree(write_buffer));
    return -1;
  }

  // Verify sq_head increased
  if (sq_head <= last_sq_head_start) {
    fprintf(stderr, "ERROR: sq_head did not increase: %u (last was %u)\n",
            sq_head, last_sq_head_start);
    HIP_CHECK(hipHostFree(write_buffer));
    return -1;
  }

  // Update queue state for next operation
  uint16_t new_cq_head = (cq_head_start + 1) % queue_size;
  uint16_t new_sq_tail = (sq_tail_start + 1) % queue_size;
  if (cq_head_inout != nullptr) {
    *cq_head_inout = new_cq_head;
  }
  if (last_sq_head_inout != nullptr) {
    *last_sq_head_inout = sq_head;
  }
  if (sq_tail_inout != nullptr) {
    *sq_tail_inout = new_sq_tail;
  }

  printf("Write test passed: %u blocks written to LBA %llu\n", blocks,
         (unsigned long long)base_lba);

  HIP_CHECK(hipHostFree(write_buffer));
  return 0;
}

// Test simple read operation
static int test_simple_read(const char* /* nvme_device */, uint32_t nsid,
                            uint32_t lba_size, uint64_t base_lba,
                            uint32_t blocks, struct nvme_queue_info* queue_info,
                            void* nvme_bar0_gpu, uint16_t* cq_head_inout,
                            uint16_t* last_sq_head_inout,
                            uint16_t* sq_tail_inout, uint16_t cid,
                            uint16_t queue_size) {
  hipError_t err;
  const uint32_t transfer_size = blocks * lba_size;
  const uint16_t queue_id = 1;

  // Doorbell offset: base (0x1000) + (2 * queue_id) * stride (4 bytes)
  const uint32_t doorbell_offset = 0x1000 + (2 * queue_id) * 4;

  // Allocate read buffer with coherent memory for GPU access
  uint8_t* read_buffer = nullptr;
  err = hipHostMalloc(&read_buffer, transfer_size,
                      hipHostMallocMapped | hipHostMallocCoherent);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to allocate read buffer: %s\n",
            hipGetErrorString(err));
    return -1;
  }

  // Get GPU pointer
  uint8_t* read_buffer_gpu = nullptr;
  err = hipHostGetDevicePointer(reinterpret_cast<void**>(&read_buffer_gpu),
                                read_buffer, 0);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to get GPU pointer: %s\n", hipGetErrorString(err));
    HIP_CHECK(hipHostFree(read_buffer));
    return -1;
  }

  // Get DMA address using xioGetPhysAddr for host-allocated coherent memory
  uint64_t read_buffer_dma = xioGetPhysAddr(read_buffer);
  if (read_buffer_dma == 0) {
    fprintf(stderr,
            "Warning: Failed to get physical address for read buffer\n");
    fprintf(stderr, "Falling back to virtual address (may not work)\n");
    read_buffer_dma = reinterpret_cast<uint64_t>(read_buffer);
  }

  // Zero-initialize read buffer
  memset(read_buffer, 0, transfer_size);

  // Get queue pointers
  struct nvme_sqe* sqe =
    static_cast<struct nvme_sqe*>(queue_info->sq_gpu
                                     ? queue_info->sq_gpu
                                     : queue_info->sq_virt);
  struct nvme_cqe* cqe =
    static_cast<struct nvme_cqe*>(queue_info->cq_gpu
                                     ? queue_info->cq_gpu
                                     : queue_info->cq_virt);

  // Don't zero SQ - we write to sequential slots matching the controller's head
  // Don't zero CQ - it may contain previous completions that we need to skip

  // Initialize queue state tracking
  uint16_t cq_head_start = (cq_head_inout != nullptr) ? *cq_head_inout : 1;
  uint16_t last_sq_head_start = (last_sq_head_inout != nullptr)
                                  ? *last_sq_head_inout
                                  : 1;
  uint16_t sq_tail_start = (sq_tail_inout != nullptr) ? *sq_tail_inout : 1;
  uint16_t cid_to_use = (cid != 0) ? cid : 2;

  // Debug: Check current CQ state before read
  volatile struct nvme_cqe* check_cqe = &cqe[cq_head_start];
  nvme_ep::cqeType check_data = nvme_ep::cqeRead(
    reinterpret_cast<volatile nvme_ep::cqeType*>(check_cqe));
  fprintf(stderr,
          "Read test: Before launch, cqe[%u]: cmd_id=%u, sq_head=%u, "
          "phase=%u, last_sq_head_start=%u, sq_tail_start=%u\n",
          cq_head_start, check_data.command_id, check_data.sq_head,
          NVME_CQE_STATUS_PHASE(check_data.status), last_sq_head_start,
          sq_tail_start);

  // Launch kernel
  hipLaunchKernelGGL(test_simple_read_kernel, dim3(1), dim3(1), 0, 0, sqe, cqe,
                     read_buffer_dma, nsid, base_lba, blocks, lba_size,
                     doorbell_offset, nvme_bar0_gpu, cid_to_use, queue_size,
                     cq_head_start, last_sq_head_start, sq_tail_start);

  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    fprintf(stderr, "Kernel launch failed: %s\n", hipGetErrorString(err));
    HIP_CHECK(hipHostFree(read_buffer));
    return -1;
  }

  // Kernel already polled and verified the completion with matching command_id
  // Just read from cq_head_start to get status and sq_head for tracking
  volatile struct nvme_cqe* completion = &cqe[cq_head_start];
  nvme_ep::cqeType cqe_data = nvme_ep::cqeRead(
    reinterpret_cast<volatile nvme_ep::cqeType*>(completion));
  uint16_t cmd_id = cqe_data.command_id;
  uint16_t sq_head = cqe_data.sq_head;
  uint8_t phase = NVME_CQE_STATUS_PHASE(cqe_data.status);

  // Debug output
  fprintf(stderr,
          "Read completion: cmd_id=%u (expected %u), sq_head=%u "
          "(last=%u), phase=%u, cq_head=%u\n",
          cmd_id, cid_to_use, sq_head, last_sq_head_start, phase,
          cq_head_start);

  if (!nvme_ep::nvme_cqe_ok(completion)) {
    uint8_t sc = nvme_ep::nvme_cqe_status_code(completion);
    uint8_t sct = nvme_ep::nvme_cqe_status_type(completion);
    fprintf(stderr, "ERROR: Read command failed: SC=0x%02x, SCT=0x%x\n", sc,
            sct);
    fprintf(stderr, "  Status indicates command was processed but failed\n");
    HIP_CHECK(hipHostFree(read_buffer));
    return -1;
  }

  // Verify sq_head increased
  if (sq_head <= last_sq_head_start) {
    fprintf(stderr, "ERROR: sq_head did not increase: %u (last was %u)\n",
            sq_head, last_sq_head_start);
    HIP_CHECK(hipHostFree(read_buffer));
    return -1;
  }

  // Update queue state for next operation
  uint16_t new_cq_head = (cq_head_start + 1) % queue_size;
  uint16_t new_sq_tail = (sq_tail_start + 1) % queue_size;
  if (cq_head_inout != nullptr) {
    *cq_head_inout = new_cq_head;
  }
  if (last_sq_head_inout != nullptr) {
    *last_sq_head_inout = sq_head;
  }
  if (sq_tail_inout != nullptr) {
    *sq_tail_inout = new_sq_tail;
  }

  printf("Read test passed: %u blocks read from LBA %llu\n", blocks,
         (unsigned long long)base_lba);

  // Verify read data matches written pattern
  size_t error_offset = 0;
  bool verify_ok = nvme_ep::nvme_verify_pattern(read_buffer, transfer_size,
                                                base_lba * lba_size, lba_size,
                                                &error_offset, 0);
  if (!verify_ok) {
    fprintf(stderr, "ERROR: Read data verification failed at offset %zu\n",
            error_offset);
    HIP_CHECK(hipHostFree(read_buffer));
    return -1;
  }
  printf("Read data verification passed\n");

  HIP_CHECK(hipHostFree(read_buffer));
  return 0;
}

int main(int argc, char* argv[]) {
  const char* nvme_device = nullptr;
  uint32_t nsid = 1;
  uint32_t iterations = 0;    // 0 = single test mode, >0 = loop mode
  uint32_t blocks_per_op = 8; // Blocks per write/read operation

  // Check for HSA_FORCE_FINE_GRAIN_PCIE environment variable
  const char* fine_grain = getenv("HSA_FORCE_FINE_GRAIN_PCIE");
  if (!fine_grain || strcmp(fine_grain, "1") != 0) {
    fprintf(stderr, "WARNING: HSA_FORCE_FINE_GRAIN_PCIE not set to 1.\n");
    fprintf(stderr,
            "This may cause GPU page faults when accessing host memory.\n");
    fprintf(stderr, "Set with: export HSA_FORCE_FINE_GRAIN_PCIE=1\n");
    fprintf(stderr, "Continuing anyway...\n\n");
  }

  // Parse command-line arguments
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--controller") == 0 && i + 1 < argc) {
      nvme_device = argv[++i];
    } else if (strcmp(argv[i], "--namespace") == 0 && i + 1 < argc) {
      nsid = static_cast<uint32_t>(atoi(argv[++i]));
    } else if (strcmp(argv[i], "--iterations") == 0 && i + 1 < argc) {
      iterations = static_cast<uint32_t>(atoi(argv[++i]));
    } else if (strcmp(argv[i], "--blocks-per-op") == 0 && i + 1 < argc) {
      blocks_per_op = static_cast<uint32_t>(atoi(argv[++i]));
    } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
      printf("Usage: %s [OPTIONS]\n", argv[0]);
      printf("Options:\n");
      printf("  --controller <device>  NVMe controller device (e.g., "
             "/dev/nvme0)\n");
      printf("  --namespace <nsid>     Namespace ID (default: 1)\n");
      printf("  --iterations <num>     Number of iterations for loop mode "
             "(default: 0 = single test)\n");
      printf("  --blocks-per-op <num>  Blocks per write/read operation "
             "(default: 8)\n");
      printf("  --help, -h             Show this help message\n");
      return 0;
    } else {
      fprintf(stderr, "Unknown option: %s\n", argv[i]);
      fprintf(stderr, "Use --help for usage information\n");
      return 1;
    }
  }

  if (nvme_device == nullptr) {
    fprintf(stderr, "ERROR: --controller must be specified\n");
    fprintf(stderr, "Use --help for usage information\n");
    return 1;
  }

  // Ensure kernel module is loaded
  if (!xioCheckKernelModuleLoaded()) {
    printf("Kernel module not loaded, attempting to load...\n");
    int ret = xioLoadKernelModule();
    if (ret != 0) {
      fprintf(stderr, "Failed to load kernel module: %s\n", strerror(-ret));
      fprintf(stderr, "Please load manually with: sudo modprobe rocm-xio\n");
      return 1;
    }
  }

  // Ensure device node exists
  int ret = xioEnsureDeviceNode();
  if (ret != 0) {
    fprintf(stderr, "Failed to ensure device node exists: %s\n",
            strerror(-ret));
    fprintf(stderr, "Please create manually with: sudo mknod /dev/rocm-xio c "
                    "<major> 0\n");
    return 1;
  }

  // Check if NVMe device is rootfs (safety check)
  ret = nvme_ep_check_rootfs(nvme_device);
  if (ret != 0) {
    fprintf(stderr, "ERROR: NVMe device appears to be the root filesystem.\n");
    fprintf(stderr,
            "This test will NOT run on the root filesystem for safety.\n");
    fprintf(stderr, "Please specify a different NVMe device.\n");
    return 1;
  }

  // Initialize HIP
  hipError_t err = hipInit(0);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to initialize HIP: %s\n", hipGetErrorString(err));
    return 1;
  }

  // Query LBA size
  unsigned lba_size = 0;
  ret = nvme_ep_query_lba_size(nvme_device, nsid, &lba_size);
  if (ret != 0) {
    fprintf(stderr, "Failed to query LBA size: %s\n", strerror(-ret));
    return 1;
  }
  printf("LBA size: %u bytes\n", lba_size);

  // Query namespace capacity
  uint64_t capacity_lbas = 0;
  ret = nvme_ep_query_namespace_capacity(nvme_device, nsid, &capacity_lbas);
  if (ret != 0) {
    fprintf(stderr, "Failed to query namespace capacity: %s\n", strerror(-ret));
    return 1;
  }
  printf("Namespace capacity: %llu LBAs\n", (unsigned long long)capacity_lbas);

  // Read initial SMART log
  struct nvme_smart_log initial_smart_log;
  ret = nvme_ep_read_smart_log(nvme_device, &initial_smart_log);
  if (ret != 0) {
    fprintf(stderr, "Failed to read initial SMART log: %s\n", strerror(-ret));
    return 1;
  }

  uint64_t initial_data_units_written = le128_to_u64(
    initial_smart_log.data_units_written);
  uint64_t initial_data_units_read = le128_to_u64(
    initial_smart_log.data_units_read);
  uint64_t initial_host_writes = le128_to_u64(initial_smart_log.host_writes);
  uint64_t initial_host_reads = le128_to_u64(initial_smart_log.host_reads);

  printf("Initial SMART log:\n");
  printf("  Data Units Written: %llu\n",
         (unsigned long long)initial_data_units_written);
  printf("  Data Units Read: %llu\n",
         (unsigned long long)initial_data_units_read);
  printf("  Host Write Commands: %llu\n",
         (unsigned long long)initial_host_writes);
  printf("  Host Read Commands: %llu\n",
         (unsigned long long)initial_host_reads);

  // Get NVMe BDF from device path using library function
  uint16_t nvme_bdf = 0;
  ret = xioDetectBdfFromDevice(nvme_device, &nvme_bdf);
  if (ret != 0) {
    fprintf(stderr, "Failed to detect NVMe BDF: %s\n", strerror(-ret));
    return 1;
  }
  printf("NVMe BDF: 0x%04x\n", nvme_bdf);

  // Test emulated detection
  bool is_emulated = false;
  ret = xioDetectEmulatedNvme(nvme_device, &is_emulated);
  if (ret == 0) {
    printf("NVMe device type: %s\n", is_emulated ? "EMULATED" : "PASSTHROUGH");
  } else {
    fprintf(stderr, "Warning: Failed to detect NVMe device type: %s\n",
            strerror(-ret));
  }

  // Create queues
  struct nvme_queue_info queue_info;
  uint16_t queue_id = 1;
  // Request larger queue size to support many operations without wrapping
  // NVMe spec supports up to 65535 entries (must be power of 2)
  // Start with 1024 - if controller supports larger, we can increase
  uint16_t queue_size = 1024;

  ret = nvme_ep::nvme_create_queue_via_ioctl(nvme_device, ROCM_XIO_DEVICE_PATH,
                                             queue_id, queue_size, nvme_bdf, 0,
                                             &queue_info);
  if (ret != 0) {
    fprintf(stderr, "Failed to create queues: %s\n", strerror(-ret));
    return 1;
  }
  
  // Calculate actual queue size in entries from queue_info
  // queue_info.sq_size is in bytes, divide by SQE size to get entries
  // This is the size we allocated, which should match what we requested
  uint16_t allocated_queue_size = static_cast<uint16_t>(
    queue_info.sq_size / 64); // NVME_EP_SQE_SIZE is 64 bytes
  printf("Queues created successfully (requested: %u entries, allocated: %u entries)\n",
         queue_size, allocated_queue_size);
  
  // IMPORTANT: Use the actual allocated queue size, not the requested size
  // The controller may silently reduce the queue size if it doesn't support
  // the requested size, and we must use the actual size for all operations
  if (allocated_queue_size != queue_size) {
    fprintf(stderr, "WARNING: Allocated queue size (%u) does not match requested size (%u)\n",
            allocated_queue_size, queue_size);
    fprintf(stderr, "  Using allocated size (%u) for all operations\n",
            allocated_queue_size);
  }
  
  // Use the actual allocated queue size for all operations
  queue_size = allocated_queue_size;

  // Map NVMe BAR0 for doorbell access using library function
  void* nvme_bar0_cpu = nullptr;
  void* nvme_bar0_gpu = nullptr;
  ret = nvme_ep_map_bar0(nvme_bdf, &nvme_bar0_cpu, &nvme_bar0_gpu);
  if (ret != 0) {
    fprintf(stderr, "Error: Failed to map NVMe BAR0: %s\n", strerror(-ret));
    fprintf(stderr, "BAR0 mapping is required for doorbell operations\n");
    return 1;
  }
  printf("NVMe BAR0 mapped for doorbell access\n");

  // Run tests - either single test mode or loop mode
  if (iterations == 0) {
    // Single test mode
    uint64_t base_lba = 0;
    uint16_t cq_head = 0;
    uint16_t last_sq_head = 0;
    uint16_t sq_tail = 0;
    printf("\nRunning write test...\n");
    ret = test_simple_write(nvme_device, nsid, lba_size, base_lba,
                            blocks_per_op, &queue_info, nvme_bar0_gpu, &cq_head,
                            &last_sq_head, &sq_tail, 1, queue_size);
    if (ret != 0) {
      fprintf(stderr, "Write test failed\n");
      return 1;
    }

    // Read SMART log after write
    struct nvme_smart_log after_write_smart_log;
    ret = nvme_ep_read_smart_log(nvme_device, &after_write_smart_log);
    if (ret != 0) {
      fprintf(stderr, "Failed to read SMART log after write: %s\n",
              strerror(-ret));
      return 1;
    }

    uint64_t after_write_data_units_written = le128_to_u64(
      after_write_smart_log.data_units_written);
    uint64_t after_write_host_writes = le128_to_u64(
      after_write_smart_log.host_writes);

    printf("SMART log after write:\n");
    printf("  Data Units Written delta: %llu\n",
           (unsigned long long)(after_write_data_units_written -
                                initial_data_units_written));
    printf("  Host Write Commands delta: %llu\n",
           (unsigned long long)(after_write_host_writes - initial_host_writes));

    // Run read test
    printf("\nRunning read test...\n");
    ret = test_simple_read(nvme_device, nsid, lba_size, base_lba, blocks_per_op,
                           &queue_info, nvme_bar0_gpu, &cq_head, &last_sq_head,
                           &sq_tail, 2, queue_size);
    if (ret != 0) {
      fprintf(stderr, "Read test failed\n");
      return 1;
    }

    // Read SMART log after read
    struct nvme_smart_log after_read_smart_log;
    ret = nvme_ep_read_smart_log(nvme_device, &after_read_smart_log);
    if (ret != 0) {
      fprintf(stderr, "Failed to read SMART log after read: %s\n",
              strerror(-ret));
      return 1;
    }

    uint64_t after_read_data_units_read = le128_to_u64(
      after_read_smart_log.data_units_read);
    uint64_t after_read_host_reads = le128_to_u64(
      after_read_smart_log.host_reads);

    printf("SMART log after read:\n");
    printf("  Data Units Read delta: %llu\n",
           (unsigned long long)(after_read_data_units_read -
                                initial_data_units_read));
    printf("  Host Read Commands delta: %llu\n",
           (unsigned long long)(after_read_host_reads - initial_host_reads));

    printf("\nAll tests passed!\n");
  } else {
    // Loop mode: perform 'iterations' number of writes and reads at random LBAs
    printf("\nRunning loop mode: %u operations, %u blocks per operation\n",
           iterations, blocks_per_op);
    printf("Namespace capacity: %llu LBAs\n",
           (unsigned long long)capacity_lbas);

    // Calculate max LBA that fits within namespace (accounting for
    // blocks_per_op)
    uint64_t max_lba = (capacity_lbas >= blocks_per_op)
                         ? (capacity_lbas - blocks_per_op)
                         : 0;
    if (max_lba == 0) {
      fprintf(stderr,
              "Error: blocks_per_op (%u) exceeds namespace capacity "
              "(%llu LBAs)\n",
              blocks_per_op, (unsigned long long)capacity_lbas);
      return 1;
    }

    // Track queue state across all operations
    uint16_t cq_head = 0;
    uint16_t last_sq_head = 0;
    uint16_t sq_tail = 0;
    uint16_t next_cid = 1;

    // Generate random LBAs for operations (same LBAs used for both writes and
    // reads)
    uint64_t* random_lbas = static_cast<uint64_t*>(
      malloc(iterations * sizeof(uint64_t)));
    if (random_lbas == nullptr) {
      fprintf(stderr, "Failed to allocate memory for random LBAs\n");
      return 1;
    }

    // Simple LFSR-based random number generator for LBA selection
    uint32_t lfsr = 0xACE1u; // Seed
    for (uint32_t i = 0; i < iterations; i++) {
      // Generate next LFSR value
      lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xB400u);
      // Map to LBA range
      random_lbas[i] = (static_cast<uint64_t>(lfsr) * max_lba) / 0xFFFFu;
    }

    printf("Phase 1: Writing %u operations at random LBAs...\n", iterations);
    for (uint32_t op = 0; op < iterations; op++) {
      uint64_t base_lba = random_lbas[op];
      ret = test_simple_write(nvme_device, nsid, lba_size, base_lba,
                              blocks_per_op, &queue_info, nvme_bar0_gpu,
                              &cq_head, &last_sq_head, &sq_tail, next_cid++,
                              queue_size);
      if (ret != 0) {
        fprintf(stderr, "Write failed at operation %u (LBA %llu)\n", op + 1,
                (unsigned long long)base_lba);
        free(random_lbas);
        return 1;
      }
      if ((op + 1) % 100 == 0 || op == iterations - 1) {
        printf("  Wrote %u/%u operations\n", op + 1, iterations);
      }
    }

    printf("Phase 2: Reading %u operations at same random LBAs...\n",
           iterations);
    for (uint32_t op = 0; op < iterations; op++) {
      uint64_t base_lba = random_lbas[op];
      ret = test_simple_read(nvme_device, nsid, lba_size, base_lba,
                             blocks_per_op, &queue_info, nvme_bar0_gpu,
                             &cq_head, &last_sq_head, &sq_tail, next_cid++,
                             queue_size);
      if (ret != 0) {
        fprintf(stderr, "Read failed at operation %u (LBA %llu)\n", op + 1,
                (unsigned long long)base_lba);
        free(random_lbas);
        return 1;
      }
      if ((op + 1) % 100 == 0 || op == iterations - 1) {
        printf("  Read %u/%u operations\n", op + 1, iterations);
      }
    }

    free(random_lbas);
    printf("Loop mode complete: %u writes, %u reads\n", iterations, iterations);

    // Read final SMART log
    struct nvme_smart_log final_smart_log;
    ret = nvme_ep_read_smart_log(nvme_device, &final_smart_log);
    if (ret != 0) {
      fprintf(stderr, "Failed to read final SMART log: %s\n", strerror(-ret));
      return 1;
    }

    uint64_t final_data_units_written = le128_to_u64(
      final_smart_log.data_units_written);
    uint64_t final_data_units_read = le128_to_u64(
      final_smart_log.data_units_read);
    uint64_t final_host_writes = le128_to_u64(final_smart_log.host_writes);
    uint64_t final_host_reads = le128_to_u64(final_smart_log.host_reads);

    printf("\n=== Final SMART log summary ===\n");
    printf("Total Data Units Written: %llu (delta: %llu)\n",
           (unsigned long long)final_data_units_written,
           (unsigned long long)(final_data_units_written -
                                initial_data_units_written));
    printf("Total Data Units Read: %llu (delta: %llu)\n",
           (unsigned long long)final_data_units_read,
           (unsigned long long)(final_data_units_read -
                                initial_data_units_read));
    printf("Total Host Write Commands: %llu (delta: %llu)\n",
           (unsigned long long)final_host_writes,
           (unsigned long long)(final_host_writes - initial_host_writes));
    printf("Total Host Read Commands: %llu (delta: %llu)\n",
           (unsigned long long)final_host_reads,
           (unsigned long long)(final_host_reads - initial_host_reads));

    printf("\nAll loop mode tests passed!\n");
  }

  return 0;
}
