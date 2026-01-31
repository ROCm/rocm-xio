/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef XIO_ENDPOINT_REGISTRY_H
#define XIO_ENDPOINT_REGISTRY_H

#include <string>
#include <vector>

#include <hip/hip_runtime.h>

// Include auto-generated EndpointType enum
#include "xio-endpoint-registry-gen.h"

// Endpoint information structure
struct EndpointInfo {
  std::string name;
  std::string description;
  EndpointType type;
};

// Get the registry of all available endpoints
const std::vector<EndpointInfo>& getEndpointRegistry();

// Convert string name to endpoint type
EndpointType getEndpointType(const std::string& name);

// Get endpoint name from type
const char* getEndpointName(EndpointType type);

// List all available endpoints
void listAvailableEndpoints();

// Validate endpoint name
bool isValidEndpoint(const std::string& name);

// Get EndpointInfo from EndpointType
EndpointInfo getEndpointInfo(EndpointType type);

#endif // XIO_ENDPOINT_REGISTRY_H
