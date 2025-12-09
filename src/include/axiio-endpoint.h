/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef AXIIO_ENDPOINT_H
#define AXIIO_ENDPOINT_H

#include <cstdint>
#include <string>

#include <hip/hip_runtime.h>

#include "axiio-endpoint-config.h"
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

  // Run endpoint test - launches GPU kernel and waits for completion
  // Calls the endpoint-specific run function directly (no dispatch)
  __host__ hipError_t run(AxiioEndpointConfig* config);

private:
  EndpointType type_;
  // Function pointer to endpoint-specific run() - set in constructor
  hipError_t (*runFunc_)(AxiioEndpointConfig*);
};

// Standalone helper functions to get queue entry sizes
__host__ size_t getSubmissionQueueEntrySize(EndpointType type);
__host__ size_t getCompletionQueueEntrySize(EndpointType type);

#endif // AXIIO_ENDPOINT_H
