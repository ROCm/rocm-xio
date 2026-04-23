/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstddef>
#include <iostream>

#include "rocm-xio-uapi.h"

/**
 * @brief Compile-time checks that userspace UAPI struct layouts match
 *        the LP64 ABI expected by the out-of-tree rocm-xio kernel module.
 */
int main() {
  static_assert(sizeof(int) == 4, "UAPI tests assume 32-bit int");
  static_assert(sizeof(struct rocm_xio_vram_req) == 32,
                 "rocm_xio_vram_req size drift");
  static_assert(offsetof(struct rocm_xio_vram_req, dmabuf_fd) == 0, "");
  static_assert(offsetof(struct rocm_xio_vram_req, nvme_bdf) == 4, "");
  static_assert(offsetof(struct rocm_xio_vram_req, flags) == 8, "");
  static_assert(offsetof(struct rocm_xio_vram_req, phys_addr) == 16, "");
  static_assert(offsetof(struct rocm_xio_vram_req, size) == 24, "");

  static_assert(sizeof(struct rocm_xio_register_queue_addr_req) == 40,
                 "rocm_xio_register_queue_addr_req size drift");
  static_assert(sizeof(struct rocm_xio_register_buffer_req) == 40,
                 "rocm_xio_register_buffer_req size drift");
  static_assert(sizeof(struct rocm_xio_mmio_bridge_shadow_req) == 24,
                 "rocm_xio_mmio_bridge_shadow_req size drift");
  static_assert(sizeof(struct rocm_xio_alloc_contig_req) == 32,
                 "rocm_xio_alloc_contig_req size drift");
  static_assert(sizeof(struct rocm_xio_free_contig_req) == 4,
                 "rocm_xio_free_contig_req size drift");

  std::cout << "rocm-xio UAPI layout checks passed\n";
  return 0;
}
