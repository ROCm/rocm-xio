/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for xio::rdma_ep::make_backend_config(). The mapping from the
 * public RdmaEpConfig / XioEndpointConfig pair to the runtime BackendConfig
 * is critical glue: regressions here silently change provider, queue depth,
 * inline thresholds, traffic class, or queue memory placement.
 */

#include <cstdio>
#include <cstring>
#include <string>

#include <hip/hip_runtime.h>

#include "gda-backend.hpp"
#include "rdma-common.h"
#include "rdma-ep.h"
#include "xio-test-assert.h"
#include "xio.h"

using xio::XioEndpointConfig;
using xio::rdma_ep::BackendConfig;
using xio::rdma_ep::make_backend_config;
using xio::rdma_ep::Provider;
using xio::rdma_ep::QueueMemMode;
using xio::rdma_ep::RdmaEpConfig;

int test_defaults_map_to_host_coherent_loopback() {
  XioEndpointConfig cfg;
  RdmaEpConfig rcfg;
  rcfg.provider = Provider::BNXT;

  BackendConfig out = make_backend_config(cfg, rcfg, /*loopback=*/true);
  ASSERT_EQ(out.provider, Provider::BNXT);
  ASSERT_EQ(out.gpu_device_id, 0);
  ASSERT_EQ(out.sq_depth, 256);
  ASSERT_EQ(out.cq_depth, 256);
  ASSERT_EQ(out.inline_threshold, 28u);
  ASSERT_TRUE(!out.pcie_relaxed_ordering);
  ASSERT_EQ(out.traffic_class, 0);
  ASSERT_TRUE(out.loopback);
  ASSERT_TRUE(!out.pci_mmio_bridge);
  ASSERT_TRUE(out.queue_mem == QueueMemMode::HOST_COHERENT);
  ASSERT_TRUE(out.hca_list == nullptr);
  return 0;
}

int test_loopback_flag_passthrough() {
  XioEndpointConfig cfg;
  RdmaEpConfig rcfg;
  BackendConfig out_lb = make_backend_config(cfg, rcfg, /*loopback=*/true);
  BackendConfig out_2node = make_backend_config(cfg, rcfg, /*loopback=*/false);
  ASSERT_TRUE(out_lb.loopback);
  ASSERT_TRUE(!out_2node.loopback);
  return 0;
}

int test_provider_passthrough() {
  XioEndpointConfig cfg;
  RdmaEpConfig rcfg;
  for (auto p : {Provider::BNXT, Provider::MLX5, Provider::IONIC,
                 Provider::ROCM_ERNIC}) {
    rcfg.provider = p;
    BackendConfig out = make_backend_config(cfg, rcfg, true);
    ASSERT_EQ(out.provider, p);
  }
  return 0;
}

int test_queue_sizing_passthrough() {
  XioEndpointConfig cfg;
  RdmaEpConfig rcfg;
  rcfg.sqDepth = 64;
  rcfg.cqDepth = 128;
  rcfg.inlineThreshold = 256;
  rcfg.trafficClass = 3;
  rcfg.gpuDeviceId = 5;
  rcfg.pcieRelaxedOrdering = true;
  BackendConfig out = make_backend_config(cfg, rcfg, true);
  ASSERT_EQ(out.sq_depth, 64);
  ASSERT_EQ(out.cq_depth, 128);
  ASSERT_EQ(out.inline_threshold, 256u);
  ASSERT_EQ(out.traffic_class, 3);
  ASSERT_EQ(out.gpu_device_id, 5);
  ASSERT_TRUE(out.pcie_relaxed_ordering);
  return 0;
}

int test_queue_mem_mode_follows_memory_mode_bit() {
  XioEndpointConfig cfg;
  RdmaEpConfig rcfg;

  cfg.memoryMode = 0;
  BackendConfig host = make_backend_config(cfg, rcfg, true);
  ASSERT_TRUE(host.queue_mem == QueueMemMode::HOST_COHERENT);

  cfg.memoryMode = XIO_MEM_MODE_SQ_DEVICE;
  BackendConfig vram = make_backend_config(cfg, rcfg, true);
  ASSERT_TRUE(vram.queue_mem == QueueMemMode::DEVICE_VRAM);

  cfg.memoryMode = XIO_MEM_MODE_SQ_DEVICE | XIO_MEM_MODE_CQ_DEVICE |
                   XIO_MEM_MODE_DATA_DEVICE;
  BackendConfig vram_full = make_backend_config(cfg, rcfg, true);
  ASSERT_TRUE(vram_full.queue_mem == QueueMemMode::DEVICE_VRAM);

  cfg.memoryMode = XIO_MEM_MODE_CQ_DEVICE;
  BackendConfig host_cq = make_backend_config(cfg, rcfg, true);
  ASSERT_TRUE(host_cq.queue_mem == QueueMemMode::HOST_COHERENT);
  return 0;
}

int test_pci_mmio_bridge_passthrough() {
  XioEndpointConfig cfg;
  RdmaEpConfig rcfg;

  cfg.pciMmioBridge = false;
  BackendConfig off = make_backend_config(cfg, rcfg, true);
  ASSERT_TRUE(!off.pci_mmio_bridge);

  cfg.pciMmioBridge = true;
  BackendConfig on = make_backend_config(cfg, rcfg, true);
  ASSERT_TRUE(on.pci_mmio_bridge);
  return 0;
}

int test_hca_list_empty_remains_null() {
  XioEndpointConfig cfg;
  RdmaEpConfig rcfg;
  rcfg.deviceName = "";
  BackendConfig out = make_backend_config(cfg, rcfg, true);
  ASSERT_TRUE(out.hca_list == nullptr);
  return 0;
}

int test_hca_list_nonempty_sets_pointer() {
  XioEndpointConfig cfg;
  RdmaEpConfig rcfg;
  rcfg.deviceName = "rocm-rdma-bnxt0";
  BackendConfig out = make_backend_config(cfg, rcfg, true);
  ASSERT_TRUE(out.hca_list != nullptr);
  ASSERT_EQ(std::string(out.hca_list), std::string("rocm-rdma-bnxt0"));
  return 0;
}

int main() {
  int failures = 0;
  failures += test_defaults_map_to_host_coherent_loopback();
  failures += test_loopback_flag_passthrough();
  failures += test_provider_passthrough();
  failures += test_queue_sizing_passthrough();
  failures += test_queue_mem_mode_follows_memory_mode_bit();
  failures += test_pci_mmio_bridge_passthrough();
  failures += test_hca_list_empty_remains_null();
  failures += test_hca_list_nonempty_sets_pointer();

  if (failures == 0) {
    printf("All make_backend_config tests passed.\n");
    return 0;
  }
  printf("%d make_backend_config test(s) failed.\n", failures);
  return 1;
}
