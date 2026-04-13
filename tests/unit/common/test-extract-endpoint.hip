/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for xio::extractEndpointName() CLI parser.
 * CPU-only: exercises pure argument parsing.
 */

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <string>

#include "xio-test-assert.h"
#include "xio.h"

int test_short_flag() {
  const char* argv[] = {"prog", "-e", "nvme"};
  std::string result = xio::extractEndpointName(3, const_cast<char**>(argv));
  ASSERT_EQ(result, "nvme");
  return 0;
}

int test_long_flag() {
  const char* argv[] = {"prog", "--endpoint", "rdma"};
  std::string result = xio::extractEndpointName(3, const_cast<char**>(argv));
  ASSERT_EQ(result, "rdma");
  return 0;
}

int test_long_equals() {
  const char* argv[] = {"prog", "--endpoint=test-ep"};
  std::string result = xio::extractEndpointName(2, const_cast<char**>(argv));
  ASSERT_EQ(result, "test-ep");
  return 0;
}

int test_short_equals() {
  const char* argv[] = {"prog", "-e=sdma"};
  std::string result = xio::extractEndpointName(2, const_cast<char**>(argv));
  ASSERT_EQ(result, "sdma");
  return 0;
}

int test_no_endpoint() {
  const char* argv[] = {"prog", "--verbose"};
  std::string result = xio::extractEndpointName(2, const_cast<char**>(argv));
  ASSERT_TRUE(result.empty());
  return 0;
}

int test_no_args() {
  const char* argv[] = {"prog"};
  std::string result = xio::extractEndpointName(1, const_cast<char**>(argv));
  ASSERT_TRUE(result.empty());
  return 0;
}

int test_short_flag_at_end() {
  const char* argv[] = {"prog", "-e"};
  std::string result = xio::extractEndpointName(2, const_cast<char**>(argv));
  ASSERT_TRUE(result.empty());
  return 0;
}

int test_mixed_args() {
  const char* argv[] = {"prog", "-n", "100", "-e", "rdma", "-v"};
  std::string result = xio::extractEndpointName(6, const_cast<char**>(argv));
  ASSERT_EQ(result, "rdma");
  return 0;
}

int main() {
  int failures = 0;
  failures += test_short_flag();
  failures += test_long_flag();
  failures += test_long_equals();
  failures += test_short_equals();
  failures += test_no_endpoint();
  failures += test_no_args();
  failures += test_short_flag_at_end();
  failures += test_mixed_args();

  if (failures == 0) {
    printf("All extractEndpointName "
           "tests passed.\n");
    return 0;
  }
  printf("%d extractEndpointName "
         "test(s) failed.\n",
         failures);
  return 1;
}
