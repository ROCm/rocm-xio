# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# XIOIonicKernelModule.cmake
#
# Builds the ionic_rdma.ko RDMA kernel module
# and a patched ionic.ko ethernet module via DKMS.
# The v6 patch series adds RDMA auxiliary device
# support to the ionic ethernet driver and
# introduces the ionic_rdma InfiniBand driver.
#
# Included from the top-level CMakeLists.txt
# when GDA_IONIC=ON.

option(IONIC_BUILD_KMOD
  "Setup ionic RDMA DKMS modules" OFF)

set(IONIC_DKMS_SETUP_SCRIPT
  "${CMAKE_SOURCE_DIR}/kernel/ionic/setup-ionic-rdma-dkms.sh")

if(IONIC_BUILD_KMOD)
  message(STATUS
    "ionic: DKMS kmod targets enabled"
    " (kernel/ionic/setup-ionic-rdma-dkms.sh)")

  add_custom_target(build-ionic-rdma-dkms
    COMMAND ${IONIC_DKMS_SETUP_SCRIPT}
      --build-only
    COMMENT
      "Building ionic RDMA DKMS modules"
      " (no install)"
    VERBATIM
  )

  add_custom_target(install-ionic-rdma-dkms
    COMMAND ${IONIC_DKMS_SETUP_SCRIPT}
    COMMENT
      "Building and installing ionic RDMA"
      " DKMS modules"
    VERBATIM
  )

  add_custom_target(remove-ionic-rdma-dkms
    COMMAND ${IONIC_DKMS_SETUP_SCRIPT}
      --uninstall
    COMMENT
      "Removing ionic RDMA DKMS modules"
    VERBATIM
  )
endif()
