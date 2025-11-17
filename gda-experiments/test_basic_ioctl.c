#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <fcntl.h>
#include <sys/ioctl.h>

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

#define NVME_GDA_GET_DEVICE_INFO                                               \
  _IOR(NVME_GDA_MAGIC, 1, struct nvme_gda_device_info)

int main() {
  printf("Opening /dev/nvme_gda0...\n");
  int fd = open("/dev/nvme_gda0", O_RDWR);
  if (fd < 0) {
    perror("open");
    return 1;
  }
  printf("✓ Opened\n");

  printf("\nCalling GET_DEVICE_INFO...\n");
  struct nvme_gda_device_info info;
  memset(&info, 0, sizeof(info));

  if (ioctl(fd, NVME_GDA_GET_DEVICE_INFO, &info) < 0) {
    perror("ioctl");
    return 1;
  }

  printf("✓ Success!\n");
  printf("  Vendor: 0x%04x\n", info.vendor_id);
  printf("  Device: 0x%04x\n", info.device_id);
  printf("  BAR0: 0x%llx\n", (unsigned long long)info.bar0_addr);

  return 0;
}
