/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <errno.h>

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <string>
#include <vector>

#include <hip/hip_runtime.h>

#include <dirent.h>
#include <fcntl.h>
#include <linux/ioctl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "xio.h"

#ifndef __HIP_DEVICE_COMPILE__
#include <cstdint>

#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#endif // __HIP_DEVICE_COMPILE__

namespace xio {

void printDeviceInfo() {
  int deviceCount;
  HIP_CHECK(hipGetDeviceCount(&deviceCount));
  std::cout << "Number of devices: " << deviceCount << std::endl;

  for (int deviceId = 0; deviceId < deviceCount; ++deviceId) {
    hipDeviceProp_t deviceProp;
    HIP_CHECK(hipGetDeviceProperties(&deviceProp, deviceId));
    std::cout << "Device " << deviceId + 1 << ":" << std::endl
              << " Properties:" << std::endl;
    std::cout << "  Name: " << deviceProp.name << std::endl;
    std::cout << "  Total Global Memory: "
              << deviceProp.totalGlobalMem / (1024 * 1024) << " MiB"
              << std::endl;
    std::cout << "  Shared Memory per Block: "
              << deviceProp.sharedMemPerBlock / 1024 << " KiB" << std::endl;
    std::cout << "  Registers per Block: " << deviceProp.regsPerBlock
              << std::endl;
    std::cout << "  Warp Size: " << deviceProp.warpSize << std::endl;
    std::cout << "  Max Threads per Block: " << deviceProp.maxThreadsPerBlock
              << std::endl;
    std::cout << "  Max Threads per Multiprocessor: "
              << deviceProp.maxThreadsPerMultiProcessor << std::endl;
    std::cout << "  Number of Multiprocessors: "
              << deviceProp.multiProcessorCount << std::endl;
    std::cout << "  Max Threads Dimensions: [" << deviceProp.maxThreadsDim[0]
              << ", " << deviceProp.maxThreadsDim[1] << ", "
              << deviceProp.maxThreadsDim[2] << "]" << std::endl;
    std::cout << "  Max Grid Size: [" << deviceProp.maxGridSize[0] << ", "
              << deviceProp.maxGridSize[1] << ", " << deviceProp.maxGridSize[2]
              << "]" << std::endl;
    std::cout << "  Max Clock Frequency (Multiprocessor): "
              << deviceProp.clockRate << " KHz" << std::endl;
    int wallClkRate;
    HIP_CHECK(hipDeviceGetAttribute(&wallClkRate,
                                    hipDeviceAttributeWallClockRate, deviceId));
    std::cout << "  Wall Clock Frequency (Constant): " << wallClkRate << " KHz"
              << std::endl;
  }
}

// Print GPU arch, UUID, and PCIe bus address.
void printGpuDeviceDetails(int deviceId) {
  hipDeviceProp_t prop;
  hipError_t err = hipGetDeviceProperties(&prop, deviceId);
  if (err != hipSuccess) {
    std::cout << "  GPU " << deviceId << ": failed to get properties ("
              << hipGetErrorString(err) << ")" << std::endl;
    return;
  }
  std::cout << "  Device ID: " << deviceId << std::endl;
  const char* modelName = prop.name;
  if (modelName != nullptr) {
    std::cout << "  Model: " << modelName << std::endl;
  } else {
    // No known model from GCN arch; show driver name
    char nameBuf[256];
    err = hipDeviceGetName(nameBuf, sizeof(nameBuf),
                           static_cast<hipDevice_t>(deviceId));
    if (err == hipSuccess && nameBuf[0] != '\0') {
      std::cout << "  Model: " << nameBuf << std::endl;
    } else {
      std::cout << "  Model: " << prop.name << std::endl;
    }
  }
  if (prop.gcnArchName[0] != '\0') {
    std::cout << "  GCN Arch: " << prop.gcnArchName << std::endl;
  }
  // UUID as hex string (hipUUID.bytes is 16 bytes)
  std::cout << "  UUID: ";
  for (int i = 0; i < 16; i++) {
    std::cout << std::hex << std::setfill('0') << std::setw(2)
              << (static_cast<unsigned>(prop.uuid.bytes[i]) & 0xFF);
  }
  std::cout << std::dec << std::endl;
  char pciBusId[32];
  err = hipDeviceGetPCIBusId(pciBusId, sizeof(pciBusId), deviceId);
  if (err == hipSuccess) {
    std::cout << "  PCIe Bus: " << pciBusId << std::endl;
  } else {
    std::cout << "  PCIe Bus: (unavailable)" << std::endl;
  }
}

void printStatistics(const std::vector<double>& durations,
                     unsigned totalIterations, unsigned numThreads,
                     unsigned readIterations, unsigned writeIterations,
                     unsigned verifiedReadsCount) {
  if (durations.empty()) {
    return;
  }

  // Calculate statistics
  double minVal = *std::min_element(durations.begin(), durations.end());
  double maxVal = *std::max_element(durations.begin(), durations.end());
  double sum = 0.0;
  for (double d : durations)
    sum += d;
  double avg = sum / durations.size();

  double variance = 0.0;
  for (double d : durations) {
    variance += (d - avg) * (d - avg);
  }
  variance /= durations.size();
  double stddev = std::sqrt(variance);

  // Print statistics - choose appropriate unit based on average
  // Use ms if >= 1 ms, us if >= 1 us, otherwise ns
  double min_display, max_display, avg_display, stddev_display;
  const char* time_unit;

  if (avg >= 1000000.0) {
    // Use milliseconds
    min_display = minVal / 1000000.0;
    max_display = maxVal / 1000000.0;
    avg_display = avg / 1000000.0;
    stddev_display = stddev / 1000000.0;
    time_unit = " ms";
  } else if (avg >= 1000.0) {
    // Use microseconds
    min_display = minVal / 1000.0;
    max_display = maxVal / 1000.0;
    avg_display = avg / 1000.0;
    stddev_display = stddev / 1000.0;
    time_unit = " us";
  } else {
    // Use nanoseconds
    min_display = minVal;
    max_display = maxVal;
    avg_display = avg;
    stddev_display = stddev;
    time_unit = " ns";
  }

  std::cout << "\nStatistics:" << std::endl;

  // Print iterations - endpoint-specific (at the top)
  if (readIterations > 0 || writeIterations > 0) {
    // NVMe endpoint: show Reads and Writes on separate lines
    std::cout << "  Reads:            " << std::setw(10) << readIterations
              << std::endl;
    if (verifiedReadsCount != UINT_MAX && readIterations > 0) {
      // Show verified reads count if verification was attempted
      std::cout << "  Verified Reads:   " << std::setw(10) << verifiedReadsCount
                << std::endl;
    }
    std::cout << "  Writes:           " << std::setw(10) << writeIterations
              << std::endl;
  } else if (totalIterations > 0) {
    // Other endpoints: show total iterations
    std::cout << "  Iterations:       " << std::setw(10) << totalIterations
              << std::endl;
  }

  // Print threads if provided
  if (numThreads > 0) {
    std::cout << "  Threads:          " << std::setw(10) << numThreads
              << std::endl;
  }

  std::cout << "  Minimum:          " << std::setw(10) << std::fixed
            << std::setprecision(2) << min_display << time_unit << std::endl;
  std::cout << "  Maximum:          " << std::setw(10) << std::fixed
            << std::setprecision(2) << max_display << time_unit << std::endl;
  std::cout << "  Average:          " << std::setw(10) << std::fixed
            << std::setprecision(2) << avg_display << time_unit << std::endl;
  std::cout << "  Standard Dev:     " << std::setw(10) << std::fixed
            << std::setprecision(2) << stddev_display << time_unit << std::endl;
}

void printHistogram(const std::vector<double>& durations, unsigned nIterations,
                    unsigned numThreads, unsigned readIterations,
                    unsigned writeIterations, unsigned verifiedReadsCount) {
  if (durations.empty() || nIterations == 0) {
    return;
  }

  // Get min/max for histogram binning
  double minVal = *std::min_element(durations.begin(), durations.end());
  double maxVal = *std::max_element(durations.begin(), durations.end());

  if (maxVal == minVal) {
    // All values are the same
    std::cout << "\nHistogram: All values are identical." << std::endl;
  } else {
    size_t n = durations.size();

    // Determine number of bins (8 to 64, but not more than data points)
    int desiredBins = std::min(64, std::max(8, (int)nIterations / 2));
    int numBins = std::min(desiredBins, (int)n);

    // Safety check: ensure we have at least one bin
    if (numBins <= 0) {
      numBins = 1;
    }

    // Create evenly-spaced bin boundaries based on range
    // This ensures consistent binning regardless of data distribution
    double range = maxVal - minVal;
    double binWidth = (range > 0.0 && numBins > 0) ? range / numBins : 1.0;

    // Create bin edges for display
    std::vector<double> binEdges;
    for (int i = 0; i <= numBins; i++) {
      binEdges.push_back(minVal + i * binWidth);
    }
    // Ensure the last edge includes the maximum value exactly
    binEdges[numBins] = maxVal;

    std::vector<int> bins(numBins, 0);
    // Fill histogram bins using direct calculation
    for (double d : durations) {
      // Calculate bin index directly
      int binIdx;
      if (d <= minVal) {
        binIdx = 0;
      } else if (d >= maxVal) {
        binIdx = numBins - 1;
      } else {
        // Calculate which bin this value falls into
        binIdx = (int)((d - minVal) / binWidth);
        // Clamp to valid range (shouldn't be necessary, but be safe)
        if (binIdx < 0) {
          binIdx = 0;
        } else if (binIdx >= numBins) {
          binIdx = numBins - 1;
        }
      }
      bins[binIdx]++;
    }

    // Find max count for scaling
    int maxCount = *std::max_element(bins.begin(), bins.end());

    // Choose appropriate unit based on average: ms if >= 1 ms, us if >= 1 us,
    // otherwise ns
    double avg = (minVal + maxVal) / 2.0;
    double edge1, edge2;
    const char* time_unit;

    if (avg >= 1000000.0) {
      // Use milliseconds
      time_unit = " ms";
    } else if (avg >= 1000.0) {
      // Use microseconds
      time_unit = " us";
    } else {
      // Use nanoseconds
      time_unit = " ns";
    }

    // Print histogram
    std::cout << "\nHistogram (Runtime in" << time_unit << "):" << std::endl;
    const int barWidth = 60;
    for (int i = 0; i < numBins; i++) {
      if (avg >= 1000000.0) {
        edge1 = binEdges[i] / 1000000.0;
        edge2 = binEdges[i + 1] / 1000000.0;
      } else if (avg >= 1000.0) {
        edge1 = binEdges[i] / 1000.0;
        edge2 = binEdges[i + 1] / 1000.0;
      } else {
        edge1 = binEdges[i];
        edge2 = binEdges[i + 1];
      }
      std::cout << "  [" << std::setw(8) << std::fixed << std::setprecision(1)
                << edge1 << " - " << std::setw(8) << std::fixed
                << std::setprecision(1) << edge2 << "): ";

      int barLen = (maxCount > 0) ? (bins[i] * barWidth / maxCount) : 0;
      std::cout << std::string(barLen, '#');
      if (bins[i] > 0) {
        std::cout << " " << bins[i];
      }
      std::cout << std::endl;
    }
  }

  // Print statistics after histogram
  printStatistics(durations, nIterations, numThreads, readIterations,
                  writeIterations, verifiedReadsCount);
}

// Helper function to allocate HSA device memory
hsa_status_t allocDeviceMemory(size_t size, void** ptr, const char* direction) {
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

  hsa_iterate_agents(
    [](hsa_agent_t agent, void* data) -> hsa_status_t {
      hsa_device_type_t device_type;
      hsa_status_t status = hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE,
                                               &device_type);
      if (status != HSA_STATUS_SUCCESS) {
        return status;
      }

      if (device_type == HSA_DEVICE_TYPE_GPU) {
        // Found GPU agent, iterate its regions
        // Look for fine-grained global region first (better for CPU-GPU
        // coherence) Then fall back to coarse-grained if fine-grained not
        // available
        struct RegionData {
          hsa_region_t fine;
          hsa_region_t coarse;
        };
        RegionData regions = {{0}, {0}};

        hsa_agent_iterate_regions(
          agent,
          [](hsa_region_t region, void* data) -> hsa_status_t {
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
              status = hsa_region_get_info(
                region, HSA_REGION_INFO_RUNTIME_ALLOC_ALLOWED, &alloc_allowed);
              if (status == HSA_STATUS_SUCCESS && alloc_allowed) {
                // Check if fine-grained or coarse-grained
                uint32_t global_flags;
                status = hsa_region_get_info(region,
                                             HSA_REGION_INFO_GLOBAL_FLAGS,
                                             &global_flags);
                if (status == HSA_STATUS_SUCCESS) {
                  RegionData* regions_ptr = (RegionData*)data;

                  if (global_flags & HSA_REGION_GLOBAL_FLAG_FINE_GRAINED) {
                    regions_ptr->fine = region;
                  } else if (global_flags &
                             HSA_REGION_GLOBAL_FLAG_COARSE_GRAINED) {
                    regions_ptr->coarse = region;
                  }
                }
              }
            }
            return HSA_STATUS_SUCCESS;
          },
          &regions);

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
    },
    &device_region);

