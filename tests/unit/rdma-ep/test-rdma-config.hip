/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for rdma_ep::RdmaEpConfig validation and Provider enum.
 */

#include <cassert>
#include <cstring>
#include <string>

#include <hip/hip_runtime.h>

#include "rdma-ep.h"
#include "vendor-ops.hpp"

#define ASSERT_EQ(a, b) assert((a) == (b))
#define ASSERT_TRUE(x) assert(x)
#define ASSERT_STREQ(a, b) assert(strcmp((a), (b)) == 0)

int test_provider_enum() {
  ASSERT_EQ(static_cast<uint8_t>(rdma_ep::Provider::BNXT), 0);
  ASSERT_EQ(static_cast<uint8_t>(rdma_ep::Provider::MLX5), 1);
  ASSERT_EQ(static_cast<uint8_t>(rdma_ep::Provider::IONIC), 2);
  ASSERT_EQ(static_cast<uint8_t>(rdma_ep::Provider::UNKNOWN), 0xFF);
  return 0;
}

int test_provider_name() {
  ASSERT_STREQ(rdma_ep::provider_name(rdma_ep::Provider::BNXT), "bnxt");
  ASSERT_STREQ(rdma_ep::provider_name(rdma_ep::Provider::MLX5), "mlx5");
  ASSERT_STREQ(rdma_ep::provider_name(rdma_ep::Provider::IONIC), "ionic");
  ASSERT_STREQ(rdma_ep::provider_name(rdma_ep::Provider::UNKNOWN), "unknown");
  return 0;
}

int test_provider_from_string() {
  ASSERT_EQ(rdma_ep::provider_from_string("bnxt"), rdma_ep::Provider::BNXT);
  ASSERT_EQ(rdma_ep::provider_from_string("bnxt_re"), rdma_ep::Provider::BNXT);
  ASSERT_EQ(rdma_ep::provider_from_string("mlx5"), rdma_ep::Provider::MLX5);
  ASSERT_EQ(rdma_ep::provider_from_string("ionic"), rdma_ep::Provider::IONIC);
  ASSERT_EQ(rdma_ep::provider_from_string("pensando"),
            rdma_ep::Provider::IONIC);
  ASSERT_EQ(rdma_ep::provider_from_string("invalid"),
            rdma_ep::Provider::UNKNOWN);
  ASSERT_EQ(rdma_ep::provider_from_string(nullptr),
            rdma_ep::Provider::UNKNOWN);
  return 0;
}

int test_config_defaults() {
  rdma_ep::RdmaEpConfig cfg;
  ASSERT_EQ(cfg.provider, rdma_ep::Provider::BNXT);
  ASSERT_EQ(cfg.iterations, 128u);
  ASSERT_EQ(cfg.sqDepth, 256u);
  ASSERT_EQ(cfg.cqDepth, 256u);
  ASSERT_EQ(cfg.transferSize, 4096u);
  ASSERT_EQ(cfg.inlineThreshold, 28u);
  ASSERT_TRUE(cfg.loopback);
  ASSERT_EQ(cfg.gpuDeviceId, 0);
  return 0;
}

int test_config_validate_good() {
  rdma_ep::RdmaEpConfig cfg;
  cfg.providerStr = "bnxt";
  std::string err = rdma_ep::validateConfig(&cfg);
  ASSERT_TRUE(err.empty());
  ASSERT_EQ(cfg.provider, rdma_ep::Provider::BNXT);
  return 0;
}

int test_config_validate_bad_provider() {
  rdma_ep::RdmaEpConfig cfg;
  cfg.providerStr = "nonexistent";
  std::string err = rdma_ep::validateConfig(&cfg);
  ASSERT_TRUE(!err.empty());
  return 0;
}

int test_config_validate_zero_iterations() {
  rdma_ep::RdmaEpConfig cfg;
  cfg.providerStr = "bnxt";
  cfg.iterations = 0;
  std::string err = rdma_ep::validateConfig(&cfg);
  ASSERT_TRUE(!err.empty());
  return 0;
}

int test_config_validate_null() {
  std::string err = rdma_ep::validateConfig(nullptr);
  ASSERT_TRUE(!err.empty());
  return 0;
}

int main() {
  int failures = 0;
  failures += test_provider_enum();
  failures += test_provider_name();
  failures += test_provider_from_string();
  failures += test_config_defaults();
  failures += test_config_validate_good();
  failures += test_config_validate_bad_provider();
  failures += test_config_validate_zero_iterations();
  failures += test_config_validate_null();

  if (failures == 0) {
    printf("All rdma-ep config tests passed.\n");
    return 0;
  }
  printf("%d config test(s) failed.\n", failures);
  return 1;
}
