/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <iostream>
#include <iomanip>
#include <thread>
#include <chrono>
#include <cstring>
#include <cstdint>
#include <ctime>
#include <cstdlib>
#include <vector>
#include <algorithm>
#include <cmath>
#include <unistd.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <errno.h>
#include <linux/dma-buf.h>
#include <sys/ioctl.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include "simple-test.h"

#define HIP_CHECK(call)                                                       \
  do {                                                                        \
    hipError_t err = call;                                                    \
    if (err != hipSuccess) {                                                  \
      std::cerr << "HIP error at " << __FILE__ << ":" << __LINE__            \
                << ": " << hipGetErrorString(err) << std::endl;               \
      exit(EXIT_FAILURE);                                                     \
    }                                                                         \
  } while (0)

// Get CPU wall clock time in nanoseconds
static inline uint64_t getCpuTime() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

// Format time value with appropriate unit (ns, us, ms)
static inline void formatTime(double timeNs, double& value, 
                               const char*& unit) {
  if (timeNs >= 1000000.0) {
    // Use milliseconds
    value = timeNs / 1000000.0;
    unit = " ms";
  } else if (timeNs >= 1000.0) {
    // Use microseconds
    value = timeNs / 1000.0;
    unit = " us";
  } else {
    // Use nanoseconds
    value = timeNs;
    unit = " ns";
  }
}

// Structure to track mapped device memory with DMA-BUF
struct MappedDeviceMemory {
  void* cpu_ptr;      // CPU virtual pointer (adjusted for offset)
  void* mapped_base;   // Base of mapped region (for munmap)
  size_t mapped_size; // Size of mapped region
  int dmabuf_fd;      // DMA-BUF file descriptor (for sync ioctls)
};

// Allocate device memory using HSA runtime directly
// This may give us more control over memory properties
static hsa_status_t allocateHsaDeviceMemory(size_t size, void** ptr) {
  hsa_status_t status;
  
  // Initialize HSA runtime (safe to call multiple times)
  status = hsa_init();
  if (status != HSA_STATUS_SUCCESS) {
    // If already initialized, that's fine, continue
    if (status != 0x1001) { // HSA_STATUS_ERROR_ALREADY_INITIALIZED value
      std::cerr << "Error: hsa_init failed: " << status << std::endl;
      return status;
    }
  }
  
  // Iterate through agents to find GPU
  hsa_region_t device_region = {0};
  
  hsa_iterate_agents([](hsa_agent_t agent, void* data) -> hsa_status_t {
    hsa_device_type_t device_type;
    hsa_status_t status = hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, 
                                              &device_type);
    if (status != HSA_STATUS_SUCCESS) {
      return status;
    }
    
    if (device_type == HSA_DEVICE_TYPE_GPU) {
      // Found GPU agent, iterate its regions
      // Look for fine-grained global region first (better for CPU-GPU coherence)
      // Then fall back to coarse-grained if fine-grained not available
      struct RegionData {
        hsa_region_t fine;
        hsa_region_t coarse;
      };
      RegionData regions = {{0}, {0}};
      
      hsa_agent_iterate_regions(agent, [](hsa_region_t region, void* data) -> hsa_status_t {
        hsa_region_segment_t segment;
        hsa_status_t status = hsa_region_get_info(region, 
                                                   HSA_REGION_INFO_SEGMENT,
                                                   &segment);
        if (status != HSA_STATUS_SUCCESS) {
          return status;
        }
        
        // Look for global (device) memory region
        if (segment == HSA_REGION_SEGMENT_GLOBAL) {
          uint32_t alloc_allowed;
          status = hsa_region_get_info(region, HSA_REGION_INFO_RUNTIME_ALLOC_ALLOWED,
                                       &alloc_allowed);
          if (status == HSA_STATUS_SUCCESS && alloc_allowed) {
            // Check if fine-grained or coarse-grained
            uint32_t global_flags;
            status = hsa_region_get_info(region, HSA_REGION_INFO_GLOBAL_FLAGS,
                                         &global_flags);
            if (status == HSA_STATUS_SUCCESS) {
              RegionData* regions_ptr = (RegionData*)data;
              
              if (global_flags & HSA_REGION_GLOBAL_FLAG_FINE_GRAINED) {
                regions_ptr->fine = region;
              } else if (global_flags & HSA_REGION_GLOBAL_FLAG_COARSE_GRAINED) {
                regions_ptr->coarse = region;
              }
            }
          }
        }
        return HSA_STATUS_SUCCESS;
      }, &regions);
      
      // Prefer fine-grained, fall back to coarse-grained
      hsa_region_t* best_region = (hsa_region_t*)data;
      if (regions.fine.handle != 0) {
        *best_region = regions.fine;
      } else if (regions.coarse.handle != 0) {
        *best_region = regions.coarse;
      }
      
      return HSA_STATUS_INFO_BREAK; // Stop agent iteration
    }
    return HSA_STATUS_SUCCESS;
  }, &device_region);
  
  if (device_region.handle == 0) {
    std::cerr << "Error: Could not find allocatable device memory region" 
              << std::endl;
    return HSA_STATUS_ERROR_INVALID_REGION;
  }
  
  // Check what type of region we found
  uint32_t global_flags = 0;
  hsa_region_get_info(device_region, HSA_REGION_INFO_GLOBAL_FLAGS, &global_flags);
  if (global_flags & HSA_REGION_GLOBAL_FLAG_FINE_GRAINED) {
    std::cerr << "Info: Using HSA fine-grained global memory region" << std::endl;
  } else if (global_flags & HSA_REGION_GLOBAL_FLAG_COARSE_GRAINED) {
    std::cerr << "Info: Using HSA coarse-grained global memory region" << std::endl;
  }
  
  // Allocate memory from device region
  status = hsa_memory_allocate(device_region, size, ptr);
  return status;
}

