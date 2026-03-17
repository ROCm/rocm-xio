# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# CPU-only unit tests for the test-ep endpoint.

xio_add_test(
  NAME test-ep-config
  SOURCE test-ep-config.hip
  LABELS unit test-ep
  TIMEOUT 30
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/test-ep
)
