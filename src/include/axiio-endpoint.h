/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef AXIIO_ENDPOINT_H
#define AXIIO_ENDPOINT_H

#include <cstdint>
#include <memory>
#include <string>

#include <hip/hip_runtime.h>

#include "axiio-endpoint-config.h"
#include "axiio-endpoint-registry.h"
// AUTO-GENERATED - DO NOT EDIT MANUALLY
#include "axiio-endpoint-includes-gen.h"

/*
 * AxiioEndpoint Base Class
 *
 * Base class for all endpoint implementations. Uses polymorphism to
 * eliminate switch statements and function pointers.
 */
class AxiioEndpoint {
public:
  virtual ~AxiioEndpoint() = default;

  // Accessors (host-only)
  __host__ virtual EndpointType getType() const = 0;
  __host__ virtual const char* getName() const = 0;
  __host__ virtual const char* getDescription() const = 0;

  // Get queue entry sizes (host-only) - each derived class knows its sizes
  __host__ virtual size_t getSubmissionQueueEntrySize() const = 0;
  __host__ virtual size_t getCompletionQueueEntrySize() const = 0;

  // Run endpoint test - launches GPU kernel and waits for completion
  // Each derived class implements this to call its specific run function
  __host__ virtual hipError_t run(AxiioEndpointConfig* config) = 0;
};

// Factory function to create endpoint instances
// Returns unique_ptr for proper ownership management
__host__ std::unique_ptr<AxiioEndpoint> createEndpoint(EndpointType type);
__host__ std::unique_ptr<AxiioEndpoint> createEndpoint(
  const std::string& endpointName);

#endif // AXIIO_ENDPOINT_H