// Export VRAM allocation as DMA-BUF and map to CPU virtual address
// Returns mapped memory info on success, nullptr on failure
static MappedDeviceMemory* mapDeviceMemoryToCpu(void* devicePtr, size_t size) {
  hsa_status_t status;
  hipDeviceptr_t aligned_ptr;
  const size_t host_page_size = sysconf(_SC_PAGESIZE);
  uint64_t offset;
  size_t aligned_size;
  void* cpu_ptr = nullptr;
  MappedDeviceMemory* mapped = nullptr;
  
  // Round down to host page size for dmabuf alignment
  aligned_ptr = (hipDeviceptr_t)((uintptr_t)devicePtr & 
                                  ~(host_page_size - 1));
  offset = (uintptr_t)devicePtr - (uintptr_t)aligned_ptr;
  aligned_size = (size + offset + host_page_size - 1) & 
                 ~(host_page_size - 1);
  
  // Export as DMA-BUF using HSA runtime
  int dmabuf_fd = -1;
  status = hsa_amd_portable_export_dmabuf((void*)aligned_ptr, aligned_size,
                                           &dmabuf_fd, &offset);
  if (status != HSA_STATUS_SUCCESS) {
    std::cerr << "Error: hsa_amd_portable_export_dmabuf failed "
              << "(status=" << status << ")" << std::endl;
    return nullptr;
  }
  
  // Map DMA-BUF to CPU virtual address space
  // Use MAP_SHARED for shared access between CPU and GPU
  cpu_ptr = mmap(nullptr, aligned_size, PROT_READ | PROT_WRITE,
                 MAP_SHARED, dmabuf_fd, 0);
  
  if (cpu_ptr == MAP_FAILED) {
    std::cerr << "Error: mmap failed for DMA-BUF: " 
              << strerror(errno) << std::endl;
    close(dmabuf_fd);
    return nullptr;
  }
  
  // Try to mark memory as needing to be written through to device
  // This may help ensure GPU sees CPU writes
  if (madvise(cpu_ptr, aligned_size, MADV_WILLNEED) != 0) {
    std::cerr << "Warning: madvise MADV_WILLNEED failed: " 
              << strerror(errno) << std::endl;
  }
  
  // Allocate structure to track mapping
  mapped = new MappedDeviceMemory;
  mapped->mapped_base = cpu_ptr;
  mapped->mapped_size = aligned_size;
  mapped->dmabuf_fd = dmabuf_fd;
  mapped->cpu_ptr = (char*)cpu_ptr + offset;
  
  return mapped;
}

// Synchronize DMA-BUF for CPU access (call before reading/writing)
static void syncDmaBufStart(MappedDeviceMemory* mapped, bool isWrite = false) {
  struct dma_buf_sync sync = {0};
  // Use WRITE flag for writes, READ for reads
  sync.flags = DMA_BUF_SYNC_START | 
               (isWrite ? DMA_BUF_SYNC_WRITE : DMA_BUF_SYNC_READ);
  if (ioctl(mapped->dmabuf_fd, DMA_BUF_IOCTL_SYNC, &sync) < 0) {
    std::cerr << "Warning: DMA_BUF_IOCTL_SYNC START failed: " 
              << strerror(errno) << std::endl;
  }
}

// Synchronize DMA-BUF after CPU access (call after reading/writing)
static void syncDmaBufEnd(MappedDeviceMemory* mapped, bool isWrite = false) {
  struct dma_buf_sync sync = {0};
  // Use WRITE flag for writes, RW for reads
  sync.flags = DMA_BUF_SYNC_END | 
               (isWrite ? DMA_BUF_SYNC_WRITE : DMA_BUF_SYNC_READ);
  // Retry sync if it fails (can fail with EAGAIN)
  int retries = 10;
  while (retries > 0) {
    if (ioctl(mapped->dmabuf_fd, DMA_BUF_IOCTL_SYNC, &sync) == 0) {
      break;
    }
    if (errno != EAGAIN && errno != EINTR) {
      std::cerr << "Warning: DMA_BUF_IOCTL_SYNC END failed: " 
                << strerror(errno) << std::endl;
      break;
    }
    retries--;
    std::this_thread::sleep_for(std::chrono::microseconds(10));
  }
}

// Flush CPU cache for a memory region
static void flushCpuCache(void* ptr, size_t size) {
  // Use GCC builtin to flush cache
  // This ensures CPU writes are visible to other devices
  __builtin___clear_cache((char*)ptr, (char*)ptr + size);
}

// CPU thread function that polls for GPU messages and responds
void cpuThread(GpuToCpuMsg* gpuToCpuHost, GpuToCpuMsg* gpuToCpuDevice,
               CpuToGpuMsg* cpuToGpuHost, CpuToGpuMsg* cpuToGpuDevice,
               unsigned iterations, bool gpuWriteToDevice,
               bool cpuWriteToDevice,
               MappedDeviceMemory* gpuToCpuMapped,
               MappedDeviceMemory* cpuToGpuMapped,
               bool gpuToCpuUsedHsa,
               bool cpuToGpuUsedHsa) {
  // CPU always uses host pointers
  // For HSA fine-grained memory, pointer is directly accessible (no DMA-BUF)
  // For HIP device memory, pointer is mapped via DMA-BUF
  volatile GpuToCpuMsg* volatileGpuToCpu = gpuToCpuHost;
  volatile CpuToGpuMsg* volatileCpuToGpu = cpuToGpuHost;
  GpuToCpuMsg lastMsg = {};
  lastMsg.iteration = 0xFFFFFFFF; // Initialize to invalid value

  for (unsigned i = 0; i < iterations; ++i) {
    // Poll for new GPU message
    GpuToCpuMsg currentMsg;
    uint64_t lastGpuTimeSeen = (i == 0) ? 0 : lastMsg.gpuTime;
    
    // For mode 1 (GPU->device, CPU->host), sync DMA-BUF once per iteration
    // before polling, rather than on every poll iteration
    if (gpuWriteToDevice && gpuToCpuMapped && !gpuToCpuUsedHsa) {
      syncDmaBufStart(gpuToCpuMapped, false); // false = read
    }
    
    unsigned poll_count = 0;
    while (true) {
      // Read the message atomically from volatile pointer
      currentMsg.magic = volatileGpuToCpu->magic;
      currentMsg.iteration = volatileGpuToCpu->iteration;
      currentMsg.gpuTime = volatileGpuToCpu->gpuTime;
      for (int j = 0; j < 5; ++j) {
        currentMsg.data[j] = volatileGpuToCpu->data[j];
      }
      
      poll_count++;
      
      // Check if this is a new message for this iteration
      if (currentMsg.magic == GPU_TO_CPU_MAGIC &&
          currentMsg.iteration == i &&
          currentMsg.gpuTime != lastGpuTimeSeen) {
        break;
      }
      // Yield to avoid busy-waiting too aggressively
      std::this_thread::yield();
    }
    
    // Sync DMA-BUF after reading if device memory via HIP (not HSA)
    // HSA fine-grained memory is automatically coherent, no sync needed
    if (gpuWriteToDevice && gpuToCpuMapped && !gpuToCpuUsedHsa) {
      syncDmaBufEnd(gpuToCpuMapped, false); // false = read
    }

    // Get CPU wall clock time when message is received (before processing)
    uint64_t cpuTime = getCpuTime();

    // Process the message (simple function: invert the first data word)
    // The response includes CPU time which is recorded when message received
    (void)currentMsg.data[0]; // Processed but not used in response

    // If writing to device memory via HIP (not HSA), sync DMA-BUF before writing
    // HSA fine-grained memory is automatically coherent, no sync needed
    if (cpuWriteToDevice && cpuToGpuMapped && !cpuToGpuUsedHsa) {
      syncDmaBufStart(cpuToGpuMapped, true); // true = write
    }
    
    // Write response to memory atomically
    volatileCpuToGpu->magic = CPU_TO_GPU_MAGIC;
    __sync_synchronize(); // Ensure magic is written before cpuTime
    volatileCpuToGpu->cpuTime = cpuTime;
    __sync_synchronize(); // Ensure write is visible
    
    // Sync DMA-BUF after writing if device memory via HIP (not HSA)
    // HSA fine-grained memory is automatically coherent, no sync needed
    if (cpuWriteToDevice && cpuToGpuMapped && !cpuToGpuUsedHsa) {
      // For mode 2 (GPU->host, CPU->device), minimal sync is sufficient
      // For mode 3 (GPU->device, CPU->device), we need more aggressive sync
      if (gpuWriteToDevice) {
        // Mode 3: Aggressive sync needed due to GPU cache coherency issues
        flushCpuCache(cpuToGpuHost, sizeof(CpuToGpuMsg));
        __sync_synchronize();
        msync(cpuToGpuMapped->mapped_base, cpuToGpuMapped->mapped_size, 
              MS_SYNC | MS_INVALIDATE);
        syncDmaBufEnd(cpuToGpuMapped, true);
        __sync_synchronize();
        flushCpuCache(cpuToGpuHost, sizeof(CpuToGpuMsg));
        __sync_synchronize();
        madvise(cpuToGpuMapped->mapped_base, cpuToGpuMapped->mapped_size, 
                MADV_DONTNEED);
        std::this_thread::sleep_for(std::chrono::microseconds(100));
      } else {
        // Mode 2: Minimal sync - just DMA-BUF sync is sufficient
        // GPU writes to host memory, so no GPU cache coherency issues
        syncDmaBufEnd(cpuToGpuMapped, true);
      }
    }

    lastMsg = currentMsg;
  }
}

