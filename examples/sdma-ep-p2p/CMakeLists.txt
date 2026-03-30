# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Example: GPU-initiated peer-to-peer DMA transfer via
# the SDMA endpoint.
#
# Requires two GPUs with XGMI/Infinity Fabric P2P access.
#
# Build against an installed rocm-xio:
#   cmake -S . -B build \
#     -DCMAKE_PREFIX_PATH=<install-prefix>
#   cmake --build build

cmake_minimum_required(VERSION 3.21)
project(sdma-ep-p2p LANGUAGES CXX HIP)

find_package(rocm-xio REQUIRED)
find_package(hsa-runtime64 CONFIG REQUIRED)

add_executable(sdma-ep-p2p sdma-ep-p2p.hip)
target_link_libraries(sdma-ep-p2p PRIVATE
  rocm-xio::rocm-xio
  hsa-runtime64::hsa-runtime64)
target_link_options(sdma-ep-p2p PRIVATE -fgpu-rdc)
