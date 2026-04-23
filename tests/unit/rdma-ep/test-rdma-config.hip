/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for xio::rdma_ep::RdmaEpConfig validation and Provider enum.
 */

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <hip/hip_runtime.h>

#include "rdma-ep.h"
#include "vendor-ops.hpp"
#include "xio-test-assert.h"

int test_provider_enum() {
  ASSERT_EQ(static_cast<uint8_t>(xio::rdma_ep::Provider::BNXT), 0);
  ASSERT_EQ(static_cast<uint8_t>(xio::rdma_ep::Provider::MLX5), 1);
  ASSERT_EQ(static_cast<uint8_t>(xio::rdma_ep::Provider::IONIC), 2);
  ASSERT_EQ(static_cast<uint8_t>(xio::rdma_ep::Provider::ROCM_ERNIC), 3);
  ASSERT_EQ(static_cast<uint8_t>(xio::rdma_ep::Provider::UNKNOWN), 0xFF);
  return 0;
}

int test_provider_name() {
  ASSERT_STREQ(xio::rdma_ep::provider_name(xio::rdma_ep::Provider::BNXT), "bnxt");
  ASSERT_STREQ(xio::rdma_ep::provider_name(xio::rdma_ep::Provider::MLX5), "mlx5");
  ASSERT_STREQ(xio::rdma_ep::provider_name(xio::rdma_ep::Provider::IONIC), "ionic");
  ASSERT_STREQ(xio::rdma_ep::provider_name(xio::rdma_ep::Provider::ROCM_ERNIC),
               "rocm-ernic");
  ASSERT_STREQ(xio::rdma_ep::provider_name(xio::rdma_ep::Provider::UNKNOWN), "unknown");
  return 0;
}

int test_provider_from_string() {
  ASSERT_EQ(xio::rdma_ep::provider_from_string("bnxt"), xio::rdma_ep::Provider::BNXT);
  ASSERT_EQ(xio::rdma_ep::provider_from_string("bnxt_re"), xio::rdma_ep::Provider::BNXT);
  ASSERT_EQ(xio::rdma_ep::provider_from_string("mlx5"), xio::rdma_ep::Provider::MLX5);
  ASSERT_EQ(xio::rdma_ep::provider_from_string("ionic"), xio::rdma_ep::Provider::IONIC);
  ASSERT_EQ(xio::rdma_ep::provider_from_string("pensando"),
            xio::rdma_ep::Provider::IONIC);
  ASSERT_EQ(xio::rdma_ep::provider_from_string("rocm_ernic"),
            xio::rdma_ep::Provider::ROCM_ERNIC);
  ASSERT_EQ(xio::rdma_ep::provider_from_string("ernic"),
            xio::rdma_ep::Provider::ROCM_ERNIC);
  ASSERT_EQ(xio::rdma_ep::provider_from_string("rocm-ernic"),
            xio::rdma_ep::Provider::ROCM_ERNIC);
  ASSERT_EQ(xio::rdma_ep::provider_from_string("invalid"),
            xio::rdma_ep::Provider::UNKNOWN);
  ASSERT_EQ(xio::rdma_ep::provider_from_string(nullptr), xio::rdma_ep::Provider::UNKNOWN);
  return 0;
}

int test_config_defaults() {
  xio::rdma_ep::RdmaEpConfig cfg;
  ASSERT_EQ(cfg.provider, xio::rdma_ep::Provider::BNXT);
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
  xio::rdma_ep::RdmaEpConfig cfg;
  cfg.providerStr = "bnxt";
  std::string err = xio::rdma_ep::validateConfig(&cfg);
  ASSERT_TRUE(err.empty());
  ASSERT_EQ(cfg.provider, xio::rdma_ep::Provider::BNXT);
  return 0;
}

int test_config_validate_bad_provider() {
  xio::rdma_ep::RdmaEpConfig cfg;
  cfg.providerStr = "nonexistent";
  std::string err = xio::rdma_ep::validateConfig(&cfg);
  ASSERT_TRUE(!err.empty());
  return 0;
}

int test_config_validate_zero_iterations() {
  xio::rdma_ep::RdmaEpConfig cfg;
  cfg.providerStr = "bnxt";
  cfg.iterations = 0;
  std::string err = xio::rdma_ep::validateConfig(&cfg);
  ASSERT_TRUE(err.empty());
  return 0;
}

int test_config_validate_null() {
  std::string err = xio::rdma_ep::validateConfig(nullptr);
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
