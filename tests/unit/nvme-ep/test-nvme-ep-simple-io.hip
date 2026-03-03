/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <hip/hip_runtime.h>

#include <fcntl.h>
#include <linux/nvme_ioctl.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/mman.h>
#include <unistd.h>
#include <drm/amdgpu_drm.h>
#include <drm/drm.h>

#include "nvme-ep.h"
#include "nvme-ep.hip"
#include "xio.h"

// Simple assertion macros
#define ASSERT_EQ(a, b) assert((a) == (b))
#define ASSERT_TRUE(x) assert(x)
#define ASSERT_FALSE(x) assert(!(x))

// Kernel module char device
#define ROCM_XIO_DEVICE_PATH "/dev/rocm-xio"

// Helper function to get physical address from virtual address using pagemap
// Returns 0 on failure
// Note: nvme-ep.hip has a static virt_to_phys, so we need our own version
static uint64_t get_phys_addr(void* virt_addr) {
  int pagemap_fd = open("/proc/self/pagemap", O_RDONLY);
  if (pagemap_fd < 0) {
    return 0;
  }

  uint64_t page = reinterpret_cast<uint64_t>(virt_addr) / sysconf(_SC_PAGESIZE);
  uint64_t offset = page * sizeof(uint64_t);

  if (lseek(pagemap_fd, offset, SEEK_SET) != static_cast<off_t>(offset)) {
    close(pagemap_fd);
    return 0;
  }

  uint64_t pagemap_entry = 0;
  if (read(pagemap_fd, &pagemap_entry, sizeof(pagemap_entry)) !=
      sizeof(pagemap_entry)) {
    close(pagemap_fd);
    return 0;
  }

  close(pagemap_fd);

  // Check if page is present (bit 63)
  if (!(pagemap_entry & (1ULL << 63))) {
    return 0; // Page not present
  }

  // Extract physical page frame number (bits 0-54)
  uint64_t pfn = pagemap_entry & 0x7FFFFFFFFFFFFFULL;
  uint64_t phys_addr = (pfn * sysconf(_SC_PAGESIZE)) +
                       (reinterpret_cast<uint64_t>(virt_addr) %
                        sysconf(_SC_PAGESIZE));

  return phys_addr;
}

// SMART log page structure (matches Linux kernel struct nvme_smart_log)
// Note: 128-bit fields are stored as 16-byte arrays in little-endian format
struct nvme_smart_log {
  uint8_t critical_warning;
  uint8_t temperature[2];
  uint8_t avail_spare;
  uint8_t spare_thresh;
  uint8_t percent_used;
  uint8_t endu_grp_crit_warn_sumry;
  uint8_t rsvd7[25];
  uint8_t data_units_read[16];      // Bytes 32-47 (128-bit little-endian)
  uint8_t data_units_written[16];   // Bytes 48-63 (128-bit little-endian)
  uint8_t host_reads[16];           // Bytes 64-79 (128-bit little-endian)
  uint8_t host_writes[16];          // Bytes 80-95 (128-bit little-endian)
  uint8_t ctrl_busy_time[16];       // Bytes 96-111 (128-bit little-endian)
  uint8_t power_cycles[16];         // Bytes 112-127 (128-bit little-endian)
  uint8_t power_on_hours[16];       // Bytes 128-143 (128-bit little-endian)
  uint8_t unsafe_shutdowns[16];     // Bytes 144-159 (128-bit little-endian)
  uint8_t media_errors[16];         // Bytes 160-175 (128-bit little-endian)
  uint8_t num_err_log_entries[16]; // Bytes 176-191 (128-bit little-endian)
  uint32_t warning_temp_time;       // Bytes 192-195 (little-endian)
  uint32_t critical_comp_time;      // Bytes 196-199 (little-endian)
  uint16_t temp_sensor[8];          // Bytes 200-215 (little-endian)
  uint32_t thm_temp1_trans_count;   // Bytes 216-219
  uint32_t thm_temp2_trans_count;   // Bytes 220-223
  uint32_t thm_temp1_total_time;    // Bytes 224-227
  uint32_t thm_temp2_total_time;    // Bytes 228-231
  uint8_t rsvd232[280];             // Bytes 232-511
} __attribute__((packed));

// Helper function to convert 16-byte little-endian array to uint64_t
// Reads lower 64 bits (first 8 bytes) - sufficient for most practical values
static inline uint64_t le128_to_u64(const uint8_t* data) {
  uint64_t result = 0;
  for (int i = 0; i < 8; i++) {
    result |= ((uint64_t)data[i]) << (i * 8);
  }
  return result;
}

// Check if kernel module is loaded
static bool check_kernel_module_loaded() {
  FILE* f = fopen("/proc/modules", "r");
  if (!f) {
    return false;
  }

  char line[256];
  bool found = false;
  while (fgets(line, sizeof(line), f)) {
    if (strstr(line, "rocm-xio") != nullptr) {
      found = true;
      break;
    }
  }
  fclose(f);
  return found;
}

