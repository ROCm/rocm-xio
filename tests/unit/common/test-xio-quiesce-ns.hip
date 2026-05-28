/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * CPU-only unit tests for the xioQuiesceNvmeNamespace() /
 * xioUnquiesceNvmeNamespace() helpers in src/common/xio-common.hip.
 *
 * The helpers wrap the ROCM_XIO_QUIESCE_NS / ROCM_XIO_UNQUIESCE_NS
 * ioctls added so the in-kernel NVMe block-layer dispatcher can
 * be told to stop using a namespace request_queue while rocm-xio
 * owns one of its hardware queues. These tests run in CI where
 * /dev/rocm-xio is absent, so they only validate the argument
 * checks and a missing-kernel-module fallback.
 */

#include <cerrno>
#include <cstdio>
#include <cstdlib>

#include <hip/hip_runtime.h>

#include "xio-test-assert.h"
#include "xio.h"

int test_bad_kmod_fd_is_rejected() {
  ASSERT_EQ(xioQuiesceNvmeNamespace(-1, "/dev/nvme0n1"), -EINVAL);
  ASSERT_EQ(xioUnquiesceNvmeNamespace(-1, "/dev/nvme0n1"), -EINVAL);
  return 0;
}

int test_null_path_is_rejected() {
  ASSERT_EQ(xioQuiesceNvmeNamespace(0, nullptr), -EINVAL);
  ASSERT_EQ(xioUnquiesceNvmeNamespace(0, nullptr), -EINVAL);
  return 0;
}

int test_empty_path_is_rejected() {
  ASSERT_EQ(xioQuiesceNvmeNamespace(0, ""), -EINVAL);
  ASSERT_EQ(xioUnquiesceNvmeNamespace(0, ""), -EINVAL);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_bad_kmod_fd_is_rejected();
  failures += test_null_path_is_rejected();
  failures += test_empty_path_is_rejected();
  if (failures == 0) {
    printf("All xioQuiesceNvmeNamespace argument tests passed.\n");
    return 0;
  }
  printf("%d xioQuiesceNvmeNamespace test(s) failed.\n", failures);
  return 1;
}
