/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

#include <hip/hip_runtime.h>

#include <unistd.h>

#include "axiio.h"

void axiioPrintDeviceInfo() {
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

void axiioPrintStatistics(const std::vector<double>& durations,
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

void axiioPrintHistogram(const std::vector<double>& durations,
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
  axiioPrintStatistics(durations, nIterations, numThreads, readIterations,
                       writeIterations, verifiedReadsCount);
}

// Helper function to allocate HSA device memory
hsa_status_t axiioAllocDeviceMemory(size_t size, void** ptr,
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
    std::cerr << "  Info: (" << direction << "):  Using HSA fine-grained "
              << "global memory region" << std::endl;
  } else if (global_flags & HSA_REGION_GLOBAL_FLAG_COARSE_GRAINED) {
    std::cerr << "  Info: (" << direction << "):  Using HSA coarse-grained "
              << "global memory region" << std::endl;
  }

  // Allocate memory from device region
  status = hsa_memory_allocate(device_region, size, ptr);
  return status;
}

// Allocate submission queue memory based on memory mode
// Returns hipSuccess on success, hipErrorMemoryAllocation on failure
hipError_t axiioAllocateSubmissionQueue(size_t size, unsigned memoryMode,
                                        void** ptr) {
  bool gpuWriteToDevice = (memoryMode & 0x1) != 0; // LSB

  if (gpuWriteToDevice) {
    // Allocate device memory using HSA
    const size_t host_page_size = sysconf(_SC_PAGESIZE);
    size_t alignedSize = ((size + host_page_size - 1) / host_page_size) *
                         host_page_size;

    hsa_status_t hsa_status = axiioAllocDeviceMemory(alignedSize, ptr,
                                                     "GPU->CPU (SQE)");
    if (hsa_status != HSA_STATUS_SUCCESS) {
      std::cerr << "Error: HSA memory allocation failed for submission queue: "
                << hsa_status << std::endl;
      return hipErrorMemoryAllocation;
    }
    memset(*ptr, 0, size);
  } else {
    // Allocate host-accessible memory using HIP
    HIP_CHECK(hipHostMalloc(ptr, size, hipHostMallocDefault));
    memset(*ptr, 0, size);
  }

  return hipSuccess;
}

// Allocate completion queue memory based on memory mode
// Returns hipSuccess on success, hipErrorMemoryAllocation on failure
hipError_t axiioAllocateCompletionQueue(size_t size, unsigned memoryMode,
                                        void** ptr) {
  bool cpuWriteToDevice = (memoryMode & 0x2) != 0; // MSB

  if (cpuWriteToDevice) {
    // Allocate device memory using HSA
    const size_t host_page_size = sysconf(_SC_PAGESIZE);
    size_t alignedSize = ((size + host_page_size - 1) / host_page_size) *
                         host_page_size;

    hsa_status_t hsa_status = axiioAllocDeviceMemory(alignedSize, ptr,
                                                     "CPU->GPU (CQE)");
    if (hsa_status != HSA_STATUS_SUCCESS) {
      std::cerr << "Error: HSA memory allocation failed for completion queue: "
                << hsa_status << std::endl;
      return hipErrorMemoryAllocation;
    }
    memset(*ptr, 0, size);
  } else {
    // Allocate host-accessible memory using HIP
    HIP_CHECK(hipHostMalloc(ptr, size, hipHostMallocDefault));
    memset(*ptr, 0, size);
  }

  return hipSuccess;
}

// Free submission queue memory based on memory mode
void axiioFreeSubmissionQueue(void* ptr, unsigned memoryMode) {
  bool gpuWriteToDevice = (memoryMode & 0x1) != 0; // LSB

  if (gpuWriteToDevice) {
    // Free HSA device memory
    if (ptr != nullptr) {
      hsa_memory_free(ptr);
    }
  } else {
    // Free HIP host memory
    if (ptr != nullptr) {
      HIP_CHECK(hipHostFree(ptr));
    }
  }
}

// Free completion queue memory based on memory mode
void axiioFreeCompletionQueue(void* ptr, unsigned memoryMode) {
  bool cpuWriteToDevice = (memoryMode & 0x2) != 0; // MSB

  if (cpuWriteToDevice) {
    // Free HSA device memory
    if (ptr != nullptr) {
      hsa_memory_free(ptr);
    }
  } else {
    // Free HIP host memory
    if (ptr != nullptr) {
      HIP_CHECK(hipHostFree(ptr));
    }
  }
}

// Extract endpoint name from command line arguments
// This allows endpoints to add their CLI options before full parsing
// Returns empty string if endpoint name not found in arguments
std::string axiioExtractEndpointName(int argc, char** argv) {
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