/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef AXIIO_HELPERS_H
#define AXIIO_HELPERS_H

#include <iostream>
#include <vector>

#include <hip/hip_runtime.h>

#define HIP_CHECK(expression)                                                  \
  {                                                                            \
    const hipError_t status = expression;                                      \
    if (status != hipSuccess) {                                                \
      std::cerr << "HIP error " << status << ": " << hipGetErrorString(status) \
                << " at " << __FILE__ << ":" << __LINE__ << std::endl;         \
    }                                                                          \
  }

void axxioPrintDeviceInfo();
void axxioPrintStatistics(const std::vector<double>& durations,
                          unsigned totalIterations = 0,
                          unsigned readIterations = 0,
                          unsigned writeIterations = 0,
                          unsigned verifiedReadsCount = 0);
void axxioPrintHistogram(const std::vector<double>& durations,
                         unsigned nIterations, unsigned readIterations = 0,
                         unsigned writeIterations = 0,
                         unsigned verifiedReadsCount = 0);

#endif // AXIIO_HELPERS_H
