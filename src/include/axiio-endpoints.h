/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef AXIIO_ENDPOINTS_H
#define AXIIO_ENDPOINTS_H

#include <cstdint>

#include <hip/hip_runtime.h>

#include "axiio-endpoint-registry.h"

// Include endpoint-specific headers to get their size definitions
// AUTO-GENERATED SECTION - DO NOT EDIT MANUALLY
#include "axiio-endpoint-includes-gen.h"

// Calculate padding sizes
// Fixed fields: magicID (1) + entryId (2) + timeStamp (8) + dataPayload (8) =
// 19 CQE fixed fields: magicID (1) + entryId (2) + dataPayload (8) = 11
#define AXIIO_SQE_PAD_SIZE (AXIIO_SQE_SIZE - 19) // 19 = 1+2+8+8
#define AXIIO_CQE_PAD_SIZE (AXIIO_CQE_SIZE - 11) // 11 = 1+2+8

// Common queue entry structures (used by all endpoints)
struct sqeType_s {
  uint8_t magicID;      // 1 byte
  uint16_t entryId;     // 2 bytes
  uint64_t timeStamp;   // 8 bytes
  uint64_t dataPayload; // 8 bytes
  uint8_t padField[AXIIO_SQE_PAD_SIZE];
} __attribute__((packed));

struct cqeType_s {
  uint8_t magicID;      // 1 byte
  uint16_t entryId;     // 2 bytes
  uint64_t dataPayload; // 8 bytes
  uint8_t padField[AXIIO_CQE_PAD_SIZE];
} __attribute__((packed));

class axiioEndPoint {
public:
  typedef struct sqeType_s sqeType;
  typedef struct cqeType_s cqeType;

  // Endpoint type for runtime selection
  EndpointType endpointType;

  // Constructor
  __host__ __device__ axiioEndPoint() : endpointType(EndpointType::TEST_EP) {
  }
  __host__ __device__ axiioEndPoint(EndpointType type) : endpointType(type) {
  }

  // Dispatch functions - these read endpointType from the object
  // NOTE: Object must be in GPU-accessible memory when called from device!
  __device__ void driveEndpoint(unsigned, sqeType*, cqeType*,
                                unsigned long long int*,
                                unsigned long long int*);
  __host__ __device__ void emulateEndpoint(unsigned, sqeType*, cqeType*);

  // Static dispatch functions that take endpointType as parameter
  // These are safe to call with endpointType from value (no object deref
  // needed)
  __device__ static void driveEndpointDispatch(EndpointType type, unsigned,
                                               sqeType*, cqeType*,
                                               unsigned long long int*,
                                               unsigned long long int*);
  __host__ __device__ static void emulateEndpointDispatch(EndpointType type,
                                                          unsigned, sqeType*,
                                                          cqeType*);
};

#endif // AXIIO_ENDPOINTS_H
