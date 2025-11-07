// Test program to generate doorbell operations for tracing
// This writes to doorbells from CPU to verify trace capture works

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define NVME_GDA_MAGIC 'N'

struct nvme_gda_device_info {
  uint64_t bar0_addr;
  uint64_t bar0_size;
  uint32_t doorbell_stride;
  uint32_t max_queue_entries;
  uint16_t vendor_id;
  uint16_t device_id;
  uint16_t subsystem_vendor_id;
  uint16_t subsystem_device_id;
  uint8_t serial_number[20];
  uint8_t model_number[40];
  uint8_t firmware_rev[8];
};

struct nvme_gda_create_queue {
  uint16_t qsize;
  uint16_t flags; // Returns QID
};

struct nvme_gda_queue_info {
  uint16_t qid;
  uint16_t qsize;
  uint64_t sqe_dma_addr;
  uint64_t cqe_dma_addr;
  uint64_t sq_doorbell_offset;
  uint64_t cq_doorbell_offset;
};

#define NVME_GDA_GET_DEVICE_INFO                                               \
  _IOR(NVME_GDA_MAGIC, 1, struct nvme_gda_device_info)
#define NVME_GDA_CREATE_QUEUE                                                  \
  _IOWR(NVME_GDA_MAGIC, 2, struct nvme_gda_create_queue)
#define NVME_GDA_GET_QUEUE_INFO                                                \
  _IOR(NVME_GDA_MAGIC, 3, struct nvme_gda_queue_info)

#define NVME_GDA_MMAP_SQE 0
#define NVME_GDA_MMAP_CQE 1
#define NVME_GDA_MMAP_DOORBELL 2

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "Usage: %s /dev/nvme_gda0\n", argv[0]);
    return 1;
  }

  printf("NVMe GDA Doorbell Trace Test\n");
  printf("============================\n\n");

  // Open device
  int fd = open(argv[1], O_RDWR);
  if (fd < 0) {
    perror("open");
    return 1;
  }
  printf("✓ Device opened\n");

  // Get device info
  struct nvme_gda_device_info info;
  if (ioctl(fd, NVME_GDA_GET_DEVICE_INFO, &info) < 0) {
    perror("ioctl GET_DEVICE_INFO");
    close(fd);
    return 1;
  }
  printf("✓ Device info retrieved\n");
  printf("  Vendor: 0x%04x, Device: 0x%04x\n", info.vendor_id, info.device_id);
  printf("  BAR0: 0x%llx (size: 0x%llx)\n", (unsigned long long)info.bar0_addr,
         (unsigned long long)info.bar0_size);
  printf("  Doorbell stride: %u DWORDs\n", info.doorbell_stride);
  printf("  Max queue entries: %u\n\n", info.max_queue_entries);

  // Create queue
  struct nvme_gda_create_queue req = {.qsize = 16, .flags = 0};
  if (ioctl(fd, NVME_GDA_CREATE_QUEUE, &req) < 0) {
    perror("ioctl CREATE_QUEUE");
    close(fd);
    return 1;
  }
  uint16_t qid = req.flags;
  printf("✓ Queue created: QID=%u, size=%u\n", qid, req.qsize);

  // Get queue info
  struct nvme_gda_queue_info qinfo;
  if (ioctl(fd, NVME_GDA_GET_QUEUE_INFO, &qinfo) < 0) {
    perror("ioctl GET_QUEUE_INFO");
    close(fd);
    return 1;
  }
  printf("✓ Queue info retrieved\n");
  printf("  SQ doorbell offset: 0x%llx\n",
         (unsigned long long)qinfo.sq_doorbell_offset);
  printf("  CQ doorbell offset: 0x%llx\n\n",
         (unsigned long long)qinfo.cq_doorbell_offset);

  // Map doorbell registers
  size_t doorbell_size = 4096; // Page size
  void* doorbell_base = mmap(NULL, doorbell_size, PROT_READ | PROT_WRITE,
                             MAP_SHARED, fd,
                             NVME_GDA_MMAP_DOORBELL * getpagesize());
  if (doorbell_base == MAP_FAILED) {
    perror("mmap doorbell");
    close(fd);
    return 1;
  }
  printf("✓ Doorbell registers mapped at %p\n", doorbell_base);

  // Calculate doorbell offsets within page
  uint32_t sq_offset = qinfo.sq_doorbell_offset & (getpagesize() - 1);
  uint32_t cq_offset = qinfo.cq_doorbell_offset & (getpagesize() - 1);

  volatile uint32_t* sq_doorbell = (volatile uint32_t*)((char*)doorbell_base +
                                                        sq_offset);
  volatile uint32_t* cq_doorbell = (volatile uint32_t*)((char*)doorbell_base +
                                                        cq_offset);

  printf("  SQ doorbell: %p (offset 0x%x)\n", sq_doorbell, sq_offset);
  printf("  CQ doorbell: %p (offset 0x%x)\n\n", cq_doorbell, cq_offset);

  // Test doorbell operations
  printf("Testing doorbell writes...\n");
  printf("==========================\n\n");

  printf("Test 1: Read initial doorbell values\n");
  uint32_t sq_initial = *sq_doorbell;
  uint32_t cq_initial = *cq_doorbell;
  printf("  SQ doorbell: %u\n", sq_initial);
  printf("  CQ doorbell: %u\n\n", cq_initial);

  printf("Test 2: Write to SQ doorbell (simulating command submission)\n");
  for (int i = 1; i <= 5; i++) {
    printf("  Writing SQ doorbell = %d... ", i);
    fflush(stdout);
    *sq_doorbell = i;
    usleep(100000); // 100ms delay for trace visibility
    uint32_t readback = *sq_doorbell;
    printf("readback = %u\n", readback);
  }
  printf("\n");

  printf(
    "Test 3: Write to CQ doorbell (simulating completion acknowledgment)\n");
  for (int i = 1; i <= 3; i++) {
    printf("  Writing CQ doorbell = %d... ", i);
    fflush(stdout);
    *cq_doorbell = i;
    usleep(100000); // 100ms delay
    uint32_t readback = *cq_doorbell;
    printf("readback = %u\n", readback);
  }
  printf("\n");

  printf("Test 4: Alternating SQ/CQ doorbell writes\n");
  for (int i = 0; i < 3; i++) {
    printf("  Round %d:\n", i + 1);
    printf("    SQ doorbell = %d\n", 10 + i);
    *sq_doorbell = 10 + i;
    usleep(50000);
    printf("    CQ doorbell = %d\n", 5 + i);
    *cq_doorbell = 5 + i;
    usleep(50000);
  }
  printf("\n");

  // Cleanup
  munmap(doorbell_base, doorbell_size);
  close(fd);

  printf("✓ Test complete!\n");
  printf("\nTo check trace output on host:\n");
  printf("  cat /tmp/nvme-gda-trace.log | grep -i doorbell\n");
  printf("  cat /tmp/nvme-gda-trace.log | grep -i mmio\n");
  printf("\n");

  return 0;
}
