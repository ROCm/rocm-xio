/*
 * Test NVMe P2P Vendor Command
 * 
 * Sends vendor-specific admin command 0xC0 to trigger P2P initialization
 * and retrieve IOVA addresses for GPU direct access.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/nvme_ioctl.h>

/* P2P IOVA Info structure (matches nvme-p2p.h in QEMU) */
struct nvme_p2p_iova_info {
    uint64_t sqe_iova;
    uint64_t cqe_iova;
    uint64_t doorbell_iova;
    uint32_t sqe_size;
    uint32_t cqe_size;
    uint32_t doorbell_size;
    uint16_t queue_depth;
    uint16_t reserved;
} __attribute__((packed));

int main(int argc, char **argv)
{
    int fd;
    struct nvme_admin_cmd cmd;
    struct nvme_p2p_iova_info info;
    int ret;
    const char *nvme_dev = "/dev/nvme0";
    
    if (argc > 1) {
        nvme_dev = argv[1];
    }
    
    printf("===========================================\n");
    printf("NVMe P2P Vendor Command Test\n");
    printf("===========================================\n");
    printf("Device: %s\n\n", nvme_dev);
    
    /* Open NVMe device */
    fd = open(nvme_dev, O_RDONLY);
    if (fd < 0) {
        perror("Failed to open NVMe device");
        printf("Usage: %s [/dev/nvmeX]\n", argv[0]);
        printf("Note: You may need to run with sudo\n");
        return 1;
    }
    
    printf("Sending vendor-specific admin command 0xC0...\n");
    
    /* Prepare vendor-specific admin command */
    memset(&cmd, 0, sizeof(cmd));
    cmd.opcode = 0xC0;  /* Vendor-specific: Get P2P IOVA Info */
    cmd.addr = (uint64_t)&info;
    cmd.data_len = sizeof(info);
    
    /* Send command */
    ret = ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd);
    if (ret < 0) {
        perror("Failed to send admin command");
        printf("\nThis could mean:\n");
        printf("  1. P2P not configured (missing p2p-gpu property)\n");
        printf("  2. GPU device not found or not accessible\n");
        printf("  3. IOMMU mapping failed\n");
        close(fd);
        return 1;
    }
    
    printf("✓ Command succeeded!\n\n");
    
    /* Display results */
    printf("===========================================\n");
    printf("P2P IOVA Addresses (for GPU access)\n");
    printf("===========================================\n");
    printf("SQE IOVA:       0x%016lx (size: 0x%x)\n", info.sqe_iova, info.sqe_size);
    printf("CQE IOVA:       0x%016lx (size: 0x%x)\n", info.cqe_iova, info.cqe_size);
    printf("Doorbell IOVA:  0x%016lx (size: 0x%x)\n", info.doorbell_iova, info.doorbell_size);
    printf("Queue Depth:    %u\n", info.queue_depth);
    printf("===========================================\n\n");
    
    printf("✅ P2P initialization successful!\n");
    printf("These IOVA addresses can now be used by the GPU\n");
    printf("to directly access NVMe queues and doorbells.\n\n");
    
    close(fd);
    return 0;
}

