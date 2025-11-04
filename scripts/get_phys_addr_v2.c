/* Enhanced Physical Address Lookup Utility
 *
 * This utility allocates memory (optionally using huge pages), locks it,
 * and returns the physical address via /proc/self/pagemap.
 *
 * Supports:
 *   - Regular pages (4KB)
 *   - Huge pages (2MB)
 *   - Multiple page mappings
 *   - Error detection
 *
 * Usage:
 *   ./get_phys_addr_v2 <size_bytes> [--huge-pages]
 *
 * Returns:
 *   Physical address (hex) on stdout
 *   Exit code 0 on success, non-zero on failure
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#define PAGE_SIZE 4096
#define HUGE_PAGE_SIZE (2 * 1024 * 1024) // 2MB

// Read physical address from /proc/self/pagemap
static int get_phys_addr(void* virt_addr, uint64_t* phys_addr) {
  int fd = open("/proc/self/pagemap", O_RDONLY);
  if (fd < 0) {
    perror("Failed to open /proc/self/pagemap");
    fprintf(stderr, "Note: Requires CAP_SYS_RAWIO or root privileges\n");
    return -1;
  }

  // Calculate offset in pagemap file
  size_t page_size = sysconf(_SC_PAGE_SIZE);
  uint64_t virt_pfn = (uint64_t)virt_addr / page_size;
  off_t offset = virt_pfn * sizeof(uint64_t);

  // Seek to the entry
  if (lseek(fd, offset, SEEK_SET) == -1) {
    perror("Failed to seek in pagemap");
    close(fd);
    return -1;
  }

  // Read the page map entry
  uint64_t pagemap_entry;
  if (read(fd, &pagemap_entry, sizeof(pagemap_entry)) !=
      sizeof(pagemap_entry)) {
    perror("Failed to read pagemap entry");
    close(fd);
    return -1;
  }

  close(fd);

  // Check if page is present
  if (!(pagemap_entry & (1ULL << 63))) {
    fprintf(stderr, "Error: Page not present in memory\n");
    return -1;
  }

  // Extract physical frame number (bits 0-54)
  uint64_t pfn = pagemap_entry & ((1ULL << 55) - 1);

  // Calculate physical address
  uint64_t page_offset = (uint64_t)virt_addr % page_size;
  *phys_addr = (pfn * page_size) + page_offset;

  return 0;
}

// Check if huge pages are available
static int check_huge_pages_available() {
  FILE* fp = fopen("/proc/meminfo", "r");
  if (!fp) {
    return 0;
  }

  char line[256];
  int huge_pages_total = 0;
  int huge_pages_free = 0;

  while (fgets(line, sizeof(line), fp)) {
    if (sscanf(line, "HugePages_Total: %d", &huge_pages_total) == 1) {
      continue;
    }
    if (sscanf(line, "HugePages_Free: %d", &huge_pages_free) == 1) {
      continue;
    }
  }

  fclose(fp);

  return (huge_pages_total > 0 && huge_pages_free > 0);
}

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "Usage: %s <size_bytes> [--huge-pages]\n", argv[0]);
    fprintf(stderr, "\n");
    fprintf(stderr,
            "Allocates memory, locks it, and returns physical address.\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  --huge-pages    Use 2MB huge pages (if available)\n");
    fprintf(stderr, "  --verbose       Print detailed information\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Requires: CAP_SYS_RAWIO or root for pagemap access\n");
    return 1;
  }

  // Parse size
  size_t size = strtoull(argv[1], NULL, 0);
  if (size == 0) {
    fprintf(stderr, "Error: Invalid size\n");
    return 1;
  }

  // Parse options
  int use_huge_pages = 0;
  int verbose = 0;

  for (int i = 2; i < argc; i++) {
    if (strcmp(argv[i], "--huge-pages") == 0) {
      use_huge_pages = 1;
    } else if (strcmp(argv[i], "--verbose") == 0) {
      verbose = 1;
    }
  }

  if (verbose) {
    fprintf(stderr, "Allocating %zu bytes...\n", size);
  }

  // Check huge pages availability if requested
  if (use_huge_pages) {
    if (!check_huge_pages_available()) {
      fprintf(
        stderr,
        "Warning: Huge pages not available, falling back to regular pages\n");
      fprintf(stderr, "To enable: sudo sysctl -w vm.nr_hugepages=128\n");
      use_huge_pages = 0;
    }
  }

  // Allocate memory
  void* buffer;
  int mmap_flags = MAP_PRIVATE | MAP_ANONYMOUS;

  if (use_huge_pages) {
    mmap_flags |= MAP_HUGETLB;
    if (verbose) {
      fprintf(stderr, "Using huge pages (2MB)...\n");
    }
  }

  buffer = mmap(NULL, size, PROT_READ | PROT_WRITE, mmap_flags, -1, 0);

  if (buffer == MAP_FAILED) {
    if (use_huge_pages) {
      // Retry without huge pages
      if (verbose) {
        fprintf(
          stderr,
          "Huge page allocation failed, retrying with regular pages...\n");
      }
      mmap_flags &= ~MAP_HUGETLB;
      buffer = mmap(NULL, size, PROT_READ | PROT_WRITE, mmap_flags, -1, 0);
    }

    if (buffer == MAP_FAILED) {
      perror("Failed to allocate memory");
      return 1;
    }
  }

  if (verbose) {
    fprintf(stderr, "Virtual address: %p\n", buffer);
  }

  // Lock memory to prevent swapping
  if (mlock(buffer, size) != 0) {
    perror("Failed to lock memory");
    fprintf(stderr, "Note: May require CAP_IPC_LOCK or increased limits\n");
    munmap(buffer, size);
    return 1;
  }

  if (verbose) {
    fprintf(stderr, "Memory locked successfully\n");
  }

  // Touch all pages to ensure they're allocated
  if (verbose) {
    fprintf(stderr, "Touching pages to ensure allocation...\n");
  }

  size_t page_size = use_huge_pages ? HUGE_PAGE_SIZE : PAGE_SIZE;
  for (size_t offset = 0; offset < size; offset += page_size) {
    volatile char* ptr = (volatile char*)buffer + offset;
    *ptr = 0;
  }

  // Get physical address of first page
  uint64_t phys_addr;
  if (get_phys_addr(buffer, &phys_addr) != 0) {
    fprintf(stderr, "Failed to get physical address\n");
    munmap(buffer, size);
    return 1;
  }

  if (verbose) {
    fprintf(stderr, "Physical address: 0x%016lx\n", phys_addr);
    fprintf(stderr, "Page size: %zu bytes\n", page_size);
    fprintf(stderr, "Number of pages: %zu\n",
            (size + page_size - 1) / page_size);
  }

  // Print physical address to stdout (for scripts)
  printf("0x%016lx\n", phys_addr);

  if (verbose) {
    fprintf(stderr, "\nKeeping memory mapped for testing...\n");
    fprintf(stderr, "Press Ctrl+C to exit and free memory\n");

    // Keep running until interrupted
    pause();
  }

  // Cleanup (only reached if not verbose)
  munmap(buffer, size);

  return 0;
}
