# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# XIODocumentation.cmake
# Sphinx + rocm_docs.doxygen + Doxygen (ROCm rocPRIM-style layout:
# docs/doxygen/, XML under the build tree, Breathe wired by rocm_docs.doxygen).

option(XIO_BUILD_DOCS
  "Build documentation with Sphinx + rocm_docs.doxygen + Doxygen"
  OFF)

if(XIO_BUILD_DOCS)
  # Docs-only configures skip the main library block where GNUInstallDirs
  # is normally included.
  include(GNUInstallDirs)

  find_package(Doxygen REQUIRED)
  find_package(Python3 REQUIRED COMPONENTS Interpreter)

  # ── Python venv with rocm-docs-core (Sphinx + Breathe + optional doxysphinx)
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

  # ── Doxygen: configured tree (rocPRIM-style cwd = doxygen output root)
  set(XIO_DOC_PATH "${CMAKE_BINARY_DIR}/docs")
  set(XIO_DOXYGEN_WORKDIR "${CMAKE_BINARY_DIR}/docs-doxygen")

  file(MAKE_DIRECTORY "${XIO_DOXYGEN_WORKDIR}")

  set(_xio_doxygen_inputs
    "${CMAKE_SOURCE_DIR}/src/include"
    "${CMAKE_SOURCE_DIR}/src/endpoints/nvme-ep"
    "${CMAKE_SOURCE_DIR}/src/endpoints/test-ep"
    "${CMAKE_SOURCE_DIR}/src/endpoints/rdma-ep"
    "${CMAKE_SOURCE_DIR}/src/endpoints/sdma-ep"
    "${CMAKE_SOURCE_DIR}/src/endpoints/common"
    "${CMAKE_SOURCE_DIR}/src/common"
    "${CMAKE_SOURCE_DIR}/docs/doxygen"
  )
  string(REPLACE ";" " " XIO_DOXYFILE_INPUT "${_xio_doxygen_inputs}")

  configure_file(
    ${CMAKE_SOURCE_DIR}/docs/doxygen/Doxyfile.in
    ${XIO_DOXYGEN_WORKDIR}/Doxyfile
    @ONLY
  )

  configure_file(
    ${CMAKE_SOURCE_DIR}/docs/conf.py
    ${CMAKE_BINARY_DIR}/docs-sphinx/conf.py
    @ONLY
  )

  # ── Doxygen target (optional pre-build; sphinx-html also runs Doxygen via
  # rocm_docs.doxygen)
  add_custom_target(doxygen
    COMMAND ${DOXYGEN_EXECUTABLE} Doxyfile
    WORKING_DIRECTORY ${XIO_DOXYGEN_WORKDIR}
    COMMENT "Generating Doxygen XML in docs-doxygen/xml"
    VERBATIM
  )

  # ── Sphinx target: RST + Doxygen XML -> HTML
  add_custom_target(sphinx-html
    COMMAND ${SPHINX_BUILD}
      -b html
      -c ${CMAKE_BINARY_DIR}/docs-sphinx
      ${CMAKE_SOURCE_DIR}/docs
      ${XIO_DOC_PATH}/html
    DEPENDS docs-venv
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Building Sphinx HTML documentation"
    VERBATIM
  )

  install(
    DIRECTORY "${XIO_DOC_PATH}/html/"
    DESTINATION ${CMAKE_INSTALL_DOCDIR}
  )

  # ── Serve target: launch a local HTTP server
  set(XIO_DOCS_PORT "8080" CACHE STRING
    "Port for the docs-serve HTTP server")
  add_custom_target(docs-serve
    COMMAND ${Python3_EXECUTABLE} -m http.server
      ${XIO_DOCS_PORT} --bind 0.0.0.0
    DEPENDS sphinx-html
    WORKING_DIRECTORY ${XIO_DOC_PATH}/html
    COMMENT "Serving docs at http://0.0.0.0:${XIO_DOCS_PORT}"
    USES_TERMINAL
    VERBATIM
  )
endif()
