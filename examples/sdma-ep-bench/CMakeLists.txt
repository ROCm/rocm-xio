# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Examples: shader-initiated SDMA bandwidth and packet-rate benchmarks.
#
# Build against an installed rocm-xio:
#   cmake -S . -B build \
#     -DCMAKE_PREFIX_PATH=<install-prefix>
#   cmake --build build

cmake_minimum_required(VERSION 3.21)
project(sdma-ep-bench LANGUAGES CXX HIP)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

find_package(rocm-xio REQUIRED)
find_package(hsa-runtime64 CONFIG REQUIRED)
find_package(CLI11 CONFIG REQUIRED)

set_source_files_properties(
  sdma-ep-bw.cpp sdma-ep-rate.cpp sdma-ep-latency.cpp PROPERTIES LANGUAGE HIP)

add_executable(sdma-ep-bw
  sdma-ep-bw.cpp
  sdma_bw_kernel.hip)
function(link_sdma_benchmark target)
  target_link_libraries(${target} PRIVATE
    rocm-xio::rocm-xio
    hsa-runtime64::hsa-runtime64
    CLI11::CLI11)
  if(NOT ROCM_XIO_SHARED_LIBS)
    target_link_options(${target} PRIVATE -fgpu-rdc)
  endif()
endfunction()

link_sdma_benchmark(sdma-ep-bw)

add_executable(sdma-ep-rate
  sdma-ep-rate.cpp
  sdma_rate_kernel.hip)
link_sdma_benchmark(sdma-ep-rate)

add_executable(sdma-ep-latency
  sdma-ep-latency.cpp
  sdma_latency_kernel.hip)
link_sdma_benchmark(sdma-ep-latency)
