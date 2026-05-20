/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for the PCI MMIO bridge shadow buffer structures and the
 * host-side genPciMmioBridgeCmd() helper. The structures must match the
 * out-of-process QEMU device exactly, so layout regressions are caught here
 * at build time via static_assert and at runtime via field offsets.
 */

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include <hip/hip_runtime.h>

#include "xio-test-assert.h"
#include "xio.h"

/* ---------- Compile-time layout checks ---------- */

static_assert(sizeof(xio::pci_mmio_bridge_ring_meta) == 16,
              "pci_mmio_bridge_ring_meta size drift");
static_assert(offsetof(xio::pci_mmio_bridge_ring_meta, producer_idx) == 0,
              "producer_idx offset drift");
static_assert(offsetof(xio::pci_mmio_bridge_ring_meta, consumer_idx) == 4,
              "consumer_idx offset drift");
static_assert(offsetof(xio::pci_mmio_bridge_ring_meta, queue_depth) == 8,
              "queue_depth offset drift");
static_assert(offsetof(xio::pci_mmio_bridge_ring_meta, reserved) == 12,
              "reserved offset drift");

static_assert(sizeof(xio::pci_mmio_bridge_command) == 24,
              "pci_mmio_bridge_command size drift");
static_assert(offsetof(xio::pci_mmio_bridge_command, target_bdf) == 0, "");
static_assert(offsetof(xio::pci_mmio_bridge_command, target_bar) == 2, "");
static_assert(offsetof(xio::pci_mmio_bridge_command, reserved1) == 3, "");
static_assert(offsetof(xio::pci_mmio_bridge_command, offset) == 4, "");
static_assert(offsetof(xio::pci_mmio_bridge_command, value) == 8, "");
static_assert(offsetof(xio::pci_mmio_bridge_command, command) == 16, "");
static_assert(offsetof(xio::pci_mmio_bridge_command, size) == 17, "");
static_assert(offsetof(xio::pci_mmio_bridge_command, status) == 18, "");
static_assert(offsetof(xio::pci_mmio_bridge_command, reserved2) == 19, "");
static_assert(offsetof(xio::pci_mmio_bridge_command, sequence) == 20, "");

int test_command_constants() {
  ASSERT_EQ(PCI_MMIO_BRIDGE_CMD_NOP, 0);
  ASSERT_EQ(PCI_MMIO_BRIDGE_CMD_WRITE, 1);
  ASSERT_EQ(PCI_MMIO_BRIDGE_CMD_READ, 2);

  ASSERT_EQ(PCI_MMIO_BRIDGE_STATUS_PENDING, 0);
  ASSERT_EQ(PCI_MMIO_BRIDGE_STATUS_COMPLETE, 1);
  ASSERT_EQ(PCI_MMIO_BRIDGE_STATUS_ERROR, 2);
  return 0;
}

namespace {

constexpr uint32_t kQueueDepth = 4;
constexpr size_t kShadowSize = sizeof(xio::pci_mmio_bridge_ring_meta) +
                               kQueueDepth *
                                 sizeof(xio::pci_mmio_bridge_command);

struct ShadowBuffer {
  std::vector<uint8_t> bytes;
  xio::pci_mmio_bridge_ring_meta* meta() {
    return reinterpret_cast<xio::pci_mmio_bridge_ring_meta*>(bytes.data());
  }
  xio::pci_mmio_bridge_command* slot(uint32_t i) {
    auto* base = bytes.data() + sizeof(xio::pci_mmio_bridge_ring_meta);
    return reinterpret_cast<xio::pci_mmio_bridge_command*>(
      base + i * sizeof(xio::pci_mmio_bridge_command));
  }
};

ShadowBuffer make_shadow_buffer() {
  ShadowBuffer s;
  s.bytes.assign(kShadowSize, 0);
  s.meta()->producer_idx = 0;
  s.meta()->consumer_idx = 0;
  s.meta()->queue_depth = kQueueDepth;
  s.meta()->reserved = 0;
  return s;
}

} // namespace

int test_genPciMmioBridgeCmd_writes_first_slot() {
  ShadowBuffer s = make_shadow_buffer();

  xio::genPciMmioBridgeCmd(s.bytes.data(),
                           /*targetBdf=*/0x0030,
                           /*targetBar=*/0,
                           /*offset=*/0x1000,
                           /*value=*/0xDEADBEEFCAFEBABEULL,
                           /*command=*/PCI_MMIO_BRIDGE_CMD_WRITE,
                           /*size=*/8);

  ASSERT_EQ(s.meta()->producer_idx, 1u);
  ASSERT_EQ(s.meta()->consumer_idx, 0u);

  auto* cmd = s.slot(0);
  ASSERT_EQ(cmd->target_bdf, static_cast<uint16_t>(0x0030));
  ASSERT_EQ(cmd->target_bar, static_cast<uint8_t>(0));
  ASSERT_EQ(cmd->reserved1, static_cast<uint8_t>(0));
  ASSERT_EQ(cmd->offset, 0x1000u);
  ASSERT_EQ(cmd->value, 0xDEADBEEFCAFEBABEULL);
  ASSERT_EQ(cmd->command, static_cast<uint8_t>(PCI_MMIO_BRIDGE_CMD_WRITE));
  ASSERT_EQ(cmd->size, static_cast<uint8_t>(8));
  ASSERT_EQ(cmd->status, static_cast<uint8_t>(PCI_MMIO_BRIDGE_STATUS_PENDING));
  ASSERT_EQ(cmd->reserved2, static_cast<uint8_t>(0));
  ASSERT_EQ(cmd->sequence, 0u);
  return 0;
}

