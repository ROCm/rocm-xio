/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * LFSR-based data pattern generation and verification.
 * Refactored from nvme-ep.h into common for use by any endpoint.
 *
 * This is a __host__ __device__ function that generates deterministic
 * pseudo-random patterns from a seed + offset, suitable for verifying
 * data integrity across DMA, RDMA, or any transfer path.
 */

#ifndef XIO_DATA_PATTERN_HPP
#define XIO_DATA_PATTERN_HPP

#include <cstddef>
#include <cstdint>

#include <hip/hip_runtime.h>

namespace xio {

struct DataPatternParams {
  uint8_t* buffer;
  size_t size;
  uint64_t offset;
  uint32_t blockSize;
  uint32_t seed;
  size_t* errorOffset;
};

/**
 * Generate or verify LFSR-based test data pattern.
 *
 * Generates or verifies a deterministic pseudo-random data pattern using
 * MurmurHash3-style mixing. The pattern is derived from the block index
 * (offset / blockSize) combined with a seed value.
 *
 * @param isVerify  If true, verifies buffer matches expected pattern.
 *                  If false, writes pattern into buffer.
 * @param params    Pattern parameters (buffer, size, offset, blockSize, seed).
 * @return true on success. In verify mode, false means mismatch (errorOffset
 *         set if provided).
 */
__host__ __device__ static inline bool dataPattern(bool isVerify,
                                                   DataPatternParams& params) {
  uint64_t block = params.offset / params.blockSize;
  uint32_t base_seed = (uint32_t)(block * 0x12345678);
  uint32_t seed = base_seed ^ params.seed;

  for (size_t i = 0; i < params.size; i++) {
    uint32_t rng = (uint32_t)(block * 0x9e3779b9 + seed + i);
    rng ^= rng >> 16;
    rng *= 0x85ebca6b;
    rng ^= rng >> 13;
    rng *= 0xc2b2ae35;
    rng ^= rng >> 16;
    uint8_t expected = (uint8_t)(rng & 0xFF);

    if (isVerify) {
      if (params.buffer[i] != expected) {
        if (params.errorOffset)
          *params.errorOffset = i;
        return false;
      }
    } else {
      params.buffer[i] = expected;
    }
  }

  return true;
}

} // namespace xio

#endif // XIO_DATA_PATTERN_HPP
