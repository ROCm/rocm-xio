# Copyright (c) 2026 IBM Corporation
#
# SPDX-License-Identifier: MIT

# Standalone NVMe Key-Value validation tools for the rocm-xio nvme-ep endpoint.
#
# These are host-side C programs with NO rocm-xio / HIP dependency:
#   - kv_cpu_probe : GPU-free KV Store/Retrieve via the /dev/nvme0 passthrough
#                    ioctl (validates KV controller enumeration + SQE encoding).
#   - create_rbd   : RBD test-image fixture for the block path (needs Ceph's
#                    librados/librbd).
#
# Build standalone:
#   cmake -S examples/nvme-kv -B build
#   cmake --build build

cmake_minimum_required(VERSION 3.21)
project(nvme-kv-examples LANGUAGES C)

# kv_cpu_probe only needs libc and the kernel NVMe ioctl uapi header, so it
# always builds. Running it needs a KV NVMe controller, hence CI builds it
# compile-only (see tests/integration/CMakeLists.txt).
add_executable(kv_cpu_probe kv_cpu_probe.c)

# create_rbd needs Ceph's librados/librbd. Build it only when those are present
# so the project still configures cleanly on hosts without Ceph installed.
find_path(RADOS_INCLUDE_DIR rados/librados.h)
find_path(RBD_INCLUDE_DIR rbd/librbd.h)
find_library(RADOS_LIBRARY rados)
find_library(RBD_LIBRARY rbd)

if(RADOS_INCLUDE_DIR AND RBD_INCLUDE_DIR AND RADOS_LIBRARY AND RBD_LIBRARY)
  add_executable(create_rbd create_rbd.c)
  target_include_directories(create_rbd PRIVATE
    ${RADOS_INCLUDE_DIR} ${RBD_INCLUDE_DIR})
  target_link_libraries(create_rbd PRIVATE
    ${RBD_LIBRARY} ${RADOS_LIBRARY})
  message(STATUS "nvme-kv-examples: librados/librbd found; building create_rbd")
else()
  message(STATUS
    "nvme-kv-examples: librados/librbd not found; skipping create_rbd")
endif()
