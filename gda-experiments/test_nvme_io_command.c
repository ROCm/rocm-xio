// Test posting actual NVMe I/O commands and seeing them in trace
// This posts REAL NVMe READ/WRITE commands to the submission queue

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <stdint.h>
#include <time.h>

#define NVME_GDA_MAGIC 'N'

// NVMe opcodes
#define NVME_CMD_READ   0x02
#define NVME_CMD_WRITE  0x01
#define NVME_CMD_FLUSH  0x00

// NVMe command structure (64 bytes)
struct nvme_command {
	union {
		struct {
			uint8_t  opcode;
			uint8_t  flags;
			uint16_t command_id;
			uint32_t nsid;
			uint64_t rsvd2;
			uint64_t metadata;
			uint64_t prp1;
			uint64_t prp2;
			uint32_t cdw10;
			uint32_t cdw11;
			uint32_t cdw12;
			uint32_t cdw13;
			uint32_t cdw14;
			uint32_t cdw15;
		} common;
		struct {
			uint8_t  opcode;
			uint8_t  flags;
			uint16_t command_id;
			uint32_t nsid;
			uint64_t rsvd2;
			uint64_t metadata;
			uint64_t prp1;
			uint64_t prp2;
			uint64_t slba;      // Starting LBA
			uint16_t length;    // Number of blocks (0-based)
			uint16_t control;
			uint32_t dsmgmt;
			uint32_t reftag;
			uint16_t apptag;
			uint16_t appmask;
		} rw;
	};
};

// NVMe completion structure (16 bytes)
struct nvme_completion {
	uint32_t result;
	uint32_t rsvd;
	uint16_t sq_head;
	uint16_t sq_id;
	uint16_t command_id;
	uint16_t status;  // Includes phase bit in bit 0
};

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

#define NVME_GDA_MMAP_SQE       0
#define NVME_GDA_MMAP_CQE       1
#define NVME_GDA_MMAP_DOORBELL  2

// Helper to wait a bit
static inline void wait_ms(int ms) {
	struct timespec ts = {0, ms * 1000000};
	nanosleep(&ts, NULL);
}

