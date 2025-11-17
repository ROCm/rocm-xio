/*
 * NVMe AXIIO Kernel Module Integration
 *
 * Helper functions to use the nvme_axiio kernel module for queue and doorbell
 * management.
 */

#ifndef NVME_AXIIO_KERNEL_H
#define NVME_AXIIO_KERNEL_H

#include <cstring>
#include <iostream>

#include <fcntl.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

// Include the kernel module header
#include "../kernel-module/nvme_axiio.h"

namespace nvme_axiio {

/*
 * Kernel module context - manages queues and doorbells via kernel module
 */
struct KernelModuleContext {
  int axiio_fd; // /dev/nvme-axiio file descriptor
  int mem_fd;   // /dev/mem file descriptor for doorbell mapping

  nvme_axiio_queue_info qinfo; // Queue info from kernel module

  void* bar0_mapped;              // mmap'd BAR0 region
  volatile uint32_t* sq_doorbell; // GPU-accessible doorbell (HSA-locked)
  volatile uint32_t* cq_doorbell;
  volatile uint32_t* cpu_sq_doorbell; // CPU-accessible doorbell (original mmap)
  void* doorbell_mapping;             // Base doorbell mapping (for cleanup)

  KernelModuleContext()
    : axiio_fd(-1), mem_fd(-1), bar0_mapped(nullptr), sq_doorbell(nullptr),
      cq_doorbell(nullptr), cpu_sq_doorbell(nullptr),
      doorbell_mapping(nullptr) {
    memset(&qinfo, 0, sizeof(qinfo));
  }

  ~KernelModuleContext() {
    cleanup();
  }

  void cleanup() {
    // Cleanup HSA-locked doorbell if in exclusive mode
    if (mem_fd == -2 && doorbell_mapping) {
      // Unlock HSA memory
      hsa_amd_memory_unlock(doorbell_mapping);
      // Unmap doorbell
      munmap(doorbell_mapping, getpagesize());
      doorbell_mapping = nullptr;
      sq_doorbell = nullptr;
      cpu_sq_doorbell = nullptr;
    }

    if (bar0_mapped && bar0_mapped != MAP_FAILED) {
      munmap(bar0_mapped, qinfo.bar0_size);
      bar0_mapped = nullptr;
    }
    if (mem_fd >= 0) {
      close(mem_fd);
      mem_fd = -1;
    }
    if (axiio_fd >= 0) {
      close(axiio_fd);
      axiio_fd = -1;
    }
  }
};

/*
 * Initialize kernel module and create queue
 */
static inline int axiio_kernel_init(KernelModuleContext* ctx,
                                    uint16_t queue_id = 63,
                                    uint16_t queue_size = 1024,
                                    uint32_t nsid = 1) {
  std::cout << "\n=== Initializing NVMe AXIIO via Kernel Module ==="
            << std::endl;

  // Open kernel module device
  ctx->axiio_fd = open("/dev/nvme-axiio", O_RDWR);
  if (ctx->axiio_fd < 0) {
    std::cerr << "Error: Failed to open /dev/nvme-axiio" << std::endl;
    std::cerr
      << "  Make sure the kernel module is loaded: sudo insmod nvme_axiio.ko"
      << std::endl;
    return -1;
  }
  std::cout << "✓ Opened /dev/nvme-axiio" << std::endl;

  // Setup queue parameters
  ctx->qinfo.queue_id = queue_id;
  ctx->qinfo.queue_size = queue_size;
  ctx->qinfo.nsid = nsid;

  std::cout << "\nRequesting queue creation:" << std::endl;
  std::cout << "  Queue ID: " << queue_id << std::endl;
  std::cout << "  Queue Size: " << queue_size << " entries" << std::endl;
  std::cout << "  Namespace ID: " << nsid << std::endl;

  // Create queue via ioctl
  int ret = ioctl(ctx->axiio_fd, NVME_AXIIO_CREATE_QUEUE, &ctx->qinfo);
  if (ret < 0) {
    perror("  Error: NVME_AXIIO_CREATE_QUEUE ioctl failed");
    close(ctx->axiio_fd);
    ctx->axiio_fd = -1;
    return -1;
  }

  std::cout << "✓ Queue created successfully!" << std::endl;
  std::cout << "\nQueue Information:" << std::endl;
  std::cout << "  SQ DMA Address: 0x" << std::hex << ctx->qinfo.sq_dma_addr
            << std::dec << std::endl;
  std::cout << "  CQ DMA Address: 0x" << std::hex << ctx->qinfo.cq_dma_addr
            << std::dec << std::endl;
  std::cout << "  BAR0 Physical: 0x" << std::hex << ctx->qinfo.bar0_phys
            << std::dec << " (size " << ctx->qinfo.bar0_size << " bytes)"
            << std::endl;
  std::cout << "  SQ Doorbell: 0x" << std::hex << ctx->qinfo.sq_doorbell_phys
            << std::dec << " (offset 0x" << std::hex
            << ctx->qinfo.sq_doorbell_offset << ")" << std::dec << std::endl;
  std::cout << "  CQ Doorbell: 0x" << std::hex << ctx->qinfo.cq_doorbell_phys
            << std::dec << " (offset 0x" << std::hex
            << ctx->qinfo.cq_doorbell_offset << ")" << std::dec << std::endl;

  return 0;
}

/*
 * Map doorbell registers via /dev/mem
 */
static inline int axiio_kernel_map_doorbells(KernelModuleContext* ctx) {
  std::cout << "\n=== Mapping Doorbell Registers ===" << std::endl;

  // Open /dev/mem for physical memory access
  ctx->mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
  if (ctx->mem_fd < 0) {
    perror("Error: Failed to open /dev/mem");
    std::cerr << "  This requires root privileges" << std::endl;
    return -1;
  }
  std::cout << "✓ Opened /dev/mem" << std::endl;

  // Map BAR0 region containing doorbells
  // Align to page boundary
  size_t page_size = sysconf(_SC_PAGE_SIZE);
  uint64_t page_base = ctx->qinfo.bar0_phys & ~(page_size - 1);
  size_t map_size = ((ctx->qinfo.bar0_size + page_size - 1) / page_size) *
                    page_size;

  std::cout << "  Mapping BAR0 region:" << std::endl;
  std::cout << "    Physical address: 0x" << std::hex << ctx->qinfo.bar0_phys
            << std::dec << std::endl;
  std::cout << "    Page-aligned base: 0x" << std::hex << page_base << std::dec
            << std::endl;
  std::cout << "    Map size: " << map_size << " bytes" << std::endl;

  ctx->bar0_mapped = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                          ctx->mem_fd, page_base);
  if (ctx->bar0_mapped == MAP_FAILED) {
    perror("  Error: Failed to mmap BAR0");
    close(ctx->mem_fd);
    ctx->mem_fd = -1;
    return -1;
  }
  std::cout << "✓ BAR0 mapped to userspace at " << ctx->bar0_mapped
            << std::endl;