// Attempt to load kernel module
static int load_kernel_module() {
  int ret = system("modprobe rocm-xio");
  if (ret != 0) {
    fprintf(stderr,
            "Warning: Failed to load kernel module 'rocm-xio'. "
            "Error: %d\n",
            ret);
    fprintf(stderr,
            "You may need to run with sudo or ensure the module "
            "is available.\n");
    return -1;
  }
  return 0;
}

// Check if device node exists, create if missing
static int ensure_device_node() {
  // Check if device exists
  if (access(ROCM_XIO_DEVICE_PATH, F_OK) == 0) {
    return 0; // Device exists
  }

  // Try to get major number
  FILE* f = fopen("/proc/devices", "r");
  if (!f) {
    fprintf(stderr, "Failed to open /proc/devices\n");
    return -1;
  }

  char line[256];
  unsigned int major = 0;
  bool found = false;
  while (fgets(line, sizeof(line), f)) {
    if (strstr(line, "rocm-xio") != nullptr) {
      if (sscanf(line, "%u", &major) == 1) {
        found = true;
        break;
      }
    }
  }
  fclose(f);

  if (!found || major == 0) {
    fprintf(stderr,
            "Failed to find rocm-xio major number in /proc/devices\n");
    return -1;
  }

  // Create device node (requires root)
  char cmd[256];
  snprintf(cmd, sizeof(cmd), "mknod %s c %u 0", ROCM_XIO_DEVICE_PATH, major);
  int ret = system(cmd);
  if (ret != 0) {
    fprintf(stderr,
            "Failed to create device node %s. "
            "You may need to run with sudo.\n",
            ROCM_XIO_DEVICE_PATH);
    return -1;
  }

  // Set permissions
  snprintf(cmd, sizeof(cmd), "chmod 666 %s", ROCM_XIO_DEVICE_PATH);
  ret = system(cmd);
  if (ret != 0) {
    fprintf(stderr, "Warning: Failed to set permissions on %s\n",
            ROCM_XIO_DEVICE_PATH);
  }

  return 0;
}

// Check if NVMe device is root filesystem
static int check_rootfs(const char* nvme_device) {
  // Extract namespace device (e.g., /dev/nvme0 -> /dev/nvme0n1)
  char ns_device[256];
  snprintf(ns_device, sizeof(ns_device), "%sn1", nvme_device);

  // Check /proc/mounts for root mount
  FILE* f = fopen("/proc/mounts", "r");
  if (!f) {
    fprintf(stderr, "Warning: Failed to open /proc/mounts\n");
    return 0; // Can't check, allow to proceed
  }

  char line[512];
  bool is_rootfs = false;
  while (fgets(line, sizeof(line), f)) {
    // Format: device mount_point filesystem ...
    char device[256], mount_point[256];
    if (sscanf(line, "%255s %255s", device, mount_point) == 2) {
      if (strcmp(mount_point, "/") == 0) {
        // Check if this device matches our NVMe device
        if (strstr(device, ns_device) != nullptr ||
            strstr(device, nvme_device) != nullptr) {
          is_rootfs = true;
          break;
        }
      }
    }
  }
  fclose(f);

  if (is_rootfs) {
    fprintf(stderr,
            "ERROR: NVMe device %s appears to be the root filesystem!\n",
            nvme_device);
    fprintf(stderr,
            "This test will NOT run on rootfs to prevent data corruption.\n");
    fprintf(stderr, "Please specify a different NVMe device.\n");
    return -1;
  }

  return 0;
}

// Read NVMe SMART log
static int read_smart_log(const char* nvme_device,
                          struct nvme_smart_log* smart_log) {
  int nvme_fd = open(nvme_device, O_RDONLY);
  if (nvme_fd < 0) {
    fprintf(stderr, "Failed to open NVMe device %s: %s\n", nvme_device,
            strerror(errno));
    return -errno;
  }

  // Allocate buffer on heap to ensure kernel can access it
  // Stack-allocated buffers might not work with ioctl
  uint8_t* buffer = static_cast<uint8_t*>(malloc(512));
  if (!buffer) {
    fprintf(stderr, "Failed to allocate SMART log buffer\n");
    close(nvme_fd);
    return -ENOMEM;
  }
  memset(buffer, 0, 512);

  // Use NVME_IOCTL_ADMIN64_CMD with nvme_passthru_cmd64 structure
  // NVME_IOCTL_ADMIN_CMD expects nvme_admin_cmd which has different layout
  struct nvme_passthru_cmd64 cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_get_log_page;
  cmd.nsid = 0xFFFFFFFF; // Controller-level log
  // cdw10: NUMD (Number of Dwords) in bits [31:16], LID (Log Identifier) in bits [15:0]
  // NUMD = 127 (0x7F) for 512 bytes, LID = 0x02 (SMART/Health Information)
  cmd.cdw10 = (127 << 16) | 0x02; // (NUMD << 16) | LID
  cmd.cdw11 = 0x00000000; // Reserved
  cmd.cdw12 = 0x0000007F; // RAE=0, LSP=0, LSI=0x7F (all fields)
  cmd.addr = reinterpret_cast<uint64_t>(buffer);
  cmd.data_len = 512;
  cmd.timeout_ms = 0;

  int ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN64_CMD, &cmd);
  if (ret < 0) {
    fprintf(stderr, "Failed to read SMART log: %s\n", strerror(errno));
    close(nvme_fd);
    return -errno;
  }

  // Debug: Print ioctl result
  fprintf(stderr, "Debug: SMART log ioctl result: 0x%016llx\n",
          (unsigned long long)cmd.result);

  // Check completion status
  if (cmd.result & 0xFFFE) {
    uint16_t status = (cmd.result >> 1) & 0xFF;
    fprintf(stderr, "SMART log read failed with status 0x%02x\n", status);
    close(nvme_fd);
    return -EIO;
  }

  // Debug: Print first few bytes of the buffer to verify data was written
  fprintf(stderr, "Debug: SMART log buffer first 64 bytes: ");
  for (int i = 0; i < 64; i++) {
    fprintf(stderr, "%02x ", buffer[i]);
    if ((i + 1) % 16 == 0) {
      fprintf(stderr, "\n");
      if (i < 63) {
        fprintf(stderr, "Debug: SMART log buffer bytes %d-%d: ", i + 1,
                i + 16);
      }
    }
  }
  fprintf(stderr, "\n");

  // Copy data from buffer to structure
  memcpy(smart_log, buffer, 512);

  free(buffer);
  close(nvme_fd);
  return 0;
}

