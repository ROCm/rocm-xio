/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/endian.hpp, adapted for rocm-xio.
 * Canonical location for endian conversion helpers used by rdma-ep.
 */

#ifndef ROCM_XIO_ENDIAN_HPP
#define ROCM_XIO_ENDIAN_HPP

#include <type_traits>

#include <hip/hip_runtime.h>

namespace xio {
namespace rdma_ep {

template <typename T, std::enable_if_t<std::is_integral_v<T>, bool> = true>
constexpr inline __host__ __device__ T byteswap(T val) {
  if constexpr (sizeof(T) == 1) {
    return val;
  } else if constexpr (sizeof(T) == 2) {
    return __builtin_bswap16(val);
  } else if constexpr (sizeof(T) == 4) {
    return __builtin_bswap32(val);
  } else if constexpr (sizeof(T) == 8) {
    return __builtin_bswap64(val);
  } else {
    static_assert(sizeof(T) == 0, "byteswap not implemented for this type");
  }
}

namespace endian {

enum class Order {
  Big = __ORDER_BIG_ENDIAN__,
  Little = __ORDER_LITTLE_ENDIAN__,
  Native = __BYTE_ORDER__
};

template <Order To, Order From, typename T,
          std::enable_if_t<std::is_integral_v<T>, bool> = true>
__host__ __device__ constexpr inline T convert(T val) {
  if constexpr (To == From) {
    return val;
  } else {
    return byteswap(val);
  }
}

template <Order From, typename T>
__host__ __device__ constexpr inline T to_native(T val) {
  return convert<Order::Native, From, T>(val);
}

template <Order To, typename T>
__host__ __device__ constexpr inline T from_native(T val) {
  return convert<To, Order::Native, T>(val);
}

template <typename T>
__host__ __device__ constexpr inline T to_be(T val) {
  return convert<Order::Big, Order::Native, T>(val);
}

template <typename T>
__host__ __device__ constexpr inline T from_be(T val) {
  return convert<Order::Native, Order::Big, T>(val);
}

template <typename T>
__host__ __device__ constexpr inline T to_le(T val) {
  return convert<Order::Little, Order::Native, T>(val);
}

template <typename T>
__host__ __device__ constexpr inline T from_le(T val) {
  return convert<Order::Native, Order::Little, T>(val);
}

} // namespace endian

} // namespace rdma_ep
} // namespace xio

#endif // ROCM_XIO_ENDIAN_HPP
