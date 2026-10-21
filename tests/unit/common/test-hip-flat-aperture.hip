// Unit test: verify hipHostMalloc gives flat aperture (GPU VA == CPU VA)
// and that hipHostGetDevicePointer after hipHostRegister does NOT.
// If GPU VA != CPU VA on a registered buffer, QEMU's shadow-ring polling
// GPA (derived from CPU VA via pagemap) will not match what the GPU kernel
// writes to (the GPU VA), breaking the pci-mmio-bridge path.
#include <hip/hip_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

int main(void) {
    int rc = 0;
    hipInit(0);

    // Test 1: hipHostMalloc must give flat aperture (GPU VA == CPU VA)
    void* buf = nullptr;
    hipHostMalloc(&buf, 8192, hipHostMallocDefault | hipHostMallocMapped);
    if (!buf) { fprintf(stderr, "FAIL: hipHostMalloc returned null\n"); return 1; }

    void* gpu = nullptr;
    hipError_t e = hipHostGetDevicePointer(&gpu, buf, 0);
    if (e != hipSuccess) {
        fprintf(stderr, "FAIL: hipHostGetDevicePointer: %s\n", hipGetErrorString(e));
        rc = 1;
    } else if (gpu != buf) {
        fprintf(stderr, "FAIL: flat aperture broken — cpu=%p gpu=%p\n"
                "  hipHostMalloc+Mapped must give GPU VA == CPU VA for the\n"
                "  pci-mmio-bridge shadow ring to be visible to QEMU.\n", buf, gpu);
        rc = 1;
    } else {
        printf("PASS: hipHostMalloc flat aperture cpu=%p == gpu=%p\n", buf, gpu);
    }
    hipHostFree(buf);

    // Test 2: plain mmap + hipHostRegister does NOT give flat aperture
    // (document known non-flat behaviour so we never accidentally rely on it)
    void* raw = mmap(nullptr, 4096+8192, PROT_READ|PROT_WRITE,
                     MAP_ANONYMOUS|MAP_PRIVATE, -1, 0);
    void* ring = (char*)raw + 4096;
    hipHostRegister(ring, 8192, hipHostRegisterMapped);
    void* gpu_ring = nullptr;
    hipHostGetDevicePointer(&gpu_ring, ring, 0);
    if (ring == gpu_ring) {
        printf("NOTE: mmap+hipHostRegister IS flat on this ROCm build"
               " (unexpected but not fatal)\n");
    } else {
        printf("NOTE: mmap+hipHostRegister not flat cpu=%p gpu=%p"
               " (use hipHostMalloc instead)\n", ring, gpu_ring);
    }
    hipHostUnregister(ring);
    munmap(raw, 4096+8192);

    return rc;
}
