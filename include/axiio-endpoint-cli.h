/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef AXIIO_ENDPOINT_CLI_H
#define AXIIO_ENDPOINT_CLI_H

#include <functional>
#include <string>

#include <CLI/CLI.hpp>

namespace axiio {

/**
 * Endpoint CLI Options Registration Interface
 *
 * Each endpoint can register its own command-line options by providing
 * a registration function. This allows endpoints to have endpoint-specific
 * options without cluttering the main tester code.
 */
class EndpointCliRegistry {
public:
  /**
   * Register CLI options for an endpoint
   *
   * @param endpoint_name Name of the endpoint (e.g., "nvme-ep")
   * @param app CLI11 App object to add options to
   * @param config_ptr Pointer to endpoint-specific config structure
   */
  using RegisterFunction = std::function<void(CLI::App&, void*)>;

  /**
   * Validate options after parsing (optional)
   *
   * @param config_ptr Pointer to endpoint-specific config structure
   * @return Error message if validation fails, empty string on success
   */
  using ValidateFunction = std::function<std::string(void*)>;

  /**
   * Register an endpoint's CLI options
   */
  static void registerEndpoint(const std::string& endpoint_name,
                               RegisterFunction register_fn,
                               ValidateFunction validate_fn = nullptr) {
    // Store registration functions (simplified - in real implementation,
    // this would use a map or similar structure)
    // For now, endpoints will call this during their initialization
  }

  /**
   * Call the registration function for a specific endpoint
   */
  static void registerOptionsForEndpoint(const std::string& endpoint_name,
                                         CLI::App& app, void* config_ptr) {
    // This will be implemented by each endpoint
    // Endpoints will provide their own registration functions
  }
};

} // namespace axiio

#endif // AXIIO_ENDPOINT_CLI_H