int test_genPciMmioBridgeCmd_advances_through_slots() {
  ShadowBuffer s = make_shadow_buffer();

  for (uint32_t i = 0; i < kQueueDepth; i++) {
    xio::genPciMmioBridgeCmd(s.bytes.data(),
                             /*targetBdf=*/static_cast<uint16_t>(0xAA00u + i),
                             /*targetBar=*/static_cast<uint8_t>(i & 0xFF),
                             /*offset=*/0x100u * i,
                             /*value=*/0x1000ULL + i,
                             /*command=*/PCI_MMIO_BRIDGE_CMD_WRITE,
                             /*size=*/4);
  }

  ASSERT_EQ(s.meta()->producer_idx, kQueueDepth);
  for (uint32_t i = 0; i < kQueueDepth; i++) {
    auto* cmd = s.slot(i);
    ASSERT_EQ(cmd->target_bdf, static_cast<uint16_t>(0xAA00u + i));
    ASSERT_EQ(cmd->target_bar, static_cast<uint8_t>(i & 0xFF));
    ASSERT_EQ(cmd->offset, 0x100u * i);
    ASSERT_EQ(cmd->value, 0x1000ULL + i);
    ASSERT_EQ(cmd->sequence, i);
  }
  return 0;
}

int test_genPciMmioBridgeCmd_wraps_around_ring() {
  ShadowBuffer s = make_shadow_buffer();
  s.meta()->producer_idx = kQueueDepth;

  xio::genPciMmioBridgeCmd(s.bytes.data(),
                           /*targetBdf=*/0xBEEF,
                           /*targetBar=*/2,
                           /*offset=*/0x2000,
                           /*value=*/0x42ULL,
                           /*command=*/PCI_MMIO_BRIDGE_CMD_READ,
                           /*size=*/4);

  /* slot index = producer_idx % queue_depth = 0 for the first wrap. */
  ASSERT_EQ(s.meta()->producer_idx, kQueueDepth + 1u);
  auto* cmd = s.slot(0);
  ASSERT_EQ(cmd->target_bdf, static_cast<uint16_t>(0xBEEF));
  ASSERT_EQ(cmd->offset, 0x2000u);
  ASSERT_EQ(cmd->value, 0x42ULL);
  ASSERT_EQ(cmd->command, static_cast<uint8_t>(PCI_MMIO_BRIDGE_CMD_READ));
  ASSERT_EQ(cmd->sequence, 0u);
  return 0;
}

int test_genPciMmioBridgeCmd_zero_value_and_offset() {
  ShadowBuffer s = make_shadow_buffer();
  xio::genPciMmioBridgeCmd(s.bytes.data(), 0, 0, 0, 0, PCI_MMIO_BRIDGE_CMD_NOP,
                           1);
  ASSERT_EQ(s.meta()->producer_idx, 1u);
  auto* cmd = s.slot(0);
  ASSERT_EQ(cmd->target_bdf, 0u);
  ASSERT_EQ(cmd->target_bar, 0u);
  ASSERT_EQ(cmd->offset, 0u);
  ASSERT_EQ(cmd->value, 0ULL);
  ASSERT_EQ(cmd->command, static_cast<uint8_t>(PCI_MMIO_BRIDGE_CMD_NOP));
  ASSERT_EQ(cmd->size, static_cast<uint8_t>(1));
  ASSERT_EQ(cmd->status, static_cast<uint8_t>(PCI_MMIO_BRIDGE_STATUS_PENDING));
  return 0;
}

int main() {
  int failures = 0;
  failures += test_command_constants();
  failures += test_genPciMmioBridgeCmd_writes_first_slot();
  failures += test_genPciMmioBridgeCmd_advances_through_slots();
  failures += test_genPciMmioBridgeCmd_wraps_around_ring();
  failures += test_genPciMmioBridgeCmd_zero_value_and_offset();

  if (failures == 0) {
    printf("All PCI MMIO bridge tests passed.\n");
    return 0;
  }
  printf("%d PCI MMIO bridge test(s) failed.\n", failures);
  return 1;
}
