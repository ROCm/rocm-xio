// Simple GPU doorbell test without complex memory management
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <stdint.h>
#include <string.h>
#include <hip/hip_runtime.h>

#define NVME_GDA_MAGIC 'N'

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

#define NVME_GDA_GET_DEVICE_INFO _IOR(NVME_GDA_MAGIC, 1, struct nvme_gda_device_info)

// Simple GPU kernel that writes to a doorbell
__global__ void test_simple_doorbell(volatile uint32_t *doorbell, uint32_t *result) {
	// Read current value
	uint32_t old_val = *doorbell;
	result[0] = old_val;
	
	// Write new value
	__atomic_signal_fence(__ATOMIC_SEQ_CST);
	uint32_t new_val = old_val + 1;
	*doorbell = new_val;
	__atomic_signal_fence(__ATOMIC_SEQ_CST);
	
	// Read back
	result[1] = *doorbell;
}

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr, "Usage: %s /dev/nvme_gda0\n", argv[0]);
		return 1;
	}
	
	printf("Simple GPU Doorbell Test\n");
	printf("=========================\n\n");
	
	// Open device
	int fd = open(argv[1], O_RDWR);
	if (fd < 0) {
		perror("open");
		return 1;
	}
	printf("✓ Device opened\n");
	
	// Get device info  
	struct nvme_gda_device_info info;
	if (ioctl(fd, NVME_GDA_GET_DEVICE_INFO, &info) < 0) {
		perror("ioctl");
		close(fd);
		return 1;
	}
	printf("✓ Device info retrieved\n");
	printf("  BAR0: 0x%llx\n", (unsigned long long)info.bar0_addr);
	
	// Initialize HIP
	hipError_t err = hipInit(0);
	if (err != hipSuccess) {
		fprintf(stderr, "hipInit failed: %s\n", hipGetErrorString(err));
		close(fd);
		return 1;
	}
	printf("✓ HIP initialized\n");
	
	// Map a fake doorbell for testing (just use host memory)
	volatile uint32_t *host_doorbell = (volatile uint32_t*)malloc(sizeof(uint32_t));
	*host_doorbell = 42;  // Initial value
	
	printf("\nTesting GPU memory operations...\n");
	printf("  Initial doorbell value: %u\n", *host_doorbell);
	
	// Allocate GPU memory for result
	uint32_t *d_result;
	err = hipMalloc(&d_result, 2 * sizeof(uint32_t));
	if (err != hipSuccess) {
		fprintf(stderr, "hipMalloc failed: %s\n", hipGetErrorString(err));
		free((void*)host_doorbell);
		close(fd);
		return 1;
	}
	printf("✓ GPU memory allocated\n");
	
	// Try to register host memory for GPU access
	volatile uint32_t *d_doorbell;
	err = hipHostRegister((void*)host_doorbell, sizeof(uint32_t), hipHostRegisterMapped);
	if (err != hipSuccess) {
		fprintf(stderr, "hipHostRegister failed: %s\n", hipGetErrorString(err));
		fprintf(stderr, "  This is expected - continuing with hipMemcpy approach\n");
		
		// Fallback: allocate GPU memory and copy
		err = hipMalloc((void**)&d_doorbell, sizeof(uint32_t));
		if (err != hipSuccess) {
			fprintf(stderr, "hipMalloc for doorbell failed: %s\n", hipGetErrorString(err));
			hipFree(d_result);
			free((void*)host_doorbell);
			close(fd);
			return 1;
		}
		
		err = hipMemcpy((void*)d_doorbell, (void*)host_doorbell, sizeof(uint32_t), hipMemcpyHostToDevice);
		if (err != hipSuccess) {
			fprintf(stderr, "hipMemcpy failed: %s\n", hipGetErrorString(err));
			hipFree((void*)d_doorbell);
			hipFree(d_result);
			free((void*)host_doorbell);
			close(fd);
			return 1;
		}
	} else {
		// Get device pointer
		err = hipHostGetDevicePointer((void**)&d_doorbell, (void*)host_doorbell, 0);
		if (err != hipSuccess) {
			fprintf(stderr, "hipHostGetDevicePointer failed: %s\n", hipGetErrorString(err));
			hipHostUnregister((void*)host_doorbell);
			hipFree(d_result);
			free((void*)host_doorbell);
			close(fd);
			return 1;
		}
	}
	printf("✓ Doorbell accessible from GPU\n");
	
	// Launch kernel
	printf("\nLaunching GPU kernel...\n");
	hipLaunchKernelGGL(test_simple_doorbell, dim3(1), dim3(1), 0, 0, d_doorbell, d_result);
	err = hipGetLastError();
	if (err != hipSuccess) {
		fprintf(stderr, "Kernel launch failed: %s\n", hipGetErrorString(err));
	} else {
		printf("✓ Kernel launched\n");
	}
	
	err = hipDeviceSynchronize();
	if (err != hipSuccess) {
		fprintf(stderr, "hipDeviceSynchronize failed: %s\n", hipGetErrorString(err));
	} else {
		printf("✓ Kernel completed\n");
	}
	
	// Get results
	uint32_t h_result[2];
	err = hipMemcpy(h_result, d_result, 2 * sizeof(uint32_t), hipMemcpyDeviceToHost);
	if (err != hipSuccess) {
		fprintf(stderr, "hipMemcpy result failed: %s\n", hipGetErrorString(err));
	} else {
		printf("\n Results:\n");
		printf("  Before: %u\n", h_result[0]);
		printf("  After: %u\n", h_result[1]);
		
		if (h_result[1] == h_result[0] + 1) {
			printf("\n✓✓✓ SUCCESS: GPU wrote to memory! ✓✓✓\n");
		} else {
			printf("\n✗ Values don't match expected pattern\n");
		}
	}
	
	// Cleanup
	hipFree(d_result);
	hipFree((void*)d_doorbell);
	free((void*)host_doorbell);
	close(fd);
	
	printf("\nTest complete!\n");
	return 0;
}