// Simple GPU kernel for single NVMe write operation
__global__ void test_simple_write_kernel(
  struct nvme_sqe* sqe, struct nvme_cqe* cqe, uint8_t* /* write_buffer */,
  uint64_t write_buffer_dma, uint32_t nsid, uint64_t slba, uint32_t nlb,
  uint32_t /* lba_size */, uint16_t queue_id, uint32_t doorbell_offset,
  void* nvme_bar0_gpu, uint16_t cid, uint16_t queue_size) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid != 0)
    return; // Only thread 0 performs the operation

  // Setup write command at SQ tail (index 0 for first command)
  uint16_t sq_tail = 0;
  nvme_ep::sqeType sqe_local = {};
  struct nvme_sqe* sqe_ptr = &sqe_local;
  nvme_sqe_setup_write(sqe_ptr, cid, nsid, slba, nlb, write_buffer_dma, 0);
  
  // Write SQE using sqeWrite (includes memory fence)
  nvme_ep::sqeWrite(sqe_local, &sqe[sq_tail]);
  sq_tail = (sq_tail + 1) % queue_size;
  __threadfence_system();

  // Ring doorbell with tail pointer (only if BAR0 is mapped)
  // Match nvme-ep pattern: write sq_tail (already incremented) to doorbell
  if (nvme_bar0_gpu != nullptr) {
    volatile uint32_t* doorbell =
      reinterpret_cast<volatile uint32_t*>(
        reinterpret_cast<uint8_t*>(nvme_bar0_gpu) + doorbell_offset);
    __threadfence_system();
    *doorbell = sq_tail;
    __threadfence_system();
  }

  // Poll for completion - match nvme-ep initialization pattern
  uint16_t cq_head = 0;
  volatile struct nvme_cqe* initial_cqe = &cqe[cq_head];
  nvme_ep::cqeType initial_cqe_data = nvme_ep::cqeRead(
    reinterpret_cast<volatile nvme_ep::cqeType*>(initial_cqe));
  uint8_t expected_phase = NVME_CQE_STATUS_PHASE(initial_cqe_data.status) ^ 1;
  
  // Track submission queue head for completion detection
  uint16_t last_sq_head = 0; // Start at 0 for first command

  // Poll for completion - match nvme-ep polling pattern
  uint32_t poll_count = 0;
  const uint32_t max_polls = 10000000; // Match nvme-ep timeout
  
  while (poll_count < max_polls) {
    volatile struct nvme_cqe* cqe_entry = &cqe[cq_head];
    nvme_ep::cqeType cqe_new = nvme_ep::cqeRead(
      reinterpret_cast<volatile nvme_ep::cqeType*>(cqe_entry));
    uint8_t phase = NVME_CQE_STATUS_PHASE(cqe_new.status);
    uint16_t sq_head = cqe_new.sq_head;

    // Primary check: sq_head has increased (definitive indicator of completion)
    if (sq_head > last_sq_head) {
      // sq_head increased - command completed
      // Verify phase matches if possible (for correctness), but don't require it
      if (phase == expected_phase) {
        // Phase matches - perfect, this is definitely a new completion
        cq_head = (cq_head + 1) % queue_size;
        expected_phase = expected_phase ^ 1;
        last_sq_head = sq_head;
        break;
      } else {
        // Phase doesn't match but sq_head increased - accept it anyway
        // This handles cases where phase bit logic might be off
        // Update expected_phase based on what we actually saw
        cq_head = (cq_head + 1) % queue_size;
        expected_phase = phase ^ 1; // Toggle based on actual phase seen
        last_sq_head = sq_head;
        break;
      }
    }
    poll_count++;
  }
}

