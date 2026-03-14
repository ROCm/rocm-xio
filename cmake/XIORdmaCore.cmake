# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# XIORdmaCore.cmake
#
# Unified rdma-core build with vendor DV patches.
# Replaces XIOBnxtDirectVerbs.cmake (rdma-core
# portion) and XIOErnicDirectVerbs.cmake (rdma-core
# portion). Kernel DKMS modules remain separate.
#
# Included from the top-level CMakeLists.txt when
# any GDA vendor is enabled.

include(ExternalProject)

# -----------------------------------------------
# Configurable cache variables
# -----------------------------------------------

set(RDMA_CORE_VERSION "62.0" CACHE STRING
  "Upstream rdma-core version to download")

option(RDMA_CORE_BUILD
  "Build unified rdma-core with vendor patches" ON)

set(ERNIC_PROJECT_DIR
  "${CMAKE_SOURCE_DIR}/../rocm-ernic"
  CACHE PATH
  "Path to the rocm-ernic project directory")

# -----------------------------------------------
# Derived paths
# -----------------------------------------------

set(RDMA_CORE_DEPS_DIR
  "${CMAKE_BINARY_DIR}/_deps/rdma-core")
set(RDMA_CORE_INSTALL_DIR
  "${RDMA_CORE_DEPS_DIR}/install")

set(RDMA_CORE_BUILD_SCRIPT
  "${CMAKE_SOURCE_DIR}/scripts/build/build-rdma-core.sh")

# -----------------------------------------------
# Build targets
# -----------------------------------------------

if(RDMA_CORE_BUILD)
  include(ProcessorCount)
  ProcessorCount(NPROC)
  if(NPROC EQUAL 0)
    set(NPROC 4)
  endif()

  # Pass vendor flags to the build script
  set(_GDA_BNXT_FLAG "0")
  set(_GDA_IONIC_FLAG "0")
  set(_GDA_ERNIC_FLAG "0")
  if(GDA_BNXT)
    set(_GDA_BNXT_FLAG "1")
  endif()
  if(GDA_IONIC)
    set(_GDA_IONIC_FLAG "1")
  endif()
  if(GDA_ERNIC)
    set(_GDA_ERNIC_FLAG "1")
  endif()

  set(_RDMA_CORE_ENV
    ${CMAKE_COMMAND} -E env
      "RDMA_CORE_VERSION=${RDMA_CORE_VERSION}"
      "GDA_BNXT=${_GDA_BNXT_FLAG}"
      "GDA_IONIC=${_GDA_IONIC_FLAG}"
      "GDA_ERNIC=${_GDA_ERNIC_FLAG}"
      "ERNIC_PROJECT_DIR=${ERNIC_PROJECT_DIR}"
  )

  message(STATUS
    "rdma-core: unified build v${RDMA_CORE_VERSION}"
    " (bnxt=${_GDA_BNXT_FLAG}"
    " ionic=${_GDA_IONIC_FLAG}"
    " ernic=${_GDA_ERNIC_FLAG})")

  add_custom_target(build-rdma-core
    COMMAND ${_RDMA_CORE_ENV}
      ${RDMA_CORE_BUILD_SCRIPT}
      ${RDMA_CORE_DEPS_DIR}
      ${RDMA_CORE_INSTALL_DIR}
      ${NPROC}
      --build-only
    COMMENT
      "Building unified rdma-core (no install)"
    VERBATIM
  )

  add_custom_target(install-rdma-core
    COMMAND ${_RDMA_CORE_ENV}
      ${RDMA_CORE_BUILD_SCRIPT}
      ${RDMA_CORE_DEPS_DIR}
      ${RDMA_CORE_INSTALL_DIR}
      ${NPROC}
    COMMENT
      "Building and installing unified rdma-core"
    VERBATIM
  )

  # Export paths for downstream use
  set(RDMA_CORE_LIB_DIR
    "${RDMA_CORE_INSTALL_DIR}/lib"
    CACHE PATH
    "Unified rdma-core library directory" FORCE)
  set(RDMA_CORE_INCLUDE_DIR
    "${RDMA_CORE_INSTALL_DIR}/include"
    CACHE PATH
    "Unified rdma-core include directory" FORCE)

  message(STATUS
    "rdma-core: will install to"
    " ${RDMA_CORE_INSTALL_DIR}")
endif()
