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

# BNXT queue sizing math (CPU-only, no GPU or NIC)
xio_add_test(
  NAME test-bnxt-sizing
  SOURCE test-bnxt-sizing.hip
  LABELS unit rdma
  TIMEOUT 30
  INCLUDE_DIRS
    ${CMAKE_SOURCE_DIR}/src/endpoints/rdma-ep
    ${CMAKE_SOURCE_DIR}/src/endpoints/rdma-ep/bnxt
)

# Hardware setup fixture (runs once before all
# hardware tests via FIXTURES_REQUIRED)
if(GDA_BNXT OR GDA_IONIC OR GDA_ERNIC)
  add_test(NAME rdma-hw-setup
    COMMAND sudo
      ${CMAKE_SOURCE_DIR}/scripts/test/setup-rdma-loopback.sh)
  set_tests_properties(rdma-hw-setup PROPERTIES
    FIXTURES_SETUP RDMA_HW
    LABELS "hardware;fixture"
    TIMEOUT 60
    SKIP_RETURN_CODE 77)
endif()

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
  set_tests_properties(test-rdma-loopback PROPERTIES
    FIXTURES_REQUIRED RDMA_HW)

  # Seed-parameterized sweep tests
  foreach(seed RANGE 1 5)
    add_test(
      NAME test-rdma-loopback-seed${seed}
      COMMAND test-rdma-loopback
        --seed ${seed} --size 256)
    set_tests_properties(
      test-rdma-loopback-seed${seed}
      PROPERTIES
        LABELS "hardware;rdma;sweep"
        TIMEOUT 300
        RESOURCE_GROUPS "gpus:1"
        SKIP_RETURN_CODE 77
        FIXTURES_REQUIRED RDMA_HW)
  endforeach()
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
  set_tests_properties(test-rdma-2node PROPERTIES
    FIXTURES_REQUIRED RDMA_HW)
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
  set_tests_properties(test-rdma-ernic-loopback
    PROPERTIES FIXTURES_REQUIRED RDMA_HW)
endif()
