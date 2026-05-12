/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * SDMA Endpoint Tester Integration
 *
 * Declares the configuration structure and validation
 * helpers consumed by xio-tester and other host tooling.
 */

#pragma once

#include <cstddef>
#include <string>

#include <hip/hip_runtime.h>

namespace xio {
struct XioEndpointConfig;

namespace sdma_ep {

/**
 * @brief SDMA endpoint test configuration.
 *
 * Contains all user-facing options for the xio-tester
 * sdma-ep subcommand. Validated by validateConfig().
 */
struct SdmaEpConfig {
  std::string testType = "";  /**< Test subcommand name:
                                   "p2p", "ping-pong", or
                                   "buffer-reuse". */
  bool useHostDst = false;    /**< If true, destination is
                                   pinned host memory (single
                                   GPU, no P2P required). */
  bool verifyData = false;    /**< If true, validate the
                                   destination buffer after
                                   transfer. */
  bool useCounter = false;    /**< Use counter-based
                                   completion tracking. */
  bool useFlush = false;      /**< Use flush-based
                                   completion tracking. */
  int srcDeviceId = -1;       /**< Source HIP device ID.
                                   -1 = default (0). */
  int dstDeviceId = -1;       /**< Destination HIP device ID.
                                   -1 = default (1 for P2P,
                                   0 for --to-host). */
  size_t transferSize = 4096; /**< Per-iteration transfer
                                   size in bytes. Must be a
                                   multiple of 4. */
  unsigned iterations = 128;  /**< Number of SDMA transfers
                                    per run. */
};

/* ================================================================
 * CLI and Validation Helpers
 * ================================================================ */

__host__ std::string validateConfig(SdmaEpConfig* config);
__host__ unsigned getIterations(void* endpointConfig);
__host__ hipError_t run(XioEndpointConfig* config);

} // namespace sdma_ep
} // namespace xio
