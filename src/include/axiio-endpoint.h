/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef AXIIO_ENDPOINT_H
#define AXIIO_ENDPOINT_H

#include <cstdint>
#include <string>

#include <hip/hip_runtime.h>

#include "axiio-endpoint-registry.h"
// AUTO-GENERATED - DO NOT EDIT MANUALLY
#include "axiio-endpoint-includes-gen.h"

// Calculate padding sizes
// Fixed fields: magicID (1) + entryId (2) + timeStamp (8) + dataPayload (8) = 19
// CQE fixed fields: magicID (1) + entryId (2) + dataPayload (8) = 11
#define AXIIO_SQE_PAD_SIZE (AXIIO_SQE_SIZE - 19) // 19 = 1+2+8+8
#define AXIIO_CQE_PAD_SIZE (AXIIO_CQE_SIZE - 11) // 11 = 1+2+8

// Common queue entry structures (used internally for dispatch)
// Users don't need to know about these - they use void* buffers
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

// Forward declaration for internal dispatch function
__device__ void driveDispatch(
  EndpointType type,
  unsigned iterations,
  sqeType_s* submissionQueue,
  cqeType_s* completionQueue,
  unsigned long long int* startTimes,
  unsigned long long int* endTimes);

/*
 * AxiioEndpoint Class
 * 
 * Provides a clean API for using AxIIO endpoints while hiding
 * endpoint-specific implementation details.
 */
class AxiioEndpoint {
public:
  // Construction
  __host__ AxiioEndpoint(EndpointType type);
  __host__ AxiioEndpoint(const std::string& endpointName);
  
  // Accessors (host-only)
  __host__ EndpointType getType() const;
  __host__ const char* getName() const;
  __host__ const char* getDescription() const;
  
  // Queue operations (users provide buffers)
  // For device-side execution (real hardware)
  __device__ void drive(
    unsigned iterations,
    void* submissionQueue,      // User-provided sqeType_s buffer
    void* completionQueue,      // User-provided cqeType_s buffer
    unsigned long long int* startTimes,  // Optional timing array
    unsigned long long int* endTimes     // Optional timing array
  );
  
  // Convenience method (overload without timing)
  __device__ void drive(unsigned iterations, void* sq, void* cq) {
    drive(iterations, sq, cq, nullptr, nullptr);
  }
  
private:
  EndpointType type_;
};

#endif // AXIIO_ENDPOINT_H

