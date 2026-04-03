# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# System test aggregator -- tests here require a
# HIP-capable GPU and are labelled "system".

add_subdirectory(test-ep)
add_subdirectory(coherence)
add_subdirectory(nvme-ep)

if(GDA_BNXT OR GDA_MLX5 OR GDA_IONIC)
  add_subdirectory(rdma-ep)
endif()
