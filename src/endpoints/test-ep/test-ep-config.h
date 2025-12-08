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
 * Currently minimal, but can be extended as needed.
 */
struct TestEpConfig {
  // Test-ep specific parameters can be added here
  // For now, we rely on the base AxiioEndpointConfig

  // Default constructor
  TestEpConfig() = default;
};

} // namespace test_ep

#endif // TEST_EP_CONFIG_H