int main(int argc, char **argv) {
	const char *device_path = (argc > 1) ? argv[1] : "/dev/nvme_gda0";
	
	printf("========================================\n");
	printf("  NVMe I/O Command Test\n");
	printf("========================================\n\n");
	
	// Open device
	int fd = open(device_path, O_RDWR);
	if (fd < 0) {
		perror("open");
		return 1;
	}
	printf("✓ Device opened: %s\n", device_path);
	
	// Get device info
	struct nvme_gda_device_info info;
	if (ioctl(fd, NVME_GDA_GET_DEVICE_INFO, &info) < 0) {
		perror("ioctl GET_DEVICE_INFO");
		close(fd);
		return 1;
	}
	printf("✓ Device info retrieved\n");
	printf("  Vendor: 0x%04x, Device: 0x%04x\n", info.vendor_id, info.device_id);
	printf("  Max queue entries: %u\n\n", info.max_queue_entries);
	
	// Create I/O queue
	struct nvme_gda_create_queue req = { .qsize = 16, .flags = 0 };
	if (ioctl(fd, NVME_GDA_CREATE_QUEUE, &req) < 0) {
		perror("ioctl CREATE_QUEUE");
		close(fd);
		return 1;
	}
	uint16_t qid = req.flags;
	printf("✓ Queue created: QID=%u, size=%u\n\n", qid, req.qsize);
	
	// Get queue info
	struct nvme_gda_queue_info qinfo;
	if (ioctl(fd, NVME_GDA_GET_QUEUE_INFO, &qinfo) < 0) {
		perror("ioctl GET_QUEUE_INFO");
		close(fd);
		return 1;
	}
	
	// Map submission queue
	size_t sqe_size = ((req.qsize * 64) + 4095) & ~4095;
	struct nvme_command *sqes = mmap(NULL, sqe_size,
	                                  PROT_READ | PROT_WRITE, MAP_SHARED,
	                                  fd, NVME_GDA_MMAP_SQE * getpagesize());
	if (sqes == MAP_FAILED) {
		perror("mmap SQE");
		close(fd);
		return 1;
	}
	printf("✓ Submission queue mapped: %p\n", sqes);
	
	// Map completion queue
	size_t cqe_size = ((req.qsize * 16) + 4095) & ~4095;
	struct nvme_completion *cqes = mmap(NULL, cqe_size,
	                                     PROT_READ | PROT_WRITE, MAP_SHARED,
	                                     fd, NVME_GDA_MMAP_CQE * getpagesize());
	if (cqes == MAP_FAILED) {
		perror("mmap CQE");
		munmap(sqes, sqe_size);
		close(fd);
		return 1;
	}
	printf("✓ Completion queue mapped: %p\n", cqes);
	
	// Map doorbells
	void *doorbell_base = mmap(NULL, getpagesize(),
	                            PROT_READ | PROT_WRITE, MAP_SHARED,
	                            fd, NVME_GDA_MMAP_DOORBELL * getpagesize());
	if (doorbell_base == MAP_FAILED) {
		perror("mmap doorbell");
		munmap(cqes, cqe_size);
		munmap(sqes, sqe_size);
		close(fd);
		return 1;
	}
	
	uint32_t sq_offset = qinfo.sq_doorbell_offset & (getpagesize() - 1);
	uint32_t cq_offset = qinfo.cq_doorbell_offset & (getpagesize() - 1);
	volatile uint32_t *sq_doorbell = (volatile uint32_t*)((char*)doorbell_base + sq_offset);
	volatile uint32_t *cq_doorbell = (volatile uint32_t*)((char*)doorbell_base + cq_offset);
	
	printf("✓ Doorbells mapped: SQ=%p, CQ=%p\n\n", sq_doorbell, cq_doorbell);
	
	// Allocate data buffer (4KB page)
	void *data_buf = aligned_alloc(4096, 4096);
	if (!data_buf) {
		perror("aligned_alloc");
		goto cleanup;
	}
	memset(data_buf, 0, 4096);
	printf("✓ Data buffer allocated: %p\n\n", data_buf);
	
	// Initialize queue state
	uint16_t sq_tail = 0;
	uint16_t cq_head = 0;
	uint16_t cq_phase = 1;  // Phase bit starts at 1
	uint16_t cmd_id = 0;
	
	printf("========================================\n");
	printf("  Test 1: NVMe READ Command (LBA 0)\n");
	printf("========================================\n");
	
	// Build NVMe READ command
	struct nvme_command read_cmd = {0};
	read_cmd.rw.opcode = NVME_CMD_READ;
	read_cmd.rw.nsid = 1;  // Namespace 1
	read_cmd.rw.command_id = cmd_id++;
	read_cmd.rw.slba = 0;  // Start at LBA 0
	read_cmd.rw.length = 0;  // 1 block (0-based count)
	read_cmd.rw.prp1 = (uint64_t)data_buf;  // Data buffer
	
	printf("Posting READ command:\n");
	printf("  Opcode: 0x%02x (READ)\n", read_cmd.rw.opcode);
	printf("  NSID: %u\n", read_cmd.rw.nsid);
	printf("  SLBA: %llu\n", (unsigned long long)read_cmd.rw.slba);
	printf("  Length: %u blocks\n", read_cmd.rw.length + 1);
	printf("  CID: %u\n", read_cmd.rw.command_id);
	
	// Post command to SQ
	sqes[sq_tail] = read_cmd;
	__sync_synchronize();  // Memory barrier
	
	// Ring SQ doorbell
	sq_tail = (sq_tail + 1) % req.qsize;
	printf("\nRinging SQ doorbell: new_tail=%u\n", sq_tail);
	*sq_doorbell = sq_tail;
	
	// Poll for completion
	printf("Polling for completion...\n");
	int poll_count = 0;
	int max_polls = 10000;
	struct nvme_completion cqe;
	
	while (poll_count < max_polls) {
		cqe = cqes[cq_head];
		uint16_t phase = cqe.status & 1;
		
		if (phase == cq_phase) {
			// Got completion!
			printf("✓ Completion received! (polled %d times)\n", poll_count + 1);
			printf("  Command ID: %u\n", cqe.command_id);
			printf("  Status: 0x%04x\n", cqe.status >> 1);
			printf("  SQ Head: %u\n", cqe.sq_head);
			
			// Update CQ head
			cq_head = (cq_head + 1) % req.qsize;
			if (cq_head == 0) {
				cq_phase = !cq_phase;  // Toggle phase when wrapping
			}
			
			// Ring CQ doorbell
			printf("\nRinging CQ doorbell: new_head=%u\n", cq_head);
			*cq_doorbell = cq_head;
			
			break;
		}
		
		poll_count++;
		if (poll_count % 1000 == 0) {
			printf("  Still polling... (%d)\n", poll_count);
		}
		wait_ms(1);
	}
	
	if (poll_count >= max_polls) {
		printf("✗ Timeout waiting for completion!\n");
		printf("  CQE phase bit: %u, expected: %u\n", cqe.status & 1, cq_phase);
	} else {
		printf("\n✓ READ command completed successfully!\n");
		printf("\nData buffer (first 64 bytes):\n");
		unsigned char *buf = (unsigned char*)data_buf;
		for (int i = 0; i < 64; i++) {
			printf("%02x ", buf[i]);
			if ((i + 1) % 16 == 0) printf("\n");
		}
		printf("\n");
	}
	
	printf("\n========================================\n");
	printf("  Test 2: NVMe WRITE Command (LBA 1)\n");
	printf("========================================\n");
	
	// Fill buffer with pattern
	memset(data_buf, 0xAA, 4096);
	sprintf((char*)data_buf, "Hello from NVMe GDA test!");
	
	// Build NVMe WRITE command
	struct nvme_command write_cmd = {0};
	write_cmd.rw.opcode = NVME_CMD_WRITE;
	write_cmd.rw.nsid = 1;
	write_cmd.rw.command_id = cmd_id++;
	write_cmd.rw.slba = 1;  // Write to LBA 1
	write_cmd.rw.length = 0;  // 1 block
	write_cmd.rw.prp1 = (uint64_t)data_buf;
	
	printf("Posting WRITE command:\n");
	printf("  Opcode: 0x%02x (WRITE)\n", write_cmd.rw.opcode);
	printf("  NSID: %u\n", write_cmd.rw.nsid);
	printf("  SLBA: %llu\n", (unsigned long long)write_cmd.rw.slba);
	printf("  Data: \"%s...\"\n", (char*)data_buf);
	
	// Post and ring doorbell
	sqes[sq_tail] = write_cmd;
	__sync_synchronize();
	sq_tail = (sq_tail + 1) % req.qsize;
	printf("\nRinging SQ doorbell: new_tail=%u\n", sq_tail);
	*sq_doorbell = sq_tail;
	
	// Poll for completion
	printf("Polling for completion...\n");
	poll_count = 0;
	while (poll_count < max_polls) {
		cqe = cqes[cq_head];
		if ((cqe.status & 1) == cq_phase) {
			printf("✓ Completion received!\n");
			printf("  Status: 0x%04x\n", cqe.status >> 1);
			
			cq_head = (cq_head + 1) % req.qsize;
			if (cq_head == 0) cq_phase = !cq_phase;
			
			printf("Ringing CQ doorbell: new_head=%u\n", cq_head);
			*cq_doorbell = cq_head;
			break;
		}
		poll_count++;
		wait_ms(1);
	}
	
	if (poll_count < max_polls) {
		printf("\n✓ WRITE command completed successfully!\n");
	} else {
		printf("\n✗ Timeout on WRITE command\n");
	}
	
	printf("\n========================================\n");
	printf("  Test Summary\n");
	printf("========================================\n");
	printf("Commands posted: %u\n", cmd_id);
	printf("SQ tail: %u\n", sq_tail);
	printf("CQ head: %u\n", cq_head);
	printf("\n✓ Test complete!\n");
	printf("\nCheck QEMU trace for:\n");
	printf("  pci_nvme_io_cmd ... opc 0x2 opname 'NVME_NVM_CMD_READ'\n");
	printf("  pci_nvme_io_cmd ... opc 0x1 opname 'NVME_NVM_CMD_WRITE'\n");
	printf("\n");
	
	free(data_buf);
	
cleanup:
	munmap(doorbell_base, getpagesize());
	munmap(cqes, cqe_size);
	munmap(sqes, sqe_size);
	close(fd);
	
	return 0;
}

