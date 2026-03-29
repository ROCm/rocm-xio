# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Minimal example: list all registered rocm-xio endpoints.
#
# Build against an installed rocm-xio:
#   cmake -S . -B build \
#     -DCMAKE_PREFIX_PATH=<install-prefix>
#   cmake --build build

cmake_minimum_required(VERSION 3.21)
project(list-endpoints LANGUAGES CXX HIP)

find_package(rocm-xio REQUIRED)

add_executable(list-endpoints list-endpoints.hip)
target_link_libraries(list-endpoints PRIVATE
  rocm-xio::rocm-xio)
