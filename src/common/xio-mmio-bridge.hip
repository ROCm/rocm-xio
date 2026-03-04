/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "xio-mmio-bridge.h"
#include "xio.h"

namespace xio_mmio_bridge {

// Ring doorbell with support for both PCI MMIO bridge and direct BAR0 modes
__host__ __device__ void ringDoorbell(
  uint16_t sq_tail, uint32_t doorbell_offset, bool usePciMmioBridge,
  void* shadowBufferVirt, uint16_t nvmeTargetBdf, void* nvmeBar0Gpu) {
  if (usePciMmioBridge && shadowBufferVirt != nullptr) {
    // PCI MMIO Bridge mode - complex command structure
    volatile struct pci_mmio_bridge_ring_meta* meta =
      static_cast<volatile struct pci_mmio_bridge_ring_meta*>(shadowBufferVirt);
    uint32_t slot = meta->producer_idx % meta->queue_depth;
    volatile struct pci_mmio_bridge_command* cmd =
      reinterpret_cast<volatile struct pci_mmio_bridge_command*>(
        static_cast<volatile uint8_t*>(shadowBufferVirt) +
        sizeof(struct pci_mmio_bridge_ring_meta) +
        (slot * sizeof(struct pci_mmio_bridge_command)));
    cmd->target_bdf = nvmeTargetBdf;
    cmd->target_bar = 0;
    cmd->reserved1 = 0;
    cmd->offset = doorbell_offset;
    cmd->value = sq_tail;
    cmd->command = PCI_MMIO_BRIDGE_CMD_WRITE;
    cmd->size = 4;
    cmd->status = PCI_MMIO_BRIDGE_STATUS_PENDING;
    cmd->reserved2 = 0;
    cmd->sequence = slot;
#ifdef __HIP_DEVICE_COMPILE__
    __threadfence_system();
#endif
    meta->producer_idx = meta->producer_idx + 1;
#ifdef __HIP_DEVICE_COMPILE__
    __threadfence_system();
#endif
  } else if (!usePciMmioBridge && nvmeBar0Gpu != nullptr) {
    // Direct BAR0 mode - use generic xio_ep function
    xio_ep::ringDoorbell(nvmeBar0Gpu, doorbell_offset, sq_tail);
  }
  // If neither mode is available, silently skip (matches current behavior)
}

/**
 * Ring CQ head doorbell to notify controller that CQEs have been consumed.
 * This is critical - without updating CQ head doorbell, the controller will
 * run out of CQ slots and stall.
 */
__host__ __device__ void ringCqHeadDoorbell(
  uint16_t cq_head, uint32_t cq_doorbell_offset, bool usePciMmioBridge,
  void* shadowBufferVirt, uint16_t nvmeTargetBdf, void* nvmeBar0Gpu) {
  if (usePciMmioBridge && shadowBufferVirt != nullptr) {
    // PCI MMIO Bridge mode - complex command structure
    volatile struct pci_mmio_bridge_ring_meta* meta =
      static_cast<volatile struct pci_mmio_bridge_ring_meta*>(shadowBufferVirt);
    uint32_t slot = meta->producer_idx % meta->queue_depth;
    volatile struct pci_mmio_bridge_command* cmd =
      reinterpret_cast<volatile struct pci_mmio_bridge_command*>(
        static_cast<volatile uint8_t*>(shadowBufferVirt) +
        sizeof(struct pci_mmio_bridge_ring_meta) +
        (slot * sizeof(struct pci_mmio_bridge_command)));
    cmd->target_bdf = nvmeTargetBdf;
    cmd->target_bar = 0;
    cmd->reserved1 = 0;
    cmd->offset = cq_doorbell_offset;
    cmd->value = cq_head;
    cmd->command = PCI_MMIO_BRIDGE_CMD_WRITE;
    cmd->size = 4;
    cmd->status = PCI_MMIO_BRIDGE_STATUS_PENDING;
    cmd->reserved2 = 0;
    cmd->sequence = slot;
#ifdef __HIP_DEVICE_COMPILE__
    __threadfence_system();
#endif
    meta->producer_idx = meta->producer_idx + 1;
#ifdef __HIP_DEVICE_COMPILE__
    __threadfence_system();
#endif
  } else if (!usePciMmioBridge && nvmeBar0Gpu != nullptr) {
    // Direct BAR0 mode - use generic xio_ep function
    xio_ep::ringDoorbell(nvmeBar0Gpu, cq_doorbell_offset, cq_head);
  }
  // If neither mode is available, silently skip (matches current behavior)
}

} // namespace xio_mmio_bridge

// Host-only function for mapping PCI MMIO bridge shadow buffer
#ifndef __HIP_DEVICE_COMPILE__

#include <errno.h>

#include <cstdio>
#include <cstring>

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "xio-kmod.h"

namespace xio_mmio_bridge {

/**
 * Map PCI MMIO bridge shadow buffer for doorbell routing
 *
 * @param bridge_bdf PCI MMIO bridge BDF (0xBBDD format)
 * @param virt_addr Output: Virtual address of mapped shadow buffer
 * @return 0 on success, negative error code on failure
 */
int map_shadow_buffer(uint16_t bridge_bdf, void** virt_addr) {
  int kmod_fd = -1;
  int ret = 0;
  struct rocm_xio_mmio_bridge_shadow_req req;
  void* mapped = MAP_FAILED;

  // Open kernel module device
  kmod_fd = open(ROCM_XIO_DEVICE_PATH, O_RDWR);
  if (kmod_fd < 0) {
    fprintf(stderr, "Failed to open %s: %s\n", ROCM_XIO_DEVICE_PATH,
            strerror(errno));
    fprintf(stderr, "Please ensure the rocm-xio kernel module is loaded\n");
    return -errno;
  }

  // Get shadow buffer info from kernel module
  memset(&req, 0, sizeof(req));
  req.bridge_bdf = bridge_bdf;
  ret = ioctl(kmod_fd, ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER, &req);
  if (ret < 0) {
    fprintf(stderr, "Failed to get PCI MMIO bridge shadow buffer info: %s\n",
            strerror(errno));
    close(kmod_fd);
    return -errno;
  }

  if (req.shadow_gpa == 0) {
    fprintf(stderr, "PCI MMIO bridge shadow GPA is 0 (not configured)\n");
    close(kmod_fd);
    return -EINVAL;
  }

  // Map shadow buffer via kernel module mmap
  mapped = mmap(nullptr, req.shadow_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                kmod_fd, 0);
  if (mapped == MAP_FAILED) {
    fprintf(stderr, "Failed to mmap PCI MMIO bridge shadow buffer: %s\n",
            strerror(errno));
    close(kmod_fd);
    return -errno;
  }

  // Keep kmod_fd open for the mapping to remain valid
  // Note: In a production system, you might want to track this fd
  // and close it on cleanup, but for simplicity we'll leave it open
  // The kernel will clean it up when the process exits

  *virt_addr = mapped;
  fprintf(stderr,
          "PCI MMIO bridge shadow buffer mapped: GPA=0x%llx, "
          "size=%llu, vaddr=%p\n",
          (unsigned long long)req.shadow_gpa,
          (unsigned long long)req.shadow_size, mapped);

  return 0;
}

} // namespace xio_mmio_bridge

#endif // __HIP_DEVICE_COMPILE__
