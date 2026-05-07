/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for shared RDMA endpoint helper logic.
 */

#include <cstdint>
#include <cstdio>

#include <endian.h>

#include "ibv-core.hpp"
#include "rdma-common.h"
#include "xio-test-assert.h"

int test_provider_allowed_names() {
  ASSERT_STREQ(xio::rdma_ep::provider_allowed_names(),
               "bnxt, mlx5, ionic, or rocm-ernic");
  return 0;
}

int test_normalize_qp_key_mlx5() {
  uint32_t key = 0x11223344u;
  ASSERT_EQ(xio::rdma_ep::normalize_qp_key(xio::rdma_ep::Provider::MLX5, key),
            htobe32(key));
  return 0;
}

int test_normalize_qp_key_native_providers() {
  uint32_t key = 0x11223344u;
  ASSERT_EQ(xio::rdma_ep::normalize_qp_key(xio::rdma_ep::Provider::BNXT, key),
            key);
  ASSERT_EQ(xio::rdma_ep::normalize_qp_key(xio::rdma_ep::Provider::IONIC, key),
            key);
  ASSERT_EQ(
    xio::rdma_ep::normalize_qp_key(xio::rdma_ep::Provider::ROCM_ERNIC, key),
    key);
  ASSERT_EQ(
    xio::rdma_ep::normalize_qp_key(xio::rdma_ep::Provider::UNKNOWN, key), key);
  return 0;
}

int test_normalize_mr_keys() {
  uint32_t lkey = 0x01020304u;
  uint32_t rkey = 0xa1b2c3d4u;
  uint32_t normalized_lkey = 0;
  uint32_t normalized_rkey = 0;

  xio::rdma_ep::normalize_mr_keys(xio::rdma_ep::Provider::MLX5, lkey, rkey,
                                  &normalized_lkey, &normalized_rkey);
  ASSERT_EQ(normalized_lkey, htobe32(lkey));
  ASSERT_EQ(normalized_rkey, htobe32(rkey));

  normalized_lkey = 0;
  normalized_rkey = 0;
  xio::rdma_ep::normalize_mr_keys(xio::rdma_ep::Provider::BNXT, lkey, rkey,
                                  &normalized_lkey, &normalized_rkey);
  ASSERT_EQ(normalized_lkey, lkey);
  ASSERT_EQ(normalized_rkey, rkey);

  xio::rdma_ep::normalize_mr_keys(xio::rdma_ep::Provider::MLX5, lkey, rkey,
                                  nullptr, nullptr);
  return 0;
}

int test_rd_atomic_cap() {
  struct ibv_device_attr attr = {};

  attr.max_qp_rd_atom = 0;
  ASSERT_EQ(xio::rdma_ep::rd_atomic_cap(xio::rdma_ep::Provider::BNXT, attr),
            static_cast<uint8_t>(1));

  attr.max_qp_rd_atom = 7;
  ASSERT_EQ(xio::rdma_ep::rd_atomic_cap(xio::rdma_ep::Provider::BNXT, attr),
            static_cast<uint8_t>(7));

  attr.max_qp_rd_atom = 512;
  ASSERT_EQ(xio::rdma_ep::rd_atomic_cap(xio::rdma_ep::Provider::BNXT, attr),
            static_cast<uint8_t>(255));

  attr.max_qp_rd_atom = 1;
  ASSERT_EQ(xio::rdma_ep::rd_atomic_cap(xio::rdma_ep::Provider::IONIC, attr),
            static_cast<uint8_t>(15));
  return 0;
}

int main() {
  int failures = 0;
  failures += test_provider_allowed_names();
  failures += test_normalize_qp_key_mlx5();
  failures += test_normalize_qp_key_native_providers();
  failures += test_normalize_mr_keys();
  failures += test_rd_atomic_cap();

  if (failures == 0) {
    printf("All rdma-common tests passed.\n");
    return 0;
  }
  printf("%d rdma-common test(s) failed.\n", failures);
  return 1;
}
