/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <memory>

#include <CLI/CLI.hpp>

#include "axiio-endpoint-registry.h"
#include "axiio.h"
#include "test-ep-config.h"
#include "test-ep.h"

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
private:
  // Store doorbell queue length from CLI
  unsigned doorbell_ = 0;
  // Store emulate flag from CLI
  bool emulate_ = false;

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

  __host__ size_t
  getSubmissionQueueLength(const AxiioEndpointConfig* config) const override {
    if (config == nullptr) {
      return 1;
    }
    // Get test-ep specific config to check doorbell value
    test_ep::TestEpConfig* testEpConfig = static_cast<test_ep::TestEpConfig*>(
      config->endpointConfig);
    unsigned doorbell = (testEpConfig != nullptr) ? testEpConfig->doorbell : 0;
    if (doorbell > 0) {
      // Doorbell mode: use doorbell value as queue length
      return doorbell;
    }
    // Normal mode: one entry per thread, or 1 for single-threaded
    return (config->numThreads > 1) ? config->numThreads : 1;
  }

  __host__ size_t
  getCompletionQueueLength(const AxiioEndpointConfig* config) const override {
    if (config == nullptr) {
      return 1;
    }
    // Get test-ep specific config to check doorbell value
    test_ep::TestEpConfig* testEpConfig = static_cast<test_ep::TestEpConfig*>(
      config->endpointConfig);
    unsigned doorbell = (testEpConfig != nullptr) ? testEpConfig->doorbell : 0;
    if (doorbell > 0) {
      // Doorbell mode: use doorbell value as queue length (circular buffer)
      return doorbell;
    }
    // Normal mode: one entry per thread, or 1 for single-threaded
    return (config->numThreads > 1) ? config->numThreads : 1;
  }

  __host__ hipError_t run(AxiioEndpointConfig* config) override {
    return test_ep_run(config);
  }

  __host__ void configureCliOptions(CLI::App& app) override {
    app
      .add_option(
        "--doorbell", doorbell_,
        "Enable doorbell mode with specified queue length (0=disabled)")
      ->default_val(0)
      ->group("Endpoint Options");
    app
      .add_flag("--emulate", emulate_,
                "Run kernel code on CPU instead of GPU (for testing)")
      ->group("Endpoint Options");
  }

  __host__ void* initializeEndpointConfig() override {
    static test_ep::TestEpConfig testEpConfig;
    testEpConfig.doorbell = doorbell_;
    testEpConfig.emulate = emulate_;
    return &testEpConfig;
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

  __host__ void configureCliOptions(CLI::App& app) override {
    // RDMA endpoint can add its own CLI options here in the future
    (void)app;
  }

  __host__ void* initializeEndpointConfig() override {
    // RDMA endpoint can return its config here in the future
    return nullptr;
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

  __host__ void configureCliOptions(CLI::App& app) override {
    // SDMA endpoint can add its own CLI options here in the future
    (void)app;
  }

  __host__ void* initializeEndpointConfig() override {
    // SDMA endpoint can return its config here in the future
    return nullptr;
  }
};

// ============================================================================
// Default Implementation of Virtual Methods
// ============================================================================

void AxiioEndpoint::configureCliOptions(CLI::App& app) {
  // Default: no endpoint-specific options
  (void)app;
}

void* AxiioEndpoint::initializeEndpointConfig() {
  // Default: no endpoint-specific config
  return nullptr;
}

size_t AxiioEndpoint::getSubmissionQueueLength(
  const AxiioEndpointConfig* config) const {
  // Default: one entry per thread, or 1 for single-threaded
  return (config != nullptr && config->numThreads > 1) ? config->numThreads : 1;
}

size_t AxiioEndpoint::getCompletionQueueLength(
  const AxiioEndpointConfig* config) const {
  // Default: one entry per thread, or 1 for single-threaded
  return (config != nullptr && config->numThreads > 1) ? config->numThreads : 1;
}

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
