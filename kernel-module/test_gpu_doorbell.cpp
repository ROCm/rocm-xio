/*
 * Test program for GPU doorbell access
 * Tests if GPU can write to NVMe doorbell via peer-to-peer MMIO
 */

#include <iostream>

#include <hip/hip_runtime.h>

#include "../tester/gpu-doorbell-map.h"

#define HIP_CHECK(cmd)                                                         \
  do {                                                                         \
    hipError_t error = (cmd);                                                  \
    if (error != hipSuccess) {                                                 \
      std::cerr << "HIP error " << error << ": " << hipGetErrorString(error)   \
                << " at " << __FILE__ << ":" << __LINE__ << std::endl;         \
      return -1;                                                               \
    }                                                                          \
  } while (0)

// Simple GPU kernel to test doorbell write
__global__ void test_doorbell_write(uint32_t* doorbell_ptr, uint32_t value) {
  if (threadIdx.x == 0 && blockIdx.x == 0) {
    // Try to write to doorbell
    *doorbell_ptr = value;
    __threadfence_system();
  }
}

int main(int argc, char** argv) {
  std::cout << "=== GPU Doorbell Access Test ===" << std::endl;
  std::cout << "Testing if GPU can write to NVMe doorbell via P2P MMIO\n"
            << std::endl;

  // Map doorbell for GPU access
  gpu_doorbell::DoorbellMapping mapping = {0};
  uint16_t queue_id = 1; // Test with queue 1

  if (gpu_doorbell::map_doorbell_for_gpu(queue_id, &mapping) < 0) {
    std::cerr << "Failed to map doorbell" << std::endl;
    return 1;
  }

  std::cout << "\nMapping Results:" << std::endl;
  std::cout << "  CPU pointer: " << mapping.cpu_ptr << std::endl;
  std::cout << "  GPU pointer: " << mapping.gpu_ptr << std::endl;
  std::cout << "  Bus address: 0x" << std::hex << mapping.bus_addr << std::dec
            << std::endl;

  if (mapping.gpu_ptr == nullptr) {
    std::cout << "\n❌ GPU doorbell access NOT available" << std::endl;
    std::cout << "   GPU pointer is NULL - HSA could not map MMIO region"
              << std::endl;
    std::cout << "   This system requires CPU-hybrid mode" << std::endl;
    gpu_doorbell::unmap_doorbell(&mapping);
    return 0; // Not an error, just informational
  }

  // Test CPU write first
  std::cout << "\n=== Test 1: CPU Write ===" << std::endl;
  volatile uint32_t* cpu_db = (volatile uint32_t*)mapping.cpu_ptr;
  uint32_t original_value = *cpu_db;
  std::cout << "  Original doorbell value: " << original_value << std::endl;

  *cpu_db = 0x12345678;
  __sync_synchronize();
  std::cout << "  Wrote 0x12345678 from CPU" << std::endl;

  uint32_t readback = *cpu_db;
  std::cout << "  Read back: 0x" << std::hex << readback << std::dec
            << std::endl;

  // Restore original
  *cpu_db = original_value;
  __sync_synchronize();

  if (readback == 0x12345678) {
    std::cout << "  ✓ CPU write successful" << std::endl;
  } else {
    std::cout
      << "  ⚠️  CPU write mismatch (may be normal for write-only registers)"
      << std::endl;
  }

  // Test GPU write
  std::cout << "\n=== Test 2: GPU Write ===" << std::endl;
  std::cout << "  Launching GPU kernel to write to doorbell..." << std::endl;

  // Launch kernel
  hipLaunchKernelGGL(test_doorbell_write, dim3(1), dim3(1), 0, 0,
                     (uint32_t*)mapping.gpu_ptr, 0xABCD1234);

  hipError_t err = hipDeviceSynchronize();

  if (err == hipSuccess) {
    std::cout << "  ✓ GPU kernel completed without errors!" << std::endl;
    std::cout << "  🎉 GPU CAN write to NVMe doorbell via P2P MMIO!"
              << std::endl;

    // Try to read back (may not work for write-only registers)
    readback = *cpu_db;
    std::cout << "  Read back from CPU: 0x" << std::hex << readback << std::dec
              << std::endl;

    // Restore
    *cpu_db = original_value;

  } else {
    std::cout << "  ❌ GPU kernel failed: " << hipGetErrorString(err)
              << std::endl;
    std::cout << "  Error code: " << err << std::endl;

    if (err == hipErrorIllegalAddress || err == 700) {
      std::cout << "  This is a page fault - GPU cannot access the MMIO region"
                << std::endl;
      std::cout << "  System requires CPU-hybrid mode" << std::endl;
    }
  }

  // Check dmesg for GPU page faults
  std::cout << "\n=== Check System Logs ===" << std::endl;
  std::cout << "Run: dmesg | tail -20" << std::endl;
  std::cout << "Look for 'amdgpu' page fault messages" << std::endl;

  gpu_doorbell::unmap_doorbell(&mapping);

  std::cout << "\n=== Test Complete ===" << std::endl;
  return 0;
}
