// Comprehensive HIP debug test
#include <hip/hip_runtime.h>
#include <stdio.h>

#define CHECK_HIP(cmd) \
    do { \
        hipError_t error = (cmd); \
        if (error != hipSuccess) { \
            fprintf(stderr, "HIP error at %s:%d: %s (%d)\n", __FILE__, __LINE__, \
                    hipGetErrorString(error), error); \
        } else { \
            printf("✓ %s\n", #cmd); \
        } \
    } while(0)

__global__ void test_kernel(int *result) {
    if (threadIdx.x == 0) {
        *result = 42;
        printf("GPU: Kernel executed! ThreadIdx=%d, BlockIdx=%d\n", threadIdx.x, blockIdx.x);
    }
}

int main() {
    printf("=== HIP Debug Test ===\n\n");
    
    // Check device count
    int device_count = 0;
    CHECK_HIP(hipGetDeviceCount(&device_count));
    printf("Device count: %d\n\n", device_count);
    
    if (device_count == 0) {
        fprintf(stderr, "No HIP devices found!\n");
        return 1;
    }
    
    // Get device properties
    hipDeviceProp_t prop;
    CHECK_HIP(hipGetDeviceProperties(&prop, 0));
    printf("Device 0: %s\n", prop.name);
    printf("  Compute capability: %d.%d\n", prop.major, prop.minor);
    printf("  Memory: %lu MB\n", prop.totalGlobalMem / (1024*1024));
    printf("  Can map host memory: %d\n", prop.canMapHostMemory);
    printf("\n");
    
    // Set device
    CHECK_HIP(hipSetDevice(0));
    printf("\n");
    
    // Allocate device memory
    int *d_result = NULL;
    CHECK_HIP(hipMalloc(&d_result, sizeof(int)));
    CHECK_HIP(hipMemset(d_result, 0, sizeof(int)));
    printf("\n");
    
    // Launch kernel
    printf("Launching kernel...\n");
    hipLaunchKernelGGL(test_kernel, dim3(1), dim3(1), 0, 0, d_result);
    
    // Check for launch errors
    CHECK_HIP(hipGetLastError());
    printf("\n");
    
    // Sync
    printf("Synchronizing...\n");
    CHECK_HIP(hipDeviceSynchronize());
    printf("\n");
    
    // Copy result back
    int h_result = 0;
    CHECK_HIP(hipMemcpy(&h_result, d_result, sizeof(int), hipMemcpyDeviceToHost));
    
    printf("Result: %d (expected 42)\n", h_result);
    printf("%s\n", h_result == 42 ? "✅ SUCCESS" : "❌ FAILURE");
    
    CHECK_HIP(hipFree(d_result));
    return h_result == 42 ? 0 : 1;
}

