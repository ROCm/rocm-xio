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

/** @brief Parameters for deterministic LFSR data generation or checking. */
struct DataPatternParams {
  uint8_t* buffer;     /**< Buffer to fill or verify. */
  size_t size;         /**< Number of bytes to process. */
  uint64_t offset;     /**< Logical byte offset of the transfer. */
  uint32_t blockSize;  /**< Block size used to derive the pattern seed. */
  uint32_t seed;       /**< Caller-supplied seed mixed into the pattern. */
  size_t* errorOffset; /**< Optional output byte offset for first mismatch. */
};

/**
 * Expected pattern byte at buffer index @p index for the same rules as
 * dataPattern() with base @p baseOffset, @p blockSize, and @p seed.
 */
__host__ __device__ static inline uint8_t dataPatternExpectedByte(
    uint64_t baseOffset, uint32_t blockSize, uint32_t seed, size_t index) {
  const uint64_t block = baseOffset / blockSize;
  const uint32_t base_seed = (uint32_t)(block * 0x12345678);
  const uint32_t mixed = base_seed ^ seed;
  uint32_t rng = (uint32_t)(block * 0x9e3779b9 + mixed + index);
  rng ^= rng >> 16;
  rng *= 0x85ebca6b;
  rng ^= rng >> 13;
  rng *= 0xc2b2ae35;
  rng ^= rng >> 16;
  return (uint8_t)(rng & 0xFF);
}

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
  for (size_t i = 0; i < params.size; i++) {
    const uint8_t expected = dataPatternExpectedByte(
        params.offset, params.blockSize, params.seed, i);

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
