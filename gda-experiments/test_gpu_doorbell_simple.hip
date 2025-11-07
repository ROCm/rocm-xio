// Simplified GPU doorbell test
// Just passes the GPU doorbell pointer directly to a kernel

#include <stdio.h>
#include <stdlib.h>
#include <hip/hip_runtime.h>
#include "gda-experiments/nvme-gda/include/nvme_gda.h"

#define CHECK_HIP(cmd) \
	do { \
		hipError_t error = (cmd); \
		if (error != hipSuccess) { \
			fprintf(stderr, "HIP error %d at %s:%d: %s\n", error, __FILE__, __LINE__, hipGetErrorString(error)); \
			exit(1); \
		} \
	} while(0)

// Simple kernel that just reads/writes the doorbell
__global__ void test_doorbell_simple(volatile uint32_t *doorbell, uint32_t *results) {
	if (threadIdx.x == 0 && blockIdx.x == 0) {
		// Read current value
		uint32_t old_val = *doorbell;
		results[0] = old_val;
		
		printf("GPU: Doorbell at %p, read value %u\n", doorbell, old_val);
		
		// Write new value
		*doorbell = old_val + 1;
		
		// Read back
		uint32_t new_val = *doorbell;
		results[1] = new_val;
		
		printf("GPU: Wrote %u, read back %u\n", old_val + 1, new_val);
	}
}

int main() {
	printf("Simple GPU Doorbell Test\n");
	printf("=========================\n\n");
	
	// Initialize
	nvme_gda_context *ctx = nvme_gda_init("/dev/nvme_gda0");
	if (!ctx) {
		fprintf(stderr, "Failed to init\n");
		return 1;
	}
	
	// Create queue
	nvme_gda_queue_userspace *queue = nvme_gda_create_queue(ctx, 16);
	if (!queue) {
		fprintf(stderr, "Failed to create queue\n");
		nvme_gda_cleanup(ctx);
		return 1;
	}
	
	printf("GPU doorbell pointer: %p\n", queue->gpu_sq_doorbell);
	printf("CPU doorbell pointer: %p\n\n", queue->sq_doorbell);
	
	// Allocate result buffer
	uint32_t *d_results;
	uint32_t h_results[2] = {0, 0};
	CHECK_HIP(hipMalloc(&d_results, 2 * sizeof(uint32_t)));
	
	printf("Launching kernel...\n");
	
	// Launch kernel with GPU doorbell pointer directly
	hipLaunchKernelGGL(test_doorbell_simple, 
	                   dim3(1), dim3(1), 0, 0,
	                   queue->gpu_sq_doorbell, d_results);
	
	CHECK_HIP(hipGetLastError());
	CHECK_HIP(hipDeviceSynchronize());
	
	// Get results
	CHECK_HIP(hipMemcpy(h_results, d_results, 2 * sizeof(uint32_t), hipMemcpyDeviceToHost));
	
	printf("\nResults:\n");
	printf("  Before: %u\n", h_results[0]);
	printf("  After:  %u\n", h_results[1]);
	
	if (h_results[1] == h_results[0] + 1) {
		printf("\n✓ SUCCESS: GPU rang the doorbell!\n");
	} else {
		printf("\n✗ FAILURE\n");
	}
	
	// Cleanup
	CHECK_HIP(hipFree(d_results));
	nvme_gda_destroy_queue(queue);
	nvme_gda_cleanup(ctx);
	
	return 0;
}

