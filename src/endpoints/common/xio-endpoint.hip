/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <memory>
#include <string>

#include <CLI/CLI.hpp>

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
extern hipError_t rdma_ep_run(xio::XioEndpointConfig* config);
extern hipError_t sdma_ep_run(xio::XioEndpointConfig* config);

// Transform human-readable size (e.g. "4k", "1M") to bytes for CLI options.
// Suffixes use power-of-2 (binary): k=1024, M=1024², G=1024³ (KiB/MiB/GiB).
// Mutates s to the numeric string; returns error message or "".
static std::string transferSizeTransform(std::string& s) {
  if (s.empty())
    return "Transfer size cannot be empty";
  size_t start = s.find_first_not_of(" \t");
  if (start == std::string::npos)
    return "Invalid transfer size";
  size_t end = s.find_last_not_of(" \t");
  std::string val = s.substr(start, end - start + 1);
  if (val.empty())
    return "Invalid transfer size";
  unsigned long long mult = 1;
  char last = val.back();
  // Binary (power-of-2) units only; not SI (power-of-10)
  if (last == 'k' || last == 'K') {
    mult = 1024ULL;
    val.pop_back();
  } else if (last == 'm' || last == 'M') {
    mult = 1024ULL * 1024;
    val.pop_back();
  } else if (last == 'g' || last == 'G') {
    mult = 1024ULL * 1024 * 1024;
    val.pop_back();
  }
  if (val.empty())
    return "Invalid transfer size (missing number)";
  unsigned long long num = 0;
  try {
    num = std::stoull(val, nullptr, 0);
  } catch (...) {
    return "Transfer size must be a number (e.g. 4096 or 1M)";
  }
  if (num == 0)
    return "Transfer size must be > 0";
  unsigned long long result = num * mult;
  if (mult != 0 && result / mult != num)
    return "Transfer size overflow";
  s = std::to_string(result);
  return "";
}

// ============================================================================
// Derived Endpoint Classes
// ============================================================================

namespace xio {

class TestEndpoint : public XioEndpoint {
private:
  // Store doorbell queue length from CLI
  unsigned doorbell_ = 0;
  // Store emulate flag from CLI
  bool emulate_ = false;
  // Store iterations from CLI
  unsigned iterations_ = 128;

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
  getCompletionQueueLength(const XioEndpointConfig* config) const override {
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

  __host__ hipError_t run(XioEndpointConfig* config) override {
    return test_ep::run(config);
  }

  __host__ void configureCliOptions(CLI::App& app) override {
    app.add_option("-n,--iterations", iterations_, "Number of I/O operations")
      ->default_val(128)
      ->group("Endpoint Options");
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
    testEpConfig.iterations = iterations_;
    return &testEpConfig;
  }

  __host__ unsigned getIterations(void* endpointConfig) const override {
    if (endpointConfig) {
      test_ep::TestEpConfig* testEpConfig = static_cast<test_ep::TestEpConfig*>(
        endpointConfig);
      return testEpConfig->iterations;
    }
    return iterations_;
  }

  __host__ bool isEmulateMode() const override {
    return emulate_;
  }

  __host__ unsigned getDoorbellQueueLength() const override {
    return doorbell_;
  }
};

class NvmeEndpoint : public XioEndpoint {
private:
  // Store NVMe config
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
    // Use queue length from CLI configuration (default: 64)
    (void)config; // Not used - we use member variable instead
    return nvmeConfig_.queueLength;
  }

  __host__ size_t
  getCompletionQueueLength(const XioEndpointConfig* config) const override {
    // NVMe requires minimum queue length of 2 entries (power of 2)
    // CQ length matches SQ length
    (void)config; // Not used - we use member variable instead
    return nvmeConfig_.queueLength;
  }

  __host__ hipError_t run(XioEndpointConfig* config) override {
    return nvme_ep::run(config);
  }

  __host__ void configureCliOptions(CLI::App& app) override {
    nvme_ep::registerCliOptions(app, &nvmeConfig_);
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
      nvme_ep::nvmeEpConfig* nvmeConfig = static_cast<nvme_ep::nvmeEpConfig*>(
        endpointConfig);
      if (nvmeConfig->ioParams.readIo < 0 && nvmeConfig->ioParams.writeIo < 0) {
        // Sequential mode: both negative, return sum of absolute values
        return -nvmeConfig->ioParams.readIo + -nvmeConfig->ioParams.writeIo;
      }
      if (nvmeConfig->ioParams.writeIo < 0) {
        // Sequential mode: use absolute value of writeIo
        return -nvmeConfig->ioParams.writeIo;
      }
      if (nvmeConfig->ioParams.readIo < 0) {
        // Sequential mode: use absolute value of readIo
        return -nvmeConfig->ioParams.readIo;
      }
      return nvmeConfig->ioParams.readIo + nvmeConfig->ioParams.writeIo;
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
    return "RDMA endpoint with GDA support (BNXT, MLX5, IONIC)";
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
    return rdma_ep_run(config);
  }

  __host__ void configureCliOptions(CLI::App& app) override {
    rdma_ep::registerCliOptions(app, &rdmaConfig_);
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
  // SDMA uses raw packets (sizes vary by op); report 0 so tester skips SQE/CQE
  static constexpr size_t kSqeSize = 0;
  static constexpr size_t kCqeSize = 0;
  unsigned iterations_ = 128;
  bool useHostDst_ = false;
  bool verifyData_ = false;
  bool useCounter_ = false;
  bool useFlush_ = false;
  int srcDeviceId_ = -1;
  int dstDeviceId_ = -1;
  size_t transferSize_ = 4096;
  sdma_ep::SdmaEpConfig sdmaEpConfig_;
  std::map<std::string, CLI::App*> testSubcommands;

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
    return sdma_ep_run(config);
  }

