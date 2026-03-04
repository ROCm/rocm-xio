# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Unit tests for the rdma-ep endpoint
# These tests are GPU-based HIP tests that perform RDMA operations from the GPU

# Get directory paths from parent
set(INCLUDE_DIR ${CMAKE_SOURCE_DIR}/src/include)
set(ENDPOINTS_DIR ${CMAKE_SOURCE_DIR}/src/endpoints)

# Function to set up a GPU-based RDMA test executable
function(setup_rdma_test TEST_NAME SOURCE_FILE NEEDS_VENDOR_DIRS)
  # Create executable
  add_executable(${TEST_NAME} ${SOURCE_FILE})

  # Set language to HIP
  set_target_properties(${TEST_NAME} PROPERTIES LANGUAGE HIP)

  # Set compile options
  target_compile_options(${TEST_NAME} PRIVATE
    -std=c++17
    -Wall
    -Wextra
  )

  # Set include directories
  set(INCLUDE_DIRS
    ${INCLUDE_DIR}
    ${ENDPOINTS_DIR}/rdma-ep
  )

  if(NEEDS_VENDOR_DIRS)
    list(APPEND INCLUDE_DIRS
      ${ENDPOINTS_DIR}/rdma-ep/mlx
      ${ENDPOINTS_DIR}/rdma-ep/bnxt
      ${ENDPOINTS_DIR}/rdma-ep/ionic
      ${ENDPOINTS_DIR}/rdma-ep/rocm-ernic
    )
  endif()

  target_include_directories(${TEST_NAME} PRIVATE ${INCLUDE_DIRS})

  # Link libraries
  target_link_libraries(${TEST_NAME} PRIVATE
    rocm-xio
    hip::host
    hip::device
  )

  # If ASan is enabled, ensure test executable also links ASan runtime
  if(ENABLE_ASAN)
    target_link_options(${TEST_NAME} PRIVATE -fsanitize=address)
    target_compile_options(${TEST_NAME} PRIVATE
      -Wno-option-ignored
    )
  endif()

  # Add to CTest
  add_test(NAME ${TEST_NAME} COMMAND ${TEST_NAME})
endfunction()

# Set up all test executables
setup_rdma_test(test-rdma-wqe-cqe test-rdma-wqe-cqe.hip TRUE)
setup_rdma_test(test-rdma-vendors test-rdma-vendors.hip TRUE)
setup_rdma_test(test-rdma-queue-ops test-rdma-queue-ops.hip FALSE)
setup_rdma_test(test-rdma-cqe-generation test-rdma-cqe-generation.hip TRUE)
setup_rdma_test(test-rdma-config test-rdma-config.hip FALSE)
