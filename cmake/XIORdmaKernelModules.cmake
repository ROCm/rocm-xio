# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# XIORdmaKernelModules.cmake
#
# DKMS kernel module targets for RDMA vendors (BNXT, Ionic, ERNIC). Each vendor
# gets build-*, install-*, and remove-* targets gated by its GDA_* flag and a
# per-vendor *_BUILD_KMOD cache option.

# xio_add_kmod_targets(<VENDOR> <LABEL> <SCRIPT> <OPTION> <DESCRIPTION>)
#
# Register three DKMS custom targets for a vendor:
#   build-<LABEL>   -- build only (--build-only)
#   install-<LABEL> -- build and install
#   remove-<LABEL>  -- uninstall (--uninstall)
function(xio_add_kmod_targets VENDOR LABEL SCRIPT OPTION DESCRIPTION)
  option(${OPTION} "${DESCRIPTION}" OFF)

  set(${VENDOR}_DKMS_SETUP_SCRIPT "${SCRIPT}" PARENT_SCOPE)

  if(${OPTION})
    message(STATUS "${VENDOR}: DKMS kmod targets enabled (${SCRIPT})")

    add_custom_target(build-${LABEL}
      COMMAND ${SCRIPT} --build-only
      COMMENT "Building ${LABEL} (no install)"
      VERBATIM
    )

    add_custom_target(install-${LABEL}
      COMMAND ${SCRIPT}
      COMMENT "Building and installing ${LABEL}"
      VERBATIM
    )

    add_custom_target(remove-${LABEL}
      COMMAND ${SCRIPT} --uninstall
      COMMENT "Removing ${LABEL}"
      VERBATIM
    )
  endif()
endfunction()

# ── BNXT ─────────────────────────────────────────────────────────────────────
if(GDA_BNXT)
  xio_add_kmod_targets(bnxt bnxt-re-dkms
    "${CMAKE_SOURCE_DIR}/kernel/bnxt/setup-bnxt-re-dkms.sh"
    BNXT_BUILD_KMOD
    "Setup bnxt_re DKMS module")
endif()

# ── Ionic ────────────────────────────────────────────────────────────────────
if(GDA_IONIC)
  xio_add_kmod_targets(ionic ionic-eth-rdma-dkms
    "${CMAKE_SOURCE_DIR}/kernel/ionic/setup-ionic-eth-rdma-dkms.sh"
    IONIC_BUILD_KMOD
    "Setup ionic eth+RDMA DKMS modules")
endif()

# ── ERNIC ────────────────────────────────────────────────────────────────────
if(GDA_ERNIC)
  xio_add_kmod_targets(ernic ernic-eth-rdma-dkms
    "${CMAKE_SOURCE_DIR}/kernel/rocm-ernic/setup-rocm-ernic-eth-rdma-dkms.sh"
    ERNIC_BUILD_KMOD
    "Setup rocm-ernic eth+RDMA DKMS modules")
endif()
