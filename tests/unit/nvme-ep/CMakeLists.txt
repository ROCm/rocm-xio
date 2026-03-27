# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# CPU-only unit tests for the nvme-ep endpoint.

xio_add_test(
  NAME test-nvme-config
  SOURCE test-nvme-config.hip
  LABELS unit nvme
  TIMEOUT 30
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/nvme-ep
)

xio_add_test(
  NAME test-nvme-helpers
  SOURCE test-nvme-helpers.hip
  LABELS unit nvme
  TIMEOUT 30
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/nvme-ep
)

# Hardware integration tests (require real NVMe device)
xio_add_test(
  NAME test-nvme-hardware
  SOURCE test-nvme-hardware.hip
  LABELS hardware nvme
  TIMEOUT 60
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/nvme-ep
)
set_tests_properties(test-nvme-hardware PROPERTIES
  SKIP_RETURN_CODE 77)
