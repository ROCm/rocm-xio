/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "axiio-endpoint.h"
#include "axiio-endpoint-registry.h"

// Include endpoint headers for size information
#include "test-ep.h"
#include "nvme-ep.h"
#include "rdma-ep.h"
#include "sdma-ep.h"

// Forward declaration for dispatch function
__device__ void driveDispatch(
  EndpointType type,
  unsigned iterations,
  void* submissionQueue,
  void* completionQueue,
  unsigned long long int* startTimes,
  unsigned long long int* endTimes);

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

// Size helper methods
__host__ size_t AxiioEndpoint::getSubmissionQueueEntrySize() const {
  return ::getSubmissionQueueEntrySize(type_);
}

__host__ size_t AxiioEndpoint::getCompletionQueueEntrySize() const {
  return ::getCompletionQueueEntrySize(type_);
}

// Standalone helper functions
__host__ size_t getSubmissionQueueEntrySize(EndpointType type) {
  switch (type) {
    case EndpointType::TEST_EP:
      return TEST_EP_SQE_SIZE;
    case EndpointType::NVME_EP:
      return NVME_EP_SQE_SIZE;
    case EndpointType::RDMA_EP:
      return RDMA_EP_SQE_SIZE;
    case EndpointType::SDMA_EP:
      return SDMA_EP_SQE_SIZE;
    default:
      return 0;
  }
}

__host__ size_t getCompletionQueueEntrySize(EndpointType type) {
  switch (type) {
    case EndpointType::TEST_EP:
      return TEST_EP_CQE_SIZE;
    case EndpointType::NVME_EP:
      return NVME_EP_CQE_SIZE;
    case EndpointType::RDMA_EP:
      return RDMA_EP_CQE_SIZE;
    case EndpointType::SDMA_EP:
      return SDMA_EP_CQE_SIZE;
    default:
      return 0;
  }
}

// Drive method implementation - dispatches to endpoint-specific function
__device__ void AxiioEndpoint::drive(
  unsigned iterations,
  void* submissionQueue,
  void* completionQueue,
  unsigned long long int* startTimes,
  unsigned long long int* endTimes) {
  
  // Dispatch to endpoint-specific drive function (handles casting internally)
  driveDispatch(type_, iterations, submissionQueue, completionQueue, startTimes, endTimes);
}

