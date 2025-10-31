/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <algorithm>
#include <cmath>
#include <iomanip>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

#include "axiio.h"

 void axxioPrintDeviceInfo() {
    int deviceCount;
    HIP_CHECK(hipGetDeviceCount(&deviceCount));
    std::cout << "Number of devices: " << deviceCount << std::endl;

  for (int deviceId = 0; deviceId < deviceCount; ++deviceId) {
        hipDeviceProp_t deviceProp;
        HIP_CHECK(hipGetDeviceProperties(&deviceProp, deviceId));
        std::cout << "Device " << deviceId+1 << ":" << std::endl << " Properties:" << std::endl;
        std::cout << "  Name: " << deviceProp.name << std::endl;
        std::cout << "  Total Global Memory: " << deviceProp.totalGlobalMem / (1024 * 1024) << " MiB" << std::endl;
        std::cout << "  Shared Memory per Block: " << deviceProp.sharedMemPerBlock / 1024 << " KiB" << std::endl;
        std::cout << "  Registers per Block: " << deviceProp.regsPerBlock << std::endl;
        std::cout << "  Warp Size: " << deviceProp.warpSize << std::endl;
        std::cout << "  Max Threads per Block: " << deviceProp.maxThreadsPerBlock << std::endl;
        std::cout << "  Max Threads per Multiprocessor: " << deviceProp.maxThreadsPerMultiProcessor << std::endl;
        std::cout << "  Number of Multiprocessors: " << deviceProp.multiProcessorCount << std::endl;
        std::cout << "  Max Threads Dimensions: ["
                << deviceProp.maxThreadsDim[0] << ", "
                << deviceProp.maxThreadsDim[1] << ", "
                << deviceProp.maxThreadsDim[2] << "]" << std::endl;
        std::cout << "  Max Grid Size: ["
                << deviceProp.maxGridSize[0] << ", "
                << deviceProp.maxGridSize[1] << ", "
                << deviceProp.maxGridSize[2] << "]" << std::endl;
        std::cout << "  Max Clock Frequency (Multiprocessor): " << deviceProp.clockRate << " KHz" << std::endl;
        int wallClkRate;
        HIP_CHECK(hipDeviceGetAttribute(&wallClkRate,
        hipDeviceAttributeWallClockRate,
        deviceId));
        std::cout << "  Wall Clock Frequency (Constant): " << wallClkRate << " KHz" << std::endl;
    }
}

void axxioPrintStatistics(const std::vector<double>& durations) {
  if (durations.empty()) {
    return;
  }

  // Calculate statistics
  double minVal = *std::min_element(durations.begin(), durations.end());
  double maxVal = *std::max_element(durations.begin(), durations.end());
  double sum = 0.0;
  for (double d : durations) sum += d;
  double avg = sum / durations.size();

  double variance = 0.0;
  for (double d : durations) {
    variance += (d - avg) * (d - avg);
  }
  variance /= durations.size();
  double stddev = std::sqrt(variance);

  // Print statistics
  std::cout << "\nStatistics:" << std::endl;
  std::cout << "  Minimum:          " << std::setw(10) << std::fixed
            << std::setprecision(2) << minVal << " ns" << std::endl;
  std::cout << "  Maximum:          " << std::setw(10) << std::fixed
            << std::setprecision(2) << maxVal << " ns" << std::endl;
  std::cout << "  Average:          " << std::setw(10) << std::fixed
            << std::setprecision(2) << avg << " ns" << std::endl;
  std::cout << "  Standard Dev:     " << std::setw(10) << std::fixed
            << std::setprecision(2) << stddev << " ns" << std::endl;
}

void axxioPrintHistogram(const std::vector<double>& durations,
                         unsigned nIterations) {
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
    // Sort data for quantile-based binning (ensures no empty bins)
    std::vector<double> sortedData = durations;
    std::sort(sortedData.begin(), sortedData.end());
    
    size_t n = sortedData.size();
    
    // Determine number of bins (8 to 64, but not more than data points)
    int desiredBins = std::min(64, std::max(8, (int)nIterations / 2));
    int numBins = std::min(desiredBins, (int)n);
    
    // Create quantile-based bin boundaries to ensure each bin has at least one value
    std::vector<double> binEdges;
    binEdges.push_back(sortedData[0]);  // Start with minimum
    
    // Calculate target number of samples per bin
    double samplesPerBin = (double)n / numBins;
    
    for (int i = 1; i < numBins; i++) {
      // Calculate the index for this quantile boundary
      size_t idx = (size_t)(i * samplesPerBin);
      
      // Ensure we don't go past the end and avoid duplicates
      if (idx < n && sortedData[idx] > binEdges.back()) {
        binEdges.push_back(sortedData[idx]);
      }
    }
    
    // Add the maximum as the last edge
    binEdges.push_back(sortedData[n - 1]);
    
    // Remove any duplicate edges (can happen with repeated values)
    binEdges.erase(std::unique(binEdges.begin(), binEdges.end()), 
                   binEdges.end());
    
    // Update actual number of bins
    numBins = binEdges.size() - 1;
    std::vector<int> bins(numBins, 0);
    
    // Fill histogram bins
    for (double d : durations) {
      for (int i = 0; i < numBins; i++) {
        if (d >= binEdges[i] && (d < binEdges[i + 1] || 
            (i == numBins - 1 && d <= binEdges[i + 1]))) {
          bins[i]++;
          break;
        }
      }
    }

    // Find max count for scaling
    int maxCount = *std::max_element(bins.begin(), bins.end());

    // Print histogram
    std::cout << "\nHistogram (Runtime in ns):" << std::endl;
    const int barWidth = 60;
    for (int i = 0; i < numBins; i++) {
      std::cout << "  [" << std::setw(8) << std::fixed << std::setprecision(1)
                << binEdges[i] << " - " << std::setw(8) << std::fixed
                << std::setprecision(1) << binEdges[i + 1] << "): ";

      int barLen = (maxCount > 0) ? (bins[i] * barWidth / maxCount) : 0;
      std::cout << std::string(barLen, '#');
      if (bins[i] > 0) {
        std::cout << " " << bins[i];
      }
      std::cout << std::endl;
    }
  }

  // Print statistics after histogram
  axxioPrintStatistics(durations);
}