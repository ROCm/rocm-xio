// Basic HIP test to verify GPU is working
#include <hip/hip_runtime.h>
#include <stdio.h>

__global__ void test_kernel(int *result) {
    if (threadIdx.x == 0) {
        *result = 42;
        printf("GPU: Kernel executed!\n");
    }
}

int main() {
    printf("Testing basic HIP functionality...\n");
    
    int *d_result, h_result = 0;
    hipMalloc(&d_result, sizeof(int));
    
    hipLaunchKernelGGL(test_kernel, dim3(1), dim3(1), 0, 0, d_result);
    hipDeviceSynchronize();
    
    hipMemcpy(&h_result, d_result, sizeof(int), hipMemcpyDeviceToHost);
    
    printf("Result: %d (expected 42)\n", h_result);
    printf("%s\n", h_result == 42 ? "✓ SUCCESS" : "✗ FAILURE");
    
    hipFree(d_result);
    return h_result == 42 ? 0 : 1;
}
