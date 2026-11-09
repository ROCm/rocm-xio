# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# vfu-doorbell: a vfio-user doorbell ringee and ringer, plus the guest-side
# tool that drives them. This is a standalone project so that nothing in the
# main rocm-xio build depends on libvfio-user:
#
#   cmake -S tools/vfu-doorbell -B build-vfu-doorbell
#   cmake --build build-vfu-doorbell
#
# The server needs the sbates130272 libvfio-user fork (it calls
# vfu_mmio_write). The guest tool has no dependencies.

cmake_minimum_required(VERSION 3.21)
project(vfu-doorbell LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON) # alloca, nanosleep, getopt_long

find_path(VFIO_USER_INCLUDE_DIR libvfio-user.h
          PATH_SUFFIXES vfio-user
          HINTS /usr/local/include)
find_library(VFIO_USER_LIBRARY NAMES vfio-user
             HINTS /usr/local/lib /usr/local/lib/x86_64-linux-gnu)

add_executable(xio-doorbell xio-doorbell.c)
target_compile_options(xio-doorbell PRIVATE -Wall -Wextra)

if(VFIO_USER_INCLUDE_DIR AND VFIO_USER_LIBRARY)
  add_executable(vfu-doorbell vfu-doorbell.c)
  target_include_directories(vfu-doorbell PRIVATE ${VFIO_USER_INCLUDE_DIR})
  target_link_libraries(vfu-doorbell PRIVATE ${VFIO_USER_LIBRARY} pthread)
  target_compile_options(vfu-doorbell PRIVATE -Wall -Wextra)
else()
  message(STATUS "libvfio-user not found: building xio-doorbell only")
endif()
