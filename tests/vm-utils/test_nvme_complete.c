#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>

#define NVME_AXIIO_MAGIC 0xAE

/* Match the kernel header exactly! */
struct nvme_axiio_queue_info {
  uint16_t queue_id;
  uint16_t queue_size;
  uint32_t nsid;
  
  uint64_t sq_dma_addr_user;
  uint64_t cq_dma_addr_user;
  
  uint64_t sq_dma_addr;
  uint64_t cq_dma_addr;
  uint64_t sq_doorbell_phys;
  uint64_t cq_doorbell_phys;
  
  uint64_t bar0_phys;
  uint64_t bar0_size;
  uint32_t doorbell_stride;
  
  uint32_t sq_doorbell_offset;
  uint32_t cq_doorbell_offset;
};

struct nvme_axiio_dma_buffer {
  uint64_t size;
  uint64_t dma_addr;
  uint64_t virt_addr;
};

#define NVME_AXIIO_CREATE_QUEUE _IOWR(NVME_AXIIO_MAGIC, 1, struct nvme_axiio_queue_info)
#define NVME_AXIIO_ALLOC_DMA _IOWR(NVME_AXIIO_MAGIC, 3, struct nvme_axiio_dma_buffer)

struct nvme_sqe {
  uint8_t opcode;
  uint8_t flags;
  uint16_t command_id;
  uint32_t nsid;
  uint32_t cdw2;
  uint32_t cdw3;
  uint64_t metadata;
  uint64_t prp1;
  uint64_t prp2;
  uint32_t cdw10;
  uint32_t cdw11;
  uint32_t cdw12;
  uint32_t cdw13;
  uint32_t cdw14;
  uint32_t cdw15;
};

struct nvme_cqe {
  uint32_t result;
  uint32_t reserved;
  uint16_t sq_head;
  uint16_t sq_id;
  uint16_t command_id;
  uint16_t status;
};

int main() {
  int fd;
  struct nvme_axiio_queue_info queue_info = {0};
  struct nvme_axiio_dma_buffer data_buf;
  struct nvme_sqe *sq;
  struct nvme_cqe *cq;
  int ret;
  
  printf("=== NVMe Command Submission Test (v3) ===\n\n");
  printf("Struct sizes:\n");
  printf("  nvme_axiio_queue_info: %zu bytes (should be 88)\n", sizeof(struct nvme_axiio_queue_info));
  printf("  nvme_axiio_dma_buffer: %zu bytes\n\n", sizeof(struct nvme_axiio_dma_buffer));
  
  // Open device
  printf("1. Opening /dev/nvme-axiio...\n");
  fd = open("/dev/nvme-axiio", O_RDWR);
  if (fd < 0) {
    perror("Failed to open /dev/nvme-axiio");
    return 1;
  }
  
  // Create queue
  printf("2. Creating I/O queue (QID 10, size 64)...\n");
  queue_info.queue_id = 10;
  queue_info.queue_size = 64;
  queue_info.nsid = 1;
  
  ret = ioctl(fd, NVME_AXIIO_CREATE_QUEUE, &queue_info);
  if (ret < 0) {
    printf("ERROR: ioctl returned %d, errno=%d (%s)\n", ret, errno, strerror(errno));
    close(fd);
    return 1;
  }
  
  printf("   ✓ Queue created\n");
  printf("     SQ DMA: 0x%016lx\n", queue_info.sq_dma_addr);
  printf("     CQ DMA: 0x%016lx\n", queue_info.cq_dma_addr);
  printf("     SQ Doorbell: 0x%016lx (offset 0x%x)\n", queue_info.sq_doorbell_phys, queue_info.sq_doorbell_offset);
  printf("     CQ Doorbell: 0x%016lx (offset 0x%x)\n", queue_info.cq_doorbell_phys, queue_info.cq_doorbell_offset);
  
  printf("\n✅ SUCCESS! Queue creation working!\n");
  
  close(fd);
  return 0;
}
