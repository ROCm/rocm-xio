/*
 * Test program for NVMe AXIIO kernel module
 *
 * Demonstrates how to use the kernel module to get queue and doorbell info
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "nvme_axiio.h"

int main(int argc, char** argv) {
  int fd;
  struct nvme_axiio_queue_info qinfo;
  int ret;

  printf("NVMe AXIIO Test Program\n");
  printf("=======================\n\n");

  /* Open the axiio device */
  fd = open("/dev/nvme-axiio", O_RDWR);
  if (fd < 0) {
    perror("Failed to open /dev/nvme-axiio");
    printf(
      "Make sure the kernel module is loaded: sudo insmod nvme_axiio.ko\n");
    return 1;
  }

  printf("✓ Opened /dev/nvme-axiio\n\n");

  /* Request queue creation */
  memset(&qinfo, 0, sizeof(qinfo));
  qinfo.queue_id = 63;     /* Request queue 63 */
  qinfo.queue_size = 1024; /* 1024 entries */
  qinfo.nsid = 1;          /* Namespace 1 */

  printf("Creating queue...\n");
  printf("  Requested QID: %u\n", qinfo.queue_id);
  printf("  Queue size: %u entries\n", qinfo.queue_size);
  printf("  NSID: %u\n\n", qinfo.nsid);

  ret = ioctl(fd, NVME_AXIIO_CREATE_QUEUE, &qinfo);
  if (ret < 0) {
    perror("NVME_AXIIO_CREATE_QUEUE ioctl failed");
    close(fd);
    return 1;
  }

  printf("✓ Queue created successfully!\n\n");

  /* Display returned information */
  printf("Queue Information:\n");
  printf("=================\n");
  printf("Queue ID: %u\n", qinfo.queue_id);
  printf("\n");

  printf("DMA Addresses (for kernel use):\n");
  printf("  SQ DMA Address: 0x%016llx\n",
         (unsigned long long)qinfo.sq_dma_addr);
  printf("  CQ DMA Address: 0x%016llx\n",
         (unsigned long long)qinfo.cq_dma_addr);
  printf("\n");

  printf("BAR0 Information:\n");
  printf("  Physical Address: 0x%016llx\n",
         (unsigned long long)qinfo.bar0_phys);
  printf("  Size: 0x%llx (%llu KB)\n", (unsigned long long)qinfo.bar0_size,
         (unsigned long long)qinfo.bar0_size / 1024);
  printf("  Doorbell Stride: %u (4-byte units) = %u bytes\n",
         qinfo.doorbell_stride, qinfo.doorbell_stride * 4);
  printf("\n");

  printf("Doorbell Information:\n");
  printf("  SQ Doorbell:\n");
  printf("    Physical Address: 0x%016llx\n",
         (unsigned long long)qinfo.sq_doorbell_phys);
  printf("    Offset in BAR0: 0x%04x\n", qinfo.sq_doorbell_offset);
  printf("  CQ Doorbell:\n");
  printf("    Physical Address: 0x%016llx\n",
         (unsigned long long)qinfo.cq_doorbell_phys);
  printf("    Offset in BAR0: 0x%04x\n", qinfo.cq_doorbell_offset);
  printf("\n");

  printf("Usage in axiio-tester:\n");
  printf("======================\n");
  printf("Instead of using --nvme-device /dev/nvme0, use these addresses:\n");
  printf("  --nvme-sq-addr 0x%llx\n", (unsigned long long)qinfo.sq_dma_addr);
  printf("  --nvme-cq-addr 0x%llx\n", (unsigned long long)qinfo.cq_dma_addr);
  printf("  --nvme-doorbell-addr 0x%llx\n",
         (unsigned long long)qinfo.sq_doorbell_phys);
  printf("  --nvme-queue-id %u\n", qinfo.queue_id);
  printf("\n");

  printf("Next Steps:\n");
  printf("===========\n");
  printf("1. You can now mmap the queue memory from userspace\n");
  printf("2. Use /dev/mem to map the doorbell registers (requires root)\n");
  printf("3. Or modify axiio-tester to use this ioctl instead\n");
  printf("\n");

  /* Test mmap of SQ */
  printf("Testing mmap of SQ memory...\n");
  size_t sq_size = qinfo.queue_size * 64; /* 64 bytes per SQE */
  void* sq_mem = mmap(NULL, sq_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (sq_mem == MAP_FAILED) {
    perror("mmap SQ failed");
  } else {
    printf("✓ SQ mapped to userspace at %p\n", sq_mem);
    printf("  You can now write NVMe SQEs directly to this memory!\n");
    munmap(sq_mem, sq_size);
  }
  printf("\n");

  printf("Press Enter to cleanup and exit...");
  getchar();

  close(fd);
  printf("✓ Device closed, queues cleaned up\n");

  return 0;
}
