# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

if(NOT XIO_BUILD_DEVICE_BITCODE)
  return()
endif()

find_program(XIO_HIPCC hipcc HINTS ${ROCM_PATH}/bin REQUIRED)
find_program(XIO_CLANG_OFFLOAD_BUNDLER clang-offload-bundler
  HINTS ${ROCM_PATH}/lib/llvm/bin REQUIRED)
find_program(XIO_LLVM_LINK llvm-link HINTS ${ROCM_PATH}/lib/llvm/bin REQUIRED)

set(XIO_DEVICE_BITCODE_SOURCE
  ${PROJECT_SOURCE_DIR}/src/endpoints/sdma-ep/sdma_device_extern_c.hip)
set(XIO_DEVICE_BITCODE_DIR ${CMAKE_BINARY_DIR}/device-bitcode)
set(XIO_DEVICE_BITCODE_OUTPUTS)
set(_xio_bitcode_defines)
if(XIO_SDMA_OSS7)
  list(APPEND _xio_bitcode_defines -DXIO_SDMA_OSS7=1)
endif()

set(_xio_bitcode_arches ${CMAKE_HIP_ARCHITECTURES})
if(NOT _xio_bitcode_arches)
  set(_xio_bitcode_arches ${OFFLOAD_ARCH})
endif()
if(NOT _xio_bitcode_arches)
  message(FATAL_ERROR
    "XIO_BUILD_DEVICE_BITCODE requires OFFLOAD_ARCH or "
    "CMAKE_HIP_ARCHITECTURES")
endif()

foreach(_arch IN LISTS _xio_bitcode_arches)
  string(REPLACE ":" "_" _arch_file "${_arch}")
  set(_output ${XIO_DEVICE_BITCODE_DIR}/xio_device_${_arch_file}.bc)
  set(_bundled_output ${_output}.bundle)
  set(_bundler_target "hip-amdgcn-amd-amdhsa--${_arch}")
  add_custom_command(
    OUTPUT ${_output}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${XIO_DEVICE_BITCODE_DIR}
    COMMAND ${XIO_HIPCC}
      --offload-arch=${_arch}
      -std=c++17
      -O2
      -fgpu-rdc
      -c -emit-llvm -x hip
      -I${PROJECT_SOURCE_DIR}/src/include
      -I${PROJECT_SOURCE_DIR}/src/endpoints/sdma-ep
      ${_xio_bitcode_defines}
      ${XIO_DEVICE_BITCODE_SOURCE}
      -o ${_bundled_output}
    COMMAND ${XIO_CLANG_OFFLOAD_BUNDLER}
      -unbundle -type=bc
      -targets=${_bundler_target}
      -input=${_bundled_output}
      -output=${_output}
    DEPENDS ${XIO_DEVICE_BITCODE_SOURCE}
      ${PROJECT_SOURCE_DIR}/src/endpoints/sdma-ep/sdma_device.hpp
      ${PROJECT_SOURCE_DIR}/src/endpoints/sdma-ep/sdma_packets.hpp
    VERBATIM
    COMMENT "Building XIO SDMA device bitcode for ${_arch}"
  )
  list(APPEND XIO_DEVICE_BITCODE_OUTPUTS ${_output})
endforeach()

add_custom_target(xio-device-bitcode ALL
  DEPENDS ${XIO_DEVICE_BITCODE_OUTPUTS})

if(BUILD_TESTING)
  list(GET XIO_DEVICE_BITCODE_OUTPUTS 0 _xio_smoke_bitcode)
  set(_xio_smoke_source
    ${PROJECT_SOURCE_DIR}/tests/unit/sdma-ep/device_bitcode_tester_kernel.hip)
  set(_xio_smoke_bundle ${CMAKE_CURRENT_BINARY_DIR}/xio_device_smoke.bundle)
  set(_xio_smoke_bc ${CMAKE_CURRENT_BINARY_DIR}/xio_device_smoke.bc)
  set(_xio_smoke_linked ${CMAKE_CURRENT_BINARY_DIR}/xio_device_smoke_linked.bc)
  list(GET _xio_bitcode_arches 0 _xio_smoke_arch)
  add_custom_command(
    OUTPUT ${_xio_smoke_linked}
    COMMAND ${XIO_HIPCC}
      --offload-arch=${_xio_smoke_arch} -std=c++17 -fgpu-rdc
      -c -emit-llvm -x hip ${_xio_smoke_source} -o ${_xio_smoke_bundle}
    COMMAND ${XIO_CLANG_OFFLOAD_BUNDLER}
      -unbundle -type=bc
      -targets=hip-amdgcn-amd-amdhsa--${_xio_smoke_arch}
      -input=${_xio_smoke_bundle} -output=${_xio_smoke_bc}
    COMMAND ${XIO_LLVM_LINK} ${_xio_smoke_bc} ${_xio_smoke_bitcode}
      -o ${_xio_smoke_linked}
    DEPENDS xio-device-bitcode ${_xio_smoke_source}
    VERBATIM
    COMMENT "Linking XIO SDMA device bitcode smoke test")
  add_custom_target(xio-device-bitcode-smoke DEPENDS ${_xio_smoke_linked})
endif()

# This path is independent of the Python bindings so the artifact can also be
# consumed by non-Python Triton applications.
install(FILES ${XIO_DEVICE_BITCODE_OUTPUTS}
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/xio/device
  COMPONENT rocm-xio-device-bitcode)

if(XIO_BUILD_PYTHON)
  install(FILES ${XIO_DEVICE_BITCODE_OUTPUTS}
    DESTINATION xio/sdma_ep/lib
    COMPONENT rocm-xio-python)
endif()
