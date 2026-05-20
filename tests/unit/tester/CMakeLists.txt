# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# CPU-only unit tests for xio-tester CLI option helpers. Built like other unit
# tests but without device RDC or hip::device linkage so the process does not
# register GPU kernels for this TU.

add_executable(test-xio-cli-options test-xio-cli-options.hip)

set_target_properties(test-xio-cli-options PROPERTIES LINKER_LANGUAGE HIP)

target_compile_options(test-xio-cli-options PRIVATE
  -std=c++17
  -Wall
  -Wextra
  -Wno-unused-parameter
)

target_include_directories(test-xio-cli-options PRIVATE
  ${XIO_INCLUDE_DIR}
  ${XIO_COMMON_DIR}
  ${XIO_TEST_COMMON_DIR}
  ${CMAKE_SOURCE_DIR}/src/tester
  ${CMAKE_SOURCE_DIR}/src/endpoints/nvme-ep
  ${CMAKE_SOURCE_DIR}/src/endpoints/rdma-ep
  ${CMAKE_SOURCE_DIR}/src/endpoints/sdma-ep
  ${CMAKE_SOURCE_DIR}/src/endpoints/test-ep
)

target_link_libraries(test-xio-cli-options PRIVATE
  rocm-xio
  hip::host
  hsa-runtime64::hsa-runtime64
  dl
)

foreach(vendor BNXT MLX5 IONIC ERNIC)
  if(GDA_${vendor})
    target_compile_definitions(test-xio-cli-options PRIVATE GDA_${vendor})
  endif()
endforeach()

if(XIO_SDMA_OSS7)
  target_compile_definitions(test-xio-cli-options PRIVATE XIO_SDMA_OSS7=1)
endif()

add_test(NAME test-xio-cli-options COMMAND test-xio-cli-options)
set_tests_properties(test-xio-cli-options PROPERTIES
  LABELS "unit;tester"
  TIMEOUT 30
)
