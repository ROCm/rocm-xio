/*
 * SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION &
 * AFFILIATES. All rights reserved. SPDX-FileCopyrightText: Modifications
 * Copyright (c) 2025-2026 Advanced Micro Devices, Inc. All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * HIP-compatible atomic wrapper for DOCA-compatible headers.
 * Replaces CUDA cuda::atomic_ref and maps memory scopes to HIP fences.
 */
#ifndef DOCA_HIP_ATOMIC_HIP_H
#define DOCA_HIP_ATOMIC_HIP_H

#include <atomic>
#include <cstdint>

#include "hip/hip_runtime.h"

namespace doca_hip {

/* Memory scope tags (match CUDA thread_scope_*) */
struct thread_scope_block {};
struct thread_scope_device {};
struct thread_scope_system {};

/* Memory orders (match std::memory_order for __atomic_* builtins) */
[[maybe_unused]] constexpr std::memory_order memory_order_relaxed =
  std::memory_order_relaxed;
[[maybe_unused]] constexpr std::memory_order memory_order_acquire =
  std::memory_order_acquire;
[[maybe_unused]] constexpr std::memory_order memory_order_release =
  std::memory_order_release;

/* Map scope to HIP fence (release semantics before store, acquire after load)
 */
template <typename Scope>
__device__ __forceinline__ void fence_release(Scope) {
  __threadfence(); /* default device scope */
}
template <>
__device__ __forceinline__ void fence_release(thread_scope_block) {
  __threadfence_block();
}
template <>
__device__ __forceinline__ void fence_release(thread_scope_device) {
  __threadfence();
}
template <>
__device__ __forceinline__ void fence_release(thread_scope_system) {
  __threadfence_system();
}

template <typename Scope>
__device__ __forceinline__ void fence_acquire(Scope) {
  __threadfence();
}
template <>
__device__ __forceinline__ void fence_acquire(thread_scope_block) {
  __threadfence_block();
}
template <>
__device__ __forceinline__ void fence_acquire(thread_scope_device) {
  __threadfence();
}
template <>
__device__ __forceinline__ void fence_acquire(thread_scope_system) {
  __threadfence_system();
}

/**
 * HIP atomic_ref using __atomic_* builtins. Scope is used only for
 * optional fences; the underlying atomics are device-wide.
 */
template <typename T, typename Scope>
class atomic_ref {
  T* ptr_;

public:
  __device__ explicit atomic_ref(T& ref) : ptr_(&ref) {
  }

  __device__ void store(T val,
                        std::memory_order order = std::memory_order_seq_cst) {
    __atomic_store_n(ptr_, val, order);
  }

  __device__ T load(std::memory_order order = std::memory_order_seq_cst) const {
    return __atomic_load_n(ptr_, order);
  }

  __device__ T fetch_add(T val,
                         std::memory_order order = std::memory_order_relaxed) {
    return __atomic_fetch_add(ptr_, val, order);
  }

  __device__ T fetch_max(T val,
                         std::memory_order order = std::memory_order_relaxed) {
    T old = __atomic_load_n(ptr_, order);
    for (;;) {
      if (val <= old)
        return old;
      T new_val = val;
      if (__atomic_compare_exchange_weak(ptr_, &old, new_val, order,
                                         std::memory_order_relaxed))
        return old;
    }
  }
};

} /* namespace doca_hip */

/* HIP-compatible compare-and-swap (return value = old value at *address).
 * Global scope. */
__device__ __forceinline__ int doca_hip_atomic_cas_block(int* address,
                                                         int compare, int val) {
  int expected = compare;
  __atomic_compare_exchange_n(address, &expected, val, /*weak=*/false,
                              std::memory_order_acq_rel,
                              std::memory_order_relaxed);
  return expected;
}

__device__ __forceinline__ int doca_hip_atomic_cas(int* address, int compare,
                                                   int val) {
  int expected = compare;
  __atomic_compare_exchange_n(address, &expected, val, /*weak=*/false,
                              std::memory_order_acq_rel,
                              std::memory_order_relaxed);
  return expected;
}

#endif /* DOCA_HIP_ATOMIC_HIP_H */
