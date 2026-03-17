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
