// Simple test to check if driver is working
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>

// From nvme_gda.h
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

#define NVME_GDA_MAGIC 'N'
#define NVME_GDA_GET_DEVICE_INFO                                               \
  _IOR(NVME_GDA_MAGIC, 1, struct nvme_gda_device_info)

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "Usage: %s /dev/nvme_gda0\n", argv[0]);
    return 1;
  }

  int fd = open(argv[1], O_RDWR);
  if (fd < 0) {
    perror("open");
    return 1;
  }

  printf("✓ Device opened successfully\n");

  struct nvme_gda_device_info info;
  if (ioctl(fd, NVME_GDA_GET_DEVICE_INFO, &info) < 0) {
    perror("ioctl");
    close(fd);
    return 1;
  }

  printf("✓ Device info retrieved:\n");
  printf("  BAR0: 0x%llx (size: 0x%llx)\n", (unsigned long long)info.bar0_addr,
         (unsigned long long)info.bar0_size);
  printf("  Doorbell stride: %u\n", info.doorbell_stride);
  printf("  Max queue entries: %u\n", info.max_queue_entries);
  printf("  Vendor: 0x%04x, Device: 0x%04x\n", info.vendor_id, info.device_id);

  close(fd);
  printf("\n✓ Driver is working!\n");
  return 0;
}
