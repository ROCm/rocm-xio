/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for shared RDMA endpoint helper logic.
 */

#include <cstdint>
#include <cstdio>
#include <cstring>

#include <endian.h>

#include "gda-backend.hpp"
#include "ibv-core.hpp"
#include "rdma-common.h"
#include "xio-test-assert.h"
#include "xio.h"

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
  ASSERT_EQ(xio::rdma_ep::normalize_qp_key(xio::rdma_ep::Provider::ROCM_ERNIC,
                                           key),
            key);
  ASSERT_EQ(xio::rdma_ep::normalize_qp_key(xio::rdma_ep::Provider::UNKNOWN,
                                           key),
            key);
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

int test_fill_rc_qp_init_attr() {
  struct ibv_qp_init_attr_ex attr;
  memset(&attr, 0xA5, sizeof(attr));
  auto* pd = reinterpret_cast<struct ibv_pd*>(static_cast<uintptr_t>(0x1000));
  auto* cq = reinterpret_cast<struct ibv_cq*>(static_cast<uintptr_t>(0x2000));

  xio::rdma_ep::fill_rc_qp_init_attr(&attr, pd, cq, 17, 3, 2, 28);

  ASSERT_EQ(attr.send_cq, cq);
  ASSERT_EQ(attr.recv_cq, cq);
  ASSERT_EQ(attr.srq, nullptr);
  ASSERT_EQ(attr.cap.max_send_wr, 17u);
  ASSERT_EQ(attr.cap.max_recv_wr, 3u);
  ASSERT_EQ(attr.cap.max_send_sge, 1u);
  ASSERT_EQ(attr.cap.max_recv_sge, 2u);
  ASSERT_EQ(attr.cap.max_inline_data, 28u);
  ASSERT_EQ(attr.qp_type, IBV_QPT_RC);
  ASSERT_EQ(attr.sq_sig_all, 0);
  ASSERT_EQ(attr.comp_mask, static_cast<uint32_t>(IBV_QP_INIT_ATTR_PD));
  ASSERT_EQ(attr.pd, pd);
  return 0;
}

int test_make_backend_config_host_queues() {
  xio::XioEndpointConfig config;
  config.memoryMode = 0;
  config.pciMmioBridge = true;

  xio::rdma_ep::RdmaEpConfig rdma;
  rdma.provider = xio::rdma_ep::Provider::IONIC;
  rdma.gpuDeviceId = 2;
  rdma.sqDepth = 512;
  rdma.cqDepth = 1024;
  rdma.inlineThreshold = 64;
  rdma.pcieRelaxedOrdering = true;
  rdma.trafficClass = 6;
  rdma.deviceName = "rocm-rdma-ionic0";

  xio::rdma_ep::BackendConfig backend =
    xio::rdma_ep::make_backend_config(config, rdma, false);

  ASSERT_EQ(backend.provider, xio::rdma_ep::Provider::IONIC);
  ASSERT_EQ(backend.gpu_device_id, 2);
  ASSERT_EQ(backend.sq_depth, 512);
  ASSERT_EQ(backend.cq_depth, 1024);
  ASSERT_EQ(backend.inline_threshold, 64u);
  ASSERT_TRUE(backend.pcie_relaxed_ordering);
  ASSERT_EQ(backend.traffic_class, 6);
  ASSERT_TRUE(!backend.loopback);
  ASSERT_TRUE(backend.pci_mmio_bridge);
  ASSERT_EQ(backend.queue_mem, xio::rdma_ep::QueueMemMode::HOST_COHERENT);
  ASSERT_STREQ(backend.hca_list, "rocm-rdma-ionic0");
  return 0;
}

int test_make_backend_config_device_queues() {
  xio::XioEndpointConfig config;
  config.memoryMode = XIO_MEM_MODE_SQ_DEVICE;

  xio::rdma_ep::RdmaEpConfig rdma;
  rdma.deviceName.clear();

  xio::rdma_ep::BackendConfig backend =
    xio::rdma_ep::make_backend_config(config, rdma, true);

  ASSERT_TRUE(backend.loopback);
  ASSERT_EQ(backend.queue_mem, xio::rdma_ep::QueueMemMode::DEVICE_VRAM);
  ASSERT_EQ(backend.hca_list, nullptr);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_provider_allowed_names();
  failures += test_normalize_qp_key_mlx5();
  failures += test_normalize_qp_key_native_providers();
  failures += test_normalize_mr_keys();
  failures += test_rd_atomic_cap();
  failures += test_fill_rc_qp_init_attr();
  failures += test_make_backend_config_host_queues();
  failures += test_make_backend_config_device_queues();

  if (failures == 0) {
    printf("All rdma-common tests passed.\n");
    return 0;
  }
  printf("%d rdma-common test(s) failed.\n", failures);
  return 1;
}
