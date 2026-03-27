# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Unit test aggregator -- all subdirectories here
# contain CPU-only tests labelled "unit".

add_subdirectory(common)
add_subdirectory(test-ep)
add_subdirectory(rdma-ep)
add_subdirectory(nvme-ep)