  // Calculate doorbell pointers
  uint64_t offset_in_page = ctx->qinfo.bar0_phys - page_base;
  char* bar0_base = (char*)ctx->bar0_mapped + offset_in_page;

  ctx->sq_doorbell = (volatile uint32_t*)(bar0_base +
                                          ctx->qinfo.sq_doorbell_offset);
  ctx->cq_doorbell = (volatile uint32_t*)(bar0_base +
                                          ctx->qinfo.cq_doorbell_offset);

  std::cout << "✓ Doorbell pointers configured:" << std::endl;
  std::cout << "    SQ Doorbell: " << (void*)ctx->sq_doorbell << std::endl;
  std::cout << "    CQ Doorbell: " << (void*)ctx->cq_doorbell << std::endl;

  // Verify we can read doorbells
  uint32_t sq_val = *ctx->sq_doorbell;
  uint32_t cq_val = *ctx->cq_doorbell;
  std::cout << "  Initial doorbell values: SQ=" << sq_val << ", CQ=" << cq_val
            << std::endl;

  return 0;
}

/*
 * Get queue memory pointers (mmap from kernel module)
 */
static inline int axiio_kernel_map_queues(KernelModuleContext* ctx,
                                          void** sq_ptr, void** cq_ptr) {
  std::cout << "\n=== Mapping Queue Memory ===" << std::endl;

  size_t sq_size = ctx->qinfo.queue_size * 64; // SQE is 64 bytes
  size_t cq_size = ctx->qinfo.queue_size * 16; // CQE is 16 bytes

  // Map SQ (offset 0 in mmap)
  *sq_ptr = mmap(NULL, sq_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                 ctx->axiio_fd, 0);
  if (*sq_ptr == MAP_FAILED) {
    perror("Error: Failed to mmap SQ");
    return -1;
  }
  std::cout << "✓ SQ mapped at " << *sq_ptr << " (" << sq_size << " bytes)"
            << std::endl;

  // Map CQ (offset 1 page = page_size bytes)
  // mmap offset must be page-aligned, so use sysconf(_SC_PAGE_SIZE)
  size_t page_size = sysconf(_SC_PAGE_SIZE);
  std::cout << "  Attempting to mmap CQ with offset " << page_size
            << " bytes..." << std::endl;
  *cq_ptr = mmap(NULL, cq_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                 ctx->axiio_fd, page_size);
  if (*cq_ptr == MAP_FAILED) {
    std::cerr << "Error: Failed to mmap CQ (errno=" << errno << ")"
              << std::endl;
    perror("  mmap error");
    munmap(*sq_ptr, sq_size);
    *sq_ptr = nullptr;
    return -1;
  }
  std::cout << "✓ CQ mapped at " << *cq_ptr << " (" << cq_size << " bytes)"
            << std::endl;

  return 0;
}

/*
 * Allocate DMA-coherent buffer through kernel module
 * Returns proper IOMMU-mapped physical address for passthrough hardware
 */
static inline int axiio_alloc_dma_buffer(int axiio_fd, size_t size,
                                         uint64_t* dma_addr_out,
                                         void** cpu_ptr_out = nullptr) {
  if (axiio_fd < 0) {
    std::cerr << "Error: Invalid axiio_fd" << std::endl;
    return -1;
  }

  nvme_axiio_dma_buffer dma_buf;
  memset(&dma_buf, 0, sizeof(dma_buf));
  dma_buf.size = size;

  if (ioctl(axiio_fd, NVME_AXIIO_ALLOC_DMA, &dma_buf) < 0) {
    perror("NVME_AXIIO_ALLOC_DMA failed");
    return -1;
  }

  std::cout << "✓ DMA buffer allocated via kernel module" << std::endl;
  std::cout << "  Size: " << size << " bytes" << std::endl;
  std::cout << "  DMA address (for NVMe): 0x" << std::hex << dma_buf.dma_addr
            << std::dec << std::endl;
  std::cout << "  Kernel virtual: 0x" << std::hex << dma_buf.virt_addr
            << std::dec << std::endl;

  *dma_addr_out = dma_buf.dma_addr;
  if (cpu_ptr_out) {
    // Note: virt_addr is kernel virtual, not userspace accessible
    // For now, we don't need CPU access to the data buffer
    *cpu_ptr_out = nullptr;
  }

  return 0;
}

} // namespace nvme_axiio

#endif // NVME_AXIIO_KERNEL_H
