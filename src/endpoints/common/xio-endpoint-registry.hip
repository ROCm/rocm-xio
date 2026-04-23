/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <algorithm>
#include <cctype>
#include <iostream>
#include <unordered_map>
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

static const std::unordered_map<std::string, EndpointType>&
endpointTypeByLowerName() {
  static const std::unordered_map<std::string, EndpointType> map = [] {
    std::unordered_map<std::string, EndpointType> out;
    std::vector<EndpointInfo> registry = ENDPOINT_REGISTRY_ENTRIES;
    for (const auto& ep : registry) {
      std::string key = ep.name;
      std::transform(key.begin(), key.end(), key.begin(),
                     [](unsigned char c) {
                       return static_cast<char>(std::tolower(c));
                     });
      out.emplace(std::move(key), ep.type);
    }
    return out;
  }();
  return map;
}

EndpointType getEndpointType(const std::string& name) {
  std::string lowerName = name;
  std::transform(lowerName.begin(), lowerName.end(), lowerName.begin(),
                 [](unsigned char c) {
                   return static_cast<char>(std::tolower(c));
                 });

  const auto& map = endpointTypeByLowerName();
  const auto it = map.find(lowerName);
  if (it != map.end()) {
    return it->second;
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
