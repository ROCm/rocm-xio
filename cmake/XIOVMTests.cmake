# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# XIOVMTests.cmake
#
# CMake targets for running xio-tester tests inside
# a running VM via SSH.
#
# Targets:
#   make vm-test-ep   Run test-ep inside the VM
#   make vm-rdma-ep   Run rdma-ep loopback inside the VM
#   make vm-nvme-ep   Run nvme-ep suite inside the VM

set(_vm_ssh_port "2222")
set(_vm_ssh_user "${XIO_VM_USERNAME}")
if(NOT _vm_ssh_user)
  set(_vm_ssh_user "$ENV{USER}")
endif()

set(_vm_ssh_opts
  "-o" "StrictHostKeyChecking=no"
  "-o" "UserKnownHostsFile=/dev/null"
  "-p" "${_vm_ssh_port}")

set(_vm_host "${_vm_ssh_user}@localhost")
set(_vm_xio_dir
  "/home/${_vm_ssh_user}/Projects/rocm-xio")

execute_process(
  COMMAND git rev-parse --short HEAD
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  OUTPUT_VARIABLE _vm_git_rev
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET)
if(NOT _vm_git_rev)
  set(_vm_git_rev "unknown")
endif()

set(_vm_build_dir
  "/opt/rocm-xio-build-${_vm_git_rev}")
set(_vm_rdma_lib
  "${_vm_build_dir}/_deps/rdma-core/install/lib")

# -------------------------------------------------
# vm-test-ep
# -------------------------------------------------
add_custom_target(vm-test-ep
  COMMAND ssh ${_vm_ssh_opts} ${_vm_host}
    "cd ${_vm_build_dir} && sudo ./xio-tester test-ep"
  COMMENT "Running test-ep inside VM"
  USES_TERMINAL
  VERBATIM
)

# -------------------------------------------------
# vm-rdma-ep
# -------------------------------------------------
add_custom_target(vm-rdma-ep
  COMMAND ssh ${_vm_ssh_opts} ${_vm_host}
    "cd ${_vm_xio_dir} && sudo VENDOR=bnxt scripts/test/setup-rdma-loopback.sh && cd ${_vm_build_dir} && sudo LD_LIBRARY_PATH=${_vm_rdma_lib} ./xio-tester rdma-ep --provider bnxt --loopback -n 128 --verbose"
  COMMENT "Running rdma-ep loopback inside VM"
  USES_TERMINAL
  VERBATIM
)

# -------------------------------------------------
# vm-nvme-ep
# -------------------------------------------------
add_custom_target(vm-nvme-ep
  COMMAND ssh ${_vm_ssh_opts} ${_vm_host}
    "cd ${_vm_xio_dir} && sudo HSA_FORCE_FINE_GRAIN_PCIE=1 NVME_EMUL=/dev/rocm-xio-nvme-emul NVME_REAL=/dev/rocm-xio-nvme-microchip ./scripts/test/test-nvme-ep"
  COMMENT "Running nvme-ep test suite inside VM"
  USES_TERMINAL
  VERBATIM
)
