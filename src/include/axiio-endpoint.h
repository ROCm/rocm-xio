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

/*
 * AxiioEndpoint Class
 * 
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
  
  // Get queue entry sizes (host-only)
  __host__ size_t getSubmissionQueueEntrySize() const;
  __host__ size_t getCompletionQueueEntrySize() const;
  
  // GPU operations (user provides buffers)
  __device__ void drive(
    unsigned iterations,
    void* submissionQueue,      // User-provided endpoint-specific buffer
    void* completionQueue,      // User-provided endpoint-specific buffer
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

// Standalone helper functions to get queue entry sizes
__host__ size_t getSubmissionQueueEntrySize(EndpointType type);
__host__ size_t getCompletionQueueEntrySize(EndpointType type);

#endif // AXIIO_ENDPOINT_H

