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

// Forward declaration for CLI11
namespace CLI {
class App;
}

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
                             // Bit 0 (LSB): GPU write location (SQE)
                             //   (0=host, 1=device)
                             // Bit 1: CPU write location (CQE)
                             //   (0=host, 1=device)
                             // Bit 2: Doorbell location (doorbell mode only)
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

  // Get queue lengths (host-only) - number of entries needed
  // Default implementation returns numThreads for multi-threaded, 1 for
  // single-threaded Derived classes can override for custom queue sizing (e.g.,
  // doorbell mode)
  __host__ virtual size_t getSubmissionQueueLength(
    const AxiioEndpointConfig* config) const;
  __host__ virtual size_t getCompletionQueueLength(
    const AxiioEndpointConfig* config) const;

  // Run endpoint test - launches GPU kernel and waits for completion
  // Each derived class implements this to call its specific run function
  __host__ virtual hipError_t run(AxiioEndpointConfig* config) = 0;

  // Configure endpoint-specific CLI options
  // Derived classes can override this to add their own CLI flags/options
  // Default implementation does nothing (no endpoint-specific options)
  __host__ virtual void configureCliOptions(CLI::App& app);

  // Initialize endpoint-specific configuration
  // Called after CLI parsing to set up endpointConfig pointer
  // Returns pointer to endpoint-specific config object (or nullptr if none)
  // Caller is responsible for managing the lifetime of the returned object
  __host__ virtual void* initializeEndpointConfig();

  // Check if endpoint is in emulate mode (runs on CPU instead of GPU)
  // Returns true if emulate mode is enabled, false otherwise
  // Default implementation returns false
  __host__ virtual bool isEmulateMode() const;

  // Get doorbell queue length (if doorbell mode is enabled)
  // Returns doorbell queue length if doorbell mode is enabled, 0 otherwise
  // Default implementation returns 0
  __host__ virtual unsigned getDoorbellQueueLength() const;
};

// Factory function to create endpoint instances
// Returns unique_ptr for proper ownership management
__host__ std::unique_ptr<AxiioEndpoint> createEndpoint(EndpointType type);
__host__ std::unique_ptr<AxiioEndpoint> createEndpoint(
  const std::string& endpointName);

// Helper functions
void axiioPrintDeviceInfo();
void axiioPrintStatistics(const std::vector<double>& durations,
                          unsigned totalIterations = 0, unsigned numThreads = 0,
                          unsigned readIterations = 0,
                          unsigned writeIterations = 0,
                          unsigned verifiedReadsCount = 0);
void axiioPrintHistogram(const std::vector<double>& durations,
                         unsigned nIterations, unsigned numThreads = 0,
                         unsigned readIterations = 0,
                         unsigned writeIterations = 0,
                         unsigned verifiedReadsCount = 0);

// Queue memory allocation functions
// memoryMode bits: Bit 0 (LSB) = GPU write location (0=host, 1=device)
//                  Bit 1 (MSB) = CPU write location (0=host, 1=device)
hipError_t axiioAllocateSubmissionQueue(size_t size, unsigned memoryMode,
                                        void** ptr);
hipError_t axiioAllocateCompletionQueue(size_t size, unsigned memoryMode,
                                        void** ptr);
void axiioFreeSubmissionQueue(void* ptr, unsigned memoryMode);
void axiioFreeCompletionQueue(void* ptr, unsigned memoryMode);

// HSA device memory allocation (for doorbell and other device memory needs)
hsa_status_t axiioAllocDeviceMemory(size_t size, void** ptr,
                                    const char* direction);

// Extract endpoint name from command line arguments
// This allows endpoints to add their CLI options before full parsing
// Returns empty string if endpoint name not found in arguments
std::string axiioExtractEndpointName(int argc, char** argv);

#endif // AXIIO_H