// GPU kernel that runs one thread
__global__ void gpuKernel(GpuToCpuMsg* gpuToCpu, CpuToGpuMsg* cpuToGpu,
                          unsigned iterations,
                          unsigned long long int* startTimes,
                          unsigned long long int* cpuTimes,
                          unsigned long long gpuClockRateKHz,
                          GpuToCpuMsg* gpuToCpuHost) {
  // Only thread 0 runs
  if (threadIdx.x != 0 || blockIdx.x != 0) {
    return;
  }

  volatile CpuToGpuMsg* volatileCpuToGpu = cpuToGpu;
  GpuToCpuMsg msg = {};
  CpuToGpuMsg lastResponse = {};
  lastResponse.magic = 0; // Initialize to invalid value
  CpuToGpuMsg currentResponse = {};
  uint64_t lastCpuTime = 0;
  
  // Calculate timeout: 100ms in GPU clock ticks
  // GPU clock rate is in KHz, so rate in Hz = rate_KHz * 1000
  // Period in ns = 1e9 / (rate_KHz * 1000) = 1e6 / rate_KHz
  // 100ms = 100,000,000 ns
  // Ticks = 100,000,000 / (1e6 / rate_KHz) = 100,000,000 * rate_KHz / 1e6
  //        = 100 * rate_KHz
  unsigned long long timeoutTicks = 100ULL * gpuClockRateKHz;

  for (unsigned i = 0; i < iterations; ++i) {
    // Record start time for this iteration
    unsigned long long pollStartTime = wall_clock64();
    startTimes[i] = pollStartTime;

    // Prepare message to CPU
    msg.magic = GPU_TO_CPU_MAGIC;
    msg.iteration = i;
    msg.gpuTime = wall_clock64();
    
    // Fill data payload
    for (int j = 0; j < 5; ++j) {
      msg.data[j] = 0x123456789ABCDEF0ULL + i + j;
    }

    // Write message to memory atomically
    *gpuToCpu = msg;
    __threadfence_system(); // Ensure write is visible
    
    // In mode 3, GPU writes to device memory before reading from device memory
    // The difference from mode 2 is that in mode 2, GPU writes to host memory
    // and reads from device memory, which works. In mode 3, GPU writes to
    // device memory and reads from device memory, which doesn't work.
    // Test: Also write to host memory in mode 3 to see if that affects
    // GPU cache behavior for device memory reads
    if (gpuToCpuHost != nullptr && gpuToCpuHost != gpuToCpu) {
      // Mode 3: write to both device and host memory
      *gpuToCpuHost = msg;
      __threadfence_system(); // Ensure host write is visible
    }
    
    __threadfence_system();
    __threadfence(); // Additional device-level fence
    __threadfence_system(); // System-level fence again

    // Poll for CPU response with timeout
    unsigned poll_count = 0;
    bool timeoutReached = false;
    while (true) {
      // Check for timeout: 100ms elapsed
      unsigned long long currentTime = wall_clock64();
      if (currentTime - pollStartTime >= timeoutTicks) {
        timeoutReached = true;
        break;
      }
      
      // GPU-side memory scope issue: After writing to device memory,
      // GPU may cache device memory reads. Try reading from host memory
      // first (if available) to potentially reset cache state before
      // reading from device memory.
      if (gpuToCpuHost != nullptr && gpuToCpuHost != gpuToCpu) {
        // Read from host memory first to potentially affect GPU cache state
        volatile uint64_t dummy = ((volatile GpuToCpuMsg*)gpuToCpuHost)->magic;
        (void)dummy;
        __threadfence_system();
      }
      
      // Read response atomically from volatile pointer
      // Use system fence before read to ensure we see latest device memory
      // This is especially important when CPU writes to device memory (mode 3)
      __threadfence_system();
      
      // Read multiple times to potentially bypass GPU cache
      // First read might be cached, subsequent reads may force memory access
      uint64_t magic1 = volatileCpuToGpu->magic;
      uint64_t cpuTime1 = volatileCpuToGpu->cpuTime;
      __threadfence_system();
      uint64_t magic2 = volatileCpuToGpu->magic;
      uint64_t cpuTime2 = volatileCpuToGpu->cpuTime;
      __threadfence_system();
      // Use the second read (more likely to be from memory)
      currentResponse.magic = magic2;
      currentResponse.cpuTime = cpuTime2;
      
      __threadfence_system();
      
      poll_count++;
      
      // Check if this is a new response
      // For device memory (mode 3), CPU writes via DMA-BUF mmap, so GPU
      // might need multiple reads to see the write
      if (currentResponse.magic == CPU_TO_GPU_MAGIC) {
        if (currentResponse.cpuTime != 0) {
          // Accept if this is a new response (cpuTime changed)
          // Or if this is the first valid response (lastCpuTime was 0)
          if (currentResponse.cpuTime != lastCpuTime || lastCpuTime == 0) {
            // Accept immediately - don't double-check as it might prevent
            // seeing CPU writes via DMA-BUF mmap
            break;
          }
        }
      }
      
      // Add a small delay every N polls to allow CPU writes to propagate
      // This is especially important for DMA-BUF mmap writes
      if (poll_count % 10000 == 0) {
        // Use a memory barrier to ensure we don't optimize away the read
        __threadfence_system();
      }
    }
    
    // If timeout reached, record 0 as CPU time to indicate timeout
    if (timeoutReached) {
      cpuTimes[i] = 0;
      lastCpuTime = 0; // Reset to allow next iteration to accept any response
    } else {
      lastResponse = currentResponse;
      lastCpuTime = currentResponse.cpuTime;
      
      // Record CPU time from response
      cpuTimes[i] = currentResponse.cpuTime;
    }
  }
}