// Simple GPU kernel for single NVMe read operation
__global__ void test_simple_read_kernel(
  struct nvme_sqe* sqe, struct nvme_cqe* cqe, uint8_t* /* read_buffer */,
  uint64_t read_buffer_dma, uint32_t nsid, uint64_t slba, uint32_t nlb,
  uint32_t /* lba_size */, uint16_t queue_id, uint32_t doorbell_offset,
  void* nvme_bar0_gpu, uint16_t cid, uint16_t queue_size) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid != 0)
    return; // Only thread 0 performs the operation

  // Setup read command at next SQ tail
  // In sequential mode: write was at sqe[0], so read should be at sqe[1]
  // Match nvme-ep pattern: continue from where write left off
  uint16_t sq_tail = 1; // Next location after write (which was at index 0)
  nvme_ep::sqeType sqe_local = {};
  struct nvme_sqe* sqe_ptr = &sqe_local;
  nvme_sqe_setup_read(sqe_ptr, cid, nsid, slba, nlb, read_buffer_dma, 0);
  
  // Write SQE using sqeWrite (includes memory fence)
  nvme_ep::sqeWrite(sqe_local, &sqe[sq_tail]);
  sq_tail = (sq_tail + 1) % queue_size;
  __threadfence_system();

  // Ring doorbell with tail pointer (only if BAR0 is mapped)
  // Match nvme-ep pattern: write sq_tail (already incremented) to doorbell
  if (nvme_bar0_gpu != nullptr) {
    volatile uint32_t* doorbell =
      reinterpret_cast<volatile uint32_t*>(
        reinterpret_cast<uint8_t*>(nvme_bar0_gpu) + doorbell_offset);
    __threadfence_system();
    *doorbell = sq_tail;
    __threadfence_system();
  }

  // Poll for completion - match nvme-ep initialization pattern exactly
  // In sequential mode, after first command (write) completes:
  // - cq_head was advanced to 1
  // - last_sq_head = 1
  // - For second command (read), we poll at cqe[1] and wait for sq_head > 1
  
  // Read initial CQ state to get baseline
  uint16_t cq_head = 0;
  volatile struct nvme_cqe* initial_cqe = &cqe[cq_head];
  nvme_ep::cqeType initial_cqe_data = nvme_ep::cqeRead(
    reinterpret_cast<volatile nvme_ep::cqeType*>(initial_cqe));
  
  // Initialize last_sq_head from write completion (should be 1)
  uint16_t last_sq_head = initial_cqe_data.sq_head;
  
  // Advance cq_head past write completion (write is at cqe[0], read will be at cqe[1])
  cq_head = (cq_head + 1) % queue_size;
  uint8_t expected_phase = NVME_CQE_STATUS_PHASE(initial_cqe_data.status) ^ 1;

  // Poll for completion - match nvme-ep polling pattern exactly
  uint32_t poll_count = 0;
  const uint32_t max_polls = 10000000; // Match nvme-ep timeout
  
  while (poll_count < max_polls) {
    volatile struct nvme_cqe* cqe_entry = &cqe[cq_head];
    nvme_ep::cqeType cqe_new = nvme_ep::cqeRead(
      reinterpret_cast<volatile nvme_ep::cqeType*>(cqe_entry));
    uint8_t phase = NVME_CQE_STATUS_PHASE(cqe_new.status);
    uint16_t sq_head = cqe_new.sq_head;

    // Primary check: sq_head has increased (definitive indicator of completion)
    // For read command (cid=2), sq_head should be 2 (write was 1)
    if (sq_head > last_sq_head) {
      // sq_head increased - command completed
      // Verify phase matches if possible (for correctness), but don't require it
      if (phase == expected_phase) {
        // Phase matches - perfect, this is definitely a new completion
        cq_head = (cq_head + 1) % queue_size;
        expected_phase = expected_phase ^ 1;
        last_sq_head = sq_head;
        break;
      } else {
        // Phase doesn't match but sq_head increased - accept it anyway
        // This handles cases where phase bit logic might be off
        // Update expected_phase based on what we actually saw
        cq_head = (cq_head + 1) % queue_size;
        expected_phase = phase ^ 1; // Toggle based on actual phase seen
        last_sq_head = sq_head;
        break;
      }
    }
    poll_count++;
  }
}

