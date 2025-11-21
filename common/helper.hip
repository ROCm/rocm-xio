/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <algorithm>
#include <climits>
#include <cmath>
#include <iomanip>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

#include <hip/hip_runtime.h>

#include "axiio-helpers.h"

void axxioPrintDeviceInfo() {
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

void axxioPrintStatistics(const std::vector<double>& durations,
                          unsigned totalIterations, unsigned readIterations,
                          unsigned writeIterations,
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

  std::cout << "  Minimum:          " << std::setw(10) << std::fixed
            << std::setprecision(2) << min_display << time_unit << std::endl;
  std::cout << "  Maximum:          " << std::setw(10) << std::fixed
            << std::setprecision(2) << max_display << time_unit << std::endl;
  std::cout << "  Average:          " << std::setw(10) << std::fixed
            << std::setprecision(2) << avg_display << time_unit << std::endl;
  std::cout << "  Standard Dev:     " << std::setw(10) << std::fixed
            << std::setprecision(2) << stddev_display << time_unit << std::endl;
}

void axxioPrintHistogram(const std::vector<double>& durations,
                         unsigned nIterations, unsigned readIterations,
                         unsigned writeIterations,
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
  axxioPrintStatistics(durations, nIterations, readIterations, writeIterations,
                       verifiedReadsCount);
}