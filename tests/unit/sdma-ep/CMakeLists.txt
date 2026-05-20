# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# CPU-only unit tests for the sdma-ep endpoint. Device-side packet builders
# remain in tests/system since they require a HIP-capable GPU.

xio_add_test(
  NAME test-sdma-config
  SOURCE test-sdma-config.hip
  LABELS unit sdma
  TIMEOUT 30
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/sdma-ep
)

xio_add_test(
  NAME test-sdma-packet-layout
  SOURCE test-sdma-packet-layout.hip
  LABELS unit sdma
  TIMEOUT 30
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/sdma-ep
)
