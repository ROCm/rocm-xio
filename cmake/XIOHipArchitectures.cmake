# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Initialize HIP architectures before project(... LANGUAGES HIP) runs.
#
# If OFFLOAD_ARCH is set, use it directly. Otherwise, try to detect a ROCm GPU
# architecture via rocminfo and seed CMAKE_HIP_ARCHITECTURES before CMake's HIP
# compiler setup runs. If rocminfo does not report a gfx* target, leave
# CMAKE_HIP_ARCHITECTURES unset and let CMake apply its default behavior.

macro(xio_init_hip_architectures)
  if(OFFLOAD_ARCH)
    set(CMAKE_HIP_ARCHITECTURES "${OFFLOAD_ARCH}" CACHE STRING
      "GPU architectures to compile for (derived from OFFLOAD_ARCH)" FORCE)
    set(OFFLOAD_ARCH_MSG "${OFFLOAD_ARCH} (specified)")
  else()
    unset(DETECTED_ARCH)

    if(NOT DEFINED ROCMINFO OR NOT ROCMINFO)
      set(_xio_rocminfo_paths "/opt/rocm/bin")
      if(DEFINED ENV{ROCM_PATH} AND NOT "$ENV{ROCM_PATH}" STREQUAL "")
        list(PREPEND _xio_rocminfo_paths "$ENV{ROCM_PATH}/bin")
      endif()
      find_program(ROCMINFO rocminfo
        PATHS ${_xio_rocminfo_paths}
        ENV PATH)
      unset(_xio_rocminfo_paths)
    endif()

    if(ROCMINFO)
      execute_process(
        COMMAND ${ROCMINFO}
        OUTPUT_VARIABLE ROCMINFO_OUTPUT
        RESULT_VARIABLE ROCMINFO_RESULT
        ERROR_QUIET
      )
      if(ROCMINFO_RESULT EQUAL 0)
        string(REGEX MATCH "gfx[0-9a-f]+" DETECTED_ARCH
          "${ROCMINFO_OUTPUT}")
      endif()
    endif()

    if(DETECTED_ARCH)
      set(OFFLOAD_ARCH "${DETECTED_ARCH}")
      set(CMAKE_HIP_ARCHITECTURES "${DETECTED_ARCH}" CACHE STRING
        "GPU architectures to compile for (auto-detected)" FORCE)
      set(OFFLOAD_ARCH_MSG "${DETECTED_ARCH} (auto-detected)")
    else()
      set(OFFLOAD_ARCH_MSG "default (CMake HIP auto-detect)")
    endif()

    unset(DETECTED_ARCH)
  endif()
endmacro()
