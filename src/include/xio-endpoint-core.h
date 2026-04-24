/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Core endpoint types and factory declarations for rocm-xio.
 */

#ifndef XIO_ENDPOINT_CORE_H
#define XIO_ENDPOINT_CORE_H

#include <climits>
#include <cstdint>
#include <memory>
#include <string>

#include <hip/hip_runtime.h>

#include "xio-endpoint-registry.h"
#include "xio-export.h"

namespace xio {

/**
 * @brief Timing statistics for less-timing mode.
 *
 * Tracks min, max, sum, and count of IO completion times.
 */
struct XioTimingStats {
  unsigned long long int minDuration = ULLONG_MAX;
  unsigned long long int maxDuration = 0;
  unsigned long long int sumDuration = 0;
  unsigned long long int count = 0;
};

/**
 * @brief Per-sub-step cycle breakdown for hot-path
 *        profiling.
 *
 * Each field accumulates GPU clock cycles spent in a
 * specific phase of an IO operation.  Enable by setting
 * XioEndpointConfig::substepStats to a GPU-accessible
 * instance of this struct.
 */
struct XioSubstepStats {
  unsigned long long int sqeBuild = 0;   ///< Cycles in SQE/WQE
                                         ///< field formulation
                                         ///< (LBA hash, PRP
                                         ///< lookup, sqeSetup).
  unsigned long long int sqeEnqueue = 0; ///< Cycles in
                                         ///< XioComEnqueue wide
                                         ///< stores to queue
                                         ///< slot.
  unsigned long long int doorbell = 0;   ///< Cycles in SQ
                                         ///< doorbell write
                                         ///< (fence + atomic
                                         ///< store).
  unsigned long long int cqPoll = 0;     ///< Cycles polling CQ
                                         ///< for completions
                                         ///< (device latency).
  unsigned long long int cqDoorbell = 0; ///< Cycles in CQ
                                         ///< doorbell write
                                         ///< (fence + atomic
                                         ///< store).
  unsigned long long int count = 0;      ///< Number of IO
                                         ///< completions
                                         ///< measured.
  unsigned long long int buildCount = 0; ///< Number of SQE
                                         ///< builds measured
                                         ///< (may differ from
                                         ///< count in batch
                                         ///< mode).
};

/**
 * @brief Base configuration structure for all endpoints.
 *
 * Contains common testing parameters that apply to all
 * endpoints. Endpoints can extend this with their own
 * configuration structures via the endpointConfig pointer.
 */
struct XioEndpointConfig {
  unsigned iterations = 128;
  unsigned numThreads = 1;
  long long delayNs = 0;
  unsigned memoryMode = 0;
  bool verbose = false;
  bool pciMmioBridge = false;

  unsigned long long int* startTimes = nullptr;
  unsigned long long int* endTimes = nullptr;
  XioTimingStats* timingStats = nullptr;
  XioSubstepStats* substepStats = nullptr;

  void* submissionQueue = nullptr;
  void* completionQueue = nullptr;
  volatile bool* stopRequested = nullptr;
  void* endpointConfig = nullptr;

  uint32_t verifyPass = 0;
  uint32_t verifyFail = 0;

  XioEndpointConfig() = default;
  XioEndpointConfig(unsigned iter, unsigned threads = 1)
    : iterations(iter), numThreads(threads) {
  }
};

/**
 * @brief Base class for all endpoint implementations.
 *
 * Uses polymorphism to eliminate switch statements and
 * function pointers.
 */
class XIO_API XioEndpoint {
public:
  virtual ~XioEndpoint() = default;

  /** @brief Get the endpoint type identifier. */
  __host__ virtual EndpointType getType() const = 0;

  /** @brief Get the endpoint name string. */
  __host__ virtual const char* getName() const = 0;

  /** @brief Get a human-readable description. */
  __host__ virtual const char* getDescription() const = 0;

  /** @brief Get submission queue entry size in bytes. */
  __host__ virtual size_t getSubmissionQueueEntrySize() const = 0;

  /** @brief Get completion queue entry size in bytes. */
  __host__ virtual size_t getCompletionQueueEntrySize() const = 0;

  /**
   * @brief Get number of submission queue entries.
   * @param config Base endpoint configuration.
   * @return Number of entries (default: numThreads).
   */
  __host__ virtual size_t getSubmissionQueueLength(
    const XioEndpointConfig* config) const;

  /**
   * @brief Get number of completion queue entries.
   * @param config Base endpoint configuration.
   * @return Number of entries (default: numThreads).
   */
  __host__ virtual size_t getCompletionQueueLength(
    const XioEndpointConfig* config) const;

  /**
   * @brief Run the endpoint test.
   * @param config Endpoint configuration.
   * @return hipSuccess on success, error code on failure.
   */
  __host__ virtual hipError_t run(XioEndpointConfig* config) = 0;

  /**
   * @brief Initialize endpoint-specific configuration.
   * @return Pointer to config object, or nullptr.
   */
  __host__ virtual void* initializeEndpointConfig();

  /**
   * @brief Apply common config to endpoint config.
   * @param endpointConfig Endpoint-specific config pointer.
   * @param baseConfig Base configuration.
   */
  __host__ virtual void applyCommonConfig(void* endpointConfig,
                                          const XioEndpointConfig* baseConfig);

  /**
   * @brief Validate endpoint-specific configuration.
   * @param endpointConfig Endpoint config to validate.
   * @return Empty string if valid, error message otherwise.
   */
  __host__ virtual std::string validateConfig(void* endpointConfig);

  /**
   * @brief Get iteration count for this endpoint.
   * @param endpointConfig Endpoint config pointer.
   * @return Number of iterations to run.
   */
  __host__ virtual unsigned getIterations(void* endpointConfig) const;

  /**
   * @brief Check if endpoint is in emulate mode.
   * @return true if emulate mode is enabled.
   */
  __host__ virtual bool isEmulateMode() const;

  /**
   * @brief Get doorbell queue length.
   * @return Doorbell queue length, or 0 if disabled.
   */
  __host__ virtual unsigned getDoorbellQueueLength() const;
};

/**
 * @brief Create an endpoint instance by type enum.
 * @param type Endpoint type identifier.
 * @return Unique pointer to the created endpoint, or nullptr if
 *         @p type is EndpointType::UNKNOWN or not supported.
 * @note Always check the return value before dereferencing.
 */
[[nodiscard]] XIO_API __host__ std::unique_ptr<XioEndpoint> createEndpoint(
  EndpointType type);

/**
 * @brief Create an endpoint instance by name string.
 * @param endpointName Name of the endpoint (case-insensitive).
 * @return Unique pointer to the created endpoint, or nullptr if
 *         the name is unknown or not supported.
 * @note Always check the return value before dereferencing.
 */
[[nodiscard]] XIO_API __host__ std::unique_ptr<XioEndpoint> createEndpoint(
  const std::string& endpointName);

} // namespace xio

#endif /* XIO_ENDPOINT_CORE_H */
