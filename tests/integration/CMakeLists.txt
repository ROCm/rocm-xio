# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# Install-integration tests for rocm-xio.
#
# These tests install the library to a temporary prefix
# and then configure, build, and run standalone example
# projects against the installed package.  All tests
# carry the "integration" CTest label.

include(XIOInstallTests)

xio_install_test_fixture()

# Configure-only: verify find_package(rocm-xio) resolves.
xio_add_install_test(
  NAME find-package
  SOURCE_DIR
    ${CMAKE_SOURCE_DIR}/examples/find-package
)

# Compile + run: list available endpoints.
xio_add_install_test(
  NAME list-endpoints
  SOURCE_DIR
    ${CMAKE_SOURCE_DIR}/examples/list-endpoints
  RUN
)

# Compile + run: iterate endpoint registry entries.
xio_add_install_test(
  NAME endpoint-info
  SOURCE_DIR
    ${CMAKE_SOURCE_DIR}/examples/endpoint-info
  RUN
)
