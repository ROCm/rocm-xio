# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# XIOBnxtKernelModule.cmake
#
# Builds the bnxt_re.ko RDMA kernel module with
# v11 uapi-extension patches via DKMS. Driver
# source is downloaded from kernel.org and patched
# by the setup script.
#
# Included from the top-level CMakeLists.txt
# when GDA_BNXT=ON.

option(BNXT_BUILD_KMOD
  "Setup bnxt_re DKMS module" OFF)

set(BNXT_DKMS_SETUP_SCRIPT
  "${CMAKE_SOURCE_DIR}/kernel/bnxt/setup-bnxt-re-dkms.sh")

if(BNXT_BUILD_KMOD)
  message(STATUS
    "bnxt: DKMS kmod targets enabled"
    " (kernel/bnxt/setup-bnxt-re-dkms.sh)")

  add_custom_target(build-bnxt-re-dkms
    COMMAND ${BNXT_DKMS_SETUP_SCRIPT}
      --build-only
    COMMENT
      "Building bnxt_re DKMS module"
      " (no install)"
    VERBATIM
  )

  add_custom_target(install-bnxt-re-dkms
    COMMAND ${BNXT_DKMS_SETUP_SCRIPT}
    COMMENT
      "Building and installing bnxt_re"
      " DKMS module"
    VERBATIM
  )

  add_custom_target(remove-bnxt-re-dkms
    COMMAND ${BNXT_DKMS_SETUP_SCRIPT}
      --uninstall
    COMMENT
      "Removing bnxt_re DKMS module"
    VERBATIM
  )
endif()