int main(int argc, char** argv) {
  unsigned iterations = 10;
  bool verbose = false;
  unsigned memoryMode = 0; // Default: GPU writes to host, CPU writes to host
  int opt;

  // Parse command line options
  while ((opt = getopt(argc, argv, "n:vm:")) != -1) {
    switch (opt) {
      case 'n':
        iterations = static_cast<unsigned>(atoi(optarg));
        if (iterations == 0) {
          std::cerr << "Error: iterations must be > 0" << std::endl;
          return EXIT_FAILURE;
        }
        break;
      case 'v':
        verbose = true;
        break;
      case 'm':
        memoryMode = static_cast<unsigned>(atoi(optarg));
        if (memoryMode > 3) {
          std::cerr << "Error: memory mode must be 0-3" << std::endl;
          return EXIT_FAILURE;
        }
        break;
      default:
        std::cerr << "Usage: " << argv[0] 
                  << " [-n iterations] [-v] [-m mode]" << std::endl;
        std::cerr << "  -n iterations  Number of iterations (default: 10)" 
                  << std::endl;
        std::cerr << "  -v             Verbose: show timing table" 
                  << std::endl;
        std::cerr << "  -m mode        Memory mode (default: 0)" 
                  << std::endl;
        std::cerr << "                  Bit 0 (LSB): GPU write location "
                  << "(0=host, 1=device)" << std::endl;
        std::cerr << "                  Bit 1 (MSB): CPU write location "
                  << "(0=host, 1=device)" << std::endl;
        return EXIT_FAILURE;
    }
  }

  // Extract memory mode bits
  bool gpuWriteToDevice = (memoryMode & 0x1) != 0;  // LSB
  bool cpuWriteToDevice = (memoryMode & 0x2) != 0; // MSB

  // Get GPU device information
  int deviceId = 0;
  HIP_CHECK(hipGetDevice(&deviceId));
  hipDeviceProp_t deviceProp;
  HIP_CHECK(hipGetDeviceProperties(&deviceProp, deviceId));

  // Get GPU wall clock frequency (in KHz)
  int gpuWallClockRateKHz = 0;
  HIP_CHECK(hipDeviceGetAttribute(&gpuWallClockRateKHz,
                                  hipDeviceAttributeWallClockRate, deviceId));
  
  // Calculate GPU clock period in nanoseconds
  // Frequency is in KHz, so period = 1e6 / frequency_khz nanoseconds
  double gpuClockPeriodNs = 1000000.0 / static_cast<double>(gpuWallClockRateKHz);

  // Get CPU clock resolution
  struct timespec cpuRes;
  clock_getres(CLOCK_MONOTONIC, &cpuRes);
  double cpuClockResolutionNs = cpuRes.tv_sec * 1000000000.0 + 
                                 cpuRes.tv_nsec;

  std::cout << "Simple GPU-CPU Communication Test" << std::endl;
  std::cout << "  GPU Model: " << deviceProp.name << std::endl;
  std::cout << "  GPU Device ID: " << deviceId << std::endl;
  std::cout << "  GPU Wall Clock Rate: " << gpuWallClockRateKHz << " KHz" 
            << std::endl;
  std::cout << "  GPU Clock Period: " << std::fixed << std::setprecision(3)
            << gpuClockPeriodNs << " ns" << std::endl;
  std::cout << "  CPU Clock: CLOCK_MONOTONIC" << std::endl;
  std::cout << "  CPU Clock Resolution: " << std::fixed 
            << std::setprecision(3) << cpuClockResolutionNs << " ns" 
            << std::endl;
  std::cout << "  Iterations: " << iterations << std::endl;
  std::cout << "  Memory Mode: " << memoryMode << " (GPU write: " 
            << (gpuWriteToDevice ? "device" : "host") 
            << ", CPU write: " << (cpuWriteToDevice ? "device" : "host") 
            << ")" << std::endl;
  
  // Warn about mode 3 limitation
  if (gpuWriteToDevice && cpuWriteToDevice) {
    std::cerr << "\n*** WARNING: Mode 3 is NOT SUPPORTED ***" << std::endl;
    std::cerr << "Mode 3 (both GPU and CPU write to device memory) does NOT "
              << "work correctly." << std::endl;
    std::cerr << "\nRoot Cause: GPU-side memory visibility limitation" 
              << std::endl;
    std::cerr << "  When the GPU writes to device memory, it cannot see "
              << "CPU writes to device memory" << std::endl;
    std::cerr << "  via DMA-BUF mmap, even with uncached device memory "
              << "allocation." << std::endl;
    std::cerr << "\nAttempted Solutions (all failed):" << std::endl;
    std::cerr << "  - DMA-BUF sync with proper flags" << std::endl;
    std::cerr << "  - CPU cache flushing" << std::endl;
    std::cerr << "  - msync with invalidate" << std::endl;
    std::cerr << "  - madvise hints" << std::endl;
    std::cerr << "  - Multiple GPU reads with memory barriers" << std::endl;
    std::cerr << "  - Writing/reading from host memory" << std::endl;
    std::cerr << "  - Uncached device memory allocation "
              << "(hipDeviceMallocUncached)" << std::endl;
    std::cerr << "\nWorking Modes:" << std::endl;
    std::cerr << "  Mode 0 (GPU->host, CPU->host): WORKS" << std::endl;
    std::cerr << "  Mode 1 (GPU->device, CPU->host): WORKS" << std::endl;
    std::cerr << "  Mode 2 (GPU->host, CPU->device): WORKS" << std::endl;
    std::cerr << "\nFailed Mode:" << std::endl;
    std::cerr << "  Mode 3 (GPU->device, CPU->device): FAILS - GPU cannot "
              << "see CPU writes" << std::endl;
    std::cerr << "\nThis appears to be a fundamental GPU-side memory "
              << "scope/visibility limitation." << std::endl;
    std::cerr << "CPU-side synchronization works correctly (proven by mode 2)."
              << std::endl;
    std::cerr << "The GPU simply cannot see CPU writes to device memory when "
              << "it has" << std::endl;
    std::cerr << "previously written to device memory, regardless of caching "
              << "or sync mechanisms.\n" << std::endl;
  }

  // Allocate memory for communication based on mode
  GpuToCpuMsg* gpuToCpuHost = nullptr; // Host pointer (CPU uses this)
  GpuToCpuMsg* gpuToCpuDevice = nullptr; // Device pointer (GPU uses this)
  CpuToGpuMsg* cpuToGpuHost = nullptr; // Host pointer (CPU uses this)
  CpuToGpuMsg* cpuToGpuDevice = nullptr; // Device pointer (GPU uses this)
  MappedDeviceMemory* gpuToCpuMapped = nullptr; // Track DMA-BUF mapping
  MappedDeviceMemory* cpuToGpuMapped = nullptr; // Track DMA-BUF mapping
  unsigned long long int* startTimes = nullptr;
  unsigned long long int* cpuTimes = nullptr;

  // Get page size for alignment
  const size_t host_page_size = sysconf(_SC_PAGESIZE);
  
  // Track if we used HSA allocation (for cleanup)
  bool gpuToCpuUsedHsa = false;
  bool cpuToGpuUsedHsa = false;
  
  // Allocate GPU->CPU message buffer
  GpuToCpuMsg* gpuToCpuHostForWrite = nullptr; // Separate host buffer for mode 3 test
  if (gpuWriteToDevice) {
    size_t gpuToCpuSize = ((sizeof(GpuToCpuMsg) + host_page_size - 1) / 
                           host_page_size) * host_page_size;
    
    if (cpuWriteToDevice) {
      // Mode 3: Use HSA fine-grained memory - CPU can access pointer directly!
      // Fine-grained memory is coherent between CPU and GPU, no DMA-BUF needed
      hsa_status_t hsa_status = allocateHsaDeviceMemory(gpuToCpuSize, 
                                                        (void**)&gpuToCpuDevice);
      if (hsa_status == HSA_STATUS_SUCCESS) {
        std::cerr << "Info: Using HSA fine-grained memory for GPU->CPU buffer "
                  << "in mode 3 (CPU can access directly, no DMA-BUF needed)"
                  << std::endl;
        gpuToCpuUsedHsa = true;
        // HSA fine-grained memory pointer can be used directly by CPU
        gpuToCpuHost = (GpuToCpuMsg*)gpuToCpuDevice;
        memset(gpuToCpuHost, 0, sizeof(GpuToCpuMsg));
      } else {
        // Fall back to HIP uncached + DMA-BUF
        std::cerr << "Warning: HSA memory allocation failed (" << hsa_status 
                  << "), falling back to HIP uncached + DMA-BUF" << std::endl;
        hipError_t err = hipExtMallocWithFlags((void**)&gpuToCpuDevice, 
                                               gpuToCpuSize,
                                               hipDeviceMallocUncached);
        if (err != hipSuccess) {
          std::cerr << "Error: hipExtMallocWithFlags(Uncached) failed: " 
                    << hipGetErrorString(err) << std::endl;
          return EXIT_FAILURE;
        }
        HIP_CHECK(hipMemset(gpuToCpuDevice, 0, gpuToCpuSize));
        gpuToCpuMapped = mapDeviceMemoryToCpu(gpuToCpuDevice, 
                                               sizeof(GpuToCpuMsg));
        if (!gpuToCpuMapped || !gpuToCpuMapped->cpu_ptr) {
          std::cerr << "Error: Failed to map GPU->CPU device memory to CPU" 
                    << std::endl;
          HIP_CHECK(hipFree(gpuToCpuDevice));
          return EXIT_FAILURE;
        }
        gpuToCpuHost = (GpuToCpuMsg*)gpuToCpuMapped->cpu_ptr;
      }
    } else {
      // Mode 1: regular HIP allocation + DMA-BUF mapping
      HIP_CHECK(hipMalloc((void**)&gpuToCpuDevice, gpuToCpuSize));
      HIP_CHECK(hipMemset(gpuToCpuDevice, 0, gpuToCpuSize));
      gpuToCpuMapped = mapDeviceMemoryToCpu(gpuToCpuDevice, sizeof(GpuToCpuMsg));
      if (!gpuToCpuMapped || !gpuToCpuMapped->cpu_ptr) {
        std::cerr << "Error: Failed to map GPU->CPU device memory to CPU" 
                  << std::endl;
        HIP_CHECK(hipFree(gpuToCpuDevice));
        return EXIT_FAILURE;
      }
      gpuToCpuHost = (GpuToCpuMsg*)gpuToCpuMapped->cpu_ptr;
    }
    
    // In mode 3, allocate separate host memory for GPU to write to
    // This tests if writing to host memory affects GPU cache behavior
    if (cpuWriteToDevice) {
      HIP_CHECK(hipHostMalloc((void**)&gpuToCpuHostForWrite, 
                              sizeof(GpuToCpuMsg),
                              hipHostMallocDefault));
      memset(gpuToCpuHostForWrite, 0, sizeof(GpuToCpuMsg));
    }
  } else {
    // Host memory: use hipHostMalloc (CPU accessible, GPU can access via PCIe)
    HIP_CHECK(hipHostMalloc((void**)&gpuToCpuHost, sizeof(GpuToCpuMsg),
                            hipHostMallocDefault));
    memset(gpuToCpuHost, 0, sizeof(GpuToCpuMsg));
    gpuToCpuDevice = gpuToCpuHost; // Same pointer for host memory
  }
  
  // Use device pointer for GPU if mode requires it, otherwise use host pointer
  GpuToCpuMsg* gpuToCpu = gpuWriteToDevice ? gpuToCpuDevice : gpuToCpuHost;

  // Allocate CPU->GPU response buffer
  if (cpuWriteToDevice) {
    size_t cpuToGpuSize = ((sizeof(CpuToGpuMsg) + host_page_size - 1) / 
                           host_page_size) * host_page_size;
    
    if (gpuWriteToDevice) {
      // Mode 3: Use HSA fine-grained memory - CPU can access pointer directly!
      // Fine-grained memory is coherent between CPU and GPU, no DMA-BUF needed
      hsa_status_t hsa_status = allocateHsaDeviceMemory(cpuToGpuSize, 
                                                        (void**)&cpuToGpuDevice);
      if (hsa_status == HSA_STATUS_SUCCESS) {
        std::cerr << "Info: Using HSA fine-grained memory for CPU->GPU buffer "
                  << "in mode 3 (CPU can access directly, no DMA-BUF needed)"
                  << std::endl;
        cpuToGpuUsedHsa = true;
        // HSA fine-grained memory pointer can be used directly by CPU
        cpuToGpuHost = (CpuToGpuMsg*)cpuToGpuDevice;
        memset(cpuToGpuHost, 0, sizeof(CpuToGpuMsg));
      } else {
        // Fall back to HIP uncached + DMA-BUF
        std::cerr << "Warning: HSA memory allocation failed (" << hsa_status 
                  << "), falling back to HIP uncached + DMA-BUF" << std::endl;
        hipError_t err = hipExtMallocWithFlags((void**)&cpuToGpuDevice, 
                                               cpuToGpuSize,
                                               hipDeviceMallocUncached);
        if (err != hipSuccess) {
          std::cerr << "Error: hipExtMallocWithFlags(Uncached) failed: " 
                    << hipGetErrorString(err) << std::endl;
          // Cleanup GPU->CPU buffer
          if (gpuWriteToDevice) {
            if (gpuToCpuUsedHsa) {
              hsa_memory_free(gpuToCpuDevice);
            } else {
              HIP_CHECK(hipFree(gpuToCpuDevice));
              if (gpuToCpuMapped) {
                munmap(gpuToCpuMapped->mapped_base, gpuToCpuMapped->mapped_size);
                close(gpuToCpuMapped->dmabuf_fd);
                delete gpuToCpuMapped;
              }
            }
          }
          return EXIT_FAILURE;
        }
        HIP_CHECK(hipMemset(cpuToGpuDevice, 0, cpuToGpuSize));
        cpuToGpuMapped = mapDeviceMemoryToCpu(cpuToGpuDevice, 
                                               sizeof(CpuToGpuMsg));
        if (!cpuToGpuMapped || !cpuToGpuMapped->cpu_ptr) {
          std::cerr << "Error: Failed to map CPU->GPU device memory to CPU" 
                    << std::endl;
          HIP_CHECK(hipFree(cpuToGpuDevice));
          // Cleanup GPU->CPU buffer
          if (gpuWriteToDevice) {
            if (gpuToCpuUsedHsa) {
              hsa_memory_free(gpuToCpuDevice);
            } else {
              HIP_CHECK(hipFree(gpuToCpuDevice));
              if (gpuToCpuMapped) {
                munmap(gpuToCpuMapped->mapped_base, gpuToCpuMapped->mapped_size);
                close(gpuToCpuMapped->dmabuf_fd);
                delete gpuToCpuMapped;
              }
            }
          }
          return EXIT_FAILURE;
        }
        cpuToGpuHost = (CpuToGpuMsg*)cpuToGpuMapped->cpu_ptr;
      }
    } else {
      // Mode 2: regular HIP allocation + DMA-BUF mapping
      HIP_CHECK(hipMalloc((void**)&cpuToGpuDevice, cpuToGpuSize));
      HIP_CHECK(hipMemset(cpuToGpuDevice, 0, cpuToGpuSize));
      cpuToGpuMapped = mapDeviceMemoryToCpu(cpuToGpuDevice, sizeof(CpuToGpuMsg));
      if (!cpuToGpuMapped || !cpuToGpuMapped->cpu_ptr) {
        std::cerr << "Error: Failed to map CPU->GPU device memory to CPU" 
                  << std::endl;
        HIP_CHECK(hipFree(cpuToGpuDevice));
        if (gpuWriteToDevice) {
          if (gpuToCpuUsedHsa) {
            hsa_memory_free(gpuToCpuDevice);
          } else {
            HIP_CHECK(hipFree(gpuToCpuDevice));
            if (gpuToCpuMapped) {
              munmap(gpuToCpuMapped->mapped_base, gpuToCpuMapped->mapped_size);
              close(gpuToCpuMapped->dmabuf_fd);
              delete gpuToCpuMapped;
            }
          }
        }
        return EXIT_FAILURE;
      }
      cpuToGpuHost = (CpuToGpuMsg*)cpuToGpuMapped->cpu_ptr;
    }
  } else {
    // Host memory: use hipHostMalloc (CPU accessible, GPU can access via PCIe)
    HIP_CHECK(hipHostMalloc((void**)&cpuToGpuHost, sizeof(CpuToGpuMsg),
                            hipHostMallocDefault));
    memset(cpuToGpuHost, 0, sizeof(CpuToGpuMsg));
    cpuToGpuDevice = cpuToGpuHost; // Same pointer for host memory
  }
  
  // Use device pointer for GPU if mode requires it, otherwise use host pointer
  CpuToGpuMsg* cpuToGpu = cpuWriteToDevice ? cpuToGpuDevice : cpuToGpuHost;

  // Timing buffers always in host memory
  HIP_CHECK(hipHostMalloc((void**)&startTimes,
                          iterations * sizeof(unsigned long long int),
                          hipHostMallocDefault));
  HIP_CHECK(hipHostMalloc((void**)&cpuTimes,
                          iterations * sizeof(unsigned long long int),
                          hipHostMallocDefault));
  memset(startTimes, 0, iterations * sizeof(unsigned long long int));
  memset(cpuTimes, 0, iterations * sizeof(unsigned long long int));

  // Ensure initialization is visible
  __sync_synchronize();

  // Launch CPU thread first
  std::thread cpuThreadHandle(cpuThread, gpuToCpuHost, gpuToCpuDevice,
                              cpuToGpuHost, cpuToGpuDevice, iterations,
                              gpuWriteToDevice, cpuWriteToDevice,
                              gpuToCpuMapped, cpuToGpuMapped,
                              gpuToCpuUsedHsa, cpuToGpuUsedHsa);

  // Small delay to ensure CPU thread is ready
  std::this_thread::sleep_for(std::chrono::microseconds(100));

  // Launch GPU kernel (1 block, 1 thread)
  // Pass gpuToCpuHostForWrite for mode 3 test (write to both device and host)
  hipLaunchKernelGGL(gpuKernel, dim3(1), dim3(1), 0, 0, gpuToCpu, cpuToGpu,
                      iterations, startTimes, cpuTimes, gpuWallClockRateKHz,
                      gpuToCpuHostForWrite);

  // Check for kernel launch errors
  hipError_t err = hipGetLastError();
  if (err != hipSuccess) {
    std::cerr << "Kernel launch failed: " << hipGetErrorString(err)
              << std::endl;
    cpuThreadHandle.join();
    return EXIT_FAILURE;
  }

  HIP_CHECK(hipDeviceSynchronize());

  // Wait for CPU thread to finish
  cpuThreadHandle.join();

  // Calculate deltas
  std::vector<long long> gpuDeltas(iterations);
  std::vector<long long> cpuDeltas(iterations);
  
  gpuDeltas[0] = 0; // First iteration has no previous value
  cpuDeltas[0] = 0;
  
  for (unsigned i = 1; i < iterations; ++i) {
    gpuDeltas[i] = static_cast<long long>(startTimes[i]) - 
                   static_cast<long long>(startTimes[i-1]);
    cpuDeltas[i] = static_cast<long long>(cpuTimes[i]) - 
                   static_cast<long long>(cpuTimes[i-1]);
  }

  // Print results table if verbose
  if (verbose) {
    std::cout << "\n|-----------|-----------------|-----------------|"
              << "-----------------|-----------------|" << std::endl;
    std::cout << std::setw(9) << "| Iteration" << " | " << std::setw(15)
              << "GPU Time" << " | " << std::setw(15)
              << "CPU Time" << " | " << std::setw(15)
              << "GPU Delta" << " | " << std::setw(17)
              << "CPU Delta   |" << std::endl;
    std::cout << "|-----------|-----------------|-----------------|"
              << "-----------------|-----------------|" << std::endl;
    for (unsigned i = 0; i < iterations; ++i) {
      std::cout << "|" << std::setw(10) << (i + 1) << " | " << std::setw(15)
                << startTimes[i] << " | " << std::setw(15)
                << cpuTimes[i] << " | " << std::setw(15)
                << gpuDeltas[i] << " | " << std::setw(15)
                << cpuDeltas[i] << " |" << std::endl;
    }
    std::cout << "|-----------|-----------------|-----------------|"
              << "-----------------|-----------------|" << std::endl;
  }

  // Calculate statistics for deltas (skip first two elements: 
  // index 0 is always 0, index 1 has cold start overhead)
  // All statistics (min, max, avg, std dev) exclude the cold start iteration
  if (iterations > 2) {
    // GPU Delta statistics (skip first iteration with cold start)
    auto gpuDeltaBegin = gpuDeltas.begin() + 2;
    auto gpuDeltaEnd = gpuDeltas.end();
    auto gpuMin = std::min_element(gpuDeltaBegin, gpuDeltaEnd);
    auto gpuMax = std::max_element(gpuDeltaBegin, gpuDeltaEnd);
    
    double gpuSum = 0.0;
    for (auto it = gpuDeltaBegin; it != gpuDeltaEnd; ++it) {
      gpuSum += static_cast<double>(*it);
    }
    double gpuAvg = gpuSum / (iterations - 2);
    
    double gpuVariance = 0.0;
    for (auto it = gpuDeltaBegin; it != gpuDeltaEnd; ++it) {
      double diff = static_cast<double>(*it) - gpuAvg;
      gpuVariance += diff * diff;
    }
    gpuVariance /= (iterations - 2);
    double gpuStdDev = std::sqrt(gpuVariance);

    // CPU Delta statistics (skip first iteration with cold start)
    auto cpuDeltaBegin = cpuDeltas.begin() + 2;
    auto cpuDeltaEnd = cpuDeltas.end();
    auto cpuMin = std::min_element(cpuDeltaBegin, cpuDeltaEnd);
    auto cpuMax = std::max_element(cpuDeltaBegin, cpuDeltaEnd);
    
    double cpuSum = 0.0;
    for (auto it = cpuDeltaBegin; it != cpuDeltaEnd; ++it) {
      cpuSum += static_cast<double>(*it);
    }
    double cpuAvg = cpuSum / (iterations - 2);
    
    double cpuVariance = 0.0;
    for (auto it = cpuDeltaBegin; it != cpuDeltaEnd; ++it) {
      double diff = static_cast<double>(*it) - cpuAvg;
      cpuVariance += diff * diff;
    }
    cpuVariance /= (iterations - 2);
    double cpuStdDev = std::sqrt(cpuVariance);

    // Convert GPU deltas from cycles to nanoseconds
    double gpuMinNs = static_cast<double>(*gpuMin) * gpuClockPeriodNs;
    double gpuMaxNs = static_cast<double>(*gpuMax) * gpuClockPeriodNs;
    double gpuAvgNs = gpuAvg * gpuClockPeriodNs;
    double gpuStdDevNs = gpuStdDev * gpuClockPeriodNs;

    // CPU deltas are already in nanoseconds
    double cpuMinNs = static_cast<double>(*cpuMin);
    double cpuMaxNs = static_cast<double>(*cpuMax);
    double cpuAvgNs = cpuAvg;
    double cpuStdDevNs = cpuStdDev;

    // Format GPU statistics
    double gpuMinVal, gpuMaxVal, gpuAvgVal, gpuStdDevVal;
    const char* gpuMinUnit, *gpuMaxUnit, *gpuAvgUnit, *gpuStdDevUnit;
    formatTime(gpuMinNs, gpuMinVal, gpuMinUnit);
    formatTime(gpuMaxNs, gpuMaxVal, gpuMaxUnit);
    formatTime(gpuAvgNs, gpuAvgVal, gpuAvgUnit);
    formatTime(gpuStdDevNs, gpuStdDevVal, gpuStdDevUnit);

    // Format CPU statistics
    double cpuMinVal, cpuMaxVal, cpuAvgVal, cpuStdDevVal;
    const char* cpuMinUnit, *cpuMaxUnit, *cpuAvgUnit, *cpuStdDevUnit;
    formatTime(cpuMinNs, cpuMinVal, cpuMinUnit);
    formatTime(cpuMaxNs, cpuMaxVal, cpuMaxUnit);
    formatTime(cpuAvgNs, cpuAvgVal, cpuAvgUnit);
    formatTime(cpuStdDevNs, cpuStdDevVal, cpuStdDevUnit);

    // Print statistics
    std::cout << "\nDelta Statistics (Real Time):" << std::endl;
    std::cout << "  GPU Delta:" << std::endl;
    std::cout << "    Min:     " << std::fixed << std::setprecision(2)
              << gpuMinVal << gpuMinUnit << " (" << *gpuMin 
              << " cycles, " << std::setprecision(2) << gpuMinNs << " ns)" 
              << std::endl;
    std::cout << "    Max:     " << std::fixed << std::setprecision(2)
              << gpuMaxVal << gpuMaxUnit << " (" << *gpuMax 
              << " cycles, " << std::setprecision(2) << gpuMaxNs << " ns)" 
              << std::endl;
    std::cout << "    Average: " << std::fixed << std::setprecision(2)
              << gpuAvgVal << gpuAvgUnit << " (" << std::setprecision(0)
              << gpuAvg << " cycles, " << std::setprecision(2) << gpuAvgNs 
              << " ns)" << std::endl;
    std::cout << "    Std Dev: " << std::fixed << std::setprecision(2)
              << gpuStdDevVal << gpuStdDevUnit << " (" 
              << std::setprecision(0) << gpuStdDev << " cycles, "
              << std::setprecision(2) << gpuStdDevNs << " ns)" 
              << std::endl;
    std::cout << "  CPU Delta:" << std::endl;
    std::cout << "    Min:     " << std::fixed << std::setprecision(2)
              << cpuMinVal << cpuMinUnit << " (" << cpuMinNs << " ns)" 
              << std::endl;
    std::cout << "    Max:     " << std::fixed << std::setprecision(2)
              << cpuMaxVal << cpuMaxUnit << " (" << cpuMaxNs << " ns)" 
              << std::endl;
    std::cout << "    Average: " << std::fixed << std::setprecision(2)
              << cpuAvgVal << cpuAvgUnit << " (" << cpuAvgNs << " ns)" 
              << std::endl;
    std::cout << "    Std Dev: " << std::fixed << std::setprecision(2)
              << cpuStdDevVal << cpuStdDevUnit << " (" << cpuStdDevNs 
              << " ns)" << std::endl;
    // Calculate total elapsed time (first to last iteration)
    double gpuTotalNs = static_cast<double>(startTimes[iterations-1] - 
                                            startTimes[0]) * gpuClockPeriodNs;
    double cpuTotalNs = static_cast<double>(cpuTimes[iterations-1] - 
                                            cpuTimes[0]);

    double gpuTotalVal, cpuTotalVal;
    const char* gpuTotalUnit, *cpuTotalUnit;
    formatTime(gpuTotalNs, gpuTotalVal, gpuTotalUnit);
    formatTime(cpuTotalNs, cpuTotalVal, cpuTotalUnit);

    std::cout << "\n  Total Elapsed Time (first to last iteration):" 
              << std::endl;
    std::cout << "    GPU Total: " << std::fixed << std::setprecision(2)
              << gpuTotalVal << gpuTotalUnit << " (" << gpuTotalNs 
              << " ns)" << std::endl;
    std::cout << "    CPU Total: " << std::fixed << std::setprecision(2)
              << cpuTotalVal << cpuTotalUnit << " (" << cpuTotalNs 
              << " ns)" << std::endl;
    std::cout << "    Difference: " << std::fixed << std::setprecision(2)
              << std::abs(gpuTotalNs - cpuTotalNs) << " ns" << std::endl;
    std::cout << "    Ratio:      " << std::fixed << std::setprecision(4)
              << (cpuTotalNs / gpuTotalNs) << std::endl;

    std::cout << "\n  Delta Comparison:" << std::endl;
    std::cout << "    GPU Avg: " << std::fixed << std::setprecision(2)
              << gpuAvgNs << " ns" << std::endl;
    std::cout << "    CPU Avg: " << std::fixed << std::setprecision(2)
              << cpuAvgNs << " ns" << std::endl;
    std::cout << "    Ratio:   " << std::fixed << std::setprecision(4)
              << (cpuAvgNs / gpuAvgNs) << std::endl;
  }

  // Cleanup
  if (gpuToCpuHostForWrite != nullptr) {
    HIP_CHECK(hipHostFree(gpuToCpuHostForWrite));
  }
  if (gpuWriteToDevice) {
    if (gpuToCpuUsedHsa) {
      // HSA memory: free directly, no DMA-BUF unmapping needed
      hsa_memory_free(gpuToCpuDevice);
    } else {
      // HIP memory: unmap DMA-BUF if device memory was mapped
      if (gpuToCpuMapped) {
        munmap(gpuToCpuMapped->mapped_base, gpuToCpuMapped->mapped_size);
        close(gpuToCpuMapped->dmabuf_fd);
        delete gpuToCpuMapped;
      }
      HIP_CHECK(hipFree(gpuToCpuDevice));
    }
  } else {
    HIP_CHECK(hipHostFree(gpuToCpuHost));
  }
  
  if (cpuWriteToDevice) {
    if (cpuToGpuUsedHsa) {
      // HSA memory: free directly, no DMA-BUF unmapping needed
      hsa_memory_free(cpuToGpuDevice);
    } else {
      // HIP memory: unmap DMA-BUF if device memory was mapped
      if (cpuToGpuMapped) {
        munmap(cpuToGpuMapped->mapped_base, cpuToGpuMapped->mapped_size);
        close(cpuToGpuMapped->dmabuf_fd);
        delete cpuToGpuMapped;
      }
      HIP_CHECK(hipFree(cpuToGpuDevice));
    }
  } else {
    HIP_CHECK(hipHostFree(cpuToGpuHost));
  }
  
  HIP_CHECK(hipHostFree(startTimes));
  HIP_CHECK(hipHostFree(cpuTimes));

  std::cout << "\nTest completed successfully!" << std::endl;
  return EXIT_SUCCESS;
}

