# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# XIOVirtualMachine.cmake
#
# VM targets for safe rocm-xio testing (kernel panics stay inside the VM).
#
# Targets:
#   make gen-test-vm      Create the VM image
#   make setup-test-vm    Provision via Ansible Galaxy
#   make launch-test-vm   Boot the VM
#
# Usage:
#   make launch-test-vm               # rdma (default)
#   VM_MODE=nvme make launch-test-vm  # nvme mode
#   VM_MODE=ernic make launch-test-vm # ernic mode
#   VM_MODE=full make launch-test-vm  # all devices

# ---------------------------------------------------
# 1. QEMU binary
# ---------------------------------------------------
# Cache variable: override with
#   -DQEMU_PATH=/opt/qemu-10.1.2/bin/
set(QEMU_PATH "" CACHE STRING
  "Path prefix for qemu-system-x86_64 (empty = system)")

if(QEMU_PATH)
  set(_qemu_bin "${QEMU_PATH}/qemu-system-x86_64")
  if(NOT EXISTS "${_qemu_bin}")
    # Maybe the user passed the full binary path
    if(EXISTS "${QEMU_PATH}")
      set(_qemu_bin "${QEMU_PATH}")
    else()
      message(WARNING
        "XIOVirtualMachine: qemu-system-x86_64 not "
        "found at QEMU_PATH=${QEMU_PATH}")
      set(_qemu_bin "")
    endif()
  endif()
else()
  find_program(_qemu_bin qemu-system-x86_64)
endif()

set(_qemu_ok FALSE)
if(_qemu_bin AND EXISTS "${_qemu_bin}")
  execute_process(
    COMMAND "${_qemu_bin}" --version
    OUTPUT_VARIABLE _qemu_ver_out
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
    RESULT_VARIABLE _qemu_rc)
  if(_qemu_rc EQUAL 0)
    string(REGEX MATCH
      "version ([0-9]+)\\.([0-9]+)\\.([0-9]+)"
      _qemu_match "${_qemu_ver_out}")
    if(_qemu_match)
      set(_qemu_major "${CMAKE_MATCH_1}")
      set(_qemu_minor "${CMAKE_MATCH_2}")
      if(_qemu_major GREATER 10 OR
         (_qemu_major EQUAL 10 AND
          _qemu_minor GREATER_EQUAL 1))
        set(_qemu_ok TRUE)
        message(STATUS
          "XIOVirtualMachine: QEMU ${_qemu_major}"
          ".${_qemu_minor} at ${_qemu_bin}")
      else()
        message(WARNING
          "XIOVirtualMachine: QEMU "
          "${_qemu_major}.${_qemu_minor} found but "
          ">= 10.1.0 required.")
      endif()
    endif()
  endif()
endif()

if(NOT _qemu_ok AND NOT _qemu_bin)
  message(STATUS
    "XIOVirtualMachine: qemu-system-x86_64 not found."
    " Install with:\n"
    "    sudo apt-get install qemu-system-x86\n"
    "  or set -DQEMU_PATH=/opt/qemu-10.1.2/bin/")
endif()

# ---------------------------------------------------
# 2. driverctl
# ---------------------------------------------------
find_program(DRIVERCTL driverctl)

if(NOT DRIVERCTL)
  message(STATUS
    "XIOVirtualMachine: driverctl not found. "
    "Install with:\n"
    "    sudo apt-get install driverctl")
endif()

# ---------------------------------------------------
# 3. run-vm script
# ---------------------------------------------------
find_program(RUN_VM run-vm
  HINTS "$ENV{HOME}/Projects/qemu-minimal/qemu")

if(NOT RUN_VM)
  message(STATUS
    "XIOVirtualMachine: run-vm not found. "
    "Install qemu-minimal or set -DRUN_VM=/path/to/"
    "run-vm")
endif()

# ---------------------------------------------------
# 4. VM image
# ---------------------------------------------------
set(_vm_images_dir "")
if(RUN_VM)
  get_filename_component(_run_vm_dir "${RUN_VM}" DIRECTORY)
  set(_vm_images_dir "${_run_vm_dir}/../images")
  get_filename_component(_vm_images_dir
    "${_vm_images_dir}" ABSOLUTE)
endif()

set(_vm_image_ok FALSE)
if(_vm_images_dir AND
   EXISTS "${_vm_images_dir}/rocm-xio-vm.qcow2")
  set(_vm_image_ok TRUE)
  message(STATUS
    "XIOVirtualMachine: VM image found at "
    "${_vm_images_dir}/rocm-xio-vm.qcow2")
