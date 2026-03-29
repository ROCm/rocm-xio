# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Wrapper script for CTest install-integration tests.
#
# Configures, builds, and optionally runs a standalone
# example project against an installed rocm-xio prefix.
#
# Required -D arguments:
#   SOURCE_DIR  - Absolute path to the example project.
#   BUILD_DIR   - Absolute path for the example build tree.
#   PREFIX      - Absolute path to the rocm-xio install
#                 prefix (passed as CMAKE_PREFIX_PATH).
#
# Optional -D arguments:
#   ROCM_PREFIX - Path to the ROCm installation (added
#                 to CMAKE_PREFIX_PATH so find_dependency
#                 can resolve hip and hsa-runtime64).
#   RUN_BINARY  - Name of the binary to run after building.
#                 Skipped if empty or unset.
#   HIP_COMPILER - Path to the HIP compiler to forward.

cmake_minimum_required(VERSION 3.21)

foreach(var SOURCE_DIR BUILD_DIR PREFIX)
  if(NOT ${var})
    message(FATAL_ERROR
      "${var} must be set (-D${var}=...)")
  endif()
endforeach()

# -- Configure ------------------------------------------
set(_prefix_path "${PREFIX}")
if(ROCM_PREFIX)
  set(_prefix_path "${PREFIX}\;${ROCM_PREFIX}")
endif()

set(_configure_args
  -S ${SOURCE_DIR}
  -B ${BUILD_DIR}
  "-DCMAKE_PREFIX_PATH=${_prefix_path}"
)

if(HIP_COMPILER)
  list(APPEND _configure_args
    -DCMAKE_HIP_COMPILER=${HIP_COMPILER})
endif()

message(STATUS "Configuring: ${SOURCE_DIR}")
execute_process(
  COMMAND ${CMAKE_COMMAND} ${_configure_args}
  RESULT_VARIABLE _rc
)
if(_rc)
  message(FATAL_ERROR
    "Configure failed (exit ${_rc})")
endif()

# -- Build ----------------------------------------------
message(STATUS "Building: ${BUILD_DIR}")
execute_process(
  COMMAND ${CMAKE_COMMAND} --build ${BUILD_DIR}
  RESULT_VARIABLE _rc
)
if(_rc)
  message(FATAL_ERROR
    "Build failed (exit ${_rc})")
endif()

# -- Run (optional) -------------------------------------
if(RUN_BINARY)
  set(_bin ${BUILD_DIR}/${RUN_BINARY})
  if(NOT EXISTS ${_bin})
    message(FATAL_ERROR
      "Binary not found: ${_bin}")
  endif()
  message(STATUS "Running: ${_bin}")
  execute_process(
    COMMAND ${_bin}
    RESULT_VARIABLE _rc
  )
  if(_rc)
    message(FATAL_ERROR
      "Run failed (exit ${_rc})")
  endif()
endif()

message(STATUS "Install example test passed.")