  if (device_region.handle == 0) {
    std::cerr << "Error: Could not find allocatable device memory region"
              << std::endl;
    return HSA_STATUS_ERROR_INVALID_REGION;
  }

  // Check what type of region we found
  uint32_t global_flags = 0;
  hsa_region_get_info(device_region, HSA_REGION_INFO_GLOBAL_FLAGS,
                      &global_flags);
  if (global_flags & HSA_REGION_GLOBAL_FLAG_FINE_GRAINED) {
    std::cout << "  Info: (" << direction << "):  Using HSA fine-grained "
              << "global memory region" << std::endl;
  } else if (global_flags & HSA_REGION_GLOBAL_FLAG_COARSE_GRAINED) {
    std::cout << "  Info: (" << direction << "):  Using HSA coarse-grained "
              << "global memory region" << std::endl;
  }

  // Allocate memory from device region
  status = hsa_memory_allocate(device_region, size, ptr);
  return status;
}

hipError_t allocateQueue(size_t size, bool isDeviceMemory,
                         const char* queueName, void** ptr) {
  if (isDeviceMemory) {
    // Allocate device memory using hipMalloc (exportable as DMA-BUF)
    // This matches VRAM buffer allocation and allows DMA-BUF export for
    // physical address resolution in nvme-ep
    hipError_t hipErr = hipMalloc(ptr, size);
    if (hipErr != hipSuccess) {
      std::cerr << "Error: hipMalloc failed for " << queueName << ": "
                << hipGetErrorString(hipErr) << std::endl;
      return hipErrorMemoryAllocation;
    }
    // Zero-initialize using hipMemset
    hipError_t memsetErr = hipMemset(*ptr, 0, size);
    if (memsetErr != hipSuccess) {
      std::cerr << "Warning: hipMemset failed for " << queueName << ": "
                << hipGetErrorString(memsetErr) << std::endl;
      // Continue anyway - memory might already be zeroed
    }
  } else {
    // Allocate host-accessible memory using HIP (GPU-accessible)
    // Use hipHostMallocMapped to ensure GPU can access it (needed for test-ep)
    // nvme-ep will reallocate with hipHostMallocCoherent if needed
    hipError_t hipErr = hipHostMalloc(ptr, size, hipHostMallocMapped);
    if (hipErr != hipSuccess) {
      // HIP not available (e.g., emulate mode), fall back to malloc
      *ptr = malloc(size);
      if (*ptr == nullptr) {
        std::cerr << "Error: malloc failed for " << queueName << std::endl;
        return hipErrorMemoryAllocation;
      }
    }
    memset(*ptr, 0, size);
  }

  return hipSuccess;
}

void freeQueue(void* ptr, bool isDeviceMemory, const char* queueName) {
  if (isDeviceMemory) {
    // Free HIP device memory
    if (ptr != nullptr) {
      hipError_t hipErr = hipFree(ptr);
      if (hipErr != hipSuccess) {
        std::cerr << "Warning: hipFree failed for " << queueName << ": "
                  << hipGetErrorString(hipErr) << std::endl;
      }
    }
  } else {
    // Free HIP host memory or malloc-allocated memory
    if (ptr != nullptr) {
      hipError_t hipErr = hipHostFree(ptr);
      if (hipErr != hipSuccess) {
        // Not HIP-allocated, use regular free
        free(ptr);
      }
    }
  }
}

__host__ bool reallocateQueue(void** ptr, size_t size, const char* queueName) {
  if (!ptr || !*ptr) {
    return false;
  }

  void* coherent_ptr = nullptr;
  hipError_t coherent_err = hipHostMalloc(&coherent_ptr, size,
                                          hipHostMallocMapped |
                                            hipHostMallocCoherent);
  if (coherent_err != hipSuccess) {
    fprintf(stdout, "Warning: hipHostMallocCoherent failed for %s: %s\n",
            queueName, hipGetErrorString(coherent_err));
    fprintf(stdout, "Falling back to regular allocation (may not work on "
                    "gfx900)\n");
    return false;
  }

  // Copy data from original allocation to coherent memory
  memcpy(coherent_ptr, *ptr, size);

  // Free original allocation (may be hipHostMalloc or malloc)
  hipError_t freeErr = hipHostFree(*ptr);
  if (freeErr != hipSuccess) {
    // Not HIP-allocated, use regular free
    free(*ptr);
  }

  // Update pointer to coherent allocation
  *ptr = coherent_ptr;
  return true;
}

__host__ void* getGpuPointer(void* host_ptr, bool is_device,
                             const char* queue_name) {
  if (!host_ptr || !queue_name) {
    return NULL;
  }

  if (is_device) {
    // Device memory - GPU pointer is same as host pointer
    return host_ptr;
  } else {
    // Host memory - get GPU pointer via hipHostGetDevicePointer
    void* gpu_ptr = nullptr;
    hipError_t err = hipHostGetDevicePointer(&gpu_ptr, host_ptr, 0);
    if (err != hipSuccess) {
      fprintf(stdout, "Warning: hipHostGetDevicePointer failed for %s: %s\n",
              queue_name, hipGetErrorString(err));
      return NULL;
    }
    return gpu_ptr;
  }
}

hipError_t allocateDataBuffer(size_t size, unsigned memoryMode, void** ptr) {
  bool dataBufferOnDevice = (memoryMode & XIO_MEM_MODE_DATA_DEVICE) != 0;

  if (dataBufferOnDevice) {
    // Allocate device memory using HSA
    const size_t host_page_size = sysconf(_SC_PAGESIZE);
    size_t alignedSize = ((size + host_page_size - 1) / host_page_size) *
                         host_page_size;

    hsa_status_t hsa_status = allocDeviceMemory(alignedSize, ptr,
                                                "Data Buffer");
    if (hsa_status != HSA_STATUS_SUCCESS) {
      std::cerr << "Error: HSA memory allocation failed for data buffer: "
                << hsa_status << std::endl;
      return hipErrorMemoryAllocation;
    }
    memset(*ptr, 0, size);
  } else {
    // Allocate host-accessible memory using HIP or regular malloc
    // Use hipHostMallocMapped to ensure GPU can access it (matches QEMU guest
    // code) Try HIP first, but fall back to malloc if HIP is not available
    // (emulate mode)
    hipError_t hipErr = hipHostMalloc(ptr, size, hipHostMallocMapped);
    if (hipErr != hipSuccess) {
      // HIP not available (e.g., emulate mode), use regular malloc
      *ptr = malloc(size);
      if (*ptr == nullptr) {
        return hipErrorMemoryAllocation;
      }
    }
    memset(*ptr, 0, size);
  }

  return hipSuccess;
}

// Free data buffer memory based on memory mode
void freeDataBuffer(void* ptr, unsigned memoryMode) {
  bool dataBufferOnDevice = (memoryMode & XIO_MEM_MODE_DATA_DEVICE) != 0;

  if (dataBufferOnDevice) {
    // Free HSA device memory
    if (ptr != nullptr) {
      hsa_memory_free(ptr);
    }
  } else {
    // Free HIP host memory or regular free
    if (ptr != nullptr) {
      hipError_t hipErr = hipHostFree(ptr);
      if (hipErr != hipSuccess) {
        // HIP not available (e.g., emulate mode), use regular free
        free(ptr);
      }
    }
  }
}

std::string extractEndpointName(int argc, char** argv) {
  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg == "-e" || arg == "--endpoint") {
      if (i + 1 < argc) {
        return std::string(argv[i + 1]);
      }
      break;
    } else if (arg.find("--endpoint=") == 0) {
      return arg.substr(11);
    } else if (arg.find("-e=") == 0) {
      return arg.substr(3);
    }
  }
  return std::string();
}

