/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef SDMA_EP_H
#define SDMA_EP_H

namespace sdma_ep {

struct SdmaEpConfig {
  bool useHostDst = false; // If true, use pinned host memory as destination
                           // (single GPU, no P2P required)
  bool verifyData = false; // If true, validate destination contains 0xAB
                           // after transfer (host-dst or P2P).
  // HIP device IDs. Use -1 for default (src=0, dst=1 for P2P; both 0 for
  // --to-host).
  int srcDeviceId = -1;
  int dstDeviceId = -1;
  // Per-iteration transfer size in bytes. Must be multiple of 4 (LFSR uses
  // dwords). Default 4096; can be set larger (e.g. MB) via --transfer-size.
  size_t transferSize = 4096;
};

} // namespace sdma_ep

#endif // SDMA_EP_H
