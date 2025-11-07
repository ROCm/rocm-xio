/*
 * Test GPU access to hardcoded IOVA doorbell address
 */

#include <stdio.h>

#include <hip/hip_runtime.h>

#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <sys/mman.h>

#define DOORBELL_IOVA 0x1000020000UL // Hardcoded from P2P vendor command

__global__ void test_iova_access(unsigned long iova_addr, uint32_t* results) {
  if (threadIdx.x == 0) {
    results[0] = 0xDEADBEEF; // Marker
    __threadfence_system();

    printf("GPU: Trying to access IOVA 0x%lx\n", iova_addr);

    // Try to cast IOVA as pointer and access
    volatile uint32_t* doorbell = (volatile uint32_t*)iova_addr;

    uint32_t val = *doorbell;
    results[1] = val;

    printf("GPU: Read value = %u\n", val);

    *doorbell = val + 1;
    __threadfence_system();

    results[2] = *doorbell;
    printf("GPU: Wrote %u, read back %u\n", val + 1, results[2]);
  }
}

int main() {
  printf("===========================================\n");
  printf("Hardcoded IOVA Test\n");
  printf("===========================================\n\n");

  printf("Testing GPU access to IOVA: 0x%lx\n\n", DOORBELL_IOVA);

  // Initialize HIP
  hipSetDevice(0);

  uint32_t* d_results;
  uint32_t h_results[3] = {0};
  hipMalloc(&d_results, 3 * sizeof(uint32_t));

  printf("Launching GPU kernel...\n");

  hipLaunchKernelGGL(test_iova_access, dim3(1), dim3(1), 0, 0, DOORBELL_IOVA,
                     d_results);

  hipError_t err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    printf("Sync error: %s\n", hipGetErrorString(err));
  }

  hipMemcpy(h_results, d_results, 3 * sizeof(uint32_t), hipMemcpyDeviceToHost);

  printf("\nResults:\n");
  printf("  Marker:  0x%08x (expected 0xDEADBEEF)\n", h_results[0]);
  printf("  Read:    %u\n", h_results[1]);
  printf("  Wrote:   %u\n", h_results[2]);

  if (h_results[0] == 0xDEADBEEF) {
    printf("\n✓ Kernel executed\n");
    if (h_results[2] == h_results[1] + 1) {
      printf("✅✅✅ SUCCESS! GPU accessed IOVA doorbell! ✅✅✅\n");
    } else {
      printf("⚠️  Kernel ran but access failed\n");
    }
  } else {
    printf("\n✗ Kernel didn't execute\n");
  }

  hipFree(d_results);

  printf("\n===========================================\n");
  return 0;
}