int detectPciMmioBridgeBdf(uint16_t* bdf_out) {
  if (!bdf_out) {
    return -1;
  }

  std::cout << "Detecting PCI MMIO bridge BDF" << std::endl;

  const uint16_t PCI_MMIO_BRIDGE_VENDOR_ID = 0x1b36;
  const uint16_t PCI_MMIO_BRIDGE_DEVICE_ID = 0x0015;
  const char* PCI_SYSFS_PATH = "/sys/bus/pci/devices";

  DIR* dir = opendir(PCI_SYSFS_PATH);
  if (!dir) {
    std::cerr << "Error: Failed to open " << PCI_SYSFS_PATH << ": "
              << strerror(errno) << std::endl;
    return -1;
  }

  std::vector<uint16_t> found_bdfs;
  struct dirent* entry;
  int devices_checked = 0;
  int devices_skipped = 0;

  while ((entry = readdir(dir)) != nullptr) {
    // Skip . and ..
    if (entry->d_name[0] == '.') {
      continue;
    }

    // PCI device entries are in format "0000:BB:DD.F"
    std::string dev_name = entry->d_name;
    if (dev_name.length() < 12 || dev_name.substr(0, 5) != "0000:") {
      devices_skipped++;
      std::cout << "Skipping entry (format check): " << dev_name
                << " (length=" << dev_name.length() << ")" << std::endl;
      continue;
    }

    // Parse BDF from device name (format: 0000:BB:DD.F)
    unsigned int bus, device, function;
    int parsed = sscanf(dev_name.c_str(), "0000:%02x:%02x.%x", &bus, &device,
                        &function);
    if (parsed != 3) {
      devices_skipped++;
      std::cout << "Skipping entry (parse failed): " << dev_name << " (parsed "
                << parsed << " values)" << std::endl;
      continue;
    }

    devices_checked++;

    // Construct config file path
    std::string config_path = std::string(PCI_SYSFS_PATH) + "/" + dev_name +
                              "/config";
    int fd = open(config_path.c_str(), O_RDONLY);
    if (fd < 0) {
      std::cerr << "Warning: Failed to open config file " << config_path << ": "
                << strerror(errno) << std::endl;
      continue; // Skip if can't open config
    }

    // Read Vendor ID (offset 0x00) and Device ID (offset 0x02)
    uint16_t vendor_id = 0, device_id = 0;
    bool read_vendor_ok = false;
    bool read_device_ok = false;

    if (lseek(fd, 0x00, SEEK_SET) >= 0) {
      ssize_t bytes_read = read(fd, &vendor_id, sizeof(vendor_id));
      if (bytes_read == sizeof(vendor_id)) {
        read_vendor_ok = true;
      } else {
        std::cerr << "Warning: Failed to read vendor ID from " << config_path
                  << ": read " << bytes_read << " bytes (expected "
                  << sizeof(vendor_id) << ")" << std::endl;
        vendor_id = 0;
      }
    }
    if (lseek(fd, 0x02, SEEK_SET) >= 0) {
      ssize_t bytes_read = read(fd, &device_id, sizeof(device_id));
      if (bytes_read == sizeof(device_id)) {
        read_device_ok = true;
      } else {
        std::cerr << "Warning: Failed to read device ID from " << config_path
                  << ": read " << bytes_read << " bytes (expected "
                  << sizeof(device_id) << ")" << std::endl;
        device_id = 0;
      }
    }
    close(fd);

    // Debug output for devices with Red Hat vendor ID
    if (read_vendor_ok && vendor_id == PCI_MMIO_BRIDGE_VENDOR_ID) {
      std::cout << "Found Red Hat device " << dev_name << ": vendor=0x"
                << std::hex << vendor_id << ", device=0x" << device_id
                << std::dec;
      if (read_device_ok && device_id == PCI_MMIO_BRIDGE_DEVICE_ID) {
        std::cout << " (MATCH - PCI MMIO bridge)" << std::endl;
      } else if (!read_device_ok) {
        std::cout << " (device ID read failed)" << std::endl;
      } else {
        std::cout << " (expected device=0x" << std::hex
                  << PCI_MMIO_BRIDGE_DEVICE_ID << std::dec << ")" << std::endl;
      }
    }

    // Check if this is the PCI MMIO bridge
    if (vendor_id == PCI_MMIO_BRIDGE_VENDOR_ID &&
        device_id == PCI_MMIO_BRIDGE_DEVICE_ID) {
      // Encode BDF: 0xBBDD where BB=bus (bits 15:8), D=device (bits 7:3),
      // F=function (bits 2:0)
      uint16_t bdf = (static_cast<uint16_t>(bus) << 8) |
                     (static_cast<uint16_t>(device) << 3) |
                     static_cast<uint16_t>(function);
      found_bdfs.push_back(bdf);
    }
  }

  closedir(dir);

  std::cout << "PCI MMIO bridge detection: checked " << devices_checked
            << " devices, skipped " << devices_skipped << " entries"
            << std::endl;

  // Error out if 0 or >1 bridges found
  if (found_bdfs.empty()) {
    std::cerr << "Error: PCI MMIO bridge not found (Vendor 0x" << std::hex
              << PCI_MMIO_BRIDGE_VENDOR_ID << ", Device 0x"
              << PCI_MMIO_BRIDGE_DEVICE_ID << std::dec << ")" << std::endl;
    std::cerr << "Note: PCI MMIO bridge is a QEMU device that only exists "
              << "inside a VM." << std::endl;
    std::cerr << "Please run this command inside the QEMU VM where the bridge "
              << "is present." << std::endl;
    return -1;
  }

  if (found_bdfs.size() > 1) {
    std::cerr << "Error: Multiple PCI MMIO bridges found (" << found_bdfs.size()
              << "):" << std::endl;
    for (size_t i = 0; i < found_bdfs.size(); ++i) {
      uint8_t bus = (found_bdfs[i] >> 8) & 0xFF;
      uint8_t device = (found_bdfs[i] >> 3) & 0x1F;
      uint8_t function = found_bdfs[i] & 0x7;
      std::cerr << "  " << i + 1 << ". 0000:" << std::hex << std::setfill('0')
                << std::setw(2) << static_cast<unsigned>(bus) << ":"
                << std::setw(2) << static_cast<unsigned>(device) << "."
                << std::dec << static_cast<unsigned>(function) << std::endl;
    }
    return -1;
  }

  // Exactly one bridge found - return its BDF
  *bdf_out = found_bdfs[0];
  uint8_t bus = (found_bdfs[0] >> 8) & 0xFF;
  uint8_t device = (found_bdfs[0] >> 3) & 0x1F;
  uint8_t function = found_bdfs[0] & 0x7;
  std::cout << "Detected PCI MMIO bridge at 0000:" << std::hex
            << std::setfill('0') << std::setw(2) << static_cast<unsigned>(bus)
            << ":" << std::setw(2) << static_cast<unsigned>(device) << "."
            << std::dec << static_cast<unsigned>(function) << " (BDF: 0x"
            << std::hex << std::setfill('0') << std::setw(4) << found_bdfs[0]
            << std::dec << ")" << std::endl;

  return 0;
}

__host__ int detectBdfFromDevice(const char* device_path, uint16_t* bdf_out) {
  if (!device_path || !bdf_out) {
    return -EINVAL;
  }

  // Extract device name from path (e.g., "nvme0" from "/dev/nvme0")
  std::string dev_path = device_path;
  size_t last_slash = dev_path.find_last_of('/');
  if (last_slash == std::string::npos || last_slash == dev_path.length() - 1) {
    std::cerr << "Error: Invalid device path: " << device_path << std::endl;
    return -EINVAL;
  }

  std::string device_name = dev_path.substr(last_slash + 1);

  // Build sysfs device symlink path: /sys/class/nvme/nvme0/device
  std::string sysfs_path = "/sys/class/nvme/" + device_name + "/device";

  // Read the symlink to get PCI device path
  char link_target[256];
  ssize_t len = readlink(sysfs_path.c_str(), link_target,
                         sizeof(link_target) - 1);
  if (len < 0) {
    std::cerr << "Error: Failed to read symlink " << sysfs_path << ": "
              << strerror(errno) << std::endl;
    std::cerr << "Device " << device_path << " may not exist or not be an "
              << "NVMe device" << std::endl;
    return -ENODEV;
  }
  link_target[len] = '\0';

  // Parse PCI address from symlink target
  std::string link_str = link_target;
  size_t pci_start = link_str.find("0000:");
  if (pci_start == std::string::npos) {
    std::cerr << "Error: Could not find PCI address in symlink: " << link_target
              << std::endl;
    return -ENODEV;
  }

  // Extract the PCI address substring
  size_t addr_start = pci_start;
  size_t addr_end = link_str.find('/', addr_start);
  if (addr_end == std::string::npos) {
    addr_end = link_str.length();
  }
  std::string pci_addr = link_str.substr(addr_start, addr_end - addr_start);

  // Parse bus, device, function from PCI address (format: 0000:BB:DD.F)
  unsigned int bus, device, function;
  if (sscanf(pci_addr.c_str(), "0000:%02x:%02x.%x", &bus, &device, &function) !=
      3) {
    std::cerr << "Error: Failed to parse PCI address: " << pci_addr
              << std::endl;
    return -EINVAL;
  }

  // Validate parsed values
  if (bus > 0xFF || device > 0x1F || function > 0x7) {
    std::cerr << "Error: Invalid PCI address values: bus=0x" << std::hex << bus
              << ", device=0x" << device << ", function=0x" << function
              << std::dec << std::endl;
    return -EINVAL;
  }

  // Encode BDF: 0xBBDD where BB=bus (bits 15:8), D=device (bits 7:3),
  // F=function (bits 2:0)
  uint16_t bdf = (static_cast<uint16_t>(bus) << 8) |
                 (static_cast<uint16_t>(device) << 3) |
                 static_cast<uint16_t>(function);

  *bdf_out = bdf;

  std::cout << "Detected PCI BDF for " << device_path << ": 0000:" << std::hex
            << std::setfill('0') << std::setw(2) << static_cast<unsigned>(bus)
            << ":" << std::setw(2) << static_cast<unsigned>(device) << "."
            << std::dec << static_cast<unsigned>(function) << " (BDF: 0x"
            << std::hex << std::setfill('0') << std::setw(4) << bdf << std::dec
            << ")" << std::endl;

  return 0;
}

