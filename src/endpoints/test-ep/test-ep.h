/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef TEST_EP_H
#define TEST_EP_H

#include <cstdint>

#include <hip/hip_runtime.h>

// Magic ID for test-ep queue entries
#define TEST_EP_MAGIC_ID 0xF0

// Test endpoint queue entry sizes
// Using smaller 32-byte entries for testing
#define TEST_EP_SQE_SIZE 32
#define TEST_EP_CQE_SIZE 32

// Test endpoint queue entry structures
struct test_sqe {
  uint8_t magicID;      // Magic ID for test-ep
  uint16_t entryId;     // Entry identifier
  uint64_t timeStamp;   // Timestamp
  uint64_t dataPayload; // Data payload
  uint8_t pad[32 - 19]; // Padding to 32 bytes
} __attribute__((packed));

struct test_cqe {
  uint8_t magicID;      // Magic ID for test-ep
  uint16_t entryId;     // Entry identifier
  uint64_t dataPayload; // Data payload
  uint8_t pad[32 - 11]; // Padding to 32 bytes
} __attribute__((packed));

static_assert(sizeof(struct test_sqe) == TEST_EP_SQE_SIZE, "test_sqe size mismatch");
static_assert(sizeof(struct test_cqe) == TEST_EP_CQE_SIZE, "test_cqe size mismatch");

#endif // TEST_EP_H
