/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef AXIIO_ENDPOINT_CONFIG_H
#define AXIIO_ENDPOINT_CONFIG_H

#include <cstdint>

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

#endif // AXIIO_ENDPOINT_CONFIG_H
