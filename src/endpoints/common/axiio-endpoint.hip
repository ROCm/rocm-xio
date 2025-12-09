/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <thread>
#include <vector>

#include "axiio-endpoint-registry.h"
#include "axiio-endpoint.h"

// Include endpoint headers for size information
#include "nvme-ep.h"
#include "rdma-ep.h"
#include "sdma-ep.h"
#include "test-ep.h"

// Forward declarations for endpoint-specific run functions
extern hipError_t test_ep_run(AxiioEndpointConfig* config);
extern hipError_t nvme_ep_run(AxiioEndpointConfig* config);
extern hipError_t rdma_ep_run(AxiioEndpointConfig* config);
extern hipError_t sdma_ep_run(AxiioEndpointConfig* config);

// Constructor implementations
__host__ AxiioEndpoint::AxiioEndpoint(EndpointType type) : type_(type) {
  // Set run function pointer based on endpoint type - no switch in run()
  switch (type) {
    case EndpointType::TEST_EP:
      runFunc_ = test_ep_run;
      break;
    case EndpointType::NVME_EP:
      runFunc_ = nvme_ep_run;
      break;
    case EndpointType::RDMA_EP:
      runFunc_ = rdma_ep_run;
      break;
    case EndpointType::SDMA_EP:
      runFunc_ = sdma_ep_run;
      break;
    default:
      runFunc_ = nullptr;
      break;
  }
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

// Run method implementation
__host__ hipError_t AxiioEndpoint::run(AxiioEndpointConfig* config) {
  return test_ep_run(config);
  /*if (runFunc_ == nullptr) {
    return hipErrorNotSupported;
  }
  return runFunc_(config);*/
}
