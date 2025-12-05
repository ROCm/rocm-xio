/*
 * Simplified NVMe AXIIO Kernel Module Integration
 *
 * Uses kernel module ONLY for device info and doorbell addresses.
 * Queue memory is allocated by axiio-tester with hipHostMalloc
 * (GPU-accessible).
 */

#ifndef NVME_AXIIO_SIMPLE_H
#define NVME_AXIIO_SIMPLE_H

#include <cstring>
#include <iostream>

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

// Include the kernel module header
#include "../kernel-module/nvme_axiio.h"

namespace nvme_axiio_simple {

/*
 * Get NVMe device information from kernel module
 * (BAR0, doorbell stride, etc.)
 */
static inline int get_device_info(nvme_axiio_queue_info* info,
                                  uint16_t queue_id) {
  int fd = open("/dev/nvme-axiio", O_RDWR);
  if (fd < 0) {
    perror("Error: Failed to open /dev/nvme-axiio");
    std::cerr
      << "  Make sure the kernel module is loaded: sudo insmod nvme_axiio.ko"
      << std::endl;
    return -1;
  }

  // Set queue ID to query
  info->queue_id = queue_id;

  // Get device info (no queue creation, just info)
  int ret = ioctl(fd, NVME_AXIIO_GET_DEVICE_INFO, info);
  close(fd);

  if (ret < 0) {
    perror("Error: NVME_AXIIO_GET_DEVICE_INFO failed");
    return -1;
  }

  std::cout << "✓ Got NVMe device info from kernel module" << std::endl;
  std::cout << "  BAR0: 0x" << std::hex << info->bar0_phys << std::dec
            << " (size " << info->bar0_size << " bytes)" << std::endl;
  std::cout << "  Doorbell stride: " << info->doorbell_stride << std::endl;

  // Calculate doorbell addresses for this queue
  uint32_t stride_bytes = (4 << info->doorbell_stride);
  uint32_t doorbell_base = 0x1000;

  info->sq_doorbell_offset = doorbell_base + ((queue_id * 2) * stride_bytes);
  info->cq_doorbell_offset = doorbell_base +
                             ((queue_id * 2 + 1) * stride_bytes);

  info->sq_doorbell_phys = info->bar0_phys + info->sq_doorbell_offset;
  info->cq_doorbell_phys = info->bar0_phys + info->cq_doorbell_offset;

  std::cout << "  SQ Doorbell: 0x" << std::hex << info->sq_doorbell_phys
            << std::dec << " (offset 0x" << std::hex << info->sq_doorbell_offset
            << ")" << std::dec << std::endl;
  std::cout << "  CQ Doorbell: 0x" << std::hex << info->cq_doorbell_phys
            << std::dec << " (offset 0x" << std::hex << info->cq_doorbell_offset
            << ")" << std::dec << std::endl;

  return 0;
}

/*
 * Map doorbell registers via /dev/mem
 */
static inline volatile uint32_t* map_doorbell(uint64_t doorbell_phys,
                                              uint64_t bar0_phys,
                                              uint64_t bar0_size) {
  static int mem_fd = -1;
  static void* bar0_mapped = nullptr;

  // Open /dev/mem once
  if (mem_fd < 0) {
    mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
      perror("Error: Failed to open /dev/mem");
      return nullptr;
    }
  }

  // Map BAR0 once
  if (bar0_mapped == nullptr) {
    size_t page_size = sysconf(_SC_PAGE_SIZE);
    uint64_t page_base = bar0_phys & ~(page_size - 1);
    size_t map_size = ((bar0_size + page_size - 1) / page_size) * page_size;

    bar0_mapped = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                       mem_fd, page_base);
    if (bar0_mapped == MAP_FAILED) {
      perror("Error: Failed to mmap BAR0");
      close(mem_fd);
      mem_fd = -1;
      return nullptr;
    }

    std::cout << "✓ BAR0 mapped to userspace at " << bar0_mapped << std::endl;
  }

  // Calculate doorbell pointer
  uint64_t offset_in_bar = doorbell_phys - bar0_phys;
  volatile uint32_t* doorbell = (volatile uint32_t*)((char*)bar0_mapped +
                                                     offset_in_bar);

  return doorbell;
}

} // namespace nvme_axiio_simple

#endif // NVME_AXIIO_SIMPLE_H
