# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Top-level test coordinator for rocm-xio.
#
# Label convention (filter with ctest -L / ctest -LE):
#   unit        - CPU-only, no GPU or NIC required
#   system      - Requires a HIP-capable GPU
#   hardware    - Requires specific NIC/device hardware
#   stress      - Long-running concurrency tests
#   rdma        - RDMA-specific tests
#   integration - Install + build examples against prefix
#
# CI (no device / no GPU): ctest --label-exclude 'hardware|system'
# (Do not pass two -LE flags: CMake ANDs them, so each single-label test would
# still run.)

add_subdirectory(unit)
add_subdirectory(system)
add_subdirectory(integration)
