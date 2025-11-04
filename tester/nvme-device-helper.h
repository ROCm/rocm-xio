/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef NVME_DEVICE_HELPER_H
#define NVME_DEVICE_HELPER_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fcntl.h>
#include <linux/nvme_ioctl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// NVMe Controller Registers (from NVMe spec)
#define NVME_REG_CAP 0x00  // Controller Capabilities
#define NVME_REG_VS 0x08   // Version
#define NVME_REG_CC 0x14   // Controller Configuration
#define NVME_REG_CSTS 0x1C // Controller Status
#define NVME_REG_AQA 0x24  // Admin Queue Attributes
#define NVME_REG_ASQ 0x28  // Admin Submission Queue Base Address
#define NVME_REG_ACQ 0x30  // Admin Completion Queue Base Address

// Doorbell stride from CAP register (bits 35:32)
#define NVME_CAP_DSTRD(cap) (((cap) >> 32) & 0xF)

// Controller capabilities structure
typedef struct {
  uint64_t bar0_addr; // Physical address of BAR0
  uint64_t bar0_size; // Size of BAR0 region
  void* bar0_mapped;  // Mapped BAR0 address
  uint32_t dstrd;     // Doorbell stride (in 4-byte units)
  uint64_t cap;       // Controller capabilities register
  int mem_fd;         // /dev/mem file descriptor
} nvme_controller_t;

// Get NVMe controller BAR0 address from sysfs
static inline int nvme_get_bar0_address(const char* device_path,
                                        uint64_t* bar0_addr,
                                        uint64_t* bar0_size) {
  char sysfs_path[256];
  FILE* fp;

  // Extract device name (e.g., "nvme0" from "/dev/nvme0")
  const char* dev_name = strrchr(device_path, '/');
  if (dev_name) {
    dev_name++; // Skip the '/'
  } else {
    dev_name = device_path;
  }

  // Find the PCI device for this NVMe controller
  snprintf(sysfs_path, sizeof(sysfs_path), "/sys/class/nvme/%s/device/resource",
           dev_name);

  fp = fopen(sysfs_path, "r");
  if (!fp) {
    fprintf(stderr, "Error: Cannot open %s\n", sysfs_path);
    fprintf(stderr,
            "Hint: Ensure you have permissions and the device exists\n");
    return -1;
  }

  // Read the first resource (BAR0)
  uint64_t start, end, flags;
  if (fscanf(fp, "0x%lx 0x%lx 0x%lx", &start, &end, &flags) != 3) {
    fprintf(stderr, "Error: Failed to parse resource file\n");
    fclose(fp);
    return -1;
  }
  fclose(fp);

  *bar0_addr = start;
  *bar0_size = end - start + 1;

  printf("NVMe Controller BAR0:\n");
  printf("  Address: 0x%lx\n", *bar0_addr);
  printf("  Size: 0x%lx (%lu KB)\n", *bar0_size, *bar0_size / 1024);

  return 0;
}

// Lightweight: Get doorbell addresses WITHOUT mapping BAR0 (avoids /dev/mem HIP
// conflict) Assumes standard NVMe doorbell stride (0 = 4 bytes)
static inline int nvme_get_doorbell_addresses_lightweight(
  const char* device_path, uint16_t qid, uint64_t* sq_doorbell,
  uint64_t* cq_doorbell) {
  uint64_t bar0_addr, bar0_size;

  // Get BAR0 address from sysfs (no mapping!)
  if (nvme_get_bar0_address(device_path, &bar0_addr, &bar0_size) < 0) {
    return -1;
  }

  // NVMe spec: Doorbells start at offset 0x1000
  // Standard stride is 0 (meaning 4 bytes between doorbell registers)
  // Most NVMe controllers use stride=0
  uint64_t doorbell_base = 0x1000;
  uint32_t stride = 4; // 4 bytes (stride=0)

  // SQ doorbell: base + (2 * qid) * stride
  // CQ doorbell: base + (2 * qid + 1) * stride
  uint64_t sq_offset = doorbell_base + (2 * qid) * stride;
  uint64_t cq_offset = doorbell_base + (2 * qid + 1) * stride;

  *sq_doorbell = bar0_addr + sq_offset;
  *cq_doorbell = bar0_addr + cq_offset;

  printf("Doorbell Addresses (lightweight calc, no BAR mapping):\n");
  printf("  SQ Doorbell (QID %u): 0x%lx\n", qid, *sq_doorbell);
  printf("  CQ Doorbell (QID %u): 0x%lx\n", qid, *cq_doorbell);
  printf(
    "  Assumed stride: 0 (4 bytes) - standard for most NVMe controllers\n");

  return 0;
}

