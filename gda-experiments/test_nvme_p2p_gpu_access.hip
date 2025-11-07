/*
 * Test GPU Direct Access to NVMe P2P Memory
 * 
 * This program:
 * 1. Gets IOVA addresses from the NVMe P2P vendor command
 * 2. Maps those IOVAs as GPU-accessible pointers
 * 3. Launches a GPU kernel to read/write the memory
 * 4. Validates that GPU can access the emulated NVMe memory
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/nvme_ioctl.h>
#include <hip/hip_runtime.h>

/* P2P IOVA Info structure */
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

/* GPU kernel to test memory access */
__global__ void test_p2p_access(uint64_t *iova_addr, uint32_t *results, int test_type)
{
    int tid = threadIdx.x;
    
    if (tid == 0) {
        // Try to read from the IOVA address
        if (test_type == 0) {
            // Read test
            results[0] = 0xDEADBEEF; // Mark as attempted
            uint64_t value = *iova_addr;
            results[1] = (uint32_t)(value & 0xFFFFFFFF);
            results[2] = (uint32_t)(value >> 32);
            results[3] = 0xC0FFEE; // Success marker
        } else if (test_type == 1) {
            // Write test
            results[0] = 0xCAFEBABE; // Mark as attempted
            *iova_addr = 0x123456789ABCDEF0ULL;
            results[1] = 0xB00; // Success marker
        }
    }
}

#define HIP_CHECK(cmd) \
    do { \
        hipError_t error = cmd; \
        if (error != hipSuccess) { \
            fprintf(stderr, "HIP error: %s:%d: %s (%d)\n", \
                    __FILE__, __LINE__, hipGetErrorString(error), error); \
            exit(EXIT_FAILURE); \
        } \
    } while(0)

int main(int argc, char **argv)
{
    int fd;
    struct nvme_admin_cmd cmd;
    struct nvme_p2p_iova_info info;
    const char *nvme_dev = "/dev/nvme0";
    int ret;
    
    uint32_t *d_results = NULL;
    uint32_t h_results[4] = {0};
    
    printf("===========================================\n");
    printf("GPU Direct Access Test for NVMe P2P\n");
    printf("===========================================\n\n");
    
    /* Initialize HIP */
    int device_count = 0;
    HIP_CHECK(hipGetDeviceCount(&device_count));
    printf("Found %d HIP device(s)\n", device_count);
    
    if (device_count == 0) {
        fprintf(stderr, "ERROR: No HIP devices found\n");
        return 1;
    }
    
    HIP_CHECK(hipSetDevice(0));
    
    hipDeviceProp_t prop;
    HIP_CHECK(hipGetDeviceProperties(&prop, 0));
    printf("Using GPU: %s\n\n", prop.name);
    
    /* Get P2P IOVA addresses from NVMe */
    printf("Step 1: Getting P2P IOVA addresses...\n");
    
    fd = open(nvme_dev, O_RDONLY);
    if (fd < 0) {
        perror("Failed to open NVMe device");
        return 1;
    }
    
    memset(&cmd, 0, sizeof(cmd));
    cmd.opcode = 0xC0;
    cmd.addr = (uint64_t)&info;
    cmd.data_len = sizeof(info);
    
    ret = ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd);
    if (ret < 0) {
        perror("Failed to get P2P info");
        close(fd);
        return 1;
    }
    
    close(fd);
    
    printf("✓ Got P2P IOVA addresses:\n");
    printf("  SQE IOVA:       0x%016lx\n", info.sqe_iova);
    printf("  CQE IOVA:       0x%016lx\n", info.cqe_iova);
    printf("  Doorbell IOVA:  0x%016lx\n\n", info.doorbell_iova);
    
    /* Allocate results buffer on GPU */
    HIP_CHECK(hipMalloc(&d_results, 4 * sizeof(uint32_t)));
    HIP_CHECK(hipMemset(d_results, 0, 4 * sizeof(uint32_t)));
    
    /* Test 1: Try to read from SQE IOVA */
    printf("Step 2: Testing GPU read access to SQE region...\n");
    printf("  Launching GPU kernel to read from IOVA 0x%lx...\n", info.sqe_iova);
    
    // Cast IOVA to pointer for GPU
    uint64_t *sqe_ptr = (uint64_t*)info.sqe_iova;
    
    hipLaunchKernelGGL(test_p2p_access, dim3(1), dim3(1), 0, 0,
                       sqe_ptr, d_results, 0);
    
    HIP_CHECK(hipDeviceSynchronize());
    HIP_CHECK(hipMemcpy(h_results, d_results, 4 * sizeof(uint32_t), hipMemcpyDeviceToHost));
    
    printf("  Kernel execution completed\n");
    printf("  Results: [0x%08x, 0x%08x, 0x%08x, 0x%08x]\n",
           h_results[0], h_results[1], h_results[2], h_results[3]);
    
    if (h_results[0] == 0xDEADBEEF && h_results[3] == 0xC0FFEE) {
        printf("  ✓ GPU successfully READ from NVMe P2P memory!\n");
        printf("  ✓ Value read: 0x%08x%08x\n\n", h_results[2], h_results[1]);
    } else if (h_results[0] == 0xDEADBEEF) {
        printf("  ⚠ GPU kernel executed but may have faulted\n\n");
    } else {
        printf("  ✗ GPU kernel did not execute properly\n\n");
    }
    
    /* Test 2: Try to write to CQE IOVA */
    printf("Step 3: Testing GPU write access to CQE region...\n");
    printf("  Launching GPU kernel to write to IOVA 0x%lx...\n", info.cqe_iova);
    
    HIP_CHECK(hipMemset(d_results, 0, 4 * sizeof(uint32_t)));
    
    uint64_t *cqe_ptr = (uint64_t*)info.cqe_iova;
    
    hipLaunchKernelGGL(test_p2p_access, dim3(1), dim3(1), 0, 0,
                       cqe_ptr, d_results, 1);
    
    HIP_CHECK(hipDeviceSynchronize());
    HIP_CHECK(hipMemcpy(h_results, d_results, 4 * sizeof(uint32_t), hipMemcpyDeviceToHost));
    
    printf("  Kernel execution completed\n");
    printf("  Results: [0x%08x, 0x%08x, 0x%08x, 0x%08x]\n",
           h_results[0], h_results[1], h_results[2], h_results[3]);
    
    if (h_results[0] == 0xCAFEBABE && h_results[1] == 0xB00) {
        printf("  ✓ GPU successfully WROTE to NVMe P2P memory!\n\n");
    } else if (h_results[0] == 0xCAFEBABE) {
        printf("  ⚠ GPU kernel executed but write may have faulted\n\n");
    } else {
        printf("  ✗ GPU kernel did not execute properly\n\n");
    }
    
    /* Cleanup */
    HIP_CHECK(hipFree(d_results));
    
    printf("===========================================\n");
    printf("GPU Direct Access Test Complete\n");
    printf("===========================================\n");
    
    return 0;
}

