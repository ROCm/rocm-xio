/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for rocm-xio environment parsing helpers.
 */

#include <cstdio>
#include <cstdlib>

#include <sys/wait.h>
#include <unistd.h>

#include "xio-env.h"
#include "xio-test-assert.h"

template <typename Fn>
int run_in_child(Fn fn) {
  pid_t pid = fork();
  ASSERT_TRUE(pid >= 0);
  if (pid == 0) {
    fn();
    _exit(0);
  }

  int status = 0;
  ASSERT_EQ(waitpid(pid, &status, 0), pid);
  ASSERT_TRUE(WIFEXITED(status));
  ASSERT_EQ(WEXITSTATUS(status), 0);
  return 0;
}

int test_get_env_int_default_for_unset_and_empty() {
  unsetenv("ROCXIO_TEST_ENV_INT");
  ASSERT_EQ(xio::getEnvInt("ROCXIO_TEST_ENV_INT", 42), 42);

  setenv("ROCXIO_TEST_ENV_INT", "", 1);
  ASSERT_EQ(xio::getEnvInt("ROCXIO_TEST_ENV_INT", 43), 43);
  unsetenv("ROCXIO_TEST_ENV_INT");
  return 0;
}

int test_get_env_int_decimal_values() {
  setenv("ROCXIO_TEST_ENV_INT", "12345", 1);
  ASSERT_EQ(xio::getEnvInt("ROCXIO_TEST_ENV_INT", 0), 12345);

  setenv("ROCXIO_TEST_ENV_INT", "-7", 1);
  ASSERT_EQ(xio::getEnvInt("ROCXIO_TEST_ENV_INT", 0), -7);
  unsetenv("ROCXIO_TEST_ENV_INT");
  return 0;
}

int test_get_env_int_rejects_partial_values() {
  setenv("ROCXIO_TEST_ENV_INT", "12kb", 1);
  ASSERT_EQ(xio::getEnvInt("ROCXIO_TEST_ENV_INT", 77), 77);

  setenv("ROCXIO_TEST_ENV_INT", "0x10", 1);
  ASSERT_EQ(xio::getEnvInt("ROCXIO_TEST_ENV_INT", 78), 78);
  unsetenv("ROCXIO_TEST_ENV_INT");
  return 0;
}

int test_get_env_str_default_for_unset_and_empty() {
  unsetenv("ROCXIO_TEST_ENV_STR");
  ASSERT_STREQ(xio::getEnvStr("ROCXIO_TEST_ENV_STR", "fallback"), "fallback");

  setenv("ROCXIO_TEST_ENV_STR", "", 1);
  ASSERT_STREQ(xio::getEnvStr("ROCXIO_TEST_ENV_STR", "empty-fallback"),
               "empty-fallback");
  unsetenv("ROCXIO_TEST_ENV_STR");
  return 0;
}

int test_get_env_str_returns_value() {
  setenv("ROCXIO_TEST_ENV_STR", "configured", 1);
  ASSERT_STREQ(xio::getEnvStr("ROCXIO_TEST_ENV_STR", "fallback"), "configured");
  unsetenv("ROCXIO_TEST_ENV_STR");
  return 0;
}

int test_rocxio_verbose_initialization() {
  return run_in_child([] {
           unsetenv("ROCXIO_VERBOSE");
           ASSERT_TRUE(!xio::rocxioVerbose());
         }) +
         run_in_child([] {
           setenv("ROCXIO_VERBOSE", "1", 1);
           ASSERT_TRUE(xio::rocxioVerbose());
         }) +
         run_in_child([] {
           setenv("ROCXIO_VERBOSE", "true", 1);
           ASSERT_TRUE(xio::rocxioVerbose());
         }) +
         run_in_child([] {
           setenv("ROCXIO_VERBOSE", "yes", 1);
           ASSERT_TRUE(!xio::rocxioVerbose());
         });
}

int test_rocxio_log_level_initialization() {
  return run_in_child([] {
           unsetenv("ROCXIO_VERBOSE");
           unsetenv("ROCXIO_LOG_LEVEL");
           ASSERT_EQ(xio::rocxioLogLevel(), static_cast<int>(xio::LOG_WARN));
         }) +
         run_in_child([] {
           unsetenv("ROCXIO_VERBOSE");
           setenv("ROCXIO_LOG_LEVEL", "-10", 1);
           ASSERT_EQ(xio::rocxioLogLevel(), static_cast<int>(xio::LOG_NONE));
         }) +
         run_in_child([] {
           unsetenv("ROCXIO_VERBOSE");
           setenv("ROCXIO_LOG_LEVEL", "99", 1);
           ASSERT_EQ(xio::rocxioLogLevel(), static_cast<int>(xio::LOG_TRACE));
         }) +
         run_in_child([] {
           setenv("ROCXIO_VERBOSE", "1", 1);
           setenv("ROCXIO_LOG_LEVEL", "1", 1);
           ASSERT_EQ(xio::rocxioLogLevel(), static_cast<int>(xio::LOG_INFO));
         });
}

int main() {
  int failures = 0;
  failures += test_get_env_int_default_for_unset_and_empty();
  failures += test_get_env_int_decimal_values();
  failures += test_get_env_int_rejects_partial_values();
  failures += test_get_env_str_default_for_unset_and_empty();
  failures += test_get_env_str_returns_value();
  failures += test_rocxio_verbose_initialization();
  failures += test_rocxio_log_level_initialization();

  if (failures == 0) {
    printf("All xio-env tests passed.\n");
    return 0;
  }
  printf("%d xio-env test(s) failed.\n", failures);
  return 1;
}