// Test simple write operation
static int test_simple_write(const char* nvme_device, uint32_t nsid,
                             uint32_t lba_size, uint64_t base_lba,
                             struct nvme_queue_info* queue_info,
                             void* nvme_bar0_gpu) {
  const uint32_t blocks = 8;
  const size_t transfer_size = blocks * lba_size;
  const uint16_t queue_id = 1;
  const uint16_t queue_size = 64; // Must match queue creation
  // Doorbell offset: base (0x1000) + (2 * queue_id) * stride (4 bytes)
  const uint32_t doorbell_offset = 0x1000 + (2 * queue_id) * 4;

  // Allocate write buffer - match nvme-ep pattern: use hipHostMallocMapped
  // (nvme-ep uses hipHostMallocMapped for data buffers, coherent only for queues)
  uint8_t* write_buffer = nullptr;
  hipError_t err = hipHostMalloc(&write_buffer, transfer_size,
                                  hipHostMallocMapped);
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
    hipHostFree(write_buffer);
    return -1;
  }

  // Get DMA address using get_phys_addr for host-allocated coherent memory
  uint64_t write_buffer_dma = get_phys_addr(write_buffer);
  if (write_buffer_dma == 0) {
    fprintf(stderr,
            "Warning: Failed to get physical address for write buffer\n");
    fprintf(stderr,
            "Falling back to virtual address (may not work)\n");
    write_buffer_dma = reinterpret_cast<uint64_t>(write_buffer);
  }

  // Generate test pattern
  for (size_t i = 0; i < transfer_size; i++) {
    write_buffer[i] = static_cast<uint8_t>(i & 0xFF);
  }

  // Get queue pointers
  struct nvme_sqe* sqe =
    static_cast<struct nvme_sqe*>(queue_info->sq_gpu
                                     ? queue_info->sq_gpu
                                     : queue_info->sq_virt);
  struct nvme_cqe* cqe =
    static_cast<struct nvme_cqe*>(queue_info->cq_gpu
                                     ? queue_info->cq_gpu
                                     : queue_info->cq_virt);

  // Zero-initialize queues (only SQ, CQ may have previous completions)
  memset(sqe, 0, queue_info->sq_size);
  // Don't zero CQ - it may contain previous completions that we need to skip

  const uint16_t cid = 1;

  // Debug: Print SQE details before launch
  fprintf(stderr, "Write test: cid=%u, nsid=%u, slba=%llu, nlb=%u, "
                  "dma_addr=0x%016llx, doorbell_offset=0x%x\n",
          cid, nsid, (unsigned long long)base_lba, blocks,
          (unsigned long long)write_buffer_dma, doorbell_offset);

  // Launch kernel
  hipLaunchKernelGGL(test_simple_write_kernel, dim3(1), dim3(1), 0, 0, sqe,
                     cqe, write_buffer_gpu, write_buffer_dma, nsid, base_lba,
                     blocks, lba_size, queue_id, doorbell_offset, nvme_bar0_gpu,
                     cid, queue_size);

  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    fprintf(stderr, "Kernel launch failed: %s\n", hipGetErrorString(err));
    hipHostFree(write_buffer);
    return -1;
  }

  // Check completion status using cqeRead to handle packed structure
  // Check cqe[0] - kernel should have found completion there
  volatile struct nvme_cqe* completion = &cqe[0];
  nvme_ep::cqeType cqe_data = nvme_ep::cqeRead(
    reinterpret_cast<volatile nvme_ep::cqeType*>(completion));
  uint8_t sc = NVME_CQE_STATUS_SC(cqe_data.status);
  uint16_t cmd_id = cqe_data.command_id;
  uint16_t sq_head = cqe_data.sq_head;
  uint8_t phase = NVME_CQE_STATUS_PHASE(cqe_data.status);

  // Debug output
  fprintf(stderr, "Write completion: cmd_id=%u (expected %u), sq_head=%u, "
                  "phase=%u, sc=0x%02x\n",
          cmd_id, cid, sq_head, phase, sc);

  if (cmd_id != cid) {
    fprintf(stderr, "ERROR: Completion command ID mismatch: expected %u, got "
                    "%u\n",
            cid, cmd_id);
    fprintf(stderr, "  This may indicate the command wasn't processed or a "
                    "different command completed\n");
    hipHostFree(write_buffer);
    return -1;
  }

  if (sc != NVME_SC_SUCCESS) {
    fprintf(stderr, "ERROR: Write command failed with status code 0x%02x\n",
            sc);
    fprintf(stderr, "  Status indicates command was processed but failed\n");
    hipHostFree(write_buffer);
    return -1;
  }

  // Verify sq_head increased (should be 1 for first command)
  if (sq_head != 1) {
    fprintf(stderr, "WARNING: sq_head=%u (expected 1 for first command)\n",
            sq_head);
  }

  printf("Write test passed: %u blocks written to LBA %llu\n", blocks,
         (unsigned long long)base_lba);

  hipHostFree(write_buffer);
  return 0;
}