__host__ int detectEmulatedNvme(const char* device_path,
                                bool* is_emulated_out) {
  if (!device_path || !is_emulated_out) {
    return -EINVAL;
  }

  // Extract device name from path (e.g., "nvme0" from "/dev/nvme0")
  std::string dev_path = device_path;
  size_t last_slash = dev_path.find_last_of('/');
  if (last_slash == std::string::npos || last_slash == dev_path.length() - 1) {
    std::cerr << "Error: Invalid device path: " << device_path << std::endl;
    return -EINVAL;
  }

  std::string device_name = dev_path.substr(last_slash + 1);

  // Build sysfs device symlink path: /sys/class/nvme/nvme0/device
  std::string sysfs_path = "/sys/class/nvme/" + device_name + "/device";

  // Read the symlink to get PCI device path
  char link_target[256];
  ssize_t len = readlink(sysfs_path.c_str(), link_target,
                         sizeof(link_target) - 1);
  if (len < 0) {
    std::cerr << "Error: Failed to read symlink " << sysfs_path << ": "
              << strerror(errno) << std::endl;
    std::cerr << "Device " << device_path << " may not exist or not be an "
              << "NVMe device" << std::endl;
    return -ENODEV;
  }
  link_target[len] = '\0';

  // Parse PCI address from symlink target
  std::string link_str = link_target;

  // Find the PCI address pattern (0000:BB:DD.F)
  size_t pci_start = link_str.find("0000:");
  if (pci_start == std::string::npos) {
    std::cerr << "Error: Could not find PCI address in symlink: " << link_target
              << std::endl;
    return -ENODEV;
  }

  // Extract the PCI address substring
  size_t addr_start = pci_start;
  size_t addr_end = link_str.find('/', addr_start);
  if (addr_end == std::string::npos) {
    addr_end = link_str.length();
  }
  std::string pci_addr = link_str.substr(addr_start, addr_end - addr_start);

  // Build paths to vendor and device ID files
  std::string pci_dev_path = "/sys/bus/pci/devices/" + pci_addr;
  std::string vendor_path = pci_dev_path + "/vendor";
  std::string device_path_pci = pci_dev_path + "/device";

  // Read Vendor ID
  int vendor_fd = open(vendor_path.c_str(), O_RDONLY);
  if (vendor_fd < 0) {
    std::cerr << "Error: Failed to open vendor file " << vendor_path << ": "
              << strerror(errno) << std::endl;
    return -errno;
  }

  uint16_t vendor_id = 0;
  char vendor_buf[16];
  ssize_t bytes_read = read(vendor_fd, vendor_buf, sizeof(vendor_buf) - 1);
  close(vendor_fd);

  if (bytes_read > 0) {
    vendor_buf[bytes_read] = '\0';
    // Parse hex value (format: "0x1b36\n" or "1b36\n")
    vendor_id = static_cast<uint16_t>(strtoul(vendor_buf, nullptr, 0));
  } else {
    std::cerr << "Error: Failed to read vendor ID from " << vendor_path
              << std::endl;
    return -EIO;
  }

  // Read Device ID
  int device_fd = open(device_path_pci.c_str(), O_RDONLY);
  if (device_fd < 0) {
    std::cerr << "Error: Failed to open device file " << device_path_pci << ": "
              << strerror(errno) << std::endl;
    return -errno;
  }

  uint16_t device_id = 0;
  char device_buf[16];
  bytes_read = read(device_fd, device_buf, sizeof(device_buf) - 1);
  close(device_fd);

  if (bytes_read > 0) {
    device_buf[bytes_read] = '\0';
    // Parse hex value (format: "0x0010\n" or "0010\n")
    device_id = static_cast<uint16_t>(strtoul(device_buf, nullptr, 0));
  } else {
    std::cerr << "Error: Failed to read device ID from " << device_path_pci
              << std::endl;
    return -EIO;
  }

  // QEMU emulated NVMe controllers use Vendor ID 0x1b36 (Red Hat, Inc.)
  const uint16_t QEMU_VENDOR_ID = 0x1b36;

  bool is_emulated = (vendor_id == QEMU_VENDOR_ID);

  *is_emulated_out = is_emulated;

  std::cout << "NVMe controller " << device_path << " (PCI " << pci_addr
            << "): VID=0x" << std::hex << std::setfill('0') << std::setw(4)
            << vendor_id << ", DID=0x" << std::setw(4) << device_id << std::dec
            << " -> " << (is_emulated ? "EMULATED" : "PASSTHROUGH")
            << std::endl;

  return 0;
}

// Get physical address from virtual address
__host__ uint64_t getPhysAddr(void* virt_addr) {
  int pagemap_fd = open("/proc/self/pagemap", O_RDONLY);
  if (pagemap_fd < 0) {
    return 0;
  }

  uint64_t page = reinterpret_cast<uint64_t>(virt_addr) / sysconf(_SC_PAGESIZE);
  uint64_t offset = page * sizeof(uint64_t);

  if (lseek(pagemap_fd, offset, SEEK_SET) != static_cast<off_t>(offset)) {
    close(pagemap_fd);
    return 0;
  }

  uint64_t pagemap_entry = 0;
  if (read(pagemap_fd, &pagemap_entry, sizeof(pagemap_entry)) !=
      sizeof(pagemap_entry)) {
    close(pagemap_fd);
    return 0;
  }

  close(pagemap_fd);

  // Check if page is present (bit 63)
  if (!(pagemap_entry & (1ULL << 63))) {
    return 0; // Page not present
  }

  // Extract physical page frame number (bits 0-54)
  uint64_t pfn = pagemap_entry & 0x7FFFFFFFFFFFFFULL;
  uint64_t phys_addr = (pfn * sysconf(_SC_PAGESIZE)) +
                       (reinterpret_cast<uint64_t>(virt_addr) %
                        sysconf(_SC_PAGESIZE));

  return phys_addr;
}

__host__ int getPagePhysAddrs(void* virt_addr, size_t size, uint64_t* phys_out,
                              size_t max_pages) {
  size_t page_sz = sysconf(_SC_PAGESIZE);
  uintptr_t base = reinterpret_cast<uintptr_t>(virt_addr);
  size_t num_pages = (size + page_sz - 1) / page_sz;

  if (!virt_addr || size == 0 || !phys_out || num_pages > max_pages) {
    return -EINVAL;
  }

  int fd = open("/proc/self/pagemap", O_RDONLY);
  if (fd < 0)
    return -errno;

  for (size_t i = 0; i < num_pages; i++) {
    uintptr_t page_va = base + i * page_sz;
    uint64_t page_num = page_va / page_sz;
    off_t off = page_num * sizeof(uint64_t);

    if (lseek(fd, off, SEEK_SET) != static_cast<off_t>(off)) {
      close(fd);
      return -EIO;
    }

    uint64_t entry = 0;
    if (read(fd, &entry, sizeof(entry)) != sizeof(entry)) {
      close(fd);
      return -EIO;
    }

    if (!(entry & (1ULL << 63))) {
      close(fd);
      return -EFAULT;
    }

    uint64_t pfn = entry & 0x7FFFFFFFFFFFFFULL;
    phys_out[i] = pfn * page_sz;
  }

  close(fd);
  return static_cast<int>(num_pages);
}

__host__ uint64_t getPhysAddr(void* buffer_ptr, size_t size, bool is_device,
                              uint16_t nvme_bdf,
                              const char* kernel_module_device,
                              bool is_emulated, const char* buffer_name) {
  if (!buffer_ptr || size == 0 || !buffer_name) {
    return 0;
  }

  if (is_device) {
    // Device memory (HSA) - export as DMA-BUF and get physical address
    if (!kernel_module_device) {
      fprintf(stderr,
              "ERROR: kernel_module_device required for device memory "
              "buffer %s\n",
              buffer_name);
      return 0;
    }

    uint64_t phys_addr = 0;
    int ret = exportRegVramBuf(buffer_ptr, size, nvme_bdf, kernel_module_device,
                               &phys_addr, is_emulated);
    if (ret < 0) {
      fprintf(stderr, "ERROR: Failed to register %s device memory: %s\n",
              buffer_name, strerror(-ret));
      return 0;
    }
    fprintf(stdout,
            "%s device memory: virt=0x%016llx, phys=0x%016llx (via DMA-BUF)\n",
            buffer_name,
            (unsigned long long)reinterpret_cast<uint64_t>(buffer_ptr),
            (unsigned long long)phys_addr);
    return phys_addr;
  } else {
    // Host memory - use pagemap to get physical address
    uint64_t phys_addr = getPhysAddr(buffer_ptr);
    if (phys_addr == 0) {
      fprintf(stdout,
              "Warning: Failed to get %s physical address, using "
              "virtual address\n",
              buffer_name);
      return reinterpret_cast<uint64_t>(buffer_ptr);
    }
    return phys_addr;
  }
}

__host__ int kmodRegQueue(int kmod_fd, void* virt_addr, uint64_t phys_addr,
                          size_t size, uint8_t queue_type, uint16_t nvme_bdf,
                          uint64_t prp2, const char* queue_name) {
  if (kmod_fd < 0 || !virt_addr || size == 0 || !queue_name) {
    return -EINVAL;
  }

  struct rocm_axiio_register_queue_addr_req reg_req;
  memset(&reg_req, 0, sizeof(reg_req));
  reg_req.virt_addr = reinterpret_cast<uint64_t>(virt_addr);
  reg_req.phys_addr = phys_addr;
  reg_req.size = size;
  reg_req.queue_type = queue_type;
  reg_req.nvme_bdf = nvme_bdf;
  reg_req.prp2 = prp2;

  int ret = ioctl(kmod_fd, ROCM_XIO_REGISTER_QUEUE_ADDR, &reg_req);
  if (ret < 0) {
    fprintf(stdout, "Failed to register %s address: %s\n", queue_name,
            strerror(errno));
    return -errno;
  }

  return 0;
}

__host__ int registerMemoryForGpu(void* host_ptr, size_t size, const char* name,
                                  void** gpu_ptr_out) {
  if (!host_ptr || size == 0 || !name || !gpu_ptr_out) {
    return -EINVAL;
  }

  // Initialize output
  *gpu_ptr_out = nullptr;

  // Step 1: Register with HIP
  hipError_t hip_err = hipHostRegister(host_ptr, size, hipHostRegisterMapped);
  if (hip_err != hipSuccess) {
    fprintf(stdout, "Warning: Failed to register %s with HIP: %s\n", name,
            hipGetErrorString(hip_err));
    return -1;
  }

  // Step 2: Get GPU pointer
  void* gpu_ptr = nullptr;
  hipError_t gpu_ptr_err = hipHostGetDevicePointer(&gpu_ptr, host_ptr, 0);
  if (gpu_ptr_err != hipSuccess) {
    fprintf(stdout,
            "Warning: hipHostGetDevicePointer failed for "
            "%s: %s\n",
            name, hipGetErrorString(gpu_ptr_err));
    (void)hipHostUnregister(host_ptr);
    return -1;
  }

  *gpu_ptr_out = gpu_ptr;
  fprintf(stdout,
          "Info: %s registered for GPU access: "
          "host=%p, gpu=%p\n",
          name, host_ptr, gpu_ptr);

  return 0;
}

