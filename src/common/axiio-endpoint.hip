/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "axiio-endpoint-registry.h"
#include "axiio-endpoint.h"

// Include endpoint headers for size information
#include "nvme-ep.h"
#include "rdma-ep.h"
#include "sdma-ep.h"
#include "test-ep.h"

// Forward declaration for dispatch function
__device__ void driveDispatch(EndpointType type,
                              const AxiioEndpointConfig& config,
                              void* submissionQueue, void* completionQueue);

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

// Drive method implementation - new config-based version
__device__ void AxiioEndpoint::drive(const AxiioEndpointConfig& config,
                                     void* submissionQueue,
                                     void* completionQueue) {
  // Dispatch to endpoint-specific drive function (handles casting internally)
  driveDispatch(type_, config, submissionQueue, completionQueue);
}
