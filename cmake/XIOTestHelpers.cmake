# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Reusable test helper functions for rocm-xio CTest
# integration, modelled after hipFile's
# ais_gtest_discover_tests() pattern.

set(XIO_INCLUDE_DIR ${CMAKE_SOURCE_DIR}/src/include)
set(XIO_ENDPOINTS_DIR ${CMAKE_SOURCE_DIR}/src/endpoints)
set(XIO_COMMON_DIR ${CMAKE_SOURCE_DIR}/src/common)

# xio_add_test()
#
# Add a HIP test executable registered with CTest.
#
# Usage:
#   xio_add_test(
#     NAME test-rdma-config
#     SOURCE test-rdma-config.hip
#     LABELS unit rdma
#     TIMEOUT 30
#     INCLUDE_DIRS dir1 dir2
#     EXTRA_ARGS --provider bnxt
#   )
#
# NAME       - Test target and CTest name.
# SOURCE     - Source file to compile.
# LABELS     - CTest labels for filtering
#              (unit, system, hardware, stress, rdma).
# TIMEOUT    - CTest timeout in seconds
#              (defaults based on label category).
# INCLUDE_DIRS - Extra include directories.
# EXTRA_ARGS - Extra arguments passed to the test command.
# GPU        - If set, adds RESOURCE_GROUPS for GPU.
function(xio_add_test)
  cmake_parse_arguments(
    XIO_TEST
    "GPU"
    "NAME;SOURCE;TIMEOUT"
    "LABELS;EXTRA_ARGS;INCLUDE_DIRS"
    ${ARGN}
  )

  if(NOT XIO_TEST_NAME)
    message(FATAL_ERROR "xio_add_test: NAME is required")
  endif()
  if(NOT XIO_TEST_SOURCE)
    message(FATAL_ERROR
      "xio_add_test: SOURCE is required")
  endif()

  add_executable(${XIO_TEST_NAME} ${XIO_TEST_SOURCE})

  set_target_properties(${XIO_TEST_NAME}
    PROPERTIES LINKER_LANGUAGE HIP)

  target_compile_options(${XIO_TEST_NAME} PRIVATE
    -std=c++17
    -Wall
    -Wextra
    -Wno-unused-parameter
    -fgpu-rdc
  )

  target_include_directories(${XIO_TEST_NAME} PRIVATE
    ${XIO_INCLUDE_DIR}
    ${XIO_COMMON_DIR}
  )

  if(XIO_TEST_INCLUDE_DIRS)
    target_include_directories(${XIO_TEST_NAME} PRIVATE
      ${XIO_TEST_INCLUDE_DIRS})
  endif()

  target_link_libraries(${XIO_TEST_NAME} PRIVATE
    rocm-xio
    hip::host
    hip::device
    hsa-runtime64::hsa-runtime64
    dl
  )

  target_link_options(${XIO_TEST_NAME} PRIVATE -fgpu-rdc)

  # Propagate GDA vendor defines automatically
  foreach(vendor BNXT MLX5 IONIC ERNIC)
    if(GDA_${vendor})
      target_compile_definitions(${XIO_TEST_NAME}
        PRIVATE GDA_${vendor})
    endif()
  endforeach()

  # Register test with CTest
  if(XIO_TEST_EXTRA_ARGS)
    add_test(
      NAME ${XIO_TEST_NAME}
      COMMAND ${XIO_TEST_NAME} ${XIO_TEST_EXTRA_ARGS})
  else()
    add_test(
      NAME ${XIO_TEST_NAME}
      COMMAND ${XIO_TEST_NAME})
  endif()

  # Apply labels
  if(XIO_TEST_LABELS)
    set_tests_properties(${XIO_TEST_NAME}
      PROPERTIES LABELS "${XIO_TEST_LABELS}")
  endif()

  # Apply timeout (with sensible defaults by label)
  if(XIO_TEST_TIMEOUT)
    set_tests_properties(${XIO_TEST_NAME}
      PROPERTIES TIMEOUT ${XIO_TEST_TIMEOUT})
  else()
    list(FIND XIO_TEST_LABELS "unit" _is_unit)
    list(FIND XIO_TEST_LABELS "hardware" _is_hw)
    list(FIND XIO_TEST_LABELS "stress" _is_stress)
    if(NOT _is_stress EQUAL -1)
      set_tests_properties(${XIO_TEST_NAME}
        PROPERTIES TIMEOUT 600)
    elseif(NOT _is_hw EQUAL -1)
      set_tests_properties(${XIO_TEST_NAME}
        PROPERTIES TIMEOUT 300)
    elseif(NOT _is_unit EQUAL -1)
      set_tests_properties(${XIO_TEST_NAME}
        PROPERTIES TIMEOUT 60)
    else()
      set_tests_properties(${XIO_TEST_NAME}
        PROPERTIES TIMEOUT 120)
    endif()
  endif()

  # GPU resource groups for CTest resource allocation
  if(XIO_TEST_GPU)
    set_tests_properties(${XIO_TEST_NAME}
      PROPERTIES
        RESOURCE_GROUPS "gpus:1"
        SKIP_RETURN_CODE 77
        SKIP_REGULAR_EXPRESSION "SKIP:")
  endif()

  # rdma-core library path for hardware tests
  set(_rdma_lib
    "${CMAKE_BINARY_DIR}/_deps/rdma-core/install/lib")
  if(XIO_TEST_GPU AND
     (GDA_BNXT OR GDA_IONIC OR GDA_ERNIC))
    set_tests_properties(${XIO_TEST_NAME}
      PROPERTIES ENVIRONMENT
      "LD_LIBRARY_PATH=${_rdma_lib}:$ENV{LD_LIBRARY_PATH}")
  endif()
