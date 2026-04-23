/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <iostream>
#include <string>

#include "xio-endpoint-registry-gen.h"
#include "xio-endpoint-registry.h"
#include "xio.h"

int main() {
  const auto& reg = getEndpointRegistry();
  if (reg.empty()) {
    std::cerr << "endpoint registry empty\n";
    return 1;
  }

  for (const auto& ep : reg) {
    auto created = xio::createEndpoint(ep.type);
    if (!created) {
      std::cerr << "createEndpoint failed for type enum\n";
      return 2;
    }
    const char* n = getEndpointName(ep.type);
    if (std::string(n) != ep.name) {
      std::cerr << "getEndpointName mismatch for " << ep.name << "\n";
      return 3;
    }
    auto byName = xio::createEndpoint(ep.name);
    if (!byName) {
      std::cerr << "createEndpoint failed for name " << ep.name << "\n";
      return 4;
    }
    if (getEndpointType(ep.name) != ep.type) {
      std::cerr << "getEndpointType round-trip failed for " << ep.name
                << "\n";
      return 5;
    }
  }

  if (xio::createEndpoint(EndpointType::UNKNOWN)) {
    std::cerr << "createEndpoint(UNKNOWN) should return null\n";
    return 6;
  }
  if (xio::createEndpoint("not-a-real-endpoint")) {
    std::cerr << "createEndpoint(bad name) should return null\n";
    return 7;
  }

  std::cout << "endpoint registry checks passed\n";
  return 0;
}
