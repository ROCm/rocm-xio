/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for rdma-topology PCIe address parsing.
 * CPU-only: tests ExtractBusNumber and
 * GetBusIdDistance which are pure string/math ops.
 */

#include <cassert>
#include <cstdio>
#include <cstdlib>

#include "rdma-topology.hpp"
#include "xio-test-assert.h"

using namespace rdma_ep;

int test_extract_bus_number() {
  ASSERT_EQ(ExtractBusNumber("0000:01:00.0"), 1);
  ASSERT_EQ(ExtractBusNumber("0000:00:00.0"), 0);
  ASSERT_EQ(ExtractBusNumber("0000:ff:1f.7"), 0xff);
  ASSERT_EQ(ExtractBusNumber("0000:0a:00.0"), 0x0a);
  ASSERT_EQ(ExtractBusNumber("0001:c3:00.0"), 0xc3);
  ASSERT_EQ(ExtractBusNumber("invalid"), -1);
  ASSERT_EQ(ExtractBusNumber(""), -1);
  return 0;
}

int test_bus_id_distance() {
  ASSERT_EQ(GetBusIdDistance("0000:01:00.0", "0000:02:00.0"), 1);
  ASSERT_EQ(GetBusIdDistance("0000:01:00.0", "0000:01:00.0"), 0);
  ASSERT_EQ(GetBusIdDistance("0000:0a:00.0", "0000:14:00.0"), 10);

  ASSERT_EQ(GetBusIdDistance("0000:01:00.0", "bad"), -1);
  ASSERT_EQ(GetBusIdDistance("bad", "0000:01:00.0"), -1);
  ASSERT_EQ(GetBusIdDistance("bad1", "bad2"), -1);

  ASSERT_EQ(GetBusIdDistance("0000:02:00.0", "0000:01:00.0"), 1);
  return 0;
}

int test_get_lca_depth() {
  PCIeNode root("0000:00:00.0");
  PCIeNode child1("0000:01:00.0");
  PCIeNode child2("0000:02:00.0");
  PCIeNode grandchild("0000:03:00.0");

  child1.children.insert(grandchild);
  root.children.insert(child1);
  root.children.insert(child2);

  ASSERT_EQ(GetLcaDepth("0000:00:00.0", &root, 0), 0);
  ASSERT_EQ(GetLcaDepth("0000:02:00.0", &root, 0), 1);
  ASSERT_EQ(GetLcaDepth("0000:03:00.0", &root, 0), 2);
  ASSERT_EQ(GetLcaDepth("0000:ff:00.0", &root, 0), -1);
  ASSERT_EQ(GetLcaDepth("any", nullptr, 0), -1);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_extract_bus_number();
  failures += test_bus_id_distance();
  failures += test_get_lca_depth();

  if (failures == 0) {
    printf("All rdma-topology tests passed.\n");
    return 0;
  }
  printf("%d rdma-topology test(s) failed.\n", failures);
  return 1;
}
