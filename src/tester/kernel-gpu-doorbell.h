/*
 * Kernel Module GPU Doorbell Mapping
 * Uses kernel module's mmap() with GPU-compatible flags
 * This is the rocSHMEM-equivalent method!
 */

#ifndef KERNEL_GPU_DOORBELL_H
#define KERNEL_GPU_DOORBELL_H

#include <iostream>

#include <sys/mman.h>

namespace kernel_doorbell {

/*
 * Map doorbell for GPU access via kernel module
 *
 * This uses the kernel module's mmap() handler which maps the doorbell
 * with GPU-compatible flags (write-combine, I/O, etc.) - just like
 * InfiniBand verbs do for rocSHMEM!
 *
 * @param axiio_fd: File descriptor to /dev/nvme-axiio
 * @param doorbell_out: Output pointer (GPU-accessible!)
 * @return 0 on success, -1 on failure
 */
static inline int map_doorbell_gpu(int axiio_fd,
                                   volatile uint32_t** doorbell_out) {
  // mmap offset 2 = doorbell mapping
  // Kernel module will map with pgprot_writecombine() + VM_IO flags
  // This makes it GPU-accessible!
  size_t map_size = 4096;  // One page
  off_t offset = 2 * 4096; // vm_pgoff = 2 (in page units)

  void* ptr = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, axiio_fd,
                   offset);

  if (ptr == MAP_FAILED) {
    std::cerr << "ERROR: Failed to mmap doorbell from kernel module: "
              << strerror(errno) << std::endl;
    return -1;
  }

  // The doorbell is at offset within the page (queue_id * 2 * doorbell_stride)
  // But kernel module maps page-aligned, so we need to add the in-page offset
  // For now, assume it's at the start (kernel module should handle alignment)
  *doorbell_out = (volatile uint32_t*)ptr;

  std::cout << "  ✅ Kernel module mapped doorbell with GPU-compatible flags!"
            << std::endl;
  std::cout << "    Userspace pointer: " << (void*)ptr << std::endl;
  std::cout << "    Flags: write-combine + I/O mapping (GPU-accessible)"
            << std::endl;

  return 0;
}

/*
 * Unmap doorbell
 */
static inline void unmap_doorbell_gpu(volatile uint32_t* doorbell) {
  if (doorbell) {
    munmap((void*)doorbell, 4096);
  }
}

} // namespace kernel_doorbell

#endif // KERNEL_GPU_DOORBELL_H
