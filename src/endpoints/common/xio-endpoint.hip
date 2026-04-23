/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <memory>
#include <string>

#include "xio-endpoint-registry.h"
#include "xio.h"

// Include endpoint headers for size information
#include "nvme-ep.h"
#include "rdma-ep.h"
#include "sdma-ep.h"
#include "test-ep.h"

// Forward declarations for endpoint-specific run functions
namespace xio::test_ep {
extern hipError_t run(XioEndpointConfig* config);
} // namespace xio::test_ep
namespace xio::nvme_ep {
extern hipError_t run(XioEndpointConfig* config);
std::string validateConfig(nvmeEpConfig* config);
} // namespace xio::nvme_ep

// ============================================================================
// Derived Endpoint Classes
// ============================================================================

namespace xio {

class TestEndpoint : public XioEndpoint {
private:
  test_ep::TestEpConfig config_;

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
    return test_ep::sqeSize;
  }

  __host__ size_t getCompletionQueueEntrySize() const override {
    return test_ep::cqeSize;
  }

  __host__ size_t
  getSubmissionQueueLength(const XioEndpointConfig* config) const override {
    if (config == nullptr) {
      return 1;
    }
    test_ep::TestEpConfig* testEpConfig = static_cast<test_ep::TestEpConfig*>(
      config->endpointConfig);
    unsigned doorbell = (testEpConfig != nullptr) ? testEpConfig->doorbell : 0;
    if (doorbell > 0) {
      return doorbell;
    }
    return (config->numThreads > 1) ? config->numThreads : 1;
  }

  __host__ size_t
  getCompletionQueueLength(const XioEndpointConfig* config) const override {
    if (config == nullptr) {
      return 1;
    }
    test_ep::TestEpConfig* testEpConfig = static_cast<test_ep::TestEpConfig*>(
      config->endpointConfig);
    unsigned doorbell = (testEpConfig != nullptr) ? testEpConfig->doorbell : 0;
    if (doorbell > 0) {
      return doorbell;
    }
    return (config->numThreads > 1) ? config->numThreads : 1;
  }

  __host__ hipError_t run(XioEndpointConfig* config) override {
    return test_ep::run(config);
  }

  __host__ void* initializeEndpointConfig() override {
    return &config_;
  }

  __host__ unsigned getIterations(void* endpointConfig) const override {
    if (endpointConfig) {
      auto* cfg = static_cast<test_ep::TestEpConfig*>(endpointConfig);
      return cfg->iterations;
    }
    return config_.iterations;
  }

  __host__ bool isEmulateMode() const override {
    return config_.emulate;
  }

  __host__ unsigned getDoorbellQueueLength() const override {
    return config_.doorbell;
  }
};

class NvmeEndpoint : public XioEndpoint {
private:
  nvme_ep::nvmeEpConfig nvmeConfig_;

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

  __host__ size_t
  getSubmissionQueueLength(const XioEndpointConfig* config) const override {
    (void)config;
    return nvmeConfig_.queueLength;
  }

  __host__ size_t
  getCompletionQueueLength(const XioEndpointConfig* config) const override {
    (void)config;
    return nvmeConfig_.queueLength;
  }

  __host__ hipError_t run(XioEndpointConfig* config) override {
    return nvme_ep::run(config);
  }

  __host__ void* initializeEndpointConfig() override {
    return &nvmeConfig_;
  }

  __host__ void applyCommonConfig(
    void* endpointConfig, const XioEndpointConfig* baseConfig) override {
    if (endpointConfig && baseConfig) {
      nvme_ep::nvmeEpConfig* nvmeConfig = static_cast<nvme_ep::nvmeEpConfig*>(
        endpointConfig);
      nvmeConfig->doorbellParams.usePciMmioBridge = baseConfig->pciMmioBridge;
    }
  }

  __host__ std::string validateConfig(void* endpointConfig) override {
    if (endpointConfig) {
      nvme_ep::nvmeEpConfig* nvmeConfig = static_cast<nvme_ep::nvmeEpConfig*>(
        endpointConfig);
      return nvme_ep::validateConfig(nvmeConfig);
    }
    return std::string();
  }

  __host__ unsigned getIterations(void* endpointConfig) const override {
    if (endpointConfig) {
      auto* nvmeConfig = static_cast<nvme_ep::nvmeEpConfig*>(endpointConfig);
      if (nvmeConfig->ioParams.infiniteMode) {
        return 0;
      }
      return (unsigned)(nvmeConfig->ioParams.readIo +
                        nvmeConfig->ioParams.writeIo);
    }
    return 0;
  }
};

