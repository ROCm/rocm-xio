#include <stdio.h>
#include <sys/ioctl.h>
#include <stdint.h>

#define NVME_AXIIO_MAGIC 0xAE

struct nvme_axiio_queue_info {
  uint16_t queue_id;
  uint32_t queue_size;
  uint64_t sq_dma;
  uint64_t cq_dma;
};

struct nvme_axiio_dma_buffer {
  uint64_t size;
  uint64_t dma_addr;
  uint64_t virt_addr;
};

#define NVME_AXIIO_CREATE_QUEUE _IOWR(NVME_AXIIO_MAGIC, 1, struct nvme_axiio_queue_info)
#define NVME_AXIIO_ALLOC_DMA _IOWR(NVME_AXIIO_MAGIC, 3, struct nvme_axiio_dma_buffer)

int main() {
  printf("NVME_AXIIO_CREATE_QUEUE = 0x%lx\n", NVME_AXIIO_CREATE_QUEUE);
  printf("NVME_AXIIO_ALLOC_DMA    = 0x%lx\n", NVME_AXIIO_ALLOC_DMA);
  printf("\nExpected from dmesg: 0xc018ae03\n");
  printf("\nstruct sizes:\n");
  printf("  nvme_axiio_queue_info:  %zu bytes\n", sizeof(struct nvme_axiio_queue_info));
  printf("  nvme_axiio_dma_buffer:  %zu bytes\n", sizeof(struct nvme_axiio_dma_buffer));
  return 0;
}
