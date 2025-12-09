/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef AXIIO_H
#define AXIIO_H

#include <cstdint>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include <hip/hip_runtime.h>

#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>

#include "axiio-endpoint-registry.h"
// AUTO-GENERATED - DO NOT EDIT MANUALLY
#include "axiio-endpoint-includes-gen.h"

#define HIP_CHECK(expression)                                                  \
  {                                                                            \
    const hipError_t status = expression;                                      \
    if (status != hipSuccess) {                                                \
      std::cerr << "HIP error " << status << ": " << hipGetErrorString(status) \
                << " at " << __FILE__ << ":" << __LINE__ << std::endl;         \
    }                                                                          \
  }

/**
 * Base configuration structure for all endpoints
 *
 * Contains common testing parameters that apply to all endpoints.
 * Endpoints can extend this with their own configuration structures
 * via the endpointConfig pointer.
 */
struct AxiioEndpointConfig {
  // Common testing parameters
  unsigned iterations = 128; // Number of iterations
  unsigned numThreads = 1;   // Number of GPU threads (1-32)
  long long delayNs = 0;     // Delay in nanoseconds
                             // Negative: fixed delay of |delayNs|
                             // Positive: random delay 0 to delayNs
                             // Zero: no delay
  unsigned memoryMode = 0;   // Memory mode bits:
                             // Bit 0 (LSB): GPU write location
                             //   (0=host, 1=device)
                             // Bit 1 (MSB): CPU write location
                             //   (0=host, 1=device)
  bool verbose = false;      // Verbose output flag

  // Timing arrays (optional, can be nullptr)
  unsigned long long int* startTimes = nullptr;
  unsigned long long int* endTimes = nullptr;

  // Queue pointers (host-accessible buffers)
  void* submissionQueue = nullptr; // Host-accessible SQE buffer
  void* completionQueue = nullptr; // Host-accessible CQE buffer

  // Endpoint-specific configuration (opaque pointer)
  // Endpoints cast this to their specific config type
  void* endpointConfig = nullptr;

  // Default constructor
  AxiioEndpointConfig() = default;

  // Convenience constructor for simple cases
  AxiioEndpointConfig(unsigned iter, unsigned threads = 1)
    : iterations(iter), numThreads(threads) {
  }
};

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

// Helper functions
void axxioPrintDeviceInfo();
void axxioPrintStatistics(const std::vector<double>& durations,
                          unsigned totalIterations = 0,
                          unsigned readIterations = 0,
                          unsigned writeIterations = 0,
                          unsigned verifiedReadsCount = 0);
void axxioPrintHistogram(const std::vector<double>& durations,
                         unsigned nIterations, unsigned readIterations = 0,
                         unsigned writeIterations = 0,
                         unsigned verifiedReadsCount = 0);

#endif // AXIIO_H
