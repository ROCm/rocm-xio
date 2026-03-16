# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# XIODocumentation.cmake
# Sphinx + Breathe + Doxygen documentation pipeline
# (following ROCm best practices)
#
# A Python venv is created automatically in the build tree
# and populated from requirements.txt.

option(XIO_BUILD_DOCS
  "Build documentation with Sphinx + Breathe + Doxygen"
  OFF)

if(XIO_BUILD_DOCS)
  find_package(Doxygen REQUIRED)
  find_package(Python3 REQUIRED COMPONENTS Interpreter)

  # ── Python venv with Sphinx + Breathe ──────────────────
  set(XIO_DOCS_VENV "${CMAKE_BINARY_DIR}/docs-venv")
  set(XIO_DOCS_VENV_STAMP
    "${XIO_DOCS_VENV}/stamp")
  set(XIO_DOCS_REQUIREMENTS
    "${CMAKE_SOURCE_DIR}/requirements.txt")

  if(WIN32)
    set(XIO_VENV_BIN "${XIO_DOCS_VENV}/Scripts")
  else()
    set(XIO_VENV_BIN "${XIO_DOCS_VENV}/bin")
  endif()

  set(SPHINX_BUILD "${XIO_VENV_BIN}/sphinx-build")

  add_custom_command(
    OUTPUT ${XIO_DOCS_VENV_STAMP}
    COMMAND ${Python3_EXECUTABLE} -m venv ${XIO_DOCS_VENV}
    COMMAND ${XIO_VENV_BIN}/pip install
      --quiet --upgrade pip
    COMMAND ${XIO_VENV_BIN}/pip install
      --quiet -r ${XIO_DOCS_REQUIREMENTS}
    COMMAND ${CMAKE_COMMAND} -E touch
      ${XIO_DOCS_VENV_STAMP}
    DEPENDS ${XIO_DOCS_REQUIREMENTS}
    COMMENT "Creating docs venv and installing deps"
    VERBATIM
  )

  add_custom_target(docs-venv
    DEPENDS ${XIO_DOCS_VENV_STAMP}
  )

  # ── Paths ──────────────────────────────────────────────
  set(XIO_DOC_PATH "${CMAKE_BINARY_DIR}/docs")
  set(BREATHE_DOC_XML_DIR
    "${XIO_DOC_PATH}/xml")

  set(XIO_DOXYFILE_INPUT
    "${CMAKE_SOURCE_DIR}/src/include \
     ${CMAKE_SOURCE_DIR}/src/endpoints/nvme-ep \
     ${CMAKE_SOURCE_DIR}/src/endpoints/test-ep \
     ${CMAKE_SOURCE_DIR}/src/endpoints/rdma-ep \
     ${CMAKE_SOURCE_DIR}/src/endpoints/sdma-ep \
     ${CMAKE_SOURCE_DIR}/src/endpoints/common \
     ${CMAKE_SOURCE_DIR}/src/common"
  )

  # Configure Doxyfile (substitutes @VARIABLES@)
  configure_file(
    ${CMAKE_SOURCE_DIR}/docs/Doxyfile.in
    ${CMAKE_BINARY_DIR}/Doxyfile
    @ONLY
  )

  # Configure conf.py (substitutes Breathe XML path)
  configure_file(
    ${CMAKE_SOURCE_DIR}/docs/conf.py
    ${CMAKE_BINARY_DIR}/docs-sphinx/conf.py
    @ONLY
  )

  # ── Doxygen target: source headers -> XML ──────────────
  add_custom_target(doxygen
    COMMAND ${DOXYGEN_EXECUTABLE}
      ${CMAKE_BINARY_DIR}/Doxyfile
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Generating Doxygen XML"
    VERBATIM
  )

  # ── Sphinx target: RST + Doxygen XML -> HTML ───────────
  # Target name follows ROCm convention (ROCMSphinxDoc)
  add_custom_target(sphinx-html
    COMMAND ${SPHINX_BUILD}
      -b html
      -c ${CMAKE_BINARY_DIR}/docs-sphinx
      ${CMAKE_SOURCE_DIR}/docs
      ${XIO_DOC_PATH}/html
    DEPENDS doxygen docs-venv
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Building Sphinx HTML documentation"
    VERBATIM
  )
endif()
