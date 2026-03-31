# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Coherence stress tests -- exercises GPU-to-host memory
# ordering patterns used by doorbell-driven endpoints
# (NVMe, RDMA).  Requires a HIP-capable GPU.

xio_add_test(
  NAME test-doorbell-coherence
  SOURCE test-doorbell-coherence.hip
  LABELS system stress coherence
  TIMEOUT 120
  GPU
)
