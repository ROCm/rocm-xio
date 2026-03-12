# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Unit tests for the rdma-ep endpoint (GDA-based)

set(INCLUDE_DIR ${CMAKE_SOURCE_DIR}/src/include)
set(ENDPOINTS_DIR ${CMAKE_SOURCE_DIR}/src/endpoints)
set(COMMON_DIR ${CMAKE_SOURCE_DIR}/src/common)

function(setup_rdma_test TEST_NAME SOURCE_FILE)
  add_executable(${TEST_NAME} ${SOURCE_FILE})

  set_target_properties(${TEST_NAME} PROPERTIES LANGUAGE HIP)

  target_compile_options(${TEST_NAME} PRIVATE
    -std=c++17
    -Wall
    -Wextra
    -Wno-unused-parameter
    -fgpu-rdc
  )

  target_include_directories(${TEST_NAME} PRIVATE
    ${INCLUDE_DIR}
    ${ENDPOINTS_DIR}/rdma-ep
    ${COMMON_DIR}
  )

  target_link_libraries(${TEST_NAME} PRIVATE
    rocm-xio
    hip::host
    hip::device
    hsa-runtime64::hsa-runtime64
    dl
  )

  target_link_options(${TEST_NAME} PRIVATE -fgpu-rdc)

  # Propagate GDA vendor defines to test executables
  if(GDA_BNXT)
    target_compile_definitions(${TEST_NAME} PRIVATE GDA_BNXT)
  endif()
  if(GDA_MLX5)
    target_compile_definitions(${TEST_NAME} PRIVATE GDA_MLX5)
  endif()
  if(GDA_IONIC)
    target_compile_definitions(${TEST_NAME} PRIVATE GDA_IONIC)
  endif()

  add_test(NAME ${TEST_NAME} COMMAND ${TEST_NAME})
endfunction()

# New GDA-based tests
setup_rdma_test(test-rdma-config test-rdma-config.hip)
setup_rdma_test(test-rdma-vendors test-rdma-vendors.hip)
setup_rdma_test(test-rdma-endian test-rdma-endian.hip)

# Hardware integration tests (require BNXT NIC)
if(GDA_BNXT)
  setup_rdma_test(test-rdma-bnxt-loopback test-rdma-bnxt-loopback.hip)
  setup_rdma_test(test-rdma-2node test-rdma-2node.hip)
endif()
