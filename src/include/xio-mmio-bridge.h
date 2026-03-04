/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef XIO_MMIO_BRIDGE_H
#define XIO_MMIO_BRIDGE_H

#include <cstdint>

#include "xio-kmod.h" // For IOCTL definitions

// PCI MMIO Bridge structures (matching QEMU implementation)
// These must be defined before device code that uses them
struct pci_mmio_bridge_ring_meta {
  uint32_t producer_idx; // Guest/device write index (tail)
  uint32_t consumer_idx; // QEMU read index (head)
  uint32_t queue_depth;  // Total number of command slots
  uint32_t reserved;
} __attribute__((packed));

struct pci_mmio_bridge_command {
  uint16_t target_bdf; // Bus:Device:Function (bus|devfn)
  uint8_t target_bar;  // Which BAR on target device (0-5)
  uint8_t reserved1;
  uint32_t offset; // Offset within BAR
  uint64_t value;  // Value to write, or returned value for read
  uint8_t command; // Command type (WRITE=1, READ=2)
  uint8_t size;    // Transfer size: 1, 2, 4, or 8 bytes
  uint8_t status;  // Status (PENDING=0, COMPLETE=1, ERROR=2)
  uint8_t reserved2;
  uint32_t sequence; // Sequence number for ordering
} __attribute__((packed));

// Command types
#define PCI_MMIO_BRIDGE_CMD_NOP 0
#define PCI_MMIO_BRIDGE_CMD_WRITE 1
#define PCI_MMIO_BRIDGE_CMD_READ 2

// Status codes
#define PCI_MMIO_BRIDGE_STATUS_PENDING 0
#define PCI_MMIO_BRIDGE_STATUS_COMPLETE 1
#define PCI_MMIO_BRIDGE_STATUS_ERROR 2

// Host-only code for IOCTL structures
#ifndef __HIP_DEVICE_COMPILE__

struct rocm_xio_mmio_bridge_shadow_req {
  uint16_t bridge_bdf;  // Input: PCI MMIO bridge BDF (0xBBDD format)
  uint64_t shadow_gpa;  // Output: Shadow buffer Guest Physical Address
  uint64_t shadow_size; // Output: Shadow buffer size in bytes
};

#define ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER                                 \
  _IOWR(ROCM_XIO_IOC_MAGIC, 10, struct rocm_xio_mmio_bridge_shadow_req)

// Backward compatibility: old naming convention used in nvme-ep
// TODO: Migrate nvme-ep to use rocm_xio_* naming
typedef struct rocm_xio_mmio_bridge_shadow_req
  rocm_axiio_mmio_bridge_shadow_req;

#endif // __HIP_DEVICE_COMPILE__

// Forward declarations for device/host functions
namespace xio_mmio_bridge {

// Ring doorbell with support for both PCI MMIO bridge and direct BAR0 modes
__host__ __device__ void ringDoorbell(
  uint16_t sq_tail, uint32_t doorbell_offset, bool usePciMmioBridge,
  void* shadowBufferVirt, uint16_t nvmeTargetBdf, void* nvmeBar0Gpu);

/**
 * Ring CQ head doorbell to notify controller that CQEs have been consumed.
 * This is critical - without updating CQ head doorbell, the controller will
 * run out of CQ slots and stall.
 */
__host__ __device__ void ringCqHeadDoorbell(
  uint16_t cq_head, uint32_t cq_doorbell_offset, bool usePciMmioBridge,
  void* shadowBufferVirt, uint16_t nvmeTargetBdf, void* nvmeBar0Gpu);

#ifndef __HIP_DEVICE_COMPILE__

/**
 * Map PCI MMIO bridge shadow buffer for doorbell routing
 *
 * @param bridge_bdf PCI MMIO bridge BDF (0xBBDD format)
 * @param virt_addr Output: Virtual address of mapped shadow buffer
 * @return 0 on success, negative error code on failure
 */
int map_shadow_buffer(uint16_t bridge_bdf, void** virt_addr);

#endif // __HIP_DEVICE_COMPILE__

} // namespace xio_mmio_bridge

#endif // XIO_MMIO_BRIDGE_H