else()
  message(STATUS
    "XIOVirtualMachine: VM image not found. "
    "Create with:\n"
    "    cd qemu-minimal && VM_NAME=rocm-xio-vm "
    "./gen-vm")
endif()

# ---------------------------------------------------
# 5. Detect AMD GPUs and vfio-pci binding
# ---------------------------------------------------
find_program(_lspci lspci)

set(XIO_VM_GPUS_ALL "" CACHE INTERNAL
  "All AMD GPU BDFs")
set(XIO_VM_GPUS_VFIO "" CACHE INTERNAL
  "AMD GPU BDFs bound to vfio-pci")

set(_gpu_status_lines "")

if(_lspci)
  # Query only VGA (0300) and 3D (0302) controllers
  # from AMD (vendor 1002) to avoid PCI bridges, audio,
  # and other non-GPU AMD devices.
  foreach(_class "0300" "0302")
    execute_process(
      COMMAND ${_lspci} -Dnn -d "1002::${_class}"
      OUTPUT_VARIABLE _lspci_out
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_QUIET
      RESULT_VARIABLE _lspci_rc)

    if(_lspci_rc EQUAL 0 AND _lspci_out)
      string(REPLACE "\n" ";" _lspci_lines
        "${_lspci_out}")
      foreach(_line IN LISTS _lspci_lines)
        if(_line MATCHES
           "^([0-9a-fA-F]+):([0-9a-fA-F:.]+) ")
          set(_domain "${CMAKE_MATCH_1}")
          set(_short_bdf "${CMAKE_MATCH_2}")

          # Get device description after class
          string(REGEX MATCH ": .+$" _desc "${_line}")
          string(SUBSTRING "${_desc}" 2 -1 _desc)

          # Check driver binding via sysfs
          set(_driver "none")
          set(_sysfs
            "/sys/bus/pci/devices/"
            "${_domain}:${_short_bdf}/driver")
          string(CONCAT _sysfs ${_sysfs})
          if(EXISTS "${_sysfs}")
            file(READ_SYMLINK "${_sysfs}" _drv_path)
            get_filename_component(_driver
              "${_drv_path}" NAME)
          endif()

          list(APPEND XIO_VM_GPUS_ALL
            "${_short_bdf}")
          if(_driver STREQUAL "vfio-pci")
            list(APPEND XIO_VM_GPUS_VFIO
              "${_short_bdf}")
          endif()

          list(APPEND _gpu_status_lines
            "  ${_short_bdf}  (${_driver})")
        endif()
      endforeach()
    endif()
  endforeach()
endif()

if(XIO_VM_GPUS_ALL)
  message(STATUS
    "XIOVirtualMachine: AMD GPUs found:")
  foreach(_l IN LISTS _gpu_status_lines)
    message(STATUS "  ${_l}")
  endforeach()

  if(NOT XIO_VM_GPUS_VFIO)
    message(STATUS
      "XIOVirtualMachine: No GPUs bound to vfio-pci.")
    list(GET XIO_VM_GPUS_ALL 0 _first_gpu)
    message(STATUS
      "  To bind for VM passthrough:\n"
      "    sudo driverctl set-override "
      "0000:${_first_gpu} vfio-pci\n"
      "  To restore:\n"
      "    sudo driverctl unset-override "
      "0000:${_first_gpu}")
  endif()
else()
  message(STATUS
    "XIOVirtualMachine: No AMD GPUs detected.")
endif()

# User-selectable GPU BDF
set(XIO_VM_GPU "" CACHE STRING
  "GPU BDF for VM passthrough (e.g. 10:00.0)")

if(XIO_VM_GPU)
  list(FIND XIO_VM_GPUS_ALL "${XIO_VM_GPU}" _gpu_idx)
  if(_gpu_idx EQUAL -1)
    message(WARNING
      "XIOVirtualMachine: GPU ${XIO_VM_GPU} not found."
      " Available AMD GPUs: ${XIO_VM_GPUS_ALL}")
  endif()
endif()

# ---------------------------------------------------
# 6. Build target: launch-test-vm
# ---------------------------------------------------
set(_launch_vm
  "${CMAKE_SOURCE_DIR}/scripts/test/launch-vm")

