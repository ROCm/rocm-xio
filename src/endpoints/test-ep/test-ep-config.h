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

  // Default constructor
  TestEpConfig() = default;
};

} // namespace test_ep

#endif // TEST_EP_CONFIG_H
