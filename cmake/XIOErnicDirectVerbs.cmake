# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# XIOErnicDirectVerbs.cmake
#
# Builds rdma-core with the ROCm ERNIC provider and
# optionally builds the rocm_ernic.ko kernel module
# via DKMS with DV extensions.
#
# Included from the top-level CMakeLists.txt when
# GDA_ERNIC=ON.

include(ExternalProject)

# -----------------------------------------------------------
# Configurable cache variables
# -----------------------------------------------------------

option(ERNIC_DV_BUILD_RDMA_CORE
  "Build rdma-core with rocm-ernic DV provider" ON)

option(ERNIC_DV_BUILD_KMOD
  "Setup rocm_ernic.ko DKMS module with DV" OFF)

set(ERNIC_PROJECT_DIR
  "${CMAKE_SOURCE_DIR}/../rocm-ernic"
  CACHE PATH
  "Path to the rocm-ernic project directory")

# -----------------------------------------------------------
# Derived paths
# -----------------------------------------------------------

set(ERNIC_DV_DEPS_DIR
  "${CMAKE_BINARY_DIR}/_deps/ernic-dv")
set(ERNIC_DV_RDMA_CORE_SRC
  "${ERNIC_DV_DEPS_DIR}/rdma-core-src")
set(ERNIC_DV_RDMA_CORE_BUILD
  "${ERNIC_DV_DEPS_DIR}/rdma-core-build")
set(ERNIC_DV_RDMA_CORE_INSTALL
  "${ERNIC_DV_DEPS_DIR}/rdma-core-install")

set(ERNIC_RDMA_CORE_BUILD_SCRIPT
  "${CMAKE_SOURCE_DIR}/scripts/build/build-ernic-dv-rdma-core.sh")
set(ERNIC_DKMS_SETUP_SCRIPT
  "${CMAKE_SOURCE_DIR}/kernel/rocm-ernic/setup-rocm-ernic-dv-dkms.sh")

# -----------------------------------------------------------
# Part 1: rdma-core with ROCm ERNIC provider
# -----------------------------------------------------------

if(ERNIC_DV_BUILD_RDMA_CORE)
  include(ProcessorCount)
  ProcessorCount(NPROC)
  if(NPROC EQUAL 0)
    set(NPROC 4)
  endif()

  message(STATUS
    "ernic DV: will build rdma-core with"
    " rocm_ernic provider")

  set(_ERNIC_RDMA_CORE_ARGS
    ${ERNIC_DV_RDMA_CORE_SRC}
    ${ERNIC_DV_RDMA_CORE_BUILD}
    ${ERNIC_DV_RDMA_CORE_INSTALL}
    ${ERNIC_PROJECT_DIR}
    ${NPROC}
  )

  add_custom_target(build-ernic-dv-rdma-core
    COMMAND ${ERNIC_RDMA_CORE_BUILD_SCRIPT}
      ${_ERNIC_RDMA_CORE_ARGS} --build-only
    COMMENT
      "Building rdma-core with ernic DV (no install)"
    VERBATIM
  )

  add_custom_target(install-ernic-dv-rdma-core
    COMMAND ${ERNIC_RDMA_CORE_BUILD_SCRIPT}
      ${_ERNIC_RDMA_CORE_ARGS}
    COMMENT
      "Building and installing rdma-core with"
      " ernic DV"
    VERBATIM
  )

  set(ERNIC_DV_RDMA_CORE_LIB_DIR
    "${ERNIC_DV_RDMA_CORE_INSTALL}/lib"
    CACHE PATH
    "rdma-core ernic DV library directory" FORCE)
  set(ERNIC_DV_RDMA_CORE_INCLUDE_DIR
    "${ERNIC_DV_RDMA_CORE_INSTALL}/include"
    CACHE PATH
    "rdma-core ernic DV include directory" FORCE)

  message(STATUS
    "ernic DV: rdma-core will install to"
    " ${ERNIC_DV_RDMA_CORE_INSTALL}")
endif()

# -----------------------------------------------------------
# Part 2: rocm_ernic.ko DKMS module (optional)
# -----------------------------------------------------------

if(ERNIC_DV_BUILD_KMOD)
  message(STATUS
    "ernic DV: DKMS kmod targets enabled")

  add_custom_target(build-ernic-dv-dkms
    COMMAND ${ERNIC_DKMS_SETUP_SCRIPT}
      --ernic-dir ${ERNIC_PROJECT_DIR}
      --build-only
    COMMENT
      "Building rocm_ernic DKMS module (no install)"
    VERBATIM
  )

  add_custom_target(install-ernic-dv-dkms
    COMMAND ${ERNIC_DKMS_SETUP_SCRIPT}
      --ernic-dir ${ERNIC_PROJECT_DIR}
    COMMENT
      "Building and installing rocm_ernic DKMS"
    VERBATIM
  )

  add_custom_target(remove-ernic-dv-dkms
    COMMAND ${ERNIC_DKMS_SETUP_SCRIPT}
      --uninstall
    COMMENT
      "Removing rocm_ernic DKMS module"
    VERBATIM
  )
endif()