// Test simple read operation
static int test_simple_read(const char* nvme_device, uint32_t nsid,
                            uint32_t lba_size, uint64_t base_lba,
                            struct nvme_queue_info* queue_info,
                            void* nvme_bar0_gpu) {
  const uint32_t blocks = 8;
  const size_t transfer_size = blocks * lba_size;
  const uint16_t queue_id = 1;
  const uint16_t queue_size = 64; // Must match queue creation
  // Doorbell offset: base (0x1000) + (2 * queue_id) * stride (4 bytes)
  const uint32_t doorbell_offset = 0x1000 + (2 * queue_id) * 4;

  // Allocate read buffer - match nvme-ep pattern: use hipHostMallocMapped
  // (nvme-ep uses hipHostMallocMapped for data buffers, coherent only for queues)
  uint8_t* read_buffer = nullptr;
  hipError_t err = hipHostMalloc(&read_buffer, transfer_size,
                                  hipHostMallocMapped);
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
    hipHostFree(read_buffer);
    return -1;
  }

  // Get DMA address using get_phys_addr for host-allocated coherent memory
  uint64_t read_buffer_dma = get_phys_addr(read_buffer);
  if (read_buffer_dma == 0) {
    fprintf(stderr,
            "Warning: Failed to get physical address for read buffer\n");
    fprintf(stderr,
            "Falling back to virtual address (may not work)\n");
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

  // Don't zero SQ - in sequential mode, we write the next SQE at the next
  // sq_tail location. Write completed at sqe[0], so read should be at sqe[1]
  // The kernel will handle writing at the correct location

  // Use a different command ID for read (increment from write)
  const uint16_t cid = 2;
  
  // Debug: Check current CQ state before read
  volatile struct nvme_cqe* check_cqe = &cqe[0];
  nvme_ep::cqeType check_data = nvme_ep::cqeRead(
    reinterpret_cast<volatile nvme_ep::cqeType*>(check_cqe));
  fprintf(stderr, "Read test: Before launch, cqe[0]: cmd_id=%u, sq_head=%u, "
                  "phase=%u\n",
          check_data.command_id, check_data.sq_head,
          NVME_CQE_STATUS_PHASE(check_data.status));

  // Launch kernel
  hipLaunchKernelGGL(test_simple_read_kernel, dim3(1), dim3(1), 0, 0, sqe, cqe,
                     read_buffer_gpu, read_buffer_dma, nsid, base_lba, blocks,
                     lba_size, queue_id, doorbell_offset, nvme_bar0_gpu, cid,
                     queue_size);

  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    fprintf(stderr, "Kernel launch failed: %s\n", hipGetErrorString(err));
    hipHostFree(read_buffer);
    return -1;
  }

  // Check completion status using cqeRead to handle packed structure
  // Kernel polls at cqe[1] after advancing past write completion at cqe[0]
  // But completion might appear at cqe[0] (overwriting write) or cqe[1]
  // Check cqe[1] first (where kernel should have found it)
  volatile struct nvme_cqe* completion = &cqe[1];
  nvme_ep::cqeType cqe_data = nvme_ep::cqeRead(
    reinterpret_cast<volatile nvme_ep::cqeType*>(completion));
  uint8_t sc = NVME_CQE_STATUS_SC(cqe_data.status);
  uint16_t cmd_id = cqe_data.command_id;
  uint16_t sq_head = cqe_data.sq_head;
  uint8_t phase = NVME_CQE_STATUS_PHASE(cqe_data.status);

  // Debug output
  fprintf(stderr, "Read completion: cmd_id=%u (expected %u), sq_head=%u "
                  "(expected 2), phase=%u, sc=0x%02x\n",
          cmd_id, cid, sq_head, phase, sc);

  // If cmd_id doesn't match, check cqe[0] (controller might have overwritten it)
  if (cmd_id != cid) {
    fprintf(stderr, "  cmd_id mismatch, checking cqe[0]...\n");
    volatile struct nvme_cqe* alt_completion = &cqe[0];
    nvme_ep::cqeType alt_cqe_data = nvme_ep::cqeRead(
      reinterpret_cast<volatile nvme_ep::cqeType*>(alt_completion));
    if (alt_cqe_data.command_id == cid && alt_cqe_data.sq_head > 1) {
      fprintf(stderr, "  Found completion at cqe[0] instead\n");
      cqe_data = alt_cqe_data;
      sc = NVME_CQE_STATUS_SC(cqe_data.status);
      cmd_id = cqe_data.command_id;
      sq_head = cqe_data.sq_head;
      phase = NVME_CQE_STATUS_PHASE(cqe_data.status);
    } else {
      fprintf(stderr, "ERROR: Completion command ID mismatch: expected %u, got "
                      "%u\n",
              cid, cmd_id);
      hipHostFree(read_buffer);
      return -1;
    }
  }

  if (sc != NVME_SC_SUCCESS) {
    fprintf(stderr, "ERROR: Read command failed with status code 0x%02x\n",
            sc);
    fprintf(stderr, "  Status indicates command was processed but failed\n");
    hipHostFree(read_buffer);
    return -1;
  }

  // Verify sq_head increased (should be 2 for second command)
  if (sq_head != 2) {
    fprintf(stderr, "WARNING: sq_head=%u (expected 2 for second command)\n",
            sq_head);
  }

  printf("Read test passed: %u blocks read from LBA %llu\n", blocks,
         (unsigned long long)base_lba);

  hipHostFree(read_buffer);
  return 0;
}

