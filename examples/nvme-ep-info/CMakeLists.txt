# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Example: query NVMe controller properties using the
# rocm-xio nvme-ep host-side API.
#
# Requires an NVMe device and root access.
#
# Build against an installed rocm-xio:
#   cmake -S . -B build \
#     -DCMAKE_PREFIX_PATH=<install-prefix>
#   cmake --build build

cmake_minimum_required(VERSION 3.21)
project(nvme-ep-info LANGUAGES CXX HIP)

find_package(rocm-xio REQUIRED)
find_package(hsa-runtime64 CONFIG REQUIRED)

add_executable(nvme-ep-info nvme-ep-info.hip)
target_link_libraries(nvme-ep-info PRIVATE
  rocm-xio::rocm-xio
  hsa-runtime64::hsa-runtime64)
if(NOT ROCM_XIO_SHARED_LIBS)
  target_link_options(nvme-ep-info PRIVATE -fgpu-rdc)
endif()
