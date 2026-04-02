# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# XIOKpack.cmake — kpack multi-arch packaging support
#
# Adds a 'kpack-split' custom target that extracts per-architecture
# HSACO code objects from librocm-xio.so and creates .kpack archives
# for distribution.
#
# Requires: BUILD_SHARED_LIBS=ON, XIO_USE_KPACK=ON, Python3

set(_KPACK_SPLIT_SCRIPT
  "${CMAKE_SOURCE_DIR}/scripts/build/kpack-split.py")

set(XIO_KPACK_OUTPUT_DIR
  "${CMAKE_BINARY_DIR}/kpack"
  CACHE PATH "Output directory for .kpack archives")

option(XIO_KPACK_STRIP
  "Strip device code from the shared library after kpack split" OFF)

set(_KPACK_STRIP_FLAG "")
if(XIO_KPACK_STRIP)
  set(_KPACK_STRIP_FLAG "--strip")
endif()

add_custom_target(kpack-split
  COMMAND ${Python3_EXECUTABLE} ${_KPACK_SPLIT_SCRIPT}
    --lib $<TARGET_FILE:rocm-xio>
    --output-dir ${XIO_KPACK_OUTPUT_DIR}
    --verbose
    ${_KPACK_STRIP_FLAG}
  DEPENDS rocm-xio
  WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
  COMMENT "Splitting librocm-xio.so into per-arch .kpack archives"
  VERBATIM
)

# Install kpack archives when available.  The directory may not
# exist at configure time (it is created by 'kpack-split'), so
# guard the install with an existence check at install time.
install(CODE "
  set(_kpack_dir \"${XIO_KPACK_OUTPUT_DIR}\")
  if(EXISTS \"\${_kpack_dir}\")
    file(GLOB _kpack_files \"\${_kpack_dir}/*.kpack\")
    foreach(_f \${_kpack_files})
      file(INSTALL DESTINATION
        \"\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_LIBDIR}/rocm-xio/kpack\"
        TYPE FILE FILES \"\${_f}\")
    endforeach()
  endif()
" COMPONENT rocm-xio-kpack)

message(STATUS "kpack: 'kpack-split' target available "
  "(run: cmake --build . --target kpack-split)")
message(STATUS "kpack: archives → ${XIO_KPACK_OUTPUT_DIR}")
