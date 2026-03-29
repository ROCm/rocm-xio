# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# CTest helpers for install-integration tests.
#
# These tests install rocm-xio to a temporary prefix and
# then configure, build, and run standalone example projects
# against the installed library.

set(XIO_INSTALL_TEST_PREFIX
  "${CMAKE_BINARY_DIR}/_install_test"
  CACHE PATH
  "Prefix for install-integration tests")

set(XIO_INSTALL_TEST_BUILDS
  "${CMAKE_BINARY_DIR}/_install_test_builds"
  CACHE PATH
  "Build tree root for install-integration examples")

set(XIO_RUN_INSTALL_EXAMPLE
  "${CMAKE_SOURCE_DIR}/cmake/run-install-example.cmake"
  CACHE FILEPATH
  "Path to the run-install-example.cmake script")

# Derive the ROCm prefix so examples can resolve
# find_dependency(hip) and find_dependency(hsa-runtime64)
# inside the installed rocm-xio-config.cmake.
if(hip_DIR)
  cmake_path(GET hip_DIR PARENT_PATH _hip_cmake)
  cmake_path(GET _hip_cmake PARENT_PATH _hip_lib)
  cmake_path(GET _hip_lib PARENT_PATH
    XIO_ROCM_PREFIX)
else()
  set(XIO_ROCM_PREFIX "/opt/rocm")
endif()

# xio_install_test_fixture()
#
# Register the CTest fixture that installs rocm-xio into
# XIO_INSTALL_TEST_PREFIX.  All per-example tests declare
# FIXTURES_REQUIRED on ROCM_XIO_INSTALL so CTest orders
# them correctly.
function(xio_install_test_fixture)
  add_test(
    NAME install-rocm-xio
    COMMAND ${CMAKE_COMMAND}
      --install ${CMAKE_BINARY_DIR}
      --prefix ${XIO_INSTALL_TEST_PREFIX}
  )
  set_tests_properties(install-rocm-xio PROPERTIES
    FIXTURES_SETUP ROCM_XIO_INSTALL
    LABELS "integration"
    TIMEOUT 120
  )
endfunction()

# xio_add_install_test()
#
# Register a CTest test that builds (and optionally runs) a
# standalone example project against the installed prefix.
#
# Usage:
#   xio_add_install_test(
#     NAME list-endpoints
#     SOURCE_DIR ${CMAKE_SOURCE_DIR}/examples/list-endpoints
#     [RUN]
#   )
#
# For script-mode (cmake -P) tests:
#   xio_add_install_test(
#     NAME find-package
#     SCRIPT path/to/find-package.cmake
#   )
#
# NAME       - CTest name (prefixed with "example-").
# SOURCE_DIR - Path to the standalone CMake project.
# SCRIPT     - Path to a cmake -P script (mutually
#              exclusive with SOURCE_DIR).
# RUN        - If set, run the built binary after building
#              (binary name assumed == NAME).
function(xio_add_install_test)
  cmake_parse_arguments(
    XIO_IT
    "RUN"
    "NAME;SOURCE_DIR;SCRIPT"
    ""
    ${ARGN}
  )

  if(NOT XIO_IT_NAME)
    message(FATAL_ERROR
      "xio_add_install_test: NAME is required")
  endif()

  set(_test_name "example-${XIO_IT_NAME}")

  if(XIO_IT_SCRIPT)
    # Script-mode test: cmake -P <script>
    add_test(
      NAME ${_test_name}
      COMMAND ${CMAKE_COMMAND}
        -DCMAKE_PREFIX_PATH=${XIO_INSTALL_TEST_PREFIX}
        -P ${XIO_IT_SCRIPT}
    )
  elseif(XIO_IT_SOURCE_DIR)
    set(_build_dir
      "${XIO_INSTALL_TEST_BUILDS}/${XIO_IT_NAME}")

    set(_test_args
      -DSOURCE_DIR=${XIO_IT_SOURCE_DIR}
      -DBUILD_DIR=${_build_dir}
      -DPREFIX=${XIO_INSTALL_TEST_PREFIX}
      -DROCM_PREFIX=${XIO_ROCM_PREFIX}
    )

    if(CMAKE_HIP_COMPILER)
      list(APPEND _test_args
        -DHIP_COMPILER=${CMAKE_HIP_COMPILER})
    endif()

    if(XIO_IT_RUN)
      list(APPEND _test_args
        -DRUN_BINARY=${XIO_IT_NAME})
    endif()

    add_test(
      NAME ${_test_name}
      COMMAND ${CMAKE_COMMAND}
        ${_test_args}
        -P ${XIO_RUN_INSTALL_EXAMPLE}
    )
  else()
    message(FATAL_ERROR
      "xio_add_install_test: either SOURCE_DIR "
      "or SCRIPT is required")
  endif()

  set_tests_properties(${_test_name} PROPERTIES
    FIXTURES_REQUIRED ROCM_XIO_INSTALL
    LABELS "integration"
    TIMEOUT 120
  )
endfunction()
