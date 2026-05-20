/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for xio-tester CLI option registration helpers.
 */

#include <cstdio>
#include <string>
#include <vector>

#include <CLI/CLI.hpp>

#include "xio-cli-options.cpp"
#include "xio-test-assert.h"

namespace {

void parse_app(CLI::App& app, std::initializer_list<const char*> args) {
  std::vector<std::string> owned;
  owned.emplace_back("test-xio-cli-options");
  for (const char* a : args) {
    owned.emplace_back(a);
  }
  std::vector<char*> argv;
  for (auto& s : owned) {
    argv.push_back(s.data());
  }
  app.parse(static_cast<int>(argv.size()), argv.data());
}

} // namespace

int test_transfer_size_transform_plain_and_suffixes() {
  std::string value = "4096";
  ASSERT_TRUE(transferSizeTransform(value).empty());
  ASSERT_STREQ(value.c_str(), "4096");

  value = "4k";
  ASSERT_TRUE(transferSizeTransform(value).empty());
  ASSERT_STREQ(value.c_str(), "4096");

  value = " 2M ";
  ASSERT_TRUE(transferSizeTransform(value).empty());
  ASSERT_STREQ(value.c_str(), "2097152");

  value = "1G";
  ASSERT_TRUE(transferSizeTransform(value).empty());
  ASSERT_STREQ(value.c_str(), "1073741824");
  return 0;
}

int test_transfer_size_transform_rejects_invalid_values() {
  std::string value = "";
  ASSERT_TRUE(!transferSizeTransform(value).empty());

  value = "   ";
  ASSERT_TRUE(!transferSizeTransform(value).empty());

  value = "k";
  ASSERT_STREQ(transferSizeTransform(value).c_str(),
               "Invalid transfer size (missing number)");

  value = "0";
  ASSERT_STREQ(transferSizeTransform(value).c_str(),
               "Transfer size must be > 0");

  value = "12x";
  ASSERT_STREQ(transferSizeTransform(value).c_str(),
               "Transfer size must be a number (e.g. 4096 or 1M)");
  return 0;
}

int test_detect_sdma_test_type() {
  xio::sdma_ep::SdmaEpConfig cfg;
  CLI::App app{"sdma"};
  registerSdmaEpCliOptions(app, &cfg);

  parse_app(app, {"p2p", "--to-host", "--verify"});
  detectSdmaTestType(app, &cfg);

  ASSERT_STREQ(cfg.testType.c_str(), "p2p");
  ASSERT_TRUE(cfg.useHostDst);
  ASSERT_TRUE(cfg.verifyData);
  return 0;
}

int test_detect_sdma_ping_pong_options() {
  xio::sdma_ep::SdmaEpConfig cfg;
  CLI::App app{"sdma"};
  registerSdmaEpCliOptions(app, &cfg);

  parse_app(app, {"--transfer-size", "8k", "ping-pong", "--use-counter"});
  detectSdmaTestType(app, &cfg);

  ASSERT_STREQ(cfg.testType.c_str(), "ping-pong");
  ASSERT_EQ(cfg.transferSize, static_cast<size_t>(8192));
  ASSERT_TRUE(cfg.useCounter);
  ASSERT_TRUE(!cfg.useFlush);
  return 0;
}

int test_test_ep_cli_options() {
  xio::test_ep::TestEpConfig cfg;
  CLI::App app{"test"};
  registerTestEpCliOptions(app, &cfg);

  parse_app(app, {"--iterations", "9", "--doorbell", "32", "--emulate",
                  "--verify", "--seed", "123"});

  ASSERT_EQ(cfg.iterations, 9u);
  ASSERT_EQ(cfg.doorbell, 32u);
  ASSERT_TRUE(cfg.emulate);
  ASSERT_TRUE(cfg.verify);
  ASSERT_EQ(cfg.seed, 123u);
  return 0;
}

int test_rdma_cli_provider_alias_and_2node_fields() {
  xio::rdma_ep::RdmaEpConfig cfg;
  CLI::App app{"rdma"};
  registerRdmaEpCliOptions(app, &cfg);

  parse_app(app,
            {"--provider", "pensando", "--client", "--server-host", "127.0.0.1",
             "--pingpong-size", "128", "--pingpong-iters", "7"});

  ASSERT_STREQ(cfg.providerStr.c_str(), "pensando");
  ASSERT_TRUE(cfg.isClient);
  ASSERT_TRUE(!cfg.isServer);
  ASSERT_STREQ(cfg.serverHost.c_str(), "127.0.0.1");
  ASSERT_EQ(cfg.ppSize, 128u);
  ASSERT_EQ(cfg.ppIters, 7u);
  return 0;
}

int test_nvme_cli_rejects_non_power_of_two_queue_length() {
  xio::nvme_ep::nvmeEpConfig cfg;
  CLI::App app{"nvme"};
  registerNvmeEpCliOptions(app, &cfg);

  std::vector<std::string> args = {"--controller", "/dev/null",
                                   "--queue-length", "100"};
  bool threw = false;
  try {
    std::vector<char*> argv;
    std::string prog = "test-xio-cli-options";
    argv.push_back(prog.data());
    for (auto& s : args) {
      argv.push_back(s.data());
    }
    app.parse(static_cast<int>(argv.size()), argv.data());
  } catch (const CLI::ParseError&) {
    threw = true;
  }

  ASSERT_TRUE(threw);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_transfer_size_transform_plain_and_suffixes();
  failures += test_transfer_size_transform_rejects_invalid_values();
  failures += test_detect_sdma_test_type();
  failures += test_detect_sdma_ping_pong_options();
  failures += test_test_ep_cli_options();
  failures += test_rdma_cli_provider_alias_and_2node_fields();
  failures += test_nvme_cli_rejects_non_power_of_two_queue_length();

  if (failures == 0) {
    printf("All xio-cli-options tests passed.\n");
    return 0;
  }
  printf("%d xio-cli-options test(s) failed.\n", failures);
  return 1;
}
