/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for sdma-ep configuration validation and host-visible types.
 */

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>

#include "sdma-ep.h"
#include "xio-test-assert.h"

using namespace xio::sdma_ep;

int test_config_defaults() {
  SdmaEpConfig cfg;

  ASSERT_TRUE(cfg.testType.empty());
  ASSERT_TRUE(!cfg.useHostDst);
  ASSERT_TRUE(!cfg.verifyData);
  ASSERT_TRUE(!cfg.useCounter);
  ASSERT_TRUE(!cfg.useFlush);
  ASSERT_EQ(cfg.srcDeviceId, -1);
  ASSERT_EQ(cfg.dstDeviceId, -1);
  ASSERT_EQ(cfg.transferSize, static_cast<size_t>(4096));
  ASSERT_EQ(cfg.iterations, 128u);
  return 0;
}

int test_validate_null_is_noop() {
  std::string err = validateConfig(nullptr);
  ASSERT_TRUE(err.empty());
  return 0;
}

int test_validate_requires_subcommand() {
  SdmaEpConfig cfg;
  std::string err = validateConfig(&cfg);
  ASSERT_TRUE(!err.empty());
  ASSERT_STREQ(err.c_str(), "Missing test subcommand. Available: "
                            "p2p, ping-pong, buffer-reuse");
  return 0;
}

int test_validate_accepts_supported_subcommands() {
  const char* names[] = {"p2p", "ping-pong", "buffer-reuse"};
  for (const char* name : names) {
    SdmaEpConfig cfg;
    cfg.testType = name;
    std::string err = validateConfig(&cfg);
    ASSERT_TRUE(err.empty());
  }
  return 0;
}

int test_validate_rejects_counter_and_flush() {
  SdmaEpConfig cfg;
  cfg.testType = "ping-pong";
  cfg.useCounter = true;
  cfg.useFlush = true;

  std::string err = validateConfig(&cfg);
  ASSERT_TRUE(!err.empty());
  ASSERT_STREQ(err.c_str(), "Cannot use both --use-counter and "
                            "--use-flush at the same time");
  return 0;
}

int test_validate_transfer_size_bounds() {
  SdmaEpConfig cfg;
  cfg.testType = "p2p";
  cfg.transferSize = 0;
  ASSERT_STREQ(validateConfig(&cfg).c_str(), "transfer-size must be > 0");

  cfg.transferSize = 3;
  ASSERT_STREQ(validateConfig(&cfg).c_str(),
               "transfer-size must be a multiple of 4 "
               "(LFSR uses dwords)");

  cfg.transferSize = 4;
  ASSERT_TRUE(validateConfig(&cfg).empty());

  cfg.transferSize = 1024 * 1024;
  ASSERT_TRUE(validateConfig(&cfg).empty());
  return 0;
}

int test_connection_info_fields() {
  SdmaConnectionInfo conn{};
  conn.srcDeviceId = 1;
  conn.dstDeviceId = 3;
  conn.engineId = 7;

  ASSERT_EQ(conn.srcDeviceId, 1);
  ASSERT_EQ(conn.dstDeviceId, 3);
  ASSERT_EQ(conn.engineId, 7u);
  return 0;
}

int test_queue_info_defaults_and_fields() {
  SdmaQueueInfo info{};
  ASSERT_EQ(info.deviceHandle, nullptr);
  ASSERT_EQ(info.srcDeviceId, 0);
  ASSERT_EQ(info.dstDeviceId, 0);
  ASSERT_EQ(info.channelIdx, 0);

  info.deviceHandle = reinterpret_cast<void*>(static_cast<uintptr_t>(0x1000));
  info.srcDeviceId = 2;
  info.dstDeviceId = 4;
  info.channelIdx = 6;

  ASSERT_EQ(info.deviceHandle,
            reinterpret_cast<void*>(static_cast<uintptr_t>(0x1000)));
  ASSERT_EQ(info.srcDeviceId, 2);
  ASSERT_EQ(info.dstDeviceId, 4);
  ASSERT_EQ(info.channelIdx, 6);
  return 0;
}

int test_device_side_constants_are_sane() {
  ASSERT_EQ(SDMA_QUEUE_SIZE, 1024u * 1024u);
  ASSERT_TRUE((SDMA_QUEUE_SIZE & (SDMA_QUEUE_SIZE - 1)) == 0);
  ASSERT_GT(MAX_RETRIES, 0);
  ASSERT_TRUE(!BREAK_ON_RETRIES);
  return 0;
}

int test_getIterations_returns_fixed_value() {
  SdmaEpConfig cfg;
  cfg.iterations = 999;
  unsigned iters = getIterations(&cfg);
  ASSERT_EQ(iters, 128u);
  iters = getIterations(nullptr);
  ASSERT_EQ(iters, 128u);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_config_defaults();
  failures += test_validate_null_is_noop();
  failures += test_validate_requires_subcommand();
  failures += test_validate_accepts_supported_subcommands();
  failures += test_validate_rejects_counter_and_flush();
  failures += test_validate_transfer_size_bounds();
  failures += test_connection_info_fields();
  failures += test_queue_info_defaults_and_fields();
  failures += test_device_side_constants_are_sane();
  failures += test_getIterations_returns_fixed_value();

  if (failures == 0) {
    printf("All sdma-ep config tests passed.\n");
    return 0;
  }
  printf("%d sdma-ep config test(s) failed.\n", failures);
  return 1;
}