__host__ int setupQueueForGpu(size_t size, bool is_device, uint16_t nvme_bdf,
                              const char* kernel_module_device,
                              bool is_emulated, const char* queue_name,
                              struct xioQueueSetup* setup) {
  if (!setup || size == 0 || !queue_name) {
    return -EINVAL;
  }

  // Initialize output structure
  memset(setup, 0, sizeof(*setup));
  setup->virt = nullptr;
  setup->gpu = nullptr;
  setup->phys = 0;
  setup->uses_coherent = false;

  hipError_t alloc_err = hipSuccess;
  bool hip_registered = false;

  // Step 1: Allocate queue memory
  alloc_err = allocateQueue(size, is_device, queue_name, &setup->virt);
  if (alloc_err != hipSuccess) {
    fprintf(stdout, "Failed to allocate %s: %s\n", queue_name,
            hipGetErrorString(alloc_err));
    return -ENOMEM;
  }

  // Zero-initialize queue
  memset(setup->virt, 0, size);

  // Step 2: Reallocate with coherent memory if host memory
  if (!is_device) {
    setup->uses_coherent = reallocateQueue(&setup->virt, size, queue_name);
  }

  // Step 3: Register with HIP (skip if coherent or device memory)
  if (!setup->uses_coherent && !is_device) {
    hipError_t hip_err = hipHostRegister(setup->virt, size,
                                         hipHostRegisterMapped);
    if (hip_err != hipSuccess) {
      fprintf(stdout, "Warning: Failed to register %s with HIP: %s\n",
              queue_name, hipGetErrorString(hip_err));
      // Cleanup
      if (setup->uses_coherent) {
        (void)hipHostFree(setup->virt);
      } else {
        freeQueue(setup->virt, is_device, queue_name);
      }
      setup->virt = nullptr;
      return -EIO;
    }
    hip_registered = true;
  }

  // Step 4: Get GPU pointer
  setup->gpu = getGpuPointer(setup->virt, is_device, queue_name);
  if (!setup->gpu) {
    // Cleanup
    if (hip_registered) {
      (void)hipHostUnregister(setup->virt);
    }
    if (setup->uses_coherent) {
      (void)hipHostFree(setup->virt);
    } else {
      freeQueue(setup->virt, is_device, queue_name);
    }
    setup->virt = nullptr;
    return -EIO;
  }

  // Step 5: Get physical address
  if (!kernel_module_device) {
    fprintf(stderr, "ERROR: kernel_module_device required for %s\n",
            queue_name);
    // Cleanup
    if (hip_registered) {
      (void)hipHostUnregister(setup->virt);
    }
    if (setup->uses_coherent) {
      (void)hipHostFree(setup->virt);
    } else {
      freeQueue(setup->virt, is_device, queue_name);
    }
    setup->virt = nullptr;
    setup->gpu = nullptr;
    return -EINVAL;
  }

  setup->phys = getPhysAddr(setup->virt, size, is_device, nvme_bdf,
                            kernel_module_device, is_emulated, queue_name);
  if (setup->phys == 0 && is_device) {
    // Device memory requires physical address
    fprintf(stderr,
            "ERROR: Failed to get physical address for %s device "
            "memory\n",
            queue_name);
    // Cleanup
    if (hip_registered) {
      (void)hipHostUnregister(setup->virt);
    }
    if (setup->uses_coherent) {
      (void)hipHostFree(setup->virt);
    } else {
      freeQueue(setup->virt, is_device, queue_name);
    }
    setup->virt = nullptr;
    setup->gpu = nullptr;
    return -ENOTSUP;
  }

  fprintf(stdout,
          "Info: %s setup complete: virt=%p, gpu=%p, phys=0x%llx, "
          "coherent=%d\n",
          queue_name, setup->virt, setup->gpu, (unsigned long long)setup->phys,
          setup->uses_coherent ? 1 : 0);

  return 0;
}

__host__ int buildQueuePrpList(struct xioQueueSetup* setup, size_t queue_size,
                               bool is_device, const char* queue_name) {
  if (!setup || !setup->virt || queue_size == 0)
    return -EINVAL;

  size_t page_sz = sysconf(_SC_PAGESIZE);
  size_t num_pages = (queue_size + page_sz - 1) / page_sz;

  setup->prp_list = nullptr;
  setup->prp_list_phys = 0;
  setup->prp2 = 0;

  if (num_pages <= 1)
    return 0;

  // Ensure host queue memory is page-aligned before constructing a multi-page
  // PRP list. If setup->virt came from a malloc-based fallback, it may not be
  // aligned to the system page size, which would yield incorrect PRP entries.
  if (!is_device) {
    uintptr_t virt_addr = reinterpret_cast<uintptr_t>(setup->virt);
    if ((virt_addr % page_sz) != 0) {
      fprintf(stderr,
              "ERROR: Queue %s virtual address %p is not page-aligned "
              "(page size: %zu); cannot build PRP list\n",
              queue_name, setup->virt, page_sz);
      return -EINVAL;
    }
  }

  if (is_device) {
    fprintf(stderr,
            "ERROR: PC=0 PRP list not supported "
            "for device memory %s\n",
            queue_name);
    return -ENOTSUP;
  }

  const size_t max_pages = 1024;
  uint64_t phys_addrs[max_pages];
  int ret = getPagePhysAddrs(setup->virt, queue_size, phys_addrs, max_pages);
  if (ret < 0) {
    fprintf(stderr,
            "ERROR: Failed to get page physical "
            "addresses for %s: %s\n",
            queue_name, strerror(-ret));
    return ret;
  }

  fprintf(stdout,
          "Info: %s spans %zu pages, building "
          "PRP list (PC=0)\n",
          queue_name, num_pages);
  for (size_t i = 0; i < num_pages; i++) {
    fprintf(stdout, "  page[%zu]: phys=0x%016llx\n", i,
            (unsigned long long)phys_addrs[i]);
  }

  // PC=0 uses standard PRP semantics (NVMe spec 4.4):
  // PRP1 = first page, PRP2 = second page (2 pages)
  // or PRP2 = PRP list pointer (>2 pages).
  if (num_pages == 2) {
    setup->prp2 = phys_addrs[1];
    fprintf(stdout,
            "Info: %s PRP2 = 0x%016llx "
            "(direct 2nd page)\n",
            queue_name, (unsigned long long)setup->prp2);
    return 0;
  }

  // >2 pages: build PRP list for pages 2..N
  size_t prp_entries = num_pages - 1;
  size_t prp_list_bytes = prp_entries * sizeof(uint64_t);

  if (prp_list_bytes > page_sz) {
    fprintf(stderr,
            "ERROR: PRP list for %s requires "
            "%zu bytes (max %zu). Reduce queue "
            "size.\n",
            queue_name, prp_list_bytes, page_sz);
    return -E2BIG;
  }

  void* prp_list = nullptr;
  int rc = posix_memalign(&prp_list, page_sz, page_sz);
  if (rc != 0 || !prp_list) {
    fprintf(stderr,
            "ERROR: Failed to allocate PRP list "
            "for %s\n",
            queue_name);
    return -ENOMEM;
  }
  memset(prp_list, 0, page_sz);

  if (mlock(prp_list, page_sz) != 0) {
    fprintf(stderr,
            "Warning: mlock failed for PRP "
            "list %s: %s\n",
            queue_name, strerror(errno));
  }

  uint64_t* entries = reinterpret_cast<uint64_t*>(prp_list);
  for (size_t i = 1; i < num_pages; i++) {
    entries[i - 1] = phys_addrs[i];
  }

  uint64_t prp_list_phys = getPhysAddr(prp_list);
  if (prp_list_phys == 0) {
    fprintf(stderr,
            "ERROR: Failed to get PRP list "
            "physical address for %s\n",
            queue_name);
    free(prp_list);
    return -EIO;
  }

  setup->prp_list = prp_list;
  setup->prp_list_phys = prp_list_phys;
  setup->prp2 = prp_list_phys;

  fprintf(stdout,
          "Info: %s PRP list at virt=%p "
          "phys=0x%016llx (%zu entries)\n",
          queue_name, prp_list, (unsigned long long)prp_list_phys, prp_entries);

  return 0;
}

// Check if rocm-xio kernel module is loaded
// Note: Linux converts hyphens to underscores in module names, so we check
// for "rocm_xio" in /proc/modules
bool checkKernelModuleLoaded() {
  FILE* f = fopen("/proc/modules", "r");
  if (!f) {
    return false;
  }

  char line[256];
  bool found = false;
  while (fgets(line, sizeof(line), f)) {
    if (strstr(line, "rocm_xio") != nullptr) {
      found = true;
      break;
    }
  }
  fclose(f);
  return found;
}

// Attempt to load rocm-xio kernel module
int loadKernelModule() {
  int ret = system("modprobe rocm-xio");
  if (ret != 0) {
    std::cerr << "Warning: Failed to load kernel module 'rocm-xio'. "
              << "Error: " << ret << std::endl;
    std::cerr << "You may need to run with sudo or ensure the module "
              << "is available." << std::endl;
    return -1;
  }
  return 0;
}