// Map ONLY a doorbell register (minimal mapping to reduce HIP conflict risk)
static inline volatile uint32_t* nvme_map_single_doorbell(
  uint64_t doorbell_phys_addr, int* out_fd) {
  int fd = open("/dev/mem", O_RDWR | O_SYNC);
  if (fd < 0) {
    perror("Error opening /dev/mem for doorbell");
    return nullptr;
  }

  // Map just one page containing the doorbell
  size_t page_size = sysconf(_SC_PAGE_SIZE);
  uint64_t page_base = doorbell_phys_addr & ~(page_size - 1);
  uint64_t offset_in_page = doorbell_phys_addr - page_base;

  void* mapped = mmap(NULL, page_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                      page_base);
  if (mapped == MAP_FAILED) {
    perror("Error mmapping doorbell");
    close(fd);
    return nullptr;
  }

  *out_fd = fd;
  return (volatile uint32_t*)((char*)mapped + offset_in_page);
}

// Map NVMe controller BAR0 into process memory
static inline int nvme_map_bar0(nvme_controller_t* ctrl) {
  // Open /dev/mem (requires root)
  ctrl->mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
  if (ctrl->mem_fd < 0) {
    perror("Error: Cannot open /dev/mem (need root privileges)");
    return -1;
  }

  // Map BAR0 region
  ctrl->bar0_mapped = mmap(NULL, ctrl->bar0_size, PROT_READ | PROT_WRITE,
                           MAP_SHARED, ctrl->mem_fd, ctrl->bar0_addr);

  if (ctrl->bar0_mapped == MAP_FAILED) {
    perror("Error: Failed to mmap BAR0");
    close(ctrl->mem_fd);
    return -1;
  }

  printf("Mapped BAR0 at virtual address: %p\n", ctrl->bar0_mapped);

  // Read controller capabilities
  volatile uint64_t* cap_reg = (volatile uint64_t*)((char*)ctrl->bar0_mapped +
                                                    NVME_REG_CAP);
  ctrl->cap = *cap_reg;

  // Extract doorbell stride
  ctrl->dstrd = NVME_CAP_DSTRD(ctrl->cap);

  printf("Controller Capabilities:\n");
  printf("  CAP: 0x%lx\n", ctrl->cap);
  printf("  Doorbell Stride: %u (4-byte units) = %u bytes\n", ctrl->dstrd,
         ctrl->dstrd * 4);

  return 0;
}

// Calculate doorbell physical address for a queue
static inline uint64_t nvme_get_doorbell_addr(nvme_controller_t* ctrl,
                                              uint16_t qid, bool is_sq) {
  // Doorbells start at offset 0x1000
  // SQ doorbell: 0x1000 + (2 * qid) * (4 << dstrd)
  // CQ doorbell: 0x1000 + (2 * qid + 1) * (4 << dstrd)
  uint64_t doorbell_offset = 0x1000;
  uint32_t stride = 4 << ctrl->dstrd;
  uint32_t index = (2 * qid) + (is_sq ? 0 : 1);

  uint64_t db_offset = doorbell_offset + (index * stride);
  uint64_t db_addr = ctrl->bar0_addr + db_offset;

  printf("%s Doorbell for QID %u:\n", is_sq ? "SQ" : "CQ", qid);
  printf("  Offset in BAR0: 0x%lx\n", db_offset);
  printf("  Physical Address: 0x%lx\n", db_addr);

  return db_addr;
}

