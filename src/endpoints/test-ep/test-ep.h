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

#endif // TEST_EP_H
