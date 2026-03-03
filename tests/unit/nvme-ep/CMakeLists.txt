# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Unit tests for the nvme-ep endpoint
# These tests are GPU-based HIP tests that perform NVMe operations from the GPU

# Get directory paths from parent
set(INCLUDE_DIR ${CMAKE_SOURCE_DIR}/src/include)
set(ENDPOINTS_DIR ${CMAKE_SOURCE_DIR}/src/endpoints)

# Function to set up a GPU-based NVMe test executable
function(setup_nvme_test TEST_NAME SOURCE_FILE)
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
    ${ENDPOINTS_DIR}/nvme-ep
  )

  target_include_directories(${TEST_NAME} PRIVATE ${INCLUDE_DIRS})

  # Link libraries
  target_link_libraries(${TEST_NAME} PRIVATE
    rocm-xio
    hip::host
    hip::device
    hsa-runtime64::hsa-runtime64
  )

  # Add to CTest
  # Note: This test requires --controller argument, so CTest registration
  # is just for discovery. Run manually with: ./test-nvme-ep-simple-io --controller /dev/nvme0
  add_test(NAME ${TEST_NAME} COMMAND ${TEST_NAME} --help)
  set_tests_properties(${TEST_NAME} PROPERTIES
    WILL_FAIL TRUE
    LABELS "manual"
  )
endfunction()

# Set up test executable
setup_nvme_test(test-nvme-ep-simple-io test-nvme-ep-simple-io.hip)