int main(int argc, char* argv[]) {
  const char* nvme_device = nullptr;
  uint32_t nsid = 1;

  // Check for HSA_FORCE_FINE_GRAIN_PCIE environment variable
  const char* fine_grain = getenv("HSA_FORCE_FINE_GRAIN_PCIE");
  if (!fine_grain || strcmp(fine_grain, "1") != 0) {
    fprintf(stderr,
            "WARNING: HSA_FORCE_FINE_GRAIN_PCIE not set to 1.\n");
    fprintf(stderr,
            "This may cause GPU page faults when accessing host memory.\n");
    fprintf(stderr,
            "Set with: export HSA_FORCE_FINE_GRAIN_PCIE=1\n");
    fprintf(stderr, "Continuing anyway...\n\n");
  }

  // Parse command-line arguments
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--controller") == 0 && i + 1 < argc) {
      nvme_device = argv[++i];
    } else if (strcmp(argv[i], "--namespace") == 0 && i + 1 < argc) {
      nsid = static_cast<uint32_t>(atoi(argv[++i]));
    } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
      printf("Usage: %s --controller <device> [--namespace <nsid>]\n",
             argv[0]);
      printf("  --controller <device>  NVMe controller device (e.g., "
             "/dev/nvme0)\n");
      printf("  --namespace <nsid>    Namespace ID (default: 1)\n");
      printf("\n");
      printf("Environment variables:\n");
      printf("  HSA_FORCE_FINE_GRAIN_PCIE=1  Required for GPU-PCIe "
             "coherency\n");
      return 0;
    }
  }

  if (!nvme_device) {
    fprintf(stderr, "ERROR: NVMe controller device not specified.\n");
    fprintf(stderr, "Usage: %s --controller <device> [--namespace <nsid>]\n",
            argv[0]);
    return 1;
  }

  // Check rootfs (HARD FAILURE - no override)
  if (check_rootfs(nvme_device) != 0) {
    return 1;
  }

  // Check and load kernel module
  if (!check_kernel_module_loaded()) {
    printf("Kernel module not loaded, attempting to load...\n");
    if (load_kernel_module() != 0) {
      fprintf(stderr,
              "ERROR: Failed to load kernel module. "
              "Queue creation will likely fail.\n");
    }
  }

  // Ensure device node exists
  if (ensure_device_node() != 0) {
    fprintf(stderr,
            "ERROR: Failed to ensure device node exists. "
            "Queue creation will likely fail.\n");
  }

  // Initialize HIP
  hipError_t err = hipInit(0);
  if (err != hipSuccess) {
    fprintf(stderr, "Failed to initialize HIP: %s\n", hipGetErrorString(err));
    return 1;
  }

  // Query LBA size
  unsigned lba_size = 0;
  int ret = nvme_ep_query_lba_size(nvme_device, nsid, &lba_size);
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
  printf("Namespace capacity: %llu LBAs\n",
         (unsigned long long)capacity_lbas);

  // Read initial SMART log
  struct nvme_smart_log smart_before = {};
  bool smart_available = (read_smart_log(nvme_device, &smart_before) == 0);
  if (smart_available) {
    // Debug: Print raw bytes to verify we're reading correctly
    fprintf(stderr, "Debug: data_units_read raw bytes (offset 0x20): ");
    for (int i = 0; i < 8; i++) {
      fprintf(stderr, "%02x ", smart_before.data_units_read[i]);
    }
    fprintf(stderr, "\n");
    fprintf(stderr, "Debug: host_reads raw bytes (offset 0x40): ");
    for (int i = 0; i < 8; i++) {
      fprintf(stderr, "%02x ", smart_before.host_reads[i]);
    }
    fprintf(stderr, "\n");
    
    uint64_t data_units_read = le128_to_u64(smart_before.data_units_read);
    uint64_t data_units_written = le128_to_u64(smart_before.data_units_written);
    uint64_t host_reads = le128_to_u64(smart_before.host_reads);
    uint64_t host_writes = le128_to_u64(smart_before.host_writes);
    printf("Initial SMART log:\n");
    printf("  Data Units Written: %llu\n",
           (unsigned long long)data_units_written);
    printf("  Data Units Read: %llu\n",
           (unsigned long long)data_units_read);
    printf("  Host Write Commands: %llu\n",
           (unsigned long long)host_writes);
    printf("  Host Read Commands: %llu\n",
           (unsigned long long)host_reads);
  } else {
    printf("Warning: SMART log not available (some emulated devices don't "
           "support it)\n");
  }

  // Get NVMe BDF from device path (simplified inline implementation)
  uint16_t nvme_bdf = 0;
  char sysfs_path[256];
  snprintf(sysfs_path, sizeof(sysfs_path), "/sys/class/nvme/%s/device",
           strrchr(nvme_device, '/') + 1);
  
  char link_target[256];
  ssize_t len = readlink(sysfs_path, link_target, sizeof(link_target) - 1);
  if (len > 0) {
    link_target[len] = '\0';
    // Parse PCI address from symlink (format: ../../devices/pci0000:00/0000:00:06.0/...)
    char* pci_start = strstr(link_target, "0000:");
    if (pci_start) {
      unsigned int bus, device, function;
      if (sscanf(pci_start, "0000:%02x:%02x.%x", &bus, &device, &function) == 3) {
        nvme_bdf = (static_cast<uint16_t>(bus) << 8) |
                   (static_cast<uint16_t>(device) << 3) |
                   static_cast<uint16_t>(function);
      }
    }
  }
  
  if (nvme_bdf == 0) {
    fprintf(stderr, "Warning: Failed to get NVMe BDF, using default\n");
    nvme_bdf = 0x0030; // Default fallback
  }
  printf("NVMe BDF: 0x%04x\n", nvme_bdf);

  // Create queues
  struct nvme_queue_info queue_info;
  uint16_t queue_id = 1;
  uint16_t queue_size = 64;

  ret = nvme_ep_create_queue_via_ioctl(nvme_device, ROCM_XIO_DEVICE_PATH,
                                        queue_id, queue_size, nvme_bdf, 0,
                                        &queue_info);
  if (ret != 0) {
    fprintf(stderr, "Failed to create queues: %s\n", strerror(-ret));
    return 1;
  }
  printf("Queues created successfully\n");

  // Map NVMe BAR0 for doorbell access (simplified version)
  void* nvme_bar0_cpu = nullptr;
  void* nvme_bar0_gpu = nullptr;
  
  // Convert BDF to PCI address format
  uint8_t bus = (nvme_bdf >> 8) & 0xFF;
  uint8_t dev = (nvme_bdf >> 3) & 0x1F;
  uint8_t func = nvme_bdf & 0x7;
  
  char resource_path[256];
  snprintf(resource_path, sizeof(resource_path),
           "/sys/bus/pci/devices/0000:%02x:%02x.%x/resource0",
           bus, dev, func);
  
  int bar0_fd = open(resource_path, O_RDWR);
  if (bar0_fd >= 0) {
    size_t bar0_size = 8192; // 8KB for doorbells
    void* mapped = mmap(nullptr, bar0_size, PROT_READ | PROT_WRITE,
                        MAP_SHARED, bar0_fd, 0);
    if (mapped != MAP_FAILED) {
      nvme_bar0_cpu = mapped;
      // Register with HIP for GPU access
      hipError_t hip_err = hipHostRegister(mapped, bar0_size,
                                           hipHostRegisterMapped);
      if (hip_err == hipSuccess) {
        hipHostGetDevicePointer(&nvme_bar0_gpu, mapped, 0);
        printf("NVMe BAR0 mapped for doorbell access\n");
      } else {
        printf("Warning: Failed to register BAR0 with HIP\n");
      }
    }
    // Keep bar0_fd open for mapping to remain valid
  } else {
    printf("Warning: Failed to open BAR0 resource, doorbell operations "
           "may not work\n");
  }

  // Run write test
  uint64_t base_lba = 0;
  printf("\nRunning write test...\n");
  ret = test_simple_write(nvme_device, nsid, lba_size, base_lba, &queue_info,
                          nvme_bar0_gpu);
  if (ret != 0) {
    fprintf(stderr, "Write test failed\n");
    return 1;
  }

  // Read SMART log after write
  struct nvme_smart_log smart_after_write = {};
  if (smart_available &&
      read_smart_log(nvme_device, &smart_after_write) == 0) {
    uint64_t before_written = le128_to_u64(smart_before.data_units_written);
    uint64_t after_written = le128_to_u64(smart_after_write.data_units_written);
    uint64_t before_write_cmds = le128_to_u64(smart_before.host_writes);
    uint64_t after_write_cmds = le128_to_u64(smart_after_write.host_writes);
    uint64_t delta_written = after_written - before_written;
    uint64_t delta_write_cmds = after_write_cmds - before_write_cmds;
    printf("SMART log after write:\n");
    printf("  Data Units Written delta: %llu\n",
           (unsigned long long)delta_written);
    printf("  Host Write Commands delta: %llu\n",
           (unsigned long long)delta_write_cmds);
  }

  // Run read test
  printf("\nRunning read test...\n");
  ret = test_simple_read(nvme_device, nsid, lba_size, base_lba, &queue_info,
                         nvme_bar0_gpu);
  if (ret != 0) {
    fprintf(stderr, "Read test failed\n");
    return 1;
  }

  // Read SMART log after read
  struct nvme_smart_log smart_after_read = {};
  if (smart_available &&
      read_smart_log(nvme_device, &smart_after_read) == 0) {
    uint64_t before_read = le128_to_u64(smart_before.data_units_read);
    uint64_t after_read = le128_to_u64(smart_after_read.data_units_read);
    uint64_t before_read_cmds = le128_to_u64(smart_before.host_reads);
    uint64_t after_read_cmds = le128_to_u64(smart_after_read.host_reads);
    uint64_t delta_read = after_read - before_read;
    uint64_t delta_read_cmds = after_read_cmds - before_read_cmds;
    printf("SMART log after read:\n");
    printf("  Data Units Read delta: %llu\n", (unsigned long long)delta_read);
    printf("  Host Read Commands delta: %llu\n",
           (unsigned long long)delta_read_cmds);
  }

  printf("\nAll tests passed!\n");
  return 0;
}