if(_qemu_ok AND RUN_VM AND _vm_image_ok)
  # Determine GPU_BDF to pass to the script
  set(_gpu_bdf "${XIO_VM_GPU}")
  if(NOT _gpu_bdf AND XIO_VM_GPUS_VFIO)
    list(GET XIO_VM_GPUS_VFIO 0 _gpu_bdf)
  endif()
  if(NOT _gpu_bdf AND XIO_VM_GPUS_ALL)
    list(GET XIO_VM_GPUS_ALL 0 _gpu_bdf)
  endif()
  if(NOT _gpu_bdf)
    set(_gpu_bdf "10:00.0")
  endif()

  # Build the QEMU_PATH prefix for run-vm
  set(_qemu_prefix "")
  if(_qemu_bin)
    get_filename_component(_qemu_dir
      "${_qemu_bin}" DIRECTORY)
    set(_qemu_prefix "${_qemu_dir}/")
  endif()

  add_custom_target(launch-test-vm
    COMMAND ${CMAKE_COMMAND} -E env
      "RUN_VM=${RUN_VM}"
      "GPU_BDF=${_gpu_bdf}"
      "QEMU_PATH=${_qemu_prefix}"
      "${_launch_vm}"
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Launching rocm-xio test VM"
    USES_TERMINAL
    VERBATIM
  )
else()
  # Stub target with diagnostic messages
  set(_err_cmds "")

  if(NOT _qemu_ok)
    list(APPEND _err_cmds
      COMMAND ${CMAKE_COMMAND} -E echo
        "Error: qemu-system-x86_64 not found or"
        "version < 10.1.0."
      COMMAND ${CMAKE_COMMAND} -E echo
        "  sudo apt-get install qemu-system-x86"
      COMMAND ${CMAKE_COMMAND} -E echo
        "  or: -DQEMU_PATH=/opt/qemu-10.1.2/bin/")
  endif()

  if(NOT RUN_VM)
    list(APPEND _err_cmds
      COMMAND ${CMAKE_COMMAND} -E echo
        "Error: run-vm script not found."
      COMMAND ${CMAKE_COMMAND} -E echo
        "  Install qemu-minimal or set"
        "-DRUN_VM=/path/to/run-vm")
  endif()

  if(NOT _vm_image_ok)
    list(APPEND _err_cmds
      COMMAND ${CMAKE_COMMAND} -E echo
        "Error: VM image rocm-xio-vm.qcow2 not found."
      COMMAND ${CMAKE_COMMAND} -E echo
        "  cd qemu-minimal"
      COMMAND ${CMAKE_COMMAND} -E echo
        "  VM_NAME=rocm-xio-vm ./gen-vm")
  endif()

  if(NOT DRIVERCTL)
    list(APPEND _err_cmds
      COMMAND ${CMAKE_COMMAND} -E echo
        "Warning: driverctl not found."
      COMMAND ${CMAKE_COMMAND} -E echo
        "  sudo apt-get install driverctl")
  endif()

  if(NOT XIO_VM_GPUS_VFIO)
    list(APPEND _err_cmds
      COMMAND ${CMAKE_COMMAND} -E echo
        "Warning: No AMD GPU bound to vfio-pci.")
    if(XIO_VM_GPUS_ALL)
      list(GET XIO_VM_GPUS_ALL 0 _hint_gpu)
      list(APPEND _err_cmds
        COMMAND ${CMAKE_COMMAND} -E echo
          "  sudo driverctl set-override"
          "0000:${_hint_gpu} vfio-pci")
    endif()
  endif()

  add_custom_target(launch-test-vm
    ${_err_cmds}
    COMMAND ${CMAKE_COMMAND} -E false
    COMMENT "launch-test-vm: prerequisites not met"
  )
endif()

# ---------------------------------------------------
# 7. gen-vm script and cloud-localds
# ---------------------------------------------------
find_program(GEN_VM gen-vm
  HINTS "$ENV{HOME}/Projects/qemu-minimal/qemu")

find_program(CLOUD_LOCALDS cloud-localds)

if(NOT GEN_VM)
  message(STATUS
    "XIOVirtualMachine: gen-vm not found. "
    "Install qemu-minimal or set "
    "-DGEN_VM=/path/to/gen-vm")
endif()

if(NOT CLOUD_LOCALDS)
  message(STATUS
    "XIOVirtualMachine: cloud-localds not found. "
    "Install with:\n"
    "    sudo apt-get install cloud-image-utils")
endif()

