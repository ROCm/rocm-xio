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
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "xio.h"

void xioPrintDeviceInfo() {
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
void xioPrintGpuDeviceDetails(int deviceId) {
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

void xioPrintStatistics(const std::vector<double>& durations,
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

void xioPrintHistogram(const std::vector<double>& durations,
                       unsigned nIterations, unsigned numThreads,
                       unsigned readIterations, unsigned writeIterations,
                       unsigned verifiedReadsCount) {
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
  xioPrintStatistics(durations, nIterations, numThreads, readIterations,
                     writeIterations, verifiedReadsCount);
}

// Helper function to allocate HSA device memory
hsa_status_t xioAllocDeviceMemory(size_t size, void** ptr,
                                  const char* direction) {
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

// Allocate submission queue memory based on memory mode
// Returns hipSuccess on success, hipErrorMemoryAllocation on failure
hipError_t xioAllocateSubmissionQueue(size_t size, unsigned memoryMode,
                                      void** ptr) {
  bool gpuWriteToDevice = (memoryMode & 0x1) != 0; // LSB

  if (gpuWriteToDevice) {
    // Allocate device memory using hipMalloc (exportable as DMA-BUF)
    // This matches VRAM buffer allocation and allows DMA-BUF export for
    // physical address resolution in nvme-ep
    hipError_t hipErr = hipMalloc(ptr, size);
    if (hipErr != hipSuccess) {
      std::cerr << "Error: hipMalloc failed for submission queue: "
                << hipGetErrorString(hipErr) << std::endl;
      return hipErrorMemoryAllocation;
    }
    // Zero-initialize using hipMemset
    hipError_t memsetErr = hipMemset(*ptr, 0, size);
    if (memsetErr != hipSuccess) {
      std::cerr << "Warning: hipMemset failed for submission queue: "
                << hipGetErrorString(memsetErr) << std::endl;
      // Continue anyway - memory might already be zeroed
    }
  } else {
    // Allocate host-accessible memory using HIP (GPU-accessible)
    // Use hipHostMallocMapped to ensure GPU can access it (needed for test-ep)
    // nvme-ep will reallocate with hipHostMallocCoherent if needed
    // CRITICAL: Must use hipHostMalloc - malloc is not DMA-accessible
    hipError_t hipErr = hipHostMalloc(ptr, size, hipHostMallocMapped);
    if (hipErr != hipSuccess) {
      std::cerr << "Error: hipHostMalloc failed for submission queue: "
                << hipGetErrorString(hipErr) << std::endl;
      std::cerr << "HIP is required for DMA-accessible queue memory. "
                << "Cannot fall back to malloc (not DMA-accessible)."
                << std::endl;
      return hipErrorMemoryAllocation;
    }
    memset(*ptr, 0, size);
  }

  return hipSuccess;
}

// Allocate completion queue memory based on memory mode
// Returns hipSuccess on success, hipErrorMemoryAllocation on failure
hipError_t xioAllocateCompletionQueue(size_t size, unsigned memoryMode,
                                      void** ptr) {
  bool cpuWriteToDevice = (memoryMode & 0x2) != 0; // MSB

  if (cpuWriteToDevice) {
    // Allocate device memory using hipMalloc (exportable as DMA-BUF)
    // This matches VRAM buffer allocation and allows DMA-BUF export for
    // physical address resolution in nvme-ep
    hipError_t hipErr = hipMalloc(ptr, size);
    if (hipErr != hipSuccess) {
      std::cerr << "Error: hipMalloc failed for completion queue: "
                << hipGetErrorString(hipErr) << std::endl;
      return hipErrorMemoryAllocation;
    }
    // Zero-initialize using hipMemset
    hipError_t memsetErr = hipMemset(*ptr, 0, size);
    if (memsetErr != hipSuccess) {
      std::cerr << "Warning: hipMemset failed for completion queue: "
                << hipGetErrorString(memsetErr) << std::endl;
      // Continue anyway - memory might already be zeroed
    }
  } else {
    // Allocate host-accessible memory using HIP (GPU-accessible)
    // Use hipHostMallocMapped to ensure GPU can access it (needed for test-ep)
    // nvme-ep will reallocate with hipHostMallocCoherent if needed
    // CRITICAL: Must use hipHostMalloc - malloc is not DMA-accessible
    hipError_t hipErr = hipHostMalloc(ptr, size, hipHostMallocMapped);
    if (hipErr != hipSuccess) {
      std::cerr << "Error: hipHostMalloc failed for completion queue: "
                << hipGetErrorString(hipErr) << std::endl;
      std::cerr << "HIP is required for DMA-accessible queue memory. "
                << "Cannot fall back to malloc (not DMA-accessible)."
                << std::endl;
      return hipErrorMemoryAllocation;
    }
    memset(*ptr, 0, size);
  }

  return hipSuccess;
}

// Free submission queue memory based on memory mode
void xioFreeSubmissionQueue(void* ptr, unsigned memoryMode) {
  bool gpuWriteToDevice = (memoryMode & 0x1) != 0; // LSB

  if (gpuWriteToDevice) {
    // Free HIP device memory
    if (ptr != nullptr) {
      hipError_t hipErr = hipFree(ptr);
      if (hipErr != hipSuccess) {
        std::cerr << "Warning: hipFree failed for submission queue: "
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

// Free completion queue memory based on memory mode
void xioFreeCompletionQueue(void* ptr, unsigned memoryMode) {
  bool cpuWriteToDevice = (memoryMode & 0x2) != 0; // MSB

  if (cpuWriteToDevice) {
    // Free HIP device memory
    if (ptr != nullptr) {
      hipError_t hipErr = hipFree(ptr);
      if (hipErr != hipSuccess) {
        std::cerr << "Warning: hipFree failed for completion queue: "
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

// Allocate data buffer memory based on memory mode
// Bit 3 (0x8): Data buffer location (0=host, 1=device)
// Returns hipSuccess on success, hipErrorMemoryAllocation on failure
hipError_t xioAllocateDataBuffer(size_t size, unsigned memoryMode, void** ptr) {
  bool dataBufferOnDevice = (memoryMode & 0x8) != 0; // Bit 3

  if (dataBufferOnDevice) {
    // Allocate device memory using HSA
    const size_t host_page_size = sysconf(_SC_PAGESIZE);
    size_t alignedSize = ((size + host_page_size - 1) / host_page_size) *
                         host_page_size;

    hsa_status_t hsa_status = xioAllocDeviceMemory(alignedSize, ptr,
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
void xioFreeDataBuffer(void* ptr, unsigned memoryMode) {
  bool dataBufferOnDevice = (memoryMode & 0x8) != 0; // Bit 3

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

// Extract endpoint name from command line arguments
// This allows endpoints to add their CLI options before full parsing
// Returns empty string if endpoint name not found in arguments
std::string xioExtractEndpointName(int argc, char** argv) {
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

// Detect PCI MMIO bridge BDF by scanning PCI devices
// Looks for Vendor ID 0x1b36 (Red Hat, Inc.) and Device ID 0x0015
// Returns 0 on success with BDF in *bdf_out, negative error code on failure
// Errors out if 0 or >1 PCI MMIO bridges are found
int xioDetectPciMmioBridgeBdf(uint16_t* bdf_out) {
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

// Detect PCI BDF from device file path
// Takes a device path like /dev/nvme0 or /dev/nvme1
// Returns 0 on success with BDF in *bdf_out, negative error code on failure
// Returns -ENODEV if device not found or not a PCI device
__host__ int xioDetectBdfFromDevice(const char* device_path,
                                    uint16_t* bdf_out) {
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
  // Format: ../../devices/pci0000:00/0000:00:06.0/nvme/nvme0
  // We need to extract "0000:00:06.0" from the path
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

// Detect if NVMe controller is emulated based on Vendor ID and Device ID
// Takes a device path like /dev/nvme0 or /dev/nvme1
// Returns 0 on success with is_emulated in *is_emulated_out, negative error
// code on failure Returns -ENODEV if device not found or not a PCI device
// Emulated NVMe controllers typically have Vendor ID 0x1b36 (Red Hat/QEMU)
__host__ int xioDetectEmulatedNvme(const char* device_path,
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
  // Format: ../../devices/pci0000:00/0000:00:06.0/nvme/nvme0
  // We need to extract "0000:00:06.0" from the path
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
  // This is the same vendor ID used by QEMU for other emulated PCI devices
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

// Get physical address from virtual address using /proc/self/pagemap
// Returns 0 on failure
__host__ uint64_t xioGetPhysAddr(void* virt_addr) {
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

// Check if rocm-xio kernel module is loaded
// Note: Linux converts hyphens to underscores in module names, so we check
// for "rocm_xio" in /proc/modules
bool xioCheckKernelModuleLoaded() {
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
int xioLoadKernelModule() {
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

// Ensure rocm-xio device node exists, create if missing
int xioEnsureDeviceNode() {
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

  // Create device node (requires root)
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