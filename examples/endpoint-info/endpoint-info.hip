/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Example: iterate the rocm-xio endpoint registry and
 * print each endpoint's name, description, and type.
 * CPU-only; does not require a GPU to run.
 */

#include <cstdio>
#include <cstdlib>

#include "xio.h"

int main() {
  const auto& registry = getEndpointRegistry();
  if (registry.empty()) {
    printf("ERROR: endpoint registry is empty\n");
    return 1;
  }

  printf("rocm-xio endpoint registry "
         "(%zu entries):\n\n",
         registry.size());

  for (const auto& ep : registry) {
    const char* name = getEndpointName(ep.type);
    if (!name) {
      printf("ERROR: getEndpointName() returned "
             "null for type %d\n",
             static_cast<int>(ep.type));
      return 1;
    }

    printf("  %-16s %s\n", ep.name.c_str(), ep.description.c_str());

    if (ep.name != name) {
      printf("ERROR: registry name '%s' != "
             "getEndpointName() '%s'\n",
             ep.name.c_str(), name);
      return 1;
    }

    if (!isValidEndpoint(ep.name)) {
      printf("ERROR: isValidEndpoint('%s') "
             "returned false\n",
             ep.name.c_str());
      return 1;
    }
  }

  printf("\nAll endpoint info checks passed.\n");
  return 0;
}
