/*
 * SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION &
 * AFFILIATES. All rights reserved. SPDX-FileCopyrightText: Modifications
 * Copyright (c) 2025-2026 Advanced Micro Devices, Inc. All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Compile test and basic sanity check for doca_hip_atomic.hip.h.
 * Run as: hipcc -x hip --offload-arch=<arch> -I src/include
 * test_doca_hip_atomic.hip -o test_atomic && ./test_atomic Or build with
 * rocm-xio and run the test executable.
 */
#include <cassert>
#include <cstdio>

#include "gin-ep/gin-ep.h"
#include "hip/hip_runtime.h"

#define HIP_CHECK(cmd)                                                         \
  do {                                                                         \
    hipError_t _err = (cmd);                                                   \
    if (_err != hipSuccess) {                                                  \
      std::fprintf(stderr, "HIP error %s at %s:%d\n", hipGetErrorString(_err), \
                   __FILE__, __LINE__);                                        \
      return 1;                                                                \
    }                                                                          \
  } while (0)

__global__ void test_atomic_ref() {
  __shared__ uint64_t sh_max;
  __shared__ uint64_t sh_add;
  __shared__ int lock;

  if (threadIdx.x == 0) {
    sh_max = 0;
    sh_add = 0;
    lock = 0;
  }
  __syncthreads();

  /* fetch_max (block scope) */
  doca_hip::atomic_ref<uint64_t, doca_hip::thread_scope_block> max_ref(sh_max);
  uint64_t old = max_ref.fetch_max(threadIdx.x + 1,
                                   doca_hip::memory_order_relaxed);
  (void)old;

  /* fetch_add (block scope) */
  doca_hip::atomic_ref<uint64_t, doca_hip::thread_scope_block> add_ref(sh_add);
  add_ref.fetch_add(1, doca_hip::memory_order_relaxed);

  /* lock/unlock via CAS */
  if (threadIdx.x % 2 == 0) {
    while (doca_hip_atomic_cas_block(&lock, 0, 1) != 0)
      continue;
    /* critical section */
    add_ref.fetch_add(10, doca_hip::memory_order_relaxed);
    doca_hip::atomic_ref<int, doca_hip::thread_scope_block> lock_ref(lock);
    lock_ref.store(0, doca_hip::memory_order_release);
  }
  __syncthreads();

  if (threadIdx.x == 0) {
    /* max over 0..blockDim.x-1 + 1 => blockDim.x */
    assert(sh_max == (uint64_t)blockDim.x);
    /* each thread added 1; half added 10 in critical section */
    assert(sh_add == (uint64_t)blockDim.x + (blockDim.x / 2) * 10);
  }
}

int main() {
  uint64_t* d_val = nullptr;
  HIP_CHECK(hipMalloc(&d_val, sizeof(uint64_t)));
  HIP_CHECK(hipMemset(d_val, 0, sizeof(uint64_t)));

  hipLaunchKernelGGL(test_atomic_ref, dim3(1), dim3(256), 0, 0);
  HIP_CHECK(hipDeviceSynchronize());

  HIP_CHECK(hipFree(d_val));
  std::printf("PASS: doca_hip atomic operations test\n");
  return 0;
}
