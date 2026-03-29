/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Minimal example: list all registered rocm-xio endpoints.
 * CPU-only; does not require a GPU to run.
 */

#include <cstdio>

#include "xio.h"

int main() {
  const auto& registry = getEndpointRegistry();
  if (registry.empty()) {
    printf("ERROR: endpoint registry is empty\n");
    return 1;
  }

  printf("rocm-xio: %zu endpoint(s) registered\n", registry.size());
  listAvailableEndpoints();
  return 0;
}
