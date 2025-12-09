/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef TEST_EP_CONFIG_H
#define TEST_EP_CONFIG_H

#include <cstdint>

namespace test_ep {

/**
 * Test endpoint configuration structure
 *
 * Contains test-ep-specific configuration parameters.
 */
struct TestEpConfig {
  // Enable CPU threads to poll SQEs and generate CQEs
  // When enabled, CPU threads will poll host memory for SQEs written by GPU
  // and generate CQEs with delay support
  bool enableCpuThreads = true; // Default: enabled to match simple-test
                                // behavior

  // Doorbell mode queue length
  // When > 0, enables doorbell mode with the specified queue length.
  // CPU threads do not poll individual SQEs. Instead, a single CPU thread polls
  // a doorbell address. The GPU writes SQEs to the submission queue and rings
  // the doorbell after each SQE enqueue. Doorbell location is controlled by
  // memory mode bit 2 (0=host, 1=device).
  unsigned doorbell = 0; // Default: 0 (disabled, polling mode)

  // Emulate mode: run kernel code on CPU instead of GPU
  // Useful for testing without a GPU or in CI environments
  bool emulate = false; // Default: false (use GPU)

  // Default constructor
  TestEpConfig() = default;
};

} // namespace test_ep

#endif // TEST_EP_CONFIG_H
