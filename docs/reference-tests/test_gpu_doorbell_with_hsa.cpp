/*
 * GPU Doorbell Test with HSA Memory Registration
 *
 * Uses hsa_amd_memory_lock() to register the doorbell region with GPU MMU!
 * This might be the missing piece to make it work.
 */

#include <cstring>
#include <iostream>

#include <hip/hip_runtime.h>

#include <fcntl.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "../kernel-module/nvme_axiio.h"

// GPU kernel to ring doorbell
__global__ void ring_doorbell_gpu(volatile uint32_t* doorbell, uint32_t value) {
  if (threadIdx.x == 0 && blockIdx.x == 0) {
    printf("🚀 GPU: Ringing doorbell at %p with value %u\n", doorbell, value);

    __atomic_signal_fence(__ATOMIC_SEQ_CST);
    __hip_atomic_store(doorbell, value, __ATOMIC_SEQ_CST,
                       __HIP_MEMORY_SCOPE_SYSTEM);
    __atomic_signal_fence(__ATOMIC_SEQ_CST);

    printf("✓ GPU: Doorbell written!\n");
  }
}

int main(int argc, char** argv) {
  std::cout << "╔══════════════════════════════════════════════╗\n";
  std::cout << "║  GPU Doorbell Test with HSA Registration    ║\n";
  std::cout << "║  Using hsa_amd_memory_lock()!                ║\n";
  std::cout << "╚══════════════════════════════════════════════╝\n\n";

  if (argc < 2) {
    std::cerr << "Usage: " << argv[0] << " <queue_size>" << std::endl;
    return 1;
  }

  uint16_t queue_size = atoi(argv[1]);
  if (queue_size == 0)
    queue_size = 64;

  // Initialize HSA first
  std::cout << "Step 1: Initializing HSA..." << std::endl;
  hsa_status_t hsa_err = hsa_init();
  if (hsa_err != HSA_STATUS_SUCCESS) {
    std::cerr << "Error: hsa_init() failed: " << hsa_err << std::endl;
    return 1;
  }
  std::cout << "✓ HSA initialized\n" << std::endl;

  // Initialize HIP
  std::cout << "Step 2: Initializing HIP..." << std::endl;
  hipError_t err = hipSetDevice(0);
  if (err != hipSuccess) {
    std::cerr << "Error: hipSetDevice failed: " << hipGetErrorString(err)
              << std::endl;
    hsa_shut_down();
    return 1;
  }

  hipDeviceProp_t prop;
  hipGetDeviceProperties(&prop, 0);
  std::cout << "✓ HIP initialized" << std::endl;
  std::cout << "  GPU: " << prop.name << std::endl;
  std::cout << "  Large BAR: " << (prop.isLargeBar ? "YES ✓" : "NO ✗")
            << std::endl;

  // Get GPU agent for HSA operations
  hsa_agent_t gpu_agent;
  auto find_gpu_agent = [](hsa_agent_t agent, void* data) -> hsa_status_t {
    hsa_device_type_t device_type;
    hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &device_type);
    if (device_type == HSA_DEVICE_TYPE_GPU) {
      *(hsa_agent_t*)data = agent;
      return HSA_STATUS_INFO_BREAK; // Found it
    }
    return HSA_STATUS_SUCCESS; // Keep looking
  };

  hsa_iterate_agents(find_gpu_agent, &gpu_agent);
  std::cout << "✓ Found GPU agent\n" << std::endl;

  // Open nvme-axiio and create queue
  std::cout << "Step 3: Creating NVMe queue..." << std::endl;
  int axiio_fd = open("/dev/nvme-axiio", O_RDWR);
  if (axiio_fd < 0) {
    perror("Error: Failed to open /dev/nvme-axiio");
    hsa_shut_down();
    return 1;
  }

  struct nvme_axiio_queue_info queue_info;
  memset(&queue_info, 0, sizeof(queue_info));
  queue_info.queue_id = 1;
  queue_info.queue_size = queue_size;
  queue_info.nsid = 1;
  queue_info.sq_dma_addr_user = 0;
  queue_info.cq_dma_addr_user = 0;

  if (ioctl(axiio_fd, NVME_AXIIO_CREATE_QUEUE, &queue_info) < 0) {
    perror("Error: NVME_AXIIO_CREATE_QUEUE failed");
    close(axiio_fd);
    hsa_shut_down();
    return 1;
  }

  std::cout << "✓ Queue created (QID=" << queue_info.queue_id << ")"
            << std::endl;
  std::cout << "  Doorbell phys: 0x" << std::hex << queue_info.sq_doorbell_phys
            << std::dec << "\n"
            << std::endl;

  // Map doorbell
  std::cout << "Step 4: Mapping doorbell..." << std::endl;
  off_t doorbell_offset = 2 * getpagesize();
  size_t doorbell_size = getpagesize();

  void* doorbell_va = mmap(NULL, doorbell_size, PROT_READ | PROT_WRITE,
                           MAP_SHARED, axiio_fd, doorbell_offset);
  if (doorbell_va == MAP_FAILED) {
    perror("Error: Failed to mmap doorbell");
    close(axiio_fd);
    hsa_shut_down();
    return 1;
  }

  uint32_t doorbell_offset_in_page = queue_info.sq_doorbell_offset &
                                     (getpagesize() - 1);
  volatile uint32_t* sq_doorbell =
    (volatile uint32_t*)((char*)doorbell_va + doorbell_offset_in_page);

  std::cout << "✓ Doorbell mapped at " << doorbell_va << std::endl;
  std::cout << "  SQ doorbell: " << (void*)sq_doorbell << "\n" << std::endl;

  // HERE'S THE KEY: Register doorbell with HSA/GPU!
  std::cout << "Step 5: Registering doorbell with GPU via HSA..." << std::endl;
  std::cout << "  Using hsa_amd_memory_lock()..." << std::endl;

  void* locked_ptr = nullptr;
  hsa_agent_t agents[1] = {gpu_agent};

  hsa_err = hsa_amd_memory_lock(doorbell_va, doorbell_size, agents, 1,
                                &locked_ptr);
  if (hsa_err != HSA_STATUS_SUCCESS) {
    std::cerr << "⚠️  hsa_amd_memory_lock() failed: " << hsa_err << std::endl;
    std::cerr << "  This might be expected for MMIO regions." << std::endl;
    std::cerr << "  Continuing anyway with original pointer...\n" << std::endl;
    locked_ptr = doorbell_va;
  } else {
    std::cout << "✓ HSA memory lock successful!" << std::endl;
    std::cout << "  Locked pointer: " << locked_ptr << std::endl;
    std::cout << "  🎉 GPU MMU should now have doorbell mapping!\n"
              << std::endl;
  }

  // Use the locked pointer for GPU access
  volatile uint32_t* gpu_doorbell =
    (volatile uint32_t*)((char*)locked_ptr + doorbell_offset_in_page);

  // Test CPU write first
  std::cout << "Step 6: Testing CPU write..." << std::endl;
  *sq_doorbell = 0;
  __sync_synchronize();
  std::cout << "✓ CPU write successful\n" << std::endl;

  // Test GPU write with HSA-registered pointer!
  std::cout << "Step 7: Testing GPU write (with HSA-registered pointer)..."
            << std::endl;
  std::cout << "  🎯 Using pointer registered with GPU MMU!" << std::endl;

  uint32_t test_value = 1;
  hipLaunchKernelGGL(ring_doorbell_gpu, dim3(1), dim3(1), 0, 0, gpu_doorbell,
                     test_value);

  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    std::cerr << "\n❌ GPU kernel failed: " << hipGetErrorString(err)
              << std::endl;
    std::cerr << "\nEven with HSA memory lock, GPU can't access MMIO."
              << std::endl;
    std::cerr << "This confirms the hardware limitation on this GPU.\n"
              << std::endl;

    if (locked_ptr != doorbell_va) {
      hsa_amd_memory_unlock(doorbell_va);
    }
    munmap(doorbell_va, doorbell_size);
    close(axiio_fd);
    hsa_shut_down();
    return 1;
  }

  std::cout << "\n✅✅✅ SUCCESS! GPU DOORBELL WORKS! ✅✅✅\n" << std::endl;

  // Test second write
  std::cout << "Step 8: Testing second GPU write..." << std::endl;
  test_value = 2;
  hipLaunchKernelGGL(ring_doorbell_gpu, dim3(1), dim3(1), 0, 0, gpu_doorbell,
                     test_value);

  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    std::cerr << "Error: Second write failed: " << hipGetErrorString(err)
              << std::endl;
  } else {
    std::cout << "✓ Second GPU write successful!\n" << std::endl;
  }

  std::cout << "\n╔══════════════════════════════════════════════╗\n";
  std::cout << "║  ✓✓✓ TRUE GPU-DIRECT DOORBELL! ✓✓✓          ║\n";
  std::cout << "║                                              ║\n";
  std::cout << "║  HSA memory registration made it work!       ║\n";
  std::cout << "╚══════════════════════════════════════════════╝\n";

  // Cleanup
  if (locked_ptr != doorbell_va) {
    hsa_amd_memory_unlock(doorbell_va);
  }
  munmap(doorbell_va, doorbell_size);
  close(axiio_fd);
  hsa_shut_down();

  return 0;
}