int mapMmioBridgeShadowBuffer(uint16_t bridge_bdf, void** virt_addr) {
  int kmod_fd = -1;
  int ret = 0;
  struct rocm_axiio_mmio_bridge_shadow_req req;
  void* mapped = MAP_FAILED;

  if (!virt_addr) {
    return -EINVAL;
  }

  // Open kernel module device
  kmod_fd = open(ROCM_XIO_DEVICE_PATH, O_RDWR);
  if (kmod_fd < 0) {
    fprintf(stdout, "Failed to open %s: %s\n", ROCM_XIO_DEVICE_PATH,
            strerror(errno));
    fprintf(stdout, "Please ensure the rocm-xio kernel module is loaded\n");
    return -errno;
  }

  // Get shadow buffer info from kernel module
  memset(&req, 0, sizeof(req));
  req.bridge_bdf = bridge_bdf;
  ret = ioctl(kmod_fd, ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER, &req);
  if (ret < 0) {
    fprintf(stdout, "Failed to get PCI MMIO bridge shadow buffer info: %s\n",
            strerror(errno));
    close(kmod_fd);
    return -errno;
  }

  if (req.shadow_gpa == 0) {
    fprintf(stdout, "PCI MMIO bridge shadow GPA is 0 (not configured)\n");
    close(kmod_fd);
    return -EINVAL;
  }

  // Map shadow buffer via kernel module mmap
  mapped = mmap(nullptr, req.shadow_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                kmod_fd, 0);
  if (mapped == MAP_FAILED) {
    fprintf(stdout, "Failed to mmap PCI MMIO bridge shadow buffer: %s\n",
            strerror(errno));
    close(kmod_fd);
    return -errno;
  }

  // Keep kmod_fd open for the mapping to remain valid
  // Note: In a production system, you might want to track this fd
  // and close it on cleanup, but for simplicity we'll leave it open
  // The kernel will clean it up when the process exits

  *virt_addr = mapped;
  fprintf(stdout,
          "PCI MMIO bridge shadow buffer mapped: GPA=0x%llx, "
          "size=%llu, vaddr=%p\n",
          (unsigned long long)req.shadow_gpa,
          (unsigned long long)req.shadow_size, mapped);

  return 0;
}

__host__ int registerMmioBridgeShadowBufferForGpu(void* shadow_virt,
                                                  size_t shadow_size,
                                                  void** gpu_ptr_out) {
  if (!shadow_virt || !gpu_ptr_out) {
    return -EINVAL;
  }

  // Step 1: Register with HIP for GPU access
  hipError_t hip_err = hipHostRegister(shadow_virt, shadow_size,
                                       hipHostRegisterMapped);
  if (hip_err != hipSuccess) {
    fprintf(stdout,
            "Warning: Failed to register shadow buffer "
            "with HIP: %s\n",
            hipGetErrorString(hip_err));
    fprintf(stderr, "Disabling PCI MMIO bridge mode - GPU kernel "
                    "will skip doorbell.\n");
    munmap(shadow_virt, shadow_size);
    *gpu_ptr_out = nullptr;
    return -1;
  }

  fprintf(stdout, "Shadow buffer registered with HIP for GPU "
                  "access\n");

  // Step 2: Get GPU pointer
  void* shadow_gpu_ptr = nullptr;
  hipError_t gpu_ptr_err = hipHostGetDevicePointer(&shadow_gpu_ptr, shadow_virt,
                                                   0);
  if (gpu_ptr_err != hipSuccess) {
    fprintf(stdout,
            "Warning: hipHostGetDevicePointer failed: "
            "%s\n",
            hipGetErrorString(gpu_ptr_err));
    fprintf(stderr, "Disabling PCI MMIO bridge mode - GPU kernel "
                    "will skip doorbell.\n");
    (void)hipHostUnregister(shadow_virt);
    munmap(shadow_virt, shadow_size);
    *gpu_ptr_out = nullptr;
    return -1;
  }

  fprintf(stdout,
          "Shadow buffer GPU pointer obtained: %p "
          "(host: %p)\n",
          shadow_gpu_ptr, shadow_virt);

  *gpu_ptr_out = shadow_gpu_ptr;
  return 0;
}

__host__ int mapPciBar(uint16_t pci_bdf, uint8_t bar, void** bar_cpu,
                       void** bar_gpu, size_t bar_size) {
  if (!bar_cpu || !bar_gpu) {
    return -EINVAL;
  }

  if (bar > 5) {
    fprintf(stderr, "Error: Invalid BAR number %u (must be 0-5)\n", bar);
    return -EINVAL;
  }

  int bar_fd = -1;
  void* mapped = MAP_FAILED;
  char resource_path[256];

  if (bar_size == 0) {
    bar_size = 8192;
  }

  uint8_t bus = (pci_bdf >> 8) & 0xFF;
  uint8_t dev = (pci_bdf >> 3) & 0x1F;
  uint8_t func = pci_bdf & 0x7;

  snprintf(resource_path, sizeof(resource_path),
           "/sys/bus/pci/devices/0000:%02x:%02x.%x/"
           "resource%u",
           bus, dev, func, bar);

  bar_fd = open(resource_path, O_RDWR);
  if (bar_fd < 0) {
    fprintf(stdout, "Failed to open PCI BAR%u resource %s: %s\n", bar,
            resource_path, strerror(errno));
    return -errno;
  }

  mapped = mmap(nullptr, bar_size, PROT_READ | PROT_WRITE, MAP_SHARED, bar_fd,
                0);
  if (mapped == MAP_FAILED) {
    fprintf(stdout, "Failed to mmap PCI BAR%u: %s\n", bar, strerror(errno));
    close(bar_fd);
    return -errno;
  }

  fprintf(stdout, "PCI BAR%u mapped at %p (size=%zu)\n", bar, mapped, bar_size);

  // Register with HIP for GPU access
  void* gpu_ptr = nullptr;
  hipError_t hip_err = hipHostRegister(mapped, bar_size, hipHostRegisterMapped);
  if (hip_err == hipSuccess) {
    fprintf(stdout,
            "PCI BAR%u registered with HIP for GPU "
            "access\n",
            bar);

    hipError_t gpu_ptr_err = hipHostGetDevicePointer(&gpu_ptr, mapped, 0);
    if (gpu_ptr_err != hipSuccess) {
      fprintf(stdout,
              "Warning: hipHostGetDevicePointer failed "
              "for BAR%u: %s\n",
              bar, hipGetErrorString(gpu_ptr_err));
      (void)hipHostUnregister(mapped);
      gpu_ptr = nullptr;
    }
  } else {
    fprintf(stdout,
            "Info: hipHostRegister failed for BAR%u "
            "(%s), trying hsa_amd_memory_lock\n",
            bar, hipGetErrorString(hip_err));
  }

  // Fallback: use hsa_amd_memory_lock for MMIO pages
  // that hipHostRegister cannot handle
  if (!gpu_ptr) {
    hsa_status_t status = hsa_init();
    if (status != HSA_STATUS_SUCCESS && status != (hsa_status_t)0x1001) {
      fprintf(stderr, "Error: hsa_init failed for BAR%u: %d\n", bar, status);
      munmap(mapped, bar_size);
      close(bar_fd);
      return -EIO;
    }

    hsa_agent_t gpu_agent = {0};
    hsa_iterate_agents(
      [](hsa_agent_t agent, void* data) -> hsa_status_t {
        hsa_device_type_t dev_type;
        if (hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &dev_type) ==
              HSA_STATUS_SUCCESS &&
            dev_type == HSA_DEVICE_TYPE_GPU) {
          *(hsa_agent_t*)data = agent;
          return HSA_STATUS_INFO_BREAK;
        }
        return HSA_STATUS_SUCCESS;
      },
      &gpu_agent);

    if (gpu_agent.handle == 0) {
      fprintf(stderr, "Error: No GPU agent found for BAR%u\n", bar);
      munmap(mapped, bar_size);
      close(bar_fd);
      return -ENODEV;
    }

    status = hsa_amd_memory_lock(mapped, bar_size, &gpu_agent, 1, &gpu_ptr);
    if (status != HSA_STATUS_SUCCESS) {
      fprintf(stderr,
              "Error: hsa_amd_memory_lock failed for "
              "BAR%u: %d\n",
              bar, status);
      munmap(mapped, bar_size);
      close(bar_fd);
      return -EIO;
    }

    fprintf(stdout,
            "PCI BAR%u registered via "
            "hsa_amd_memory_lock\n",
            bar);
  }

  fprintf(stdout,
          "PCI BAR%u GPU pointer obtained: %p "
          "(host: %p)\n",
          bar, gpu_ptr, mapped);

  *bar_cpu = mapped;
  *bar_gpu = gpu_ptr;

  return 0;
}

__host__ int readNvmeCapCqr(uint16_t pci_bdf, bool* cqr_out) {
  if (!cqr_out)
    return -EINVAL;

  uint8_t bus = (pci_bdf >> 8) & 0xFF;
  uint8_t dev = (pci_bdf >> 3) & 0x1F;
  uint8_t func = pci_bdf & 0x7;

  char path[256];
  snprintf(path, sizeof(path),
           "/sys/bus/pci/devices/"
           "0000:%02x:%02x.%x/resource0",
           bus, dev, func);

  int fd = open(path, O_RDONLY);
  if (fd < 0) {
    fprintf(stderr,
            "Warning: Cannot open %s to read "
            "NVMe CAP register: %s\n",
            path, strerror(errno));
    return -errno;
  }

  size_t map_size = sysconf(_SC_PAGESIZE);
  void* mapped = mmap(nullptr, map_size, PROT_READ, MAP_SHARED, fd, 0);
  if (mapped == MAP_FAILED) {
    fprintf(stderr,
            "Warning: Cannot mmap %s to read "
            "NVMe CAP register: %s\n",
            path, strerror(errno));
    close(fd);
    return -errno;
  }

  volatile uint32_t* regs = static_cast<volatile uint32_t*>(mapped);
  uint64_t cap = static_cast<uint64_t>(regs[0]) |
                 (static_cast<uint64_t>(regs[1]) << 32);

  munmap(mapped, map_size);
  close(fd);

  *cqr_out = (cap >> 16) & 1;

  fprintf(stdout,
          "NVMe CAP register: CQR=%d "
          "(%s queues %s)\n",
          *cqr_out ? 1 : 0, *cqr_out ? "contiguous" : "non-contiguous",
          *cqr_out ? "required" : "supported");

  return 0;
}

