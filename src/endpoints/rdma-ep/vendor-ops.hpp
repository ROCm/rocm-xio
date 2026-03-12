/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Vendor abstraction layer for rdma-ep. Consolidates shared patterns
 * identified across MLX5, BNXT, and IONIC vendor queue_pair implementations
 * from rocSHMEM GDA. Each vendor still implements its own WQE builder,
 * doorbell, and CQE parser; this layer provides the shared control flow,
 * locking, and logical descriptors.
 */

#ifndef RDMA_EP_VENDOR_OPS_HPP
#define RDMA_EP_VENDOR_OPS_HPP

#include <cstdint>
#include <cstring>

#include <hip/hip_runtime.h>

namespace rdma_ep {

constexpr uint32_t WF_SIZE = 64;
constexpr uint32_t SPIN_LOCK_UNLOCKED = 0;

// GPU spinlock -- replaces 3 different vendor lock implementations.
// MLX5 used __hip_atomic_exchange; BNXT used __hip_atomic_compare_exchange;
// IONIC used shared/unique variants. This unifies them.
struct SpinLock {
  uint32_t lock{SPIN_LOCK_UNLOCKED};

  __device__ void acquire() {
    while (__hip_atomic_exchange(&lock, 1u, __ATOMIC_ACQUIRE,
                                __HIP_MEMORY_SCOPE_AGENT) != 0u) {
#ifdef __HIP_DEVICE_COMPILE__
      __builtin_amdgcn_s_sleep(1);
#endif
    }
  }

  __device__ void release() {
    __hip_atomic_store(&lock, 0u, __ATOMIC_RELEASE,
                       __HIP_MEMORY_SCOPE_AGENT);
  }
};

// Logical RMA descriptor -- filled once by QueuePair dispatch, passed to
// vendor-specific WQE builder. Avoids each vendor re-extracting the same info.
struct RmaDescriptor {
  uintptr_t local_addr;
  uintptr_t remote_addr;
  uint32_t length;
  uint32_t lkey;
  uint32_t rkey;
  uint8_t opcode;
  bool send_inline;
};

// Logical AMO descriptor
struct AmoDescriptor {
  uintptr_t remote_addr;
  uint32_t rkey;
  uint8_t opcode;
  int64_t swap_add;
  int64_t compare;
  bool fetching;
  uintptr_t fetch_addr;
  uint32_t fetch_lkey;
};

// Provider ID enum (replaces rocshmem GDAProvider)
enum class Provider : uint8_t {
  BNXT = 0,
  MLX5 = 1,
  IONIC = 2,
  UNKNOWN = 0xFF,
};

__host__ inline const char *provider_name(Provider p) {
  switch (p) {
  case Provider::BNXT:
    return "bnxt";
  case Provider::MLX5:
    return "mlx5";
  case Provider::IONIC:
    return "ionic";
  default:
    return "unknown";
  }
}

__host__ inline Provider provider_from_string(const char *s) {
  if (!s)
    return Provider::UNKNOWN;
  if (strcmp(s, "bnxt") == 0 || strcmp(s, "bnxt_re") == 0)
    return Provider::BNXT;
  if (strcmp(s, "mlx5") == 0)
    return Provider::MLX5;
  if (strcmp(s, "ionic") == 0 || strcmp(s, "pensando") == 0)
    return Provider::IONIC;
  return Provider::UNKNOWN;
}

// Vendor ID constants for NIC detection
constexpr uint32_t VENDOR_ID_BROADCOM = 0x14E4;
constexpr uint32_t VENDOR_ID_MELLANOX = 0x02C9;
constexpr uint32_t VENDOR_ID_PENSANDO = 0x1DD8;

// Wave/lane helpers -- ported from rocshmem util.hpp
__device__ inline uint64_t get_active_lane_mask() {
  return __ballot(1);
}

__device__ inline int get_lane_id() {
  return __lane_id();
}

__device__ inline bool is_thread_zero_in_wave() {
  return get_lane_id() == 0;
}

__device__ inline int popcount64(uint64_t mask) {
  return __popcll(mask);
}

__device__ inline int first_lane(uint64_t mask) {
  return __ffsll(static_cast<long long>(mask)) - 1;
}

__device__ inline int last_lane(uint64_t mask) {
  return 63 - __clzll(static_cast<long long>(mask));
}

} // namespace rdma_ep

#endif // RDMA_EP_VENDOR_OPS_HPP
