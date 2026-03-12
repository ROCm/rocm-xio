# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# XIOBnxtDirectVerbs.cmake
#
# Builds rdma-core with Broadcom Direct Verbs patches and
# optionally builds the bnxt_re.ko kernel module with
# corresponding DV kernel patches.
#
# Included from the top-level CMakeLists.txt when GDA_BNXT=ON.

include(ExternalProject)

# -----------------------------------------------------------
# Configurable cache variables
# -----------------------------------------------------------

set(BNXT_DV_MODE "fork" CACHE STRING
  "Build mode: 'fork' clones DV branch directly, \
'rebase' cherry-picks DV onto RDMA_CORE_TAG")
set_property(CACHE BNXT_DV_MODE
  PROPERTY STRINGS "fork" "rebase")

set(RDMA_CORE_TAG "v62.0" CACHE STRING
  "Upstream rdma-core git tag (used in rebase mode)")

set(BNXT_DV_REPO
  "https://github.com/sbasavapatna/rdma-core.git"
  CACHE STRING
  "Broadcom Direct Verbs fork repository URL")

set(BNXT_DV_BRANCH "dv-upstream" CACHE STRING
  "Broadcom Direct Verbs fork branch")

option(BNXT_DV_BUILD_RDMA_CORE
  "Build rdma-core with bnxt Direct Verbs patches" ON)

option(BNXT_DV_BUILD_KMOD
  "Setup bnxt_re.ko DKMS module with DV patches" OFF)

# -----------------------------------------------------------
# Derived paths
# -----------------------------------------------------------

set(BNXT_DV_DEPS_DIR
  "${CMAKE_BINARY_DIR}/_deps/bnxt-dv")
set(BNXT_DV_RDMA_CORE_SRC
  "${BNXT_DV_DEPS_DIR}/rdma-core-src")
set(BNXT_DV_RDMA_CORE_BUILD
  "${BNXT_DV_DEPS_DIR}/rdma-core-build")
set(BNXT_DV_RDMA_CORE_INSTALL
  "${BNXT_DV_DEPS_DIR}/rdma-core-install")
# Build script locations
set(RDMA_CORE_BUILD_SCRIPT
  "${CMAKE_SOURCE_DIR}/scripts/build/build-bnxt-dv-rdma-core.sh")
set(DKMS_SETUP_SCRIPT
  "${CMAKE_SOURCE_DIR}/kernel/bnxt/setup-bnxt-dv-dkms.sh")

# -----------------------------------------------------------
# Part 1: rdma-core with Direct Verbs patches
# -----------------------------------------------------------

if(BNXT_DV_BUILD_RDMA_CORE)
  # Determine parallelism
  include(ProcessorCount)
  ProcessorCount(NPROC)
  if(NPROC EQUAL 0)
    set(NPROC 4)
  endif()

  if(BNXT_DV_MODE STREQUAL "fork")
    message(STATUS
      "bnxt DV: will build from fork"
      " ${BNXT_DV_BRANCH}")
  else()
    message(STATUS
      "bnxt DV: will rebase DV onto"
      " ${RDMA_CORE_TAG}")
  endif()

  # Common argument list for the build script
  set(_RDMA_CORE_ARGS
    ${BNXT_DV_RDMA_CORE_SRC}
    ${BNXT_DV_RDMA_CORE_BUILD}
    ${BNXT_DV_RDMA_CORE_INSTALL}
    ${BNXT_DV_MODE}
    ${BNXT_DV_REPO}
    ${BNXT_DV_BRANCH}
    ${RDMA_CORE_TAG}
    ${NPROC}
  )

  add_custom_target(build-bnxt-dv-rdma-core
    COMMAND ${RDMA_CORE_BUILD_SCRIPT}
      ${_RDMA_CORE_ARGS} --build-only
    COMMENT
      "Building rdma-core with bnxt DV (no install)"
    VERBATIM
  )

  add_custom_target(install-bnxt-dv-rdma-core
    COMMAND ${RDMA_CORE_BUILD_SCRIPT}
      ${_RDMA_CORE_ARGS}
    COMMENT
      "Building and installing rdma-core with bnxt DV"
    VERBATIM
  )

  # Export paths for downstream use
  set(BNXT_DV_RDMA_CORE_LIB_DIR
    "${BNXT_DV_RDMA_CORE_INSTALL}/lib"
    CACHE PATH "rdma-core DV library directory" FORCE)
  set(BNXT_DV_RDMA_CORE_INCLUDE_DIR
    "${BNXT_DV_RDMA_CORE_INSTALL}/include"
    CACHE PATH "rdma-core DV include directory" FORCE)

  message(STATUS
    "bnxt DV: rdma-core will install to"
    " ${BNXT_DV_RDMA_CORE_INSTALL}")
endif()

# -----------------------------------------------------------
# Part 2: bnxt_re.ko DKMS module (optional)
# -----------------------------------------------------------

if(BNXT_DV_BUILD_KMOD)
  message(STATUS
    "bnxt DV: DKMS kmod targets enabled"
    " (kernel/bnxt/setup-bnxt-dv-dkms.sh)")

  add_custom_target(build-bnxt-dv-dkms
    COMMAND ${DKMS_SETUP_SCRIPT} --build-only
    COMMENT
      "Building bnxt_re DKMS module (no install)"
    VERBATIM
  )

  add_custom_target(install-bnxt-dv-dkms
    COMMAND ${DKMS_SETUP_SCRIPT}
    COMMENT
      "Building and installing bnxt_re DKMS module"
    VERBATIM
  )

  add_custom_target(remove-bnxt-dv-dkms
    COMMAND ${DKMS_SETUP_SCRIPT} --uninstall
    COMMENT
      "Removing bnxt_re DKMS module"
    VERBATIM
  )
endif()
