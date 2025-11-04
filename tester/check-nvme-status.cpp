// Check NVMe controller status by reading BAR0 registers
#include <iostream>
#include <iomanip>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <cstring>
#include <stdint.h>

#include "../kernel-module/nvme_axiio.h"

int main() {
    std::cout << "=== NVMe Controller Status Check ===" << std::endl;

    // Open kernel module device
    int fd = open("/dev/nvme-axiio", O_RDWR);
    if (fd < 0) {
        std::cerr << "Failed to open /dev/nvme-axiio" << std::endl;
        return 1;
    }

    std::cout << "✓ Opened /dev/nvme-axiio" << std::endl;

    // Get device info to find BAR0 address
    struct nvme_axiio_queue_info info;
    memset(&info, 0, sizeof(info));
    
    if (ioctl(fd, NVME_AXIIO_GET_DEVICE_INFO, &info) < 0) {
        std::cerr << "Failed to get device info" << std::endl;
        close(fd);
        return 1;
    }

    std::cout << "\n=== Device Information ===" << std::endl;
    std::cout << "BAR0 Physical: 0x" << std::hex << info.bar0_phys << std::dec << std::endl;
    std::cout << "BAR0 Size: " << info.bar0_size << " bytes" << std::endl;
    std::cout << "Doorbell Stride: " << info.doorbell_stride << std::endl;

    // Open /dev/mem to read registers
    int mem_fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (mem_fd < 0) {
        std::cerr << "Failed to open /dev/mem (need root)" << std::endl;
        close(fd);
        return 1;
    }

    // Map BAR0
    void* bar0 = mmap(NULL, info.bar0_size, PROT_READ, MAP_SHARED, mem_fd, info.bar0_phys);
    if (bar0 == MAP_FAILED) {
        perror("mmap BAR0 failed");
        close(mem_fd);
        close(fd);
        return 1;
    }

    std::cout << "\n=== Controller Registers ===" << std::endl;

    // Read CAP register (0x00)
    volatile uint64_t* cap_reg = (volatile uint64_t*)bar0;
    uint64_t cap = *cap_reg;
    uint32_t mqes = (cap & 0xFFFF) + 1; // Maximum queue entries
    
    std::cout << "CAP:  0x" << std::hex << cap << std::dec << std::endl;
    std::cout << "  Max Queue Entries: " << mqes << std::endl;
    std::cout << "  Doorbell Stride: " << ((cap >> 32) & 0xF) << " (4-byte units)" << std::endl;

    // Read VS register (0x08)
    volatile uint32_t* vs_reg = (volatile uint32_t*)((char*)bar0 + 0x08);
    uint32_t vs = *vs_reg;
    std::cout << "VS:   0x" << std::hex << vs << std::dec;
    std::cout << " (Version: " << ((vs >> 16) & 0xFFFF) << "." << (vs & 0xFFFF) << ")" << std::endl;

    // Read CC register (0x14)
    volatile uint32_t* cc_reg = (volatile uint32_t*)((char*)bar0 + 0x14);
    uint32_t cc = *cc_reg;
    std::cout << "CC:   0x" << std::hex << cc << std::dec << std::endl;
    std::cout << "  Enable (EN):     " << (cc & 1 ? "YES ✅" : "NO ❌") << std::endl;
    std::cout << "  I/O Queue Sizes: SQE=" << (1 << ((cc >> 16) & 0xF)) 
              << " bytes, CQE=" << (1 << ((cc >> 20) & 0xF)) << " bytes" << std::endl;

    // Read CSTS register (0x1c)
    volatile uint32_t* csts_reg = (volatile uint32_t*)((char*)bar0 + 0x1c);
    uint32_t csts = *csts_reg;
    std::cout << "CSTS: 0x" << std::hex << csts << std::dec << std::endl;
    std::cout << "  Ready (RDY):        " << (csts & 1 ? "YES ✅" : "NO ❌") << std::endl;
    std::cout << "  Fatal Error (CFS):  " << (csts & 2 ? "YES ❌" : "NO ✅") << std::endl;
    std::cout << "  Shutdown Status:    " << ((csts >> 2) & 3) << std::endl;

    std::cout << "\n=== Summary ===" << std::endl;
    if (!(cc & 1)) {
        std::cout << "❌ Controller is NOT enabled!" << std::endl;
    } else if (!(csts & 1)) {
        std::cout << "⚠️  Controller is enabled but NOT ready!" << std::endl;
    } else if (csts & 2) {
        std::cout << "❌ Controller has FATAL ERROR!" << std::endl;
    } else {
        std::cout << "✅ Controller is enabled and ready for I/O" << std::endl;
    }

    munmap(bar0, info.bar0_size);
    close(mem_fd);
    close(fd);
    
    return 0;
}