class RdmaEndpoint : public XioEndpoint {
private:
  rdma_ep::RdmaEpConfig rdmaConfig_;

public:
  __host__ EndpointType getType() const override {
    return EndpointType::RDMA_EP;
  }

  __host__ const char* getName() const override {
    return "rdma-ep";
  }

  __host__ const char* getDescription() const override {
    return "RDMA endpoint with multi-vendor support (MLX5, BNXT_RE, IONIC, "
           "ROCM_ERNIC)";
  }

  __host__ size_t getSubmissionQueueEntrySize() const override {
    return RDMA_EP_SQE_SIZE;
  }

  __host__ size_t getCompletionQueueEntrySize() const override {
    return RDMA_EP_CQE_SIZE;
  }

  __host__ size_t
  getSubmissionQueueLength(const XioEndpointConfig* config) const override {
    (void)config;
    return 0;
  }

  __host__ size_t
  getCompletionQueueLength(const XioEndpointConfig* config) const override {
    (void)config;
    return 0;
  }

  __host__ hipError_t run(XioEndpointConfig* config) override {
    return xio::rdma_ep::run(config);
  }

  __host__ void* initializeEndpointConfig() override {
    return &rdmaConfig_;
  }

  __host__ void applyCommonConfig(
    void* endpointConfig, const XioEndpointConfig* baseConfig) override {
    (void)endpointConfig;
    (void)baseConfig;
  }

  __host__ std::string validateConfig(void* endpointConfig) override {
    if (endpointConfig) {
      auto* cfg = static_cast<rdma_ep::RdmaEpConfig*>(endpointConfig);
      return rdma_ep::validateConfig(cfg);
    }
    return std::string();
  }

  __host__ unsigned getIterations(void* endpointConfig) const override {
    if (endpointConfig) {
      return rdma_ep::getIterations(endpointConfig);
    }
    return rdmaConfig_.iterations;
  }
};

class SdmaEndpoint : public XioEndpoint {
  static constexpr size_t kSqeSize = 0;
  static constexpr size_t kCqeSize = 0;
  sdma_ep::SdmaEpConfig sdmaEpConfig_;

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
    return kSqeSize;
  }

  __host__ size_t getCompletionQueueEntrySize() const override {
    return kCqeSize;
  }

  __host__ hipError_t run(XioEndpointConfig* config) override {
    return xio::sdma_ep::run(config);
  }

  __host__ void* initializeEndpointConfig() override {
    return &sdmaEpConfig_;
  }

  __host__ std::string validateConfig(void* endpointConfig) override {
    if (endpointConfig) {
      return sdma_ep::validateConfig(
        static_cast<sdma_ep::SdmaEpConfig*>(endpointConfig));
    }
    return std::string();
  }

  __host__ unsigned getIterations(void* endpointConfig) const override {
    if (endpointConfig) {
      auto* cfg = static_cast<sdma_ep::SdmaEpConfig*>(endpointConfig);
      return cfg->iterations;
    }
    return sdmaEpConfig_.iterations;
  }
};

// ============================================================================
// Default Implementation of Virtual Methods
// ============================================================================

void* XioEndpoint::initializeEndpointConfig() {
  return nullptr;
}

void XioEndpoint::applyCommonConfig(void* endpointConfig,
                                    const XioEndpointConfig* baseConfig) {
  (void)endpointConfig;
  (void)baseConfig;
}

std::string XioEndpoint::validateConfig(void* endpointConfig) {
  (void)endpointConfig;
  return std::string();
}

unsigned XioEndpoint::getIterations(void* endpointConfig) const {
  (void)endpointConfig;
  return 128;
}

bool XioEndpoint::isEmulateMode() const {
  return false;
}

unsigned XioEndpoint::getDoorbellQueueLength() const {
  return 0;
}

size_t XioEndpoint::getSubmissionQueueLength(
  const XioEndpointConfig* config) const {
  return (config != nullptr && config->numThreads > 1) ? config->numThreads : 1;
}

size_t XioEndpoint::getCompletionQueueLength(
  const XioEndpointConfig* config) const {
  return (config != nullptr && config->numThreads > 1) ? config->numThreads : 1;
}

// ============================================================================
// Factory Function Implementation
// ============================================================================

__host__ std::unique_ptr<XioEndpoint> createEndpoint(EndpointType type) {
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

__host__ std::unique_ptr<XioEndpoint> createEndpoint(
  const std::string& endpointName) {
  EndpointType type = getEndpointType(endpointName);
  return createEndpoint(type);
}

} // namespace xio
