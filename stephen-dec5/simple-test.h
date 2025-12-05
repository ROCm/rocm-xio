/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef SIMPLE_TEST_H
#define SIMPLE_TEST_H

#include <hip/hip_runtime.h>
#include <cstdint>

// 64-byte structure for GPU -> CPU communication
struct GpuToCpuMsg {
  uint64_t magic;      // 8 bytes - magic number for validation
  uint64_t iteration; // 8 bytes - iteration number
  uint64_t gpuTime;   // 8 bytes - GPU wall clock time
  uint64_t data[5];   // 40 bytes - data payload
};

// 16-byte structure for CPU -> GPU communication
struct CpuToGpuMsg {
  uint64_t magic;      // 8 bytes - magic number for validation
  uint64_t cpuTime;   // 8 bytes - CPU wall clock time
};

// Magic numbers for synchronization
#define GPU_TO_CPU_MAGIC 0xDEADBEEFCAFEBABEULL
#define CPU_TO_GPU_MAGIC 0xBABECAFEBEEFDEADULL

static_assert(sizeof(GpuToCpuMsg) == 64, "GpuToCpuMsg must be 64 bytes");
static_assert(sizeof(CpuToGpuMsg) == 16, "CpuToGpuMsg must be 16 bytes");

#endif // SIMPLE_TEST_H

