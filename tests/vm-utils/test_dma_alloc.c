#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <stdint.h>
#include <errno.h>
#include <string.h>

#define NVME_AXIIO_MAGIC 0xAE

struct nvme_axiio_dma_buffer {
  uint64_t size;      /* IN: Size in bytes */
  uint64_t dma_addr;  /* OUT: DMA address */
  uint64_t virt_addr; /* OUT: Kernel virtual address */
};

#define NVME_AXIIO_ALLOC_DMA _IOWR(NVME_AXIIO_MAGIC, 3, struct nvme_axiio_dma_buffer)

int main() {
  int fd;
  struct nvme_axiio_dma_buffer dma_buf;
  
  printf("IOCTL number: 0x%lx\n", NVME_AXIIO_ALLOC_DMA);
  
  printf("Opening /dev/nvme-axiio...\n");
  fd = open("/dev/nvme-axiio", O_RDWR);
  if (fd < 0) {
    perror("Failed to open /dev/nvme-axiio");
    return 1;
  }
  
  printf("Allocating DMA buffer (32KB)...\n");
  dma_buf.size = 32 * 1024;
  
  int ret = ioctl(fd, NVME_AXIIO_ALLOC_DMA, &dma_buf);
  if (ret < 0) {
    printf("ERROR: ioctl returned %d, errno=%d (%s)\n", ret, errno, strerror(errno));
    close(fd);
    return 1;
  }
  
  printf("\n✅ DMA buffer allocated successfully!\n");
  printf("  Size:        %lu bytes\n", dma_buf.size);
  printf("  DMA address: 0x%016lx\n", dma_buf.dma_addr);
  printf("  Virt addr:   0x%016lx\n", dma_buf.virt_addr);
  
  close(fd);
  return 0;
}
