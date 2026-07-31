# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Example: multi-GPU shader-initiated SDMA bandwidth benchmark.
#
# Build against an installed rocm-xio:
#   cmake -S . -B build \
#     -DCMAKE_PREFIX_PATH=<install-prefix>
#   cmake --build build

cmake_minimum_required(VERSION 3.21)
project(sdma-ep-bw LANGUAGES CXX HIP)

find_package(rocm-xio REQUIRED)
find_package(hsa-runtime64 CONFIG REQUIRED)
find_package(CLI11 CONFIG REQUIRED)

add_executable(sdma-ep-bw
  sdma-ep-bw.cpp
  sdma_bw_kernel.hip)
target_link_libraries(sdma-ep-bw PRIVATE
  rocm-xio::rocm-xio
  hsa-runtime64::hsa-runtime64
  CLI11::CLI11)
if(NOT ROCM_XIO_SHARED_LIBS)
  target_link_options(sdma-ep-bw PRIVATE -fgpu-rdc)
endif()