  __host__ void configureCliOptions(CLI::App& app) override {
    app.add_option("-n,--iterations", iterations_, "Number of SDMA transfers")
      ->default_val(128)
      ->group("Endpoint Options");

    app
      .add_option("--src-gpu", srcDeviceId_,
                  "Source HIP device ID (default: 0)")
      ->default_val(-1)
      ->group("Endpoint Options");
    app
      .add_option("--dst-gpu", dstDeviceId_,
                  "Destination HIP device ID for P2P (default: 1)")
      ->default_val(-1)
      ->group("Endpoint Options");
    app
      .add_option(
        "-s,--transfer-size", transferSize_,
        "Transfer size per iteration: number or 4k/1M/2G (binary, power-of-2; "
        "default 4096)")
      ->default_val(4096)
      ->transform(CLI::Validator(transferSizeTransform,
                                 "4k/1M/2G (binary) or bytes", "SIZE"))
      ->group("Endpoint Options");

    // Register p2p subcommand
    CLI::App* p2p =
      app.add_subcommand("p2p", "Simple P2P between GPU -> GPU or GPU -> Host");
    p2p
      ->add_flag("--to-host", useHostDst_,
                 "Use pinned host memory as destination (single GPU only)")
      ->group("Endpoint Options");
    p2p
      ->add_flag("--verify", verifyData_,
                 "Verify destination buffer contains expected pattern after "
                 "transfer (host-dst or P2P)")
      ->group("Endpoint Options");
    testSubcommands["p2p"] = p2p;

    // Register ping-pong subcommand
    CLI::App* pingPong = app.add_subcommand(
      "ping-pong", "Bidirectional ping-pong transfer between two GPUs");
    pingPong
      ->add_flag("--use-counter", useCounter_,
                 "Use counter-based approach for buffer reuse")
      ->group("Endpoint Options");
    pingPong
      ->add_flag("--use-flush", useFlush_,
                 "Use flush-based approach for buffer reuse")
      ->group("Endpoint Options");
    testSubcommands["ping-pong"] = pingPong;

    // Register buffer-reuse subcommand
    CLI::App* bufferReuse = app.add_subcommand("buffer-reuse",
                                               "Test buffer reuse patterns");
    bufferReuse
      ->add_flag("--use-counter", useCounter_,
                 "Use counter-based approach for buffer reuse")
      ->group("Endpoint Options");
    bufferReuse
      ->add_flag("--use-flush", useFlush_,
                 "Use flush-based approach for buffer reuse")
      ->group("Endpoint Options");
    testSubcommands["buffer-reuse"] = bufferReuse;
  }

  __host__ void* initializeEndpointConfig() override {
    // Determine which test subcommand was selected
    for (const auto& [name, subcmd] : testSubcommands) {
      if (subcmd && subcmd->parsed()) {
        sdmaEpConfig_.testType = name;
        break;
      }
    }

    sdmaEpConfig_.useHostDst = useHostDst_;
    sdmaEpConfig_.verifyData = verifyData_;
    sdmaEpConfig_.useCounter = useCounter_;
    sdmaEpConfig_.useFlush = useFlush_;
    sdmaEpConfig_.srcDeviceId = srcDeviceId_;
    sdmaEpConfig_.dstDeviceId = dstDeviceId_;
    sdmaEpConfig_.transferSize = transferSize_;
    return &sdmaEpConfig_;
  }

  __host__ std::string validateConfig(void* endpointConfig) override {
    if (endpointConfig) {
      const auto* ep = static_cast<const sdma_ep::SdmaEpConfig*>(
        endpointConfig);
      if (ep->testType.empty()) {
        return "Missing test subcommand. Available: p2p, ping-pong, "
               "buffer-reuse";
      }
      if (ep->useCounter && ep->useFlush) {
        return "Cannot use both --use-counter and --use-flush at the same time";
      }
      if (ep->transferSize == 0)
        return "transfer-size must be > 0";
      if (ep->transferSize % 4 != 0)
        return "transfer-size must be a multiple of 4 (LFSR uses dwords)";
    }
    return std::string();
  }

  __host__ unsigned getIterations(void* endpointConfig) const override {
    (void)endpointConfig;
    return iterations_;
  }
};

// ============================================================================
// Default Implementation of Virtual Methods
// ============================================================================

void XioEndpoint::configureCliOptions(CLI::App& app) {
  // Default: no endpoint-specific options
  (void)app;
}

void* XioEndpoint::initializeEndpointConfig() {
  // Default: no endpoint-specific config
  return nullptr;
}

void XioEndpoint::applyCommonConfig(void* endpointConfig,
                                    const XioEndpointConfig* baseConfig) {
  // Default: do nothing
  (void)endpointConfig;
  (void)baseConfig;
}

std::string XioEndpoint::validateConfig(void* endpointConfig) {
  // Default: no validation
  (void)endpointConfig;
  return std::string();
}

unsigned XioEndpoint::getIterations(void* endpointConfig) const {
  // Default: return 128
  (void)endpointConfig;
  return 128;
}

bool XioEndpoint::isEmulateMode() const {
  // Default: not in emulate mode
  return false;
}

unsigned XioEndpoint::getDoorbellQueueLength() const {
  // Default: doorbell mode not enabled
  return 0;
}

size_t XioEndpoint::getSubmissionQueueLength(
  const XioEndpointConfig* config) const {
  // Default: one entry per thread, or 1 for single-threaded
  return (config != nullptr && config->numThreads > 1) ? config->numThreads : 1;
}

size_t XioEndpoint::getCompletionQueueLength(
  const XioEndpointConfig* config) const {
  // Default: one entry per thread, or 1 for single-threaded
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
