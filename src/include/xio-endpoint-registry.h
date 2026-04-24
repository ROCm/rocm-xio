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
#include "xio-export.h"

// Endpoint information structure
struct EndpointInfo {
  std::string name;
  std::string description;
  EndpointType type;
};

// Get the registry of all available endpoints
XIO_API const std::vector<EndpointInfo>& getEndpointRegistry();

// Convert string name to endpoint type
XIO_API EndpointType getEndpointType(const std::string& name);

// Get endpoint name from type
XIO_API const char* getEndpointName(EndpointType type);

// List all available endpoints
XIO_API void listAvailableEndpoints();

// Validate endpoint name
XIO_API bool isValidEndpoint(const std::string& name);

// Get EndpointInfo from EndpointType
XIO_API EndpointInfo getEndpointInfo(EndpointType type);

#endif // XIO_ENDPOINT_REGISTRY_H
