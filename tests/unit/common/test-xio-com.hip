/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for the host-side specializations of XioComEnqueue<Size>,
 * XioComDequeue<Size>, and XioComDoorbell<T> from xio.h. These templates are
 * the canonical 8-byte-wide store/load helpers used by every endpoint to fill
 * SQE/WQE slots and ring doorbells. They are declared __host__ __device__, so
 * the host path can be exercised in CPU-only CTest runs.
 */

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <hip/hip_runtime.h>

#include "xio-test-assert.h"
#include "xio.h"

namespace {

template <uint32_t Size>
void check_enqueue_dequeue_pattern() {
  static_assert(Size % sizeof(uint64_t) == 0, "Size must be multiple of 8");
  alignas(8) uint8_t src[Size];
  alignas(8) uint8_t dst[Size];
  alignas(8) uint8_t readback[Size];

  for (uint32_t i = 0; i < Size; i++) {
    src[i] = static_cast<uint8_t>((i * 13 + 7) & 0xFF);
    dst[i] = 0x00;
    readback[i] = 0xFF;
  }

  xio::XioComEnqueue<Size>(src, dst);
  if (memcmp(src, dst, Size) != 0) {
    printf("XioComEnqueue<%u> did not copy bytes correctly\n", Size);
    abort();
  }

  xio::XioComDequeue<Size>(dst, readback);
  if (memcmp(src, readback, Size) != 0) {
    printf("XioComDequeue<%u> did not copy bytes correctly\n", Size);
    abort();
  }
}

} // namespace

int test_enqueue_dequeue_sizes() {
  check_enqueue_dequeue_pattern<8>();
  check_enqueue_dequeue_pattern<16>();
  check_enqueue_dequeue_pattern<24>();
  check_enqueue_dequeue_pattern<32>();
  check_enqueue_dequeue_pattern<40>();
  check_enqueue_dequeue_pattern<48>();
  check_enqueue_dequeue_pattern<56>();
  check_enqueue_dequeue_pattern<64>();
  check_enqueue_dequeue_pattern<128>();
  check_enqueue_dequeue_pattern<256>();
  return 0;
}

int test_enqueue_does_not_touch_neighbors() {
  alignas(8) uint8_t buf[64];
  memset(buf, 0xCC, sizeof(buf));

  alignas(8) uint8_t src[16];
  memset(src, 0x55, sizeof(src));

  xio::XioComEnqueue<16>(src, buf + 16);

  for (uint32_t i = 0; i < 16; i++)
    ASSERT_EQ(buf[i], static_cast<uint8_t>(0xCC));
  for (uint32_t i = 16; i < 32; i++)
    ASSERT_EQ(buf[i], static_cast<uint8_t>(0x55));
  for (uint32_t i = 32; i < 64; i++)
    ASSERT_EQ(buf[i], static_cast<uint8_t>(0xCC));
  return 0;
}

int test_enqueue_fenced_specialization() {
  /* Fence=true is a no-op on the host path; verify the same byte-copy
   * semantics still hold so we do not regress the host build. */
  alignas(8) uint64_t src = 0x0102030405060708ULL;
  alignas(8) uint64_t dst = 0;
  xio::XioComEnqueue<sizeof(uint64_t), true>(&src, &dst);
  ASSERT_EQ(dst, 0x0102030405060708ULL);
  return 0;
}

int test_doorbell_uint32() {
  uint32_t db = 0;
  xio::XioComDoorbell<uint32_t>(&db, 0xDEADBEEFu);
  ASSERT_EQ(db, 0xDEADBEEFu);

  xio::XioComDoorbell<uint32_t>(&db, 0u);
  ASSERT_EQ(db, 0u);

  xio::XioComDoorbell<uint32_t>(&db, 0xFFFFFFFFu);
  ASSERT_EQ(db, 0xFFFFFFFFu);
  return 0;
}

int test_doorbell_uint64() {
  uint64_t db = 0;
  xio::XioComDoorbell<uint64_t>(&db, 0x0123456789ABCDEFULL);
  ASSERT_EQ(db, 0x0123456789ABCDEFULL);

  xio::XioComDoorbell<uint64_t>(&db, 0ULL);
  ASSERT_EQ(db, 0ULL);

  xio::XioComDoorbell<uint64_t>(&db, 0xFFFFFFFFFFFFFFFFULL);
  ASSERT_EQ(db, 0xFFFFFFFFFFFFFFFFULL);
  return 0;
}

int test_ring_doorbell_base_offset() {
  alignas(8) uint32_t bar[4] = {0, 0, 0, 0};
  xio::ringDoorbell(static_cast<void*>(bar), 4u, 0x12345678u);
  ASSERT_EQ(bar[0], 0u);
  ASSERT_EQ(bar[1], 0x12345678u);
  ASSERT_EQ(bar[2], 0u);
  ASSERT_EQ(bar[3], 0u);

  /* Nullptr base must be a no-op (defensive guard). */
  xio::ringDoorbell(static_cast<void*>(nullptr), 4u, 0xFFu);

  xio::ringDoorbell(static_cast<void*>(bar), 12u, 0xCAFEBABEu);
  ASSERT_EQ(bar[3], 0xCAFEBABEu);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_enqueue_dequeue_sizes();
  failures += test_enqueue_does_not_touch_neighbors();
  failures += test_enqueue_fenced_specialization();
  failures += test_doorbell_uint32();
  failures += test_doorbell_uint64();
  failures += test_ring_doorbell_base_offset();

  if (failures == 0) {
    printf("All XioComEnqueue/Dequeue/Doorbell tests passed.\n");
    return 0;
  }
  printf("%d XioComEnqueue/Dequeue/Doorbell test(s) failed.\n", failures);
  return 1;
}
