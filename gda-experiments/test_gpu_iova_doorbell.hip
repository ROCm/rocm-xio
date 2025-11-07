/*
 * Test GPU access to NVMe doorbell using IOVA addresses from P2P vendor command
 * No BAR0 mmap - we use the IOVA addresses directly
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/nvme_ioctl.h>
#include <hip/hip_runtime.h>

#define CHECK_HIP(cmd) \
    do { \
        hipError_t error = (cmd); \
        if (error != hipSuccess) { \
            fprintf(stderr, "HIP error at %s:%d: %s\n", __FILE__, __LINE__, \
                    hipGetErrorString(error)); \
            exit(1); \
        } \
    } while(0)

struct p2p_info {
    unsigned long sqe_iova;
    unsigned long cqe_iova;
    unsigned long doorbell_iova;
    unsigned int sqe_size;
    unsigned int cqe_size;
    unsigned int doorbell_size;
    unsigned short queue_depth;
    unsigned short reserved;
} __attribute__((packed));

// GPU kernel to access doorbell via IOVA
__global__ void ring_doorbell_kernel(unsigned long doorbell_iova, uint32_t *results) {
    if (threadIdx.x == 0 && blockIdx.x == 0) {
        // Cast IOVA to pointer
        volatile uint32_t *doorbell = (volatile uint32_t*)doorbell_iova;
        
        results[0] = 0xDEADBEEF; // Marker that kernel started
        __threadfence_system();
        
        printf("GPU: Kernel started! Doorbell IOVA: 0x%lx\n", doorbell_iova);
        
        // Try to read current value
        uint32_t old_val = *doorbell;
        results[1] = old_val;
        
        printf("GPU: Read doorbell value: %u\n", old_val);
        
        // Try to write new value
        *doorbell = old_val + 1;
        __threadfence_system();
        
        // Read back
        uint32_t new_val = *doorbell;
        results[2] = new_val;
        
        printf("GPU: Wrote %u, read back %u\n", old_val + 1, new_val);
    }
}

int main() {
    printf("=========================================\n");
    printf("GPU IOVA Doorbell Test\n");
    printf("=========================================\n\n");
    
    // Step 1: Get P2P IOVA addresses via vendor command
    printf("Step 1: Getting P2P IOVA addresses...\n");
    
    int fd = open("/dev/nvme0", O_RDWR);
    if (fd < 0) {
        perror("Failed to open /dev/nvme0");
        return 1;
    }
    
    struct p2p_info info;
    memset(&info, 0, sizeof(info));
    
    struct nvme_admin_cmd cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.opcode = 0xC0;  // Vendor-specific P2P command
    cmd.addr = (unsigned long)&info;
    cmd.data_len = sizeof(info);
    
    if (ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd) < 0) {
        perror("P2P vendor command failed");
        close(fd);
        return 1;
    }
    close(fd);
    
    printf("✓ Got P2P IOVA addresses\n");
    printf("  SQE IOVA:      0x%016lx\n", info.sqe_iova);
    printf("  CQE IOVA:      0x%016lx\n", info.cqe_iova);
    printf("  Doorbell IOVA: 0x%016lx\n\n", info.doorbell_iova);
    
    // Step 2: Initialize HIP
    printf("Step 2: Initializing HIP...\n");
    CHECK_HIP(hipSetDevice(0));
    printf("✓ HIP initialized\n\n");
    
    // Allocate results buffer
    uint32_t *d_results;
    uint32_t h_results[3] = {0};
    CHECK_HIP(hipMalloc(&d_results, 3 * sizeof(uint32_t)));
    CHECK_HIP(hipMemset(d_results, 0, 3 * sizeof(uint32_t)));
    
    // Step 3: Launch GPU kernel with IOVA address
    printf("Step 3: Launching GPU kernel with doorbell IOVA...\n");
    
    hipLaunchKernelGGL(ring_doorbell_kernel, 
                       dim3(1), dim3(1), 0, 0,
                       info.doorbell_iova, d_results);
    
    hipError_t err = hipGetLastError();
    if (err != hipSuccess) {
        fprintf(stderr, "Kernel launch error: %s\n", hipGetErrorString(err));
    }
    
    err = hipDeviceSynchronize();
    if (err != hipSuccess) {
        fprintf(stderr, "Synchronize error: %s\n", hipGetErrorString(err));
    }
    
    // Get results
    CHECK_HIP(hipMemcpy(h_results, d_results, 3 * sizeof(uint32_t), hipMemcpyDeviceToHost));
    
    printf("\nResults:\n");
    printf("  Kernel started marker: 0x%08x (expected 0xDEADBEEF)\n", h_results[0]);
    printf("  GPU read value:        %u\n", h_results[1]);
    printf("  GPU wrote value:       %u\n", h_results[2]);
    
    if (h_results[0] == 0xDEADBEEF) {
        printf("\n✓ Kernel executed!\n");
        if (h_results[2] == h_results[1] + 1) {
            printf("✅✅✅ SUCCESS: GPU ACCESSED DOORBELL VIA IOVA! ✅✅✅\n");
        } else {
            printf("⚠️  Kernel ran but doorbell read/write didn't work as expected\n");
        }
    } else {
        printf("\n✗ Kernel didn't execute properly\n");
    }
    
    // Cleanup
    CHECK_HIP(hipFree(d_results));
    
    printf("\n=========================================\n");
    printf("Test Complete\n");
    printf("=========================================\n");
    
    return 0;
}

