# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Example: iterate the rocm-xio endpoint registry and
# print each endpoint's name, description, and type.
#
# Build against an installed rocm-xio:
#   cmake -S . -B build \
#     -DCMAKE_PREFIX_PATH=<install-prefix>
#   cmake --build build

cmake_minimum_required(VERSION 3.21)
project(endpoint-info LANGUAGES CXX HIP)

find_package(rocm-xio REQUIRED)

add_executable(endpoint-info endpoint-info.hip)
target_link_libraries(endpoint-info PRIVATE
  rocm-xio::rocm-xio)
