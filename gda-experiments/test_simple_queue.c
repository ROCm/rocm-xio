#include <stdio.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <stdint.h>

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
	uint16_t flags;
};

struct nvme_gda_queue_info {
	uint16_t qid;
	uint16_t qsize;
	uint64_t sqe_dma_addr;
	uint64_t cqe_dma_addr;
	uint64_t sq_doorbell_offset;
	uint64_t cq_doorbell_offset;
};

#define NVME_GDA_GET_DEVICE_INFO _IOR(NVME_GDA_MAGIC, 1, struct nvme_gda_device_info)
#define NVME_GDA_CREATE_QUEUE    _IOWR(NVME_GDA_MAGIC, 2, struct nvme_gda_create_queue)
#define NVME_GDA_GET_QUEUE_INFO  _IOR(NVME_GDA_MAGIC, 3, struct nvme_gda_queue_info)

int main() {
	printf("Opening device...\n");
	int fd = open("/dev/nvme_gda0", O_RDWR);
	if (fd < 0) {
		perror("open");
		return 1;
	}
	
	printf("Getting device info...\n");
	struct nvme_gda_device_info info;
	if (ioctl(fd, NVME_GDA_GET_DEVICE_INFO, &info) < 0) {
		perror("GET_DEVICE_INFO");
		return 1;
	}
	printf("  OK\n");
	
	printf("Creating queue...\n");
	struct nvme_gda_create_queue req = { .qsize = 16, .flags = 0 };
	if (ioctl(fd, NVME_GDA_CREATE_QUEUE, &req) < 0) {
		perror("CREATE_QUEUE");
		return 1;
	}
	printf("  Created QID=%u\n", req.flags);
	
	printf("Getting queue info...\n");
	struct nvme_gda_queue_info qinfo;
	if (ioctl(fd, NVME_GDA_GET_QUEUE_INFO, &qinfo) < 0) {
		perror("GET_QUEUE_INFO");
		return 1;
	}
	printf("  OK - QID=%u\n", qinfo.qid);
	
	printf("\nAll ioctls worked!\n");
	return 0;
}