// Get virtual (CPU-accessible) doorbell pointer for a queue
static inline volatile uint32_t* nvme_get_doorbell_ptr(nvme_controller_t* ctrl,
                                                       uint16_t qid,
                                                       bool is_sq) {
  // Calculate offset within BAR0
  uint64_t doorbell_offset = 0x1000;
  uint32_t stride = 4 << ctrl->dstrd;
  uint32_t index = (2 * qid) + (is_sq ? 0 : 1);
  uint64_t db_offset = doorbell_offset + (index * stride);

  // Return virtual address (BAR0 mapped + offset)
  return (volatile uint32_t*)((char*)ctrl->bar0_mapped + db_offset);
}

// Get physical address of a virtual address using /proc/self/pagemap
static inline uint64_t virt_to_phys(void* virt_addr) {
  int fd;
  uint64_t page_frame_number;
  uint64_t offset;
  off_t seek_offset;
  ssize_t bytes_read;

  fd = open("/proc/self/pagemap", O_RDONLY);
  if (fd < 0) {
    perror("Error: Cannot open /proc/self/pagemap");
    return 0;
  }

  // Get page size
  long page_size = sysconf(_SC_PAGE_SIZE);
  if (page_size < 0) {
    perror("Error: sysconf(_SC_PAGE_SIZE) failed");
    close(fd);
    return 0;
  }

  // Calculate offset in pagemap file
  // Each entry is 8 bytes, indexed by virtual page number
  uintptr_t virt = (uintptr_t)virt_addr;
  offset = (virt / page_size) * sizeof(uint64_t);

  // Seek to the entry
  seek_offset = lseek(fd, offset, SEEK_SET);
  if (seek_offset == (off_t)-1) {
    perror("Error: lseek failed");
    close(fd);
    return 0;
  }

  // Read the page frame number
  bytes_read = read(fd, &page_frame_number, sizeof(uint64_t));
  close(fd);

  if (bytes_read != sizeof(uint64_t)) {
    fprintf(stderr, "Error: Failed to read pagemap entry\n");
    return 0;
  }

  // Check if page is present (bit 63)
  if (!(page_frame_number & (1ULL << 63))) {
    fprintf(stderr, "Error: Page not present in physical memory\n");
    return 0;
  }

  // Extract physical frame number (bits 0-54)
  uint64_t pfn = page_frame_number & ((1ULL << 55) - 1);

  // Calculate physical address
  uint64_t phys_addr = (pfn * page_size) + (virt % page_size);

  return phys_addr;
}

// Unmap and cleanup NVMe controller resources
static inline void nvme_unmap_controller(nvme_controller_t* ctrl) {
  if (ctrl->bar0_mapped && ctrl->bar0_mapped != MAP_FAILED) {
    munmap(ctrl->bar0_mapped, ctrl->bar0_size);
  }
  if (ctrl->mem_fd >= 0) {
    close(ctrl->mem_fd);
  }
}

// Initialize NVMe controller access
static inline int nvme_init_controller(const char* device_path,
                                       nvme_controller_t* ctrl) {
  memset(ctrl, 0, sizeof(*ctrl));
  ctrl->mem_fd = -1;

  printf("Initializing NVMe controller: %s\n", device_path);

  // Get BAR0 address
  if (nvme_get_bar0_address(device_path, &ctrl->bar0_addr, &ctrl->bar0_size) <
      0) {
    return -1;
  }

  // Map BAR0
  if (nvme_map_bar0(ctrl) < 0) {
    return -1;
  }

  return 0;
}

#endif // NVME_DEVICE_HELPER_H