# VM credentials
set(XIO_VM_USERNAME "$ENV{USER}" CACHE STRING
  "Username for the test VM")
set(XIO_VM_PASS "password" CACHE STRING
  "Password for the test VM user")

# Get host USER_ID at configure time
execute_process(
  COMMAND id -u
  OUTPUT_VARIABLE _host_uid
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET)
if(NOT _host_uid)
  set(_host_uid "1000")
endif()

# ---------------------------------------------------
# 8. Build target: gen-test-vm
# ---------------------------------------------------
set(_packages_file
  "${CMAKE_SOURCE_DIR}/scripts/test/"
  "packages-rocm-xio-vm")
string(CONCAT _packages_file ${_packages_file})

if(_qemu_ok AND GEN_VM AND CLOUD_LOCALDS)
  set(_qemu_prefix_gen "")
  if(_qemu_bin)
    get_filename_component(_qemu_dir_gen
      "${_qemu_bin}" DIRECTORY)
    set(_qemu_prefix_gen "${_qemu_dir_gen}/")
  endif()

  add_custom_target(gen-test-vm
    COMMAND ${CMAKE_COMMAND} -E env
      "VM_NAME=rocm-xio-vm"
      "USERNAME=${XIO_VM_USERNAME}"
      "PASS=${XIO_VM_PASS}"
      "USER_ID=${_host_uid}"
      "IMAGES=${_vm_images_dir}"
      "PACKAGES=${_packages_file}"
      "SIZE=256"
      "VCPUS=4"
      "VMEM=8192"
      "QEMU_PATH=${_qemu_prefix_gen}"
      "${GEN_VM}"
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Creating rocm-xio-vm base image"
    USES_TERMINAL
    VERBATIM
  )
else()
  set(_gen_err "")

  if(NOT _qemu_ok)
    list(APPEND _gen_err
      COMMAND ${CMAKE_COMMAND} -E echo
        "Error: QEMU not found or < 10.1.0."
      COMMAND ${CMAKE_COMMAND} -E echo
        "  -DQEMU_PATH=/opt/qemu-10.1.2/bin/")
  endif()

  if(NOT GEN_VM)
    list(APPEND _gen_err
      COMMAND ${CMAKE_COMMAND} -E echo
        "Error: gen-vm not found."
      COMMAND ${CMAKE_COMMAND} -E echo
        "  Install qemu-minimal or set"
        "-DGEN_VM=/path/to/gen-vm")
  endif()

  if(NOT CLOUD_LOCALDS)
    list(APPEND _gen_err
      COMMAND ${CMAKE_COMMAND} -E echo
        "Error: cloud-localds not found."
      COMMAND ${CMAKE_COMMAND} -E echo
        "  sudo apt-get install cloud-image-utils")
  endif()

  add_custom_target(gen-test-vm
    ${_gen_err}
    COMMAND ${CMAKE_COMMAND} -E false
    COMMENT "gen-test-vm: prerequisites not met"
  )
endif()

# ---------------------------------------------------
# 9. Ansible and setup-test-vm
# ---------------------------------------------------
find_program(ANSIBLE_PLAYBOOK ansible-playbook)
find_program(ANSIBLE_GALAXY ansible-galaxy)

set(_setup_vm
  "${CMAKE_SOURCE_DIR}/scripts/test/setup-vm")

if(ANSIBLE_PLAYBOOK AND ANSIBLE_GALAXY)
  message(STATUS
    "XIOVirtualMachine: Ansible found at "
    "${ANSIBLE_PLAYBOOK}")

  add_custom_target(setup-test-vm
    COMMAND ${CMAKE_COMMAND} -E env
      "ANSIBLE_PLAYBOOK=${ANSIBLE_PLAYBOOK}"
      "ANSIBLE_GALAXY=${ANSIBLE_GALAXY}"
      "SSH_PORT=2222"
      "VM_USERNAME=${XIO_VM_USERNAME}"
      "VM_PASS=${XIO_VM_PASS}"
      "${_setup_vm}"
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Provisioning VM via Ansible Galaxy"
    USES_TERMINAL
    VERBATIM
  )
else()
  add_custom_target(setup-test-vm
    COMMAND ${CMAKE_COMMAND} -E echo
      "Error: ansible-playbook not found."
    COMMAND ${CMAKE_COMMAND} -E echo
      "  pip install ansible"
    COMMAND ${CMAKE_COMMAND} -E false
    COMMENT "setup-test-vm: Ansible not installed"
  )
endif()
