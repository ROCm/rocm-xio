# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Smoke test: verify that find_package(rocm-xio) locates
# the installed package and resolves its dependencies.
#
# This project has no source files; it validates the
# install layout at configure time.
#
# Usage:
#   cmake -S . -B build \
#     -DCMAKE_PREFIX_PATH=<install-prefix>

cmake_minimum_required(VERSION 3.21)
project(find-package-test LANGUAGES CXX HIP)

find_package(rocm-xio REQUIRED)

message(STATUS
  "Found rocm-xio ${ROCM_XIO_VERSION}")
message(STATUS
  "  Include dirs: ${ROCM_XIO_INCLUDE_DIRS}")
message(STATUS
  "  Libraries:    ${ROCM_XIO_LIBRARIES}")

if(NOT ROCM_XIO_VERSION)
  message(FATAL_ERROR
    "ROCM_XIO_VERSION is empty after "
    "find_package(rocm-xio).")
endif()
