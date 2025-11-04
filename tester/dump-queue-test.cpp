// Quick test to dump SQ memory and verify command structure
#include <iostream>
#include <iomanip>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <cstring>
#include <stdint.h>

#include "../kernel-module/nvme_axiio.h"

// Simplified NVMe SQE structure
struct nvme_sqe {
    uint8_t opcode;
    uint8_t flags;
    uint16_t command_id;
    uint32_t nsid;
    uint32_t cdw2;
    uint32_t cdw3;
    uint64_t metadata;
    union {
        struct {
            uint64_t prp1;
            uint64_t prp2;
        } prp;
    } dptr;
    uint32_t cdw10;
    uint32_t cdw11;
    uint32_t cdw12;
    uint32_t cdw13;
    uint32_t cdw14;
    uint32_t cdw15;
};

int main() {
    // Open kernel module device
    int fd = open("/dev/nvme-axiio", O_RDWR);
    if (fd < 0) {
        std::cerr << "Failed to open /dev/nvme-axiio" << std::endl;
        return 1;
    }

    // Request queue creation
    struct nvme_axiio_queue_info qinfo;
    memset(&qinfo, 0, sizeof(qinfo));
    qinfo.queue_id = 5;
    qinfo.queue_size = 1024;
    qinfo.nsid = 1;

    if (ioctl(fd, NVME_AXIIO_CREATE_QUEUE, &qinfo) < 0) {
        perror("NVME_AXIIO_CREATE_QUEUE failed");
        close(fd);
        return 1;
    }

    std::cout << "Queue created successfully!" << std::endl;
    std::cout << "SQ DMA: 0x" << std::hex << qinfo.sq_dma_addr << std::dec << std::endl;
    std::cout << "CQ DMA: 0x" << std::hex << qinfo.cq_dma_addr << std::dec << std::endl;

    // Map SQ memory
    size_t sq_size = qinfo.queue_size * 64;
    void* sq_ptr = mmap(NULL, sq_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (sq_ptr == MAP_FAILED) {
        perror("mmap SQ failed");
        close(fd);
        return 1;
    }

    // Write a test command
    struct nvme_sqe* sqe = (struct nvme_sqe*)sq_ptr;
    memset(sqe, 0, sizeof(*sqe));
    
    // Create a simple Read command
    sqe->opcode = 0x02; // NVME_CMD_READ
    sqe->command_id = 0;
    sqe->nsid = 1; // Namespace 1
    sqe->dptr.prp.prp1 = 0x100000000ULL; // Dummy data buffer address
    sqe->dptr.prp.prp2 = 0;
    sqe->cdw10 = 0; // SLBA lower (LBA 0)
    sqe->cdw11 = 0; // SLBA upper
    sqe->cdw12 = 7; // NLB = 7 (0-based, so 8 blocks)

    std::cout << "\n=== Written SQE[0] ===" << std::endl;
    std::cout << "Opcode: 0x" << std::hex << (int)sqe->opcode << std::dec << std::endl;
    std::cout << "CID: " << sqe->command_id << std::endl;
    std::cout << "NSID: " << sqe->nsid << std::endl;
    std::cout << "PRP1: 0x" << std::hex << sqe->dptr.prp.prp1 << std::dec << std::endl;
    std::cout << "SLBA: 0x" << std::hex << ((uint64_t)sqe->cdw11 << 32 | sqe->cdw10) << std::dec << std::endl;
    std::cout << "NLB: " << (sqe->cdw12 & 0xFFFF) << " blocks" << std::endl;

    // Dump raw bytes
    std::cout << "\n=== Raw SQE bytes ===" << std::endl;
    uint8_t* bytes = (uint8_t*)sqe;
    for (int i = 0; i < 64; i++) {
        if (i % 16 == 0) std::cout << std::hex << std::setfill('0') << std::setw(4) << i << ": ";
        std::cout << std::hex << std::setfill('0') << std::setw(2) << (int)bytes[i] << " ";
        if ((i + 1) % 16 == 0) std::cout << std::endl;
    }
    std::cout << std::dec << std::endl;

    munmap(sq_ptr, sq_size);
    close(fd);
    return 0;
}