__host__ int setupContigQueueForGpu(size_t size, uint16_t nvme_bdf,
                                    const char* queue_name,
                                    struct xioQueueSetup* setup) {
  if (!setup || size == 0 || !queue_name)
    return -EINVAL;

  memset(setup, 0, sizeof(*setup));

  int kmod_fd = openDeviceWithRetry(ROCM_XIO_DEVICE_PATH, O_RDWR,
                                    "rocm-xio (contig)", 5, 100);
  if (kmod_fd < 0) {
    fprintf(stderr,
            "Error: Cannot open kernel module "
            "for %s contig alloc\n",
            queue_name);
    return -EIO;
  }

  struct rocm_axiio_alloc_contig_req req;
  memset(&req, 0, sizeof(req));
  req.size = size;
  req.nvme_bdf = nvme_bdf;

  int ret = ioctl(kmod_fd, ROCM_XIO_ALLOC_CONTIG_QUEUE, &req);
  if (ret < 0) {
    fprintf(stderr,
            "Error: ALLOC_CONTIG_QUEUE ioctl "
            "failed for %s (%zu bytes): %s\n",
            queue_name, size, strerror(errno));
    close(kmod_fd);
    return -errno;
  }

  fprintf(stdout,
          "%s: contig alloc: phys=0x%llx "
          "mmap_offset=%u size=%zu\n",
          queue_name, (unsigned long long)req.phys_addr, req.mmap_offset, size);

  off_t mmap_off = (off_t)req.mmap_offset * sysconf(_SC_PAGESIZE);
  void* mapped = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED,
                      kmod_fd, mmap_off);
  close(kmod_fd);

  if (mapped == MAP_FAILED) {
    fprintf(stderr,
            "Error: mmap failed for %s contig "
            "buffer: %s\n",
            queue_name, strerror(errno));
    int free_fd = openDeviceWithRetry(ROCM_XIO_DEVICE_PATH, O_RDWR,
                                      "rocm-xio (free)", 5, 100);
    if (free_fd >= 0) {
      struct rocm_axiio_free_contig_req freq;
      freq.mmap_offset = req.mmap_offset;
      ioctl(free_fd, ROCM_XIO_FREE_CONTIG_QUEUE, &freq);
      close(free_fd);
    }
    return -errno;
  }

  memset(mapped, 0, size);

  fprintf(stdout, "%s: contig buffer mapped at %p\n", queue_name, mapped);

  void* gpu_ptr = nullptr;
  hipError_t hip_err = hipHostRegister(mapped, size, hipHostRegisterMapped);
  if (hip_err == hipSuccess) {
    hipError_t gp_err = hipHostGetDevicePointer(&gpu_ptr, mapped, 0);
    if (gp_err != hipSuccess) {
      fprintf(stdout,
              "Warning: hipHostGetDevicePointer "
              "failed for %s: %s\n",
              queue_name, hipGetErrorString(gp_err));
      (void)hipHostUnregister(mapped);
      gpu_ptr = nullptr;
    }
  } else {
    fprintf(stdout,
            "Info: hipHostRegister failed for "
            "%s (%s), trying "
            "hsa_amd_memory_lock\n",
            queue_name, hipGetErrorString(hip_err));
  }

  if (!gpu_ptr) {
    hsa_status_t status = hsa_init();
    if (status != HSA_STATUS_SUCCESS && status != (hsa_status_t)0x1001) {
      fprintf(stderr,
              "Error: hsa_init failed for %s: "
              "%d\n",
              queue_name, status);
      munmap(mapped, size);
      return -EIO;
    }

    hsa_agent_t gpu_agent = {0};
    hsa_iterate_agents(
      [](hsa_agent_t agent, void* data) -> hsa_status_t {
        hsa_device_type_t dev_type;
        if (hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &dev_type) ==
              HSA_STATUS_SUCCESS &&
            dev_type == HSA_DEVICE_TYPE_GPU) {
          *(hsa_agent_t*)data = agent;
          return HSA_STATUS_INFO_BREAK;
        }
        return HSA_STATUS_SUCCESS;
      },
      &gpu_agent);

    if (gpu_agent.handle == 0) {
      fprintf(stderr,
              "Error: No GPU agent found for "
              "%s\n",
              queue_name);
      munmap(mapped, size);
      return -ENODEV;
    }

    status = hsa_amd_memory_lock(mapped, size, &gpu_agent, 1, &gpu_ptr);
    if (status != HSA_STATUS_SUCCESS) {
      fprintf(stderr,
              "Error: hsa_amd_memory_lock "
              "failed for %s: %d\n",
              queue_name, status);
      munmap(mapped, size);
      return -EIO;
    }

    fprintf(stdout,
            "%s: registered via "
            "hsa_amd_memory_lock\n",
            queue_name);
  }

  fprintf(stdout, "%s: contig GPU ptr: %p (host: %p)\n", queue_name, gpu_ptr,
          mapped);

  setup->virt = mapped;
  setup->gpu = gpu_ptr;
  setup->phys = req.phys_addr;
  setup->uses_coherent = false;
  setup->prp_list = nullptr;
  setup->prp_list_phys = 0;
  setup->prp2 = 0;
  setup->uses_contig = true;
  setup->contig_id = req.mmap_offset;

  return 0;
}

__host__ void freeContigQueue(struct xioQueueSetup* setup, size_t size,
                              const char* queue_name) {
  if (!setup || !setup->uses_contig)
    return;

  if (setup->gpu && setup->virt) {
    hipError_t err = hipHostUnregister(setup->virt);
    if (err != hipSuccess) {
      hsa_amd_memory_unlock(setup->virt);
    }
  }

  if (setup->virt) {
    munmap(setup->virt, size);
    setup->virt = nullptr;
  }

  int kmod_fd = openDeviceWithRetry(ROCM_XIO_DEVICE_PATH, O_RDWR,
                                    "rocm-xio (free)", 5, 100);
  if (kmod_fd >= 0) {
    struct rocm_axiio_free_contig_req freq;
    freq.mmap_offset = setup->contig_id;
    int ret = ioctl(kmod_fd, ROCM_XIO_FREE_CONTIG_QUEUE, &freq);
    if (ret < 0) {
      fprintf(stderr,
              "Warning: FREE_CONTIG_QUEUE "
              "failed for %s id=%u: %s\n",
              queue_name, setup->contig_id, strerror(errno));
    } else {
      fprintf(stdout,
              "%s: contig buffer freed "
              "(id=%u)\n",
              queue_name, setup->contig_id);
    }
    close(kmod_fd);
  }

  setup->gpu = nullptr;
  setup->phys = 0;
  setup->uses_contig = false;
  setup->contig_id = 0;
}

int ensureDeviceNode() {
  // Check if device exists
  if (access(ROCM_XIO_DEVICE_PATH, F_OK) == 0) {
    return 0; // Device exists
  }

  // Try to get major number
  FILE* f = fopen("/proc/devices", "r");
  if (!f) {
    std::cerr << "Failed to open /proc/devices" << std::endl;
    return -1;
  }

  char line[256];
  unsigned int major = 0;
  bool found = false;
  while (fgets(line, sizeof(line), f)) {
    if (strstr(line, "rocm-xio") != nullptr) {
      if (sscanf(line, "%u", &major) == 1) {
        found = true;
        break;
      }
    }
  }
  fclose(f);

  if (!found || major == 0) {
    std::cerr << "Failed to find rocm-xio major number in /proc/devices"
              << std::endl;
    return -1;
  }

  // Create device node
  char cmd[256];
  snprintf(cmd, sizeof(cmd), "mknod %s c %u 0", ROCM_XIO_DEVICE_PATH, major);
  int ret = system(cmd);
  if (ret != 0) {
    std::cerr << "Failed to create device node " << ROCM_XIO_DEVICE_PATH
              << ". You may need to run with sudo." << std::endl;
    return -1;
  }

  // Set permissions
  snprintf(cmd, sizeof(cmd), "chmod 666 %s", ROCM_XIO_DEVICE_PATH);
  ret = system(cmd);
  if (ret != 0) {
    std::cerr << "Warning: Failed to set permissions on "
              << ROCM_XIO_DEVICE_PATH << std::endl;
  }

  return 0;
}

__host__ int openDeviceWithRetry(const char* device_path, int flags,
                                 const char* device_name, int max_retries,
                                 int initial_delay_ms) {
  if (!device_path) {
    errno = EINVAL;
    return -1;
  }

  // Default values if not specified
  if (max_retries <= 0) {
    max_retries = 5;
  }
  if (initial_delay_ms <= 0) {
    initial_delay_ms = 100;
  }

  // Use device_path as name if device_name is not provided
  const char* display_name = device_name ? device_name : device_path;

  int fd = -1;
  for (int retry = 0; retry < max_retries; retry++) {
    fd = open(device_path, flags);
    if (fd >= 0) {
      return fd; // Success
    }

    // Only retry on temporary errors
    if (errno != EAGAIN && errno != EWOULDBLOCK) {
      // Not a temporary error, fail immediately
      break;
    }

    // Wait before retrying (exponential backoff)
    if (retry < max_retries - 1) {
      int delay = initial_delay_ms * (1 << retry);
      fprintf(stdout, "%s busy, retrying in %d ms (attempt %d/%d)...\n",
              display_name, delay, retry + 1, max_retries);
      usleep(delay * 1000);
    }
  }

  // All retries exhausted or non-retryable error
  fprintf(stdout, "Failed to open %s after %d retries: %s\n", display_name,
          max_retries, strerror(errno));
  return -1;
}

