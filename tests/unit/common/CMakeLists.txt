# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# CPU-only unit tests for common library code.

xio_add_test(
  NAME test-data-pattern
  SOURCE test-data-pattern.hip
  LABELS unit common
  TIMEOUT 30
)

xio_add_test(
  NAME test-rdma-topology
  SOURCE test-rdma-topology.hip
  LABELS unit common
  TIMEOUT 30
)

xio_add_test(
  NAME test-extract-endpoint
  SOURCE test-extract-endpoint.hip
  LABELS unit common
  TIMEOUT 30
)

xio_add_test(
  NAME test-rocm-xio-uapi-layout
  SOURCE test-rocm-xio-uapi-layout.hip
  LABELS unit common
  TIMEOUT 30
)

xio_add_test(
  NAME test-endpoint-registry
  SOURCE test-endpoint-registry.hip
  LABELS unit common
  TIMEOUT 30
)
