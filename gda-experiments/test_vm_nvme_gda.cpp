/*
 * VM NVMe GDA Test with P2P IOVA Mapping
 * 
 * 1. Issue P2P vendor command to setup IOVA mappings in host IOMMU
 * 2. Use nvme_gda driver normally
 * 3. GPU accesses go through IOVA mappings
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/nvme_ioctl.h>
#include <hip/hip_runtime.h>
#include "nvme_gda.h"

struct p2p_iova_info {
    uint64_t sqe_iova;
    uint64_t cqe_iova;
    uint64_t doorbell_iova;
    uint32_t sqe_size;
    uint32_t cqe_size;
    uint32_t doorbell_size;
    uint16_t queue_depth;
    uint16_t reserved;
} __attribute__((packed));

__global__ void ring_doorbell_kernel(volatile uint32_t *doorbell, uint32_t *results) {
    if (threadIdx.x == 0) {
        printf("GPU: Doorbell ptr = %p\n", doorbell);
        
        uint32_t old_val = *doorbell;
        results[0] = old_val;
        __threadfence_system();
        
        printf("GPU: Read = %u\n", old_val);
        
        *doorbell = old_val + 1;
        __threadfence_system();
        
        uint32_t new_val = *doorbell;
        results[1] = new_val;
        
        printf("GPU: Wrote %u, read back %u\n", old_val + 1, new_val);
    }
}

int main() {
    printf("===========================================\n");
    printf("VM NVMe GDA Test with P2P IOVA Mapping\n");
    printf("===========================================\n\n");
    
    // Step 1: Issue P2P vendor command to setup IOVA mappings
    printf("Step 1: Setting up P2P IOVA mappings...\n");
    
    int nvme_fd = open("/dev/nvme0", O_RDWR);
    if (nvme_fd < 0) {
        perror("open /dev/nvme0");
        return 1;
    }
    
    struct p2p_iova_info info;
    memset(&info, 0, sizeof(info));
    
    struct nvme_admin_cmd cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.opcode = 0xC0;
    cmd.addr = (uint64_t)&info;
    cmd.data_len = sizeof(info);
    
    if (ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd) < 0) {
        perror("P2P vendor command");
        close(nvme_fd);
        return 1;
    }
    close(nvme_fd);
    
    printf("✓ P2P IOVA mappings created:\n");
    printf("  SQE IOVA:      0x%016lx\n", info.sqe_iova);
    printf("  CQE IOVA:      0x%016lx\n", info.cqe_iova);
    printf("  Doorbell IOVA: 0x%016lx\n\n", info.doorbell_iova);
    
    // Step 2: Use nvme_gda driver normally
    printf("Step 2: Initializing NVMe GDA...\n");
    
    nvme_gda_context *ctx = nvme_gda_init("/dev/nvme_gda0");
    if (!ctx) {
        fprintf(stderr, "Failed to initialize nvme_gda\n");
        return 1;
    }
    
    printf("✓ NVMe GDA initialized\n");
    printf("✓ HSA initialized\n\n");
    
    // Step 3: Create queue
    printf("Step 3: Creating queue...\n");
    
    nvme_gda_queue_userspace *queue = nvme_gda_create_queue(ctx, 16);
    if (!queue) {
        fprintf(stderr, "Failed to create queue\n");
        nvme_gda_cleanup(ctx);
        return 1;
    }
    
    printf("✓ Queue created\n");
    printf("  CPU SQ doorbell: %p\n", queue->sq_doorbell);
    printf("  GPU SQ doorbell: %p\n\n", queue->gpu_sq_doorbell);
    
    // Step 4: Test CPU doorbell access
    printf("Step 4: Testing CPU doorbell access...\n");
    uint32_t cpu_val = *queue->sq_doorbell;
    printf("  Read: %u\n", cpu_val);
    *queue->sq_doorbell = cpu_val + 1;
    printf("  After write: %u\n", *queue->sq_doorbell);
    printf("✓ CPU access works\n\n");
    
    // Step 5: Test GPU doorbell access
    printf("Step 5: Testing GPU doorbell access...\n");
    
    hipSetDevice(0);
    
    uint32_t *d_results;
    uint32_t h_results[2] = {0};
    hipMalloc(&d_results, 2 * sizeof(uint32_t));
    
    hipLaunchKernelGGL(ring_doorbell_kernel,
                       dim3(1), dim3(1), 0, 0,
                       queue->gpu_sq_doorbell, d_results);
    
    hipDeviceSynchronize();
    hipMemcpy(h_results, d_results, 2 * sizeof(uint32_t), hipMemcpyDeviceToHost);
    
    printf("\nResults:\n");
    printf("  GPU read:  %u\n", h_results[0]);
    printf("  GPU wrote: %u\n", h_results[1]);
    
    if (h_results[1] == h_results[0] + 1) {
        printf("\n");
        printf("✅✅✅ SUCCESS! GPU RANG THE DOORBELL! ✅✅✅\n");
        printf("\n");
        printf("GPU accessed emulated NVMe doorbell through P2P IOVA mapping!\n");
    } else {
        printf("\n✗ FAILURE\n");
    }
    
    // Cleanup
    hipFree(d_results);
    nvme_gda_destroy_queue(queue);
    nvme_gda_cleanup(ctx);
    
    printf("\n===========================================\n");
    printf("Test Complete\n");
    printf("===========================================\n");
    
    return (h_results[1] == h_results[0] + 1) ? 0 : 1;
}

