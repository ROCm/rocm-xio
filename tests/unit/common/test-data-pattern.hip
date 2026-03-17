/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for xio::DataPatternParams and
 * xio::dataPattern() LFSR-based generation and
 * verification.
 */

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include <hip/hip_runtime.h>

#include "xio-data-pattern.hpp"

#define ASSERT_EQ(a, b) assert((a) == (b))
#define ASSERT_TRUE(x) assert(x)

int test_generate_nonzero() {
  const size_t sz = 64;
  uint8_t buf[sz];
  memset(buf, 0, sz);

  xio::DataPatternParams params = {};
  params.buffer = buf;
  params.size = sz;
  params.offset = 0;
  params.blockSize = 4096;
  params.seed = 0x42;
  params.errorOffset = nullptr;

  bool ok = xio::dataPattern(false, params);
  ASSERT_TRUE(ok);

  bool allZero = true;
  for (size_t i = 0; i < sz; i++) {
    if (buf[i] != 0) {
      allZero = false;
      break;
    }
  }
  ASSERT_TRUE(!allZero);
  return 0;
}

int test_verify_roundtrip() {
  const size_t sz = 128;
  uint8_t buf[sz];

  xio::DataPatternParams params = {};
  params.buffer = buf;
  params.size = sz;
  params.offset = 0;
  params.blockSize = 4096;
  params.seed = 0xBEEF;
  params.errorOffset = nullptr;

  bool ok = xio::dataPattern(false, params);
  ASSERT_TRUE(ok);

  ok = xio::dataPattern(true, params);
  ASSERT_TRUE(ok);
  return 0;
}

int test_verify_detects_corruption() {
  const size_t sz = 64;
  uint8_t buf[sz];

  size_t errOff = 0;
  xio::DataPatternParams params = {};
  params.buffer = buf;
  params.size = sz;
  params.offset = 0;
  params.blockSize = 4096;
  params.seed = 0xCAFE;
  params.errorOffset = &errOff;

  xio::dataPattern(false, params);

  buf[10] ^= 0xFF;

  bool ok = xio::dataPattern(true, params);
  ASSERT_TRUE(!ok);
  ASSERT_EQ(errOff, 10u);
  return 0;
}

int test_different_seeds_differ() {
  const size_t sz = 32;
  uint8_t buf1[sz], buf2[sz];

  xio::DataPatternParams p1 = {};
  p1.buffer = buf1;
  p1.size = sz;
  p1.offset = 0;
  p1.blockSize = 4096;
  p1.seed = 1;
  p1.errorOffset = nullptr;

  xio::DataPatternParams p2 = {};
  p2.buffer = buf2;
  p2.size = sz;
  p2.offset = 0;
  p2.blockSize = 4096;
  p2.seed = 2;
  p2.errorOffset = nullptr;

  xio::dataPattern(false, p1);
  xio::dataPattern(false, p2);

  ASSERT_TRUE(memcmp(buf1, buf2, sz) != 0);
  return 0;
}

int test_different_offsets_differ() {
  const size_t sz = 32;
  uint8_t buf1[sz], buf2[sz];

  xio::DataPatternParams p1 = {};
  p1.buffer = buf1;
  p1.size = sz;
  p1.offset = 0;
  p1.blockSize = 4096;
  p1.seed = 0x42;
  p1.errorOffset = nullptr;

  xio::DataPatternParams p2 = {};
  p2.buffer = buf2;
  p2.size = sz;
  p2.offset = 4096;
  p2.blockSize = 4096;
  p2.seed = 0x42;
  p2.errorOffset = nullptr;

  xio::dataPattern(false, p1);
  xio::dataPattern(false, p2);

  ASSERT_TRUE(memcmp(buf1, buf2, sz) != 0);
  return 0;
}

int test_deterministic() {
  const size_t sz = 64;
  uint8_t buf1[sz], buf2[sz];

  xio::DataPatternParams p = {};
  p.size = sz;
  p.offset = 8192;
  p.blockSize = 4096;
  p.seed = 0xD00D;
  p.errorOffset = nullptr;

  p.buffer = buf1;
  xio::dataPattern(false, p);

  p.buffer = buf2;
  xio::dataPattern(false, p);

  ASSERT_TRUE(memcmp(buf1, buf2, sz) == 0);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_generate_nonzero();
  failures += test_verify_roundtrip();
  failures += test_verify_detects_corruption();
  failures += test_different_seeds_differ();
  failures += test_different_offsets_differ();
  failures += test_deterministic();

  if (failures == 0) {
    printf("All data-pattern tests passed.\n");
    return 0;
  }
  printf("%d data-pattern test(s) failed.\n", failures);
  return 1;
}
