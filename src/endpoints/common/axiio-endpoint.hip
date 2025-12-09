/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <memory>

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

// ============================================================================
// Derived Endpoint Classes
// ============================================================================

class TestEndpoint : public AxiioEndpoint {
public:
  __host__ EndpointType getType() const override {
    return EndpointType::TEST_EP;
  }

  __host__ const char* getName() const override {
    return "test-ep";
  }

  __host__ const char* getDescription() const override {
    return "Test endpoint for development/testing";
  }

  __host__ size_t getSubmissionQueueEntrySize() const override {
    return TEST_EP_SQE_SIZE;
  }

  __host__ size_t getCompletionQueueEntrySize() const override {
    return TEST_EP_CQE_SIZE;
  }

  __host__ hipError_t run(AxiioEndpointConfig* config) override {
    return test_ep_run(config);
  }
};

class NvmeEndpoint : public AxiioEndpoint {
public:
  __host__ EndpointType getType() const override {
    return EndpointType::NVME_EP;
  }

  __host__ const char* getName() const override {
    return "nvme-ep";
  }

  __host__ const char* getDescription() const override {
    return "nvme endpoint";
  }

  __host__ size_t getSubmissionQueueEntrySize() const override {
    return NVME_EP_SQE_SIZE;
  }

  __host__ size_t getCompletionQueueEntrySize() const override {
    return NVME_EP_CQE_SIZE;
  }

  __host__ hipError_t run(AxiioEndpointConfig* config) override {
    return nvme_ep_run(config);
  }
};

class RdmaEndpoint : public AxiioEndpoint {
public:
  __host__ EndpointType getType() const override {
    return EndpointType::RDMA_EP;
  }

  __host__ const char* getName() const override {
    return "rdma-ep";
  }

  __host__ const char* getDescription() const override {
    return "RDMA endpoint with multi-vendor support (MLX5, BNXT_RE, IONIC, "
           "PVRDMA)";
  }

  __host__ size_t getSubmissionQueueEntrySize() const override {
    return RDMA_EP_SQE_SIZE;
  }

  __host__ size_t getCompletionQueueEntrySize() const override {
    return RDMA_EP_CQE_SIZE;
  }

  __host__ hipError_t run(AxiioEndpointConfig* config) override {
    return rdma_ep_run(config);
  }
};

class SdmaEndpoint : public AxiioEndpoint {
public:
  __host__ EndpointType getType() const override {
    return EndpointType::SDMA_EP;
  }

  __host__ const char* getName() const override {
    return "sdma-ep";
  }

  __host__ const char* getDescription() const override {
    return "AMD SDMA Engine endpoint";
  }

  __host__ size_t getSubmissionQueueEntrySize() const override {
    return SDMA_EP_SQE_SIZE;
  }

  __host__ size_t getCompletionQueueEntrySize() const override {
    return SDMA_EP_CQE_SIZE;
  }

  __host__ hipError_t run(AxiioEndpointConfig* config) override {
    return sdma_ep_run(config);
  }
};

// ============================================================================
// Factory Function Implementation
// ============================================================================

__host__ std::unique_ptr<AxiioEndpoint> createEndpoint(EndpointType type) {
  switch (type) {
    case EndpointType::TEST_EP:
      return std::make_unique<TestEndpoint>();
    case EndpointType::NVME_EP:
      return std::make_unique<NvmeEndpoint>();
    case EndpointType::RDMA_EP:
      return std::make_unique<RdmaEndpoint>();
    case EndpointType::SDMA_EP:
      return std::make_unique<SdmaEndpoint>();
    default:
      return nullptr;
  }
}

__host__ std::unique_ptr<AxiioEndpoint> createEndpoint(
  const std::string& endpointName) {
  EndpointType type = getEndpointType(endpointName);
  return createEndpoint(type);
}