__host__ int exportRegVramBuf(void* vram_ptr, size_t size, uint16_t nvme_bdf,
                              const char* kernel_module_device,
                              uint64_t* phys_addr_out, bool is_emulated) {
  hsa_status_t status;
  hipDeviceptr_t aligned_ptr;
  const size_t host_page_size = sysconf(_SC_PAGESIZE);
  uint64_t dmabuf_offset = 0;
  size_t aligned_size;
  int dmabuf_fd = -1;
  int kmod_fd = -1;
  int ret = 0;

  if (!vram_ptr || !phys_addr_out || size == 0) {
    return -EINVAL;
  }

  // Round down to host page size for dmabuf alignment
  aligned_ptr = (hipDeviceptr_t)((uintptr_t)vram_ptr & ~(host_page_size - 1));
  dmabuf_offset = (uintptr_t)vram_ptr - (uintptr_t)aligned_ptr;
  aligned_size = (size + dmabuf_offset + host_page_size - 1) &
                 ~(host_page_size - 1);

  fprintf(stdout,
          "  Aligning VRAM buffer: ptr=%p -> aligned=%p, "
          "size=%zu -> %zu, offset=%llu\n",
          vram_ptr, (void*)aligned_ptr, size, aligned_size,
          (unsigned long long)dmabuf_offset);

  // Export as DMA-BUF using HSA runtime
  dmabuf_fd = 0;
  status = hsa_amd_portable_export_dmabuf((void*)aligned_ptr, aligned_size,
                                          &dmabuf_fd, &dmabuf_offset);
  if (status != HSA_STATUS_SUCCESS) {
    fprintf(stdout,
            "ERROR: hsa_amd_portable_export_dmabuf failed (status=%d)\n",
            status);
    fprintf(stdout, "  This requires:\n");
    fprintf(stdout, "  - ROCm 5.3+ with dmabuf support\n");
    fprintf(stdout, "  - Kernel CONFIG_DMABUF_MOVE_NOTIFY=y\n");
    fprintf(stdout, "  - Kernel CONFIG_PCI_P2PDMA=y\n");
    return -ENOTSUP;
  }

  fprintf(stdout, "  ✅ Exported dmabuf: fd=%d, offset=0x%llx\n", dmabuf_fd,
          (unsigned long long)dmabuf_offset);

  // Open kernel module device
  kmod_fd = open(kernel_module_device, O_RDWR);
  if (kmod_fd < 0) {
    fprintf(stderr, "ERROR: Failed to open %s: %s\n", kernel_module_device,
            strerror(errno));
    close(dmabuf_fd);
    return -errno;
  }

  // Register buffer with kernel module to get physical address
  struct rocm_axiio_register_buffer_req req = {};
  req.dmabuf_fd = dmabuf_fd;
  req.virt_addr = reinterpret_cast<uint64_t>(vram_ptr);
  req.size = size;
  req.nvme_bdf = nvme_bdf;
  req.flags = is_emulated ? ROCM_XIO_FLAG_EMULATED : ROCM_XIO_FLAG_PASSTHROUGH;

  ret = ioctl(kmod_fd, ROCM_XIO_REGISTER_BUFFER, &req);
  if (ret < 0) {
    fprintf(stderr, "ERROR: ROCM_XIO_REGISTER_BUFFER ioctl failed: %s\n",
            strerror(errno));
    close(dmabuf_fd);
    close(kmod_fd);
    return -errno;
  }

  // Physical address includes the offset within the dmabuf
  *phys_addr_out = req.phys_addr + dmabuf_offset;

  fprintf(stdout,
          "  ✅ Registered buffer: virt=0x%016llx, phys=0x%016llx, "
          "size=%zu\n",
          (unsigned long long)req.virt_addr, (unsigned long long)*phys_addr_out,
          size);

  // Close dmabuf FD - kernel module has the mapping
  close(dmabuf_fd);
  close(kmod_fd);

  return 0;
}

__host__ __device__ void genPciMmioBridgeCmd(void* shadowBufferVirt,
                                             uint16_t targetBdf,
                                             uint8_t targetBar, uint32_t offset,
                                             uint64_t value, uint8_t command,
                                             uint8_t size) {
  volatile struct pci_mmio_bridge_ring_meta* meta =
    static_cast<volatile struct pci_mmio_bridge_ring_meta*>(shadowBufferVirt);
  uint32_t slot = meta->producer_idx % meta->queue_depth;
  volatile struct pci_mmio_bridge_command* cmd =
    reinterpret_cast<volatile struct pci_mmio_bridge_command*>(
      static_cast<volatile uint8_t*>(shadowBufferVirt) +
      sizeof(struct pci_mmio_bridge_ring_meta) +
      (slot * sizeof(struct pci_mmio_bridge_command)));
  cmd->target_bdf = targetBdf;
  cmd->target_bar = targetBar;
  cmd->reserved1 = 0;
  cmd->offset = offset;
  cmd->value = value;
  cmd->command = command;
  cmd->size = size;
  cmd->status = PCI_MMIO_BRIDGE_STATUS_PENDING;
  cmd->reserved2 = 0;
  cmd->sequence = slot;
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif
  meta->producer_idx = meta->producer_idx + 1;
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif
}

// Allocate GPU-accessible buffer for DMA operations
__host__ hipError_t allocateGpuAccessibleBuffer(
  size_t size, unsigned memoryMode, uint16_t targetBdf, const char* devicePath,
  struct xioBufferInfo* bufferInfo) {
  if (!bufferInfo || size == 0) {
    return hipErrorInvalidValue;
  }

  // Initialize output structure
  bufferInfo->hostPtr = nullptr;
  bufferInfo->gpuPtr = nullptr;
  bufferInfo->dmaAddr = 0;
  bufferInfo->isDeviceMemory = false;

  bool dataBufferOnDevice = (memoryMode & XIO_MEM_MODE_DATA_DEVICE) != 0;

  if (dataBufferOnDevice) {
    // Device memory - use hipMalloc for VRAM allocation
    hipError_t buf_err = hipMalloc(&bufferInfo->hostPtr, size);
    if (buf_err != hipSuccess) {
      fprintf(stderr, "Error: hipMalloc failed: %s\n",
              hipGetErrorString(buf_err));
      return buf_err;
    }

    fprintf(stdout, "  VRAM buffer virtual: %p\n", bufferInfo->hostPtr);
    fprintf(stdout, "  Exporting as DMA-BUF (HSA runtime)...\n");

    // Detect if device is emulated (needed for buffer registration flags)
    bool is_emulated = false;
    if (devicePath != nullptr) {
      (void)detectEmulatedNvme(devicePath, &is_emulated);
    }

    // Export VRAM as dmabuf and register with kernel module
    int ret = exportRegVramBuf(bufferInfo->hostPtr, size, targetBdf,
                               ROCM_XIO_DEVICE_PATH, &bufferInfo->dmaAddr,
                               is_emulated);
    if (ret < 0) {
      fprintf(stderr, "ERROR: DMA-BUF export failed for device memory: %s\n",
              strerror(-ret));
      fprintf(stderr, "  Device memory was requested but dmabuf export is "
                      "not available\n");
      (void)hipFree(bufferInfo->hostPtr);
      bufferInfo->hostPtr = nullptr;
      return hipErrorInvalidValue;
    }

    fprintf(stdout, "  Data buffer physical: 0x%016llx (VRAM)\n",
            (unsigned long long)bufferInfo->dmaAddr);
    fprintf(stdout, "  GPU writes directly to VRAM\n");
    fprintf(stdout, "  NVMe DMAs from VRAM (P2P)\n");

    // Device memory - GPU pointer is same as host pointer
    bufferInfo->gpuPtr = bufferInfo->hostPtr;
    bufferInfo->isDeviceMemory = true;
  } else {
    // Host memory - use hipHostMalloc (mapped for GPU access)
    hipError_t buf_err = hipHostMalloc(&bufferInfo->hostPtr, size,
                                       hipHostMallocMapped);
    if (buf_err != hipSuccess) {
      fprintf(stderr, "Error: hipHostMalloc failed: %s\n",
              hipGetErrorString(buf_err));
      return buf_err;
    }

    // Get physical address for host memory using /proc/self/pagemap
    bufferInfo->dmaAddr = getPhysAddr(bufferInfo->hostPtr);
    if (!bufferInfo->dmaAddr) {
      fprintf(stdout, "ERROR: Failed to get buffer physical address\n");
      (void)hipHostFree(bufferInfo->hostPtr);
      bufferInfo->hostPtr = nullptr;
      return hipErrorInvalidValue;
    }

    fprintf(stdout, "  Data buffer virtual:  %p\n", bufferInfo->hostPtr);
    fprintf(stdout, "  Data buffer physical: 0x%016llx\n",
            (unsigned long long)bufferInfo->dmaAddr);
    fprintf(stdout, "  GPU can write directly to this buffer\n");
    fprintf(stdout, "  NVMe can DMA from this buffer\n");

    // Verify buffer is GPU-accessible and get GPU pointer
    hipPointerAttribute_t attr;
    hipError_t attr_err = hipPointerGetAttributes(&attr, bufferInfo->hostPtr);
    if (attr_err != hipSuccess) {
      fprintf(stdout, "Warning: Buffer may not be GPU-accessible: %s\n",
              hipGetErrorString(attr_err));
      bufferInfo->gpuPtr = bufferInfo->hostPtr; // Fallback to host pointer
    } else {
      // Get explicit GPU pointer (may be same as host pointer for mapped
      // memory)
      void* gpu_ptr = nullptr;
      hipError_t gpu_ptr_err = hipHostGetDevicePointer(&gpu_ptr,
                                                       bufferInfo->hostPtr, 0);
      if (gpu_ptr_err == hipSuccess && gpu_ptr != nullptr) {
        bufferInfo->gpuPtr = gpu_ptr;
        fprintf(stdout, "Buffer GPU pointer: %p (host: %p)\n",
                bufferInfo->gpuPtr, bufferInfo->hostPtr);
      } else {
        // Fallback: use host pointer (should work for hipHostMallocMapped)
        bufferInfo->gpuPtr = bufferInfo->hostPtr;
      }
    }
    bufferInfo->isDeviceMemory = false;
  }

  fprintf(stdout, "Buffer allocated: virt=%p, gpu=%p, phys=0x%llx, size=%zu\n",
          bufferInfo->hostPtr, bufferInfo->gpuPtr,
          (unsigned long long)bufferInfo->dmaAddr, size);

  return hipSuccess;
}

// Free GPU-accessible buffer allocated with allocateGpuAccessibleBuffer
__host__ void freeGpuAccessibleBuffer(struct xioBufferInfo* bufferInfo) {
  if (!bufferInfo || !bufferInfo->hostPtr) {
    return;
  }

  if (bufferInfo->isDeviceMemory) {
    (void)hipFree(bufferInfo->hostPtr);
  } else {
    (void)hipHostFree(bufferInfo->hostPtr);
  }

  bufferInfo->hostPtr = nullptr;
  bufferInfo->gpuPtr = nullptr;
  bufferInfo->dmaAddr = 0;
  bufferInfo->isDeviceMemory = false;
}

__host__ bool validateGpuPointer(void* ptr, const char* name,
                                 bool disableOnFailure) {
  if (ptr == nullptr) {
    return true; // nullptr is considered valid (optional pointer)
  }

  hipPointerAttribute_t attr;
  hipError_t attr_err = hipPointerGetAttributes(&attr, ptr);
  if (attr_err != hipSuccess) {
    if (disableOnFailure) {
      fprintf(stderr,
              "Error: Failed to get %s pointer attributes: %s (code: %d)\n",
              name, hipGetErrorString(attr_err), attr_err);
      fprintf(stderr, "%s may not be GPU-accessible\n", name);
    } else {
      fprintf(stdout,
              "Warning: Failed to get %s pointer attributes: %s (code: %d)\n",
              name, hipGetErrorString(attr_err), attr_err);
      fprintf(stdout, "%s pointer may not be GPU-accessible\n", name);
    }
    return false;
  }

  fprintf(stdout, "%s GPU accessibility verified: type=%d, device=%d\n", name,
          attr.type, attr.device);
  return true;
}

} // namespace xio
