/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "axiio-endpoint.h"
#include "axiio-endpoint-registry.h"

// Constructor implementations
__host__ AxiioEndpoint::AxiioEndpoint(EndpointType type) : type_(type) {
}

__host__ AxiioEndpoint::AxiioEndpoint(const std::string& endpointName) 
  : type_(getEndpointType(endpointName)) {
}

// Accessor implementations
__host__ EndpointType AxiioEndpoint::getType() const {
  return type_;
}

__host__ const char* AxiioEndpoint::getName() const {
  return getEndpointName(type_);
}

__host__ const char* AxiioEndpoint::getDescription() const {
  const auto& registry = getEndpointRegistry();
  for (const auto& ep : registry) {
    if (ep.type == type_) {
      return ep.description.c_str();
    }
  }
  return "Unknown endpoint";
}

// Drive method implementation - dispatches to endpoint-specific function
__device__ void AxiioEndpoint::drive(
  unsigned iterations,
  void* submissionQueue,
  void* completionQueue,
  unsigned long long int* startTimes,
  unsigned long long int* endTimes) {
  
  // Cast void* buffers to internal types for dispatch
  sqeType_s* sqeAddr = static_cast<sqeType_s*>(submissionQueue);
  cqeType_s* cqeAddr = static_cast<cqeType_s*>(completionQueue);
  
  // Dispatch to endpoint-specific drive function
  driveDispatch(type_, iterations, sqeAddr, cqeAddr, startTimes, endTimes);
}