endfunction()

# xio_add_script_test()
#
# Register a shell script as a CTest entry.
#
# Usage:
#   xio_add_script_test(
#     NAME nvme-verify-seq-host-mem
#     SCRIPT ${CMAKE_SOURCE_DIR}/tests/system/nvme-ep/run-nvme-script-test.sh
#     LABELS hardware nvme verify
#     TIMEOUT 120
#     ARGS path/to/real-script.sh /dev/nvme0
#     ENVIRONMENT "MEMORY_MODE=0" "WRITE_IO=4"
#   )
#
# NAME        - CTest name.
# SCRIPT      - Path to the shell script to run.
# LABELS      - CTest labels for filtering.
# TIMEOUT     - CTest timeout in seconds (default 120).
# ARGS        - Arguments passed to the script.
# ENVIRONMENT - Environment variables for the test.
function(xio_add_script_test)
  cmake_parse_arguments(XIO_STEST ""
    "NAME;SCRIPT;TIMEOUT"
    "LABELS;ARGS;ENVIRONMENT" ${ARGN})

  if(NOT XIO_STEST_NAME)
    message(FATAL_ERROR
      "xio_add_script_test: NAME is required")
  endif()
  if(NOT XIO_STEST_SCRIPT)
    message(FATAL_ERROR
      "xio_add_script_test: SCRIPT is required")
  endif()

  add_test(
    NAME ${XIO_STEST_NAME}
    COMMAND bash ${XIO_STEST_SCRIPT} ${XIO_STEST_ARGS}
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})

  if(XIO_STEST_LABELS)
    set_tests_properties(${XIO_STEST_NAME}
      PROPERTIES LABELS "${XIO_STEST_LABELS}")
  endif()

  if(XIO_STEST_TIMEOUT)
    set_tests_properties(${XIO_STEST_NAME}
      PROPERTIES TIMEOUT ${XIO_STEST_TIMEOUT})
  else()
    set_tests_properties(${XIO_STEST_NAME}
      PROPERTIES TIMEOUT 120)
  endif()

  set_tests_properties(${XIO_STEST_NAME}
    PROPERTIES
      SKIP_RETURN_CODE 77
      SKIP_REGULAR_EXPRESSION "SKIP:")

  if(XIO_STEST_ENVIRONMENT)
    set_tests_properties(${XIO_STEST_NAME}
      PROPERTIES
        ENVIRONMENT "${XIO_STEST_ENVIRONMENT}")
  endif()
endfunction()
