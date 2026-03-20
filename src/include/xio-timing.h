/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Shared timing statistics helpers for GPU and CPU.
 * Used by nvme-ep, test-ep, rdma-ep, and any future
 * endpoint that records per-operation durations.
 *
 * Must be included at global scope (not inside a
 * namespace) so the guarded <atomic> include works.
 */

#ifndef XIO_TIMING_H
#define XIO_TIMING_H

#include <hip/hip_runtime.h>

#include "xio.h"

#ifndef __HIP_DEVICE_COMPILE__
#include <atomic>
#endif

__host__ __device__ inline void updateTimingStats(
  xio::XioTimingStats* stats, unsigned long long int duration) {
  if (stats == nullptr)
    return;

#ifdef __HIP_DEVICE_COMPILE__
  atomicAdd((unsigned long long int*)&stats->count, 1ULL);
  atomicAdd((unsigned long long int*)&stats->sumDuration, duration);

  unsigned long long int oldMin = stats->minDuration;
  while (duration < oldMin) {
    auto* addr = (unsigned long long int*)&stats->minDuration;
    unsigned long long int result = atomicCAS(addr, oldMin, duration);
    if (result == oldMin)
      break;
    oldMin = result;
  }

  unsigned long long int oldMax = stats->maxDuration;
  while (duration > oldMax) {
    auto* addr = (unsigned long long int*)&stats->maxDuration;
    unsigned long long int result = atomicCAS(addr, oldMax, duration);
    if (result == oldMax)
      break;
    oldMax = result;
  }
#else
  auto* countPtr = reinterpret_cast<std::atomic_ullong*>(&stats->count);
  auto* sumPtr = reinterpret_cast<std::atomic_ullong*>(&stats->sumDuration);
  auto* minPtr = reinterpret_cast<std::atomic_ullong*>(&stats->minDuration);
  auto* maxPtr = reinterpret_cast<std::atomic_ullong*>(&stats->maxDuration);

  countPtr->fetch_add(1);
  sumPtr->fetch_add(duration);

  unsigned long long int oldMin = minPtr->load();
  while (duration < oldMin &&
         !minPtr->compare_exchange_weak(oldMin, duration)) {
  }

  unsigned long long int oldMax = maxPtr->load();
  while (duration > oldMax &&
         !maxPtr->compare_exchange_weak(oldMax, duration)) {
  }
#endif
}

#endif // XIO_TIMING_H
