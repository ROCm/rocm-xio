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

// Configurable queue entry sizes for test endpoint
#ifndef AXIIO_SQE_SIZE_TEST_EP
#define AXIIO_SQE_SIZE_TEST_EP 64
#endif

#ifndef AXIIO_CQE_SIZE_TEST_EP
#define AXIIO_CQE_SIZE_TEST_EP 16
#endif

// Calculate padding sizes for test endpoint
#define AXIIO_SQE_PAD_SIZE (AXIIO_SQE_SIZE_TEST_EP - 19)  // 19 = 1+2+8+8
#define AXIIO_CQE_PAD_SIZE (AXIIO_CQE_SIZE_TEST_EP - 11)  // 11 = 1+2+8

// Test Endpoint Submission Queue Entry
typedef struct __attribute__((packed)) {
    uint8_t magicID;                    // 1 byte
    uint16_t entryId;                   // 2 bytes
    uint64_t timeStamp;                 // 8 bytes
    uint64_t dataPayload;               // 8 bytes
    uint8_t padField[AXIIO_SQE_PAD_SIZE];
} sqeTypeTestEndpoint;

// Test Endpoint Completion Queue Entry
typedef struct __attribute__((packed)) {
    uint8_t magicID;                    // 1 byte
    uint16_t entryId;                   // 2 bytes
    uint64_t dataPayload;               // 8 bytes
    uint8_t padField[AXIIO_CQE_PAD_SIZE];
} cqeTypeTestEndpoint;

// Define the generic endpoint types using test endpoint specific structure
struct sqeType_s {
    uint8_t magicID;
    uint16_t entryId;
    uint64_t timeStamp;
    uint64_t dataPayload;
    uint8_t padField[AXIIO_SQE_PAD_SIZE];
} __attribute__((packed));

struct cqeType_s {
    uint8_t magicID;
    uint16_t entryId;
    uint64_t dataPayload;
    uint8_t padField[AXIIO_CQE_PAD_SIZE];
} __attribute__((packed));

#endif // TEST_EP_H

