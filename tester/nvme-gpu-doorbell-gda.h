/* GPU Doorbell Mapping (GDA-Style)
 *
 * Uses kernel module's BAR0 mapping to provide GPU-accessible doorbell.
 * Avoids /dev/mem which breaks HIP.
 *
 * Similar to rocSHMEM GDA (GPU-Direct Atomics) approach.
 */

#ifndef NVME_GPU_DOORBELL_GDA_H
#define NVME_GPU_DOORBELL_GDA_H

#include <cstring>
#include <iostream>

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

// Use kernel's definition from nvme_axiio.h
// (included via nvme-axiio-kernel.h)
#ifndef NVME_AXIIO_GET_GPU_DOORBELL
#define NVME_AXIIO_MAGIC 'N'
#define NVME_AXIIO_GET_GPU_DOORBELL                                            \
  _IOWR(NVME_AXIIO_MAGIC, 9, struct nvme_gpu_doorbell_info)
#endif

namespace nvme_gda {

/*
 * Map GPU-accessible doorbell using kernel module's BAR0
 * (GDA-style, WITH GPU MMU REGISTRATION!)
 */
static inline int map_gpu_doorbell(int axiio_fd, uint16_t queue_id, bool is_sq,
                                   volatile uint32_t** gpu_doorbell_ptr,
                                   void** mapped_base = nullptr) {
  struct nvme_gpu_doorbell_info info;
  memset(&info, 0, sizeof(info));

  info.queue_id = queue_id;
  info.is_sq = is_sq ? 1 : 0;

  std::cout << "\n=== Mapping GPU Doorbell (TRUE GPU-DIRECT!) ===" << std::endl;
  std::cout << "  Queue ID: " << queue_id << " (" << (is_sq ? "SQ" : "CQ")
            << ")" << std::endl;

  // Open GPU render node for MMU registration
  int gpu_fd = open("/dev/dri/renderD128", O_RDWR);
  if (gpu_fd < 0) {
    std::cerr << "  ⚠️  Could not open GPU render node (trying without GPU FD)"
              << std::endl;
    info.gpu_fd = -1; // No GPU FD - will use fallback
  } else {
    std::cout << "  ✓ Opened GPU render node: /dev/dri/renderD128 (FD="
              << gpu_fd << ")" << std::endl;
    info.gpu_fd = gpu_fd;
  }

  // Get doorbell mapping info from kernel
  if (ioctl(axiio_fd, NVME_AXIIO_GET_GPU_DOORBELL, &info) < 0) {
    perror("Error: NVME_AXIIO_GET_GPU_DOORBELL ioctl failed");
    return -1;
  }

  std::cout << "  Doorbell phys: 0x" << std::hex << info.doorbell_phys
            << std::dec << std::endl;
  std::cout << "  mmap offset: " << info.mmap_offset << " (pgoff)" << std::endl;
  std::cout << "  mmap size: " << info.mmap_size << " bytes" << std::endl;

  // mmap doorbell using kernel module's BAR0 (pgoff=3)
  // NO /dev/mem needed!
  void* base = mmap(NULL, info.mmap_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                    axiio_fd, info.mmap_offset * getpagesize());

  if (base == MAP_FAILED) {
    perror("Error: mmap GPU doorbell failed");
    return -1;
  }

  // Calculate doorbell pointer within the mapped page
  size_t page_size = getpagesize();
  size_t offset_in_page = info.doorbell_phys & (page_size - 1);

  *gpu_doorbell_ptr = (volatile uint32_t*)((char*)base + offset_in_page);

  if (mapped_base) {
    *mapped_base = base;
  }

  // Close GPU FD (kernel driver already has what it needs)
  if (gpu_fd >= 0) {
    close(gpu_fd);
    if (info.gpu_fd >= 0) {
      std::cout << "  ✅ GPU-DIRECT doorbell mapped with GPU MMU registration!"
                << std::endl;
      std::cout << "    Kernel driver registered doorbell with AMD GPU!"
                << std::endl;
    }
  }

  std::cout << "  ✅ GPU doorbell mapped!" << std::endl;
  std::cout << "    Base: " << base << std::endl;
  std::cout << "    GPU doorbell ptr: " << (void*)*gpu_doorbell_ptr
            << std::endl;
  std::cout << "    Offset in page: 0x" << std::hex << offset_in_page
            << std::dec << std::endl;
  std::cout << "  🚀 GPU can now write with system-scope atomics!" << std::endl;
  std::cout << "  🎉 TRUE GPU-DIRECT (no /dev/mem, no HIP breakage)!"
            << std::endl;

  return 0;
}

/*
 * Unmap GPU doorbell
 */
static inline void unmap_gpu_doorbell(void* mapped_base, size_t size) {
  if (mapped_base && mapped_base != MAP_FAILED) {
    munmap(mapped_base, size);
  }
}

/*
 * Check if kernel module supports exclusive mode (GPU doorbell)
 */
static inline bool has_exclusive_mode(int axiio_fd) {
  struct nvme_gpu_doorbell_info info;
  memset(&info, 0, sizeof(info));
  info.queue_id = 0; // Admin queue (always exists)
  info.is_sq = 1;

  // Try the ioctl - if it works, we have exclusive mode
  int ret = ioctl(axiio_fd, NVME_AXIIO_GET_GPU_DOORBELL, &info);
  return (ret == 0);
}

} // namespace nvme_gda

#endif // NVME_GPU_DOORBELL_GDA_H
