/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef AXIIO_ENDPOINTS_H
#define AXIIO_ENDPOINTS_H

#include <hip/hip_runtime.h>

// Magic ID for test-ep queue entries
#define TEST_EP_MAGIC_ID 0xF0

// Submission Queue Entry - 64 bytes
typedef struct __attribute__((packed)) {
    uint8_t magicID;         // 1 byte
    uint16_t entryId;        // 2 bytes
    uint64_t timeStamp;      // 8 bytes
    uint64_t dataPayload;    // 8 bytes
    uint8_t padField[45];    // 45 bytes (total: 64 bytes)
} sqeType;

// Completion Queue Entry - 16 bytes
typedef struct __attribute__((packed)) {
    uint8_t magicID;         // 1 byte
    uint16_t entryId;        // 2 bytes
    uint64_t dataPayload;    // 8 bytes
    uint8_t padField[5];     // 5 bytes (total: 16 bytes)
} cqeType;

class axiioEndPoint {
public:
    __device__ void driveEndpoint(unsigned, sqeType *, cqeType *,
        unsigned long long int *, unsigned long long int *);
    __host__ __device__ void emulateEndpoint(unsigned, sqeType *, cqeType *);
};

#endif // AXIIO_ENDPOINTS_H
