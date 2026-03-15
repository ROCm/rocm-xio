# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Unit and hardware tests for the rdma-ep endpoint
# (GDA-based).

# CPU-only unit tests (no GPU or NIC required)
xio_add_test(
  NAME test-rdma-config
  SOURCE test-rdma-config.hip
  LABELS unit rdma
  TIMEOUT 30
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/rdma-ep
)

xio_add_test(
  NAME test-rdma-vendors
  SOURCE test-rdma-vendors.hip
  LABELS unit rdma
  TIMEOUT 30
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/rdma-ep
)

xio_add_test(
  NAME test-rdma-endian
  SOURCE test-rdma-endian.hip
  LABELS unit rdma
  TIMEOUT 30
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/rdma-ep
)

# Hardware integration tests (require NIC + GPU)
if(GDA_BNXT OR GDA_IONIC)
  xio_add_test(
    NAME test-rdma-loopback
    SOURCE test-rdma-loopback.hip
    LABELS hardware rdma
    GPU
    INCLUDE_DIRS
      ${CMAKE_SOURCE_DIR}/src/endpoints/rdma-ep
  )
endif()

if(GDA_BNXT)
  xio_add_test(
    NAME test-rdma-2node
    SOURCE test-rdma-2node.hip
    LABELS hardware rdma
    GPU
    INCLUDE_DIRS
      ${CMAKE_SOURCE_DIR}/src/endpoints/rdma-ep
  )
endif()

if(GDA_ERNIC)
  xio_add_test(
    NAME test-rdma-ernic-loopback
    SOURCE test-rdma-ernic-loopback.hip
    LABELS hardware rdma
    GPU
    INCLUDE_DIRS
      ${CMAKE_SOURCE_DIR}/src/endpoints/rdma-ep
  )
endif()
