# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

cmake_minimum_required(VERSION 3.21)

cmake_path(GET CMAKE_CURRENT_LIST_DIR PARENT_PATH _unit_dir)
cmake_path(GET _unit_dir PARENT_PATH _tests_dir)
cmake_path(GET _tests_dir PARENT_PATH _repo_root)

include("${_repo_root}/cmake/XIOHipArchitectures.cmake")

function(assert_equal expected actual label)
  if(NOT "${actual}" STREQUAL "${expected}")
    message(FATAL_ERROR
      "${label}: expected '${expected}', got '${actual}'")
  endif()
endfunction()

set(_tmp_dir "/tmp/rocm-xio-xio-hip-architectures")
file(MAKE_DIRECTORY "${_tmp_dir}")

set(_rocminfo_ok "${_tmp_dir}/fake-rocminfo-ok.sh")
file(WRITE "${_rocminfo_ok}" "#!/bin/sh\nprintf '%s\\n' 'amdgcn-amd-amdhsa--gfx950'\n")
file(CHMOD "${_rocminfo_ok}"
  PERMISSIONS
    OWNER_READ OWNER_WRITE OWNER_EXECUTE
    GROUP_READ GROUP_EXECUTE
    WORLD_READ WORLD_EXECUTE)

set(_rocminfo_none "${_tmp_dir}/fake-rocminfo-none.sh")
file(WRITE "${_rocminfo_none}" "#!/bin/sh\nprintf '%s\\n' 'no amd gpu'\n")
file(CHMOD "${_rocminfo_none}"
  PERMISSIONS
    OWNER_READ OWNER_WRITE OWNER_EXECUTE
    GROUP_READ GROUP_EXECUTE
    WORLD_READ WORLD_EXECUTE)

set(OFFLOAD_ARCH "gfx942:xnack+")
unset(CMAKE_HIP_ARCHITECTURES CACHE)
unset(CMAKE_HIP_ARCHITECTURES)
xio_init_hip_architectures()
assert_equal("gfx942:xnack+" "${CMAKE_HIP_ARCHITECTURES}" "specified arch")
assert_equal("gfx942:xnack+ (specified)" "${OFFLOAD_ARCH_MSG}" "specified message")

set(ROCMINFO "${_rocminfo_ok}")
set(OFFLOAD_ARCH "")
unset(CMAKE_HIP_ARCHITECTURES CACHE)
unset(CMAKE_HIP_ARCHITECTURES)
xio_init_hip_architectures()
assert_equal("gfx950" "${OFFLOAD_ARCH}" "auto-detected OFFLOAD_ARCH")
assert_equal("gfx950" "${CMAKE_HIP_ARCHITECTURES}" "auto-detected HIP arch")
assert_equal("gfx950 (auto-detected)" "${OFFLOAD_ARCH_MSG}" "auto-detected message")

set(ROCMINFO "${_rocminfo_none}")
set(OFFLOAD_ARCH "")
unset(CMAKE_HIP_ARCHITECTURES CACHE)
unset(CMAKE_HIP_ARCHITECTURES)
xio_init_hip_architectures()
assert_equal("OFF" "${CMAKE_HIP_ARCHITECTURES}" "no-GPU fallback")
assert_equal(
  "none detected (HIP architectures disabled; set OFFLOAD_ARCH to override)"
  "${OFFLOAD_ARCH_MSG}"
  "no-GPU message")
