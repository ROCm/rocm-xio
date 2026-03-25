# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Top-level test coordinator for rocm-xio.
#
# Label convention (filter with ctest -L):
#   unit     - CPU-only, no GPU or NIC required
#   system   - Requires a HIP-capable GPU
#   hardware - Requires specific NIC/device hardware
#   stress   - Long-running concurrency tests
#   rdma     - RDMA-specific tests

add_subdirectory(unit)
add_subdirectory(system)
