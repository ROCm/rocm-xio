# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# System tests for the sdma-ep endpoint. They need two GPUs with peer access
# and /dev/kfd, and skip (exit code 77) when those are missing.

xio_add_test(
  NAME test-sdma-host-channels
  SOURCE test-sdma-host-channels.hip
  LABELS system sdma
  TIMEOUT 60
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/sdma-ep
  GPU
)
