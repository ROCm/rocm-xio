/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <algorithm>
#include <cctype>
#include <iostream>
#include <vector>

#include <hip/hip_runtime.h>

#include "xio-endpoint-registry-gen.h"
#include "xio-endpoint-registry.h"

// Static registry of all available endpoints
static std::vector<EndpointInfo> buildEndpointRegistry() {
  // Use auto-generated endpoint registry
  std::vector<EndpointInfo> registry = ENDPOINT_REGISTRY_ENTRIES;
  return registry;
}

const std::vector<EndpointInfo>& getEndpointRegistry() {
  static std::vector<EndpointInfo> registry = buildEndpointRegistry();
  return registry;
}

EndpointType getEndpointType(const std::string& name) {
  std::string lowerName = name;
  std::transform(lowerName.begin(), lowerName.end(), lowerName.begin(),
                 [](unsigned char c) {
                   return std::tolower(c);
                 });

  const auto& registry = getEndpointRegistry();
  for (const auto& ep : registry) {
    if (ep.name == lowerName) {
      return ep.type;
    }
  }

  return EndpointType::UNKNOWN;
}

const char* getEndpointName(EndpointType type) {
  const auto& registry = getEndpointRegistry();
  for (const auto& ep : registry) {
    if (ep.type == type) {
      return ep.name.c_str();
    }
  }
  return "unknown";
}

void listAvailableEndpoints() {
  const auto& registry = getEndpointRegistry();
  std::cout << "Available endpoints:" << std::endl;
  for (const auto& ep : registry) {
    std::cout << "  " << ep.name << " - " << ep.description << std::endl;
  }
}

bool isValidEndpoint(const std::string& name) {
  return getEndpointType(name) != EndpointType::UNKNOWN;
}

// Helper function to get EndpointInfo from EndpointType
EndpointInfo getEndpointInfo(EndpointType type) {
  const auto& registry = getEndpointRegistry();
  for (const auto& ep : registry) {
    if (ep.type == type) {
      return ep;
    }
  }
  // Return unknown endpoint if not found
  return EndpointInfo{"unknown", "Unknown endpoint", EndpointType::UNKNOWN};
}
