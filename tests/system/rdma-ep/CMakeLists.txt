# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT

# RDMA-EP loopback system tests.
#
# Each test invokes one of the shell scripts in
# scripts/test/ via a thin wrapper that exits 77
# (CTest skip) when prerequisites are missing.
# The RDMA device is auto-detected or taken from
# $ROCXIO_RDMA_DEVICE at runtime.
#
# All tests depend on the RDMA_HW fixture defined
# in tests/unit/rdma-ep/CMakeLists.txt, which runs
# scripts/test/setup-rdma-loopback.sh to configure
# the neighbor-GID loopback (IP + static ARP +
# GID table wait).
#
# Labels: hardware, rdma, verify

set(_wrapper
  ${CMAKE_CURRENT_SOURCE_DIR}/run-rdma-script-test.sh)
set(_verbs_script
  ${CMAKE_SOURCE_DIR}/scripts/test/test-rdma-ep-verbs-loopback.sh)
set(_write_bw_script
  ${CMAKE_SOURCE_DIR}/scripts/test/test-rdma-ep-write-bw-loopback.sh)
set(_xio_script
  ${CMAKE_SOURCE_DIR}/scripts/test/test-rdma-ep-xio-loopback.sh)
set(_test_bin
  ${CMAKE_BINARY_DIR}/tests/unit/rdma-ep/test-rdma-loopback)
set(_rdma_lib
  ${CMAKE_BINARY_DIR}/_deps/rdma-core/install/lib)
set(_rdma_bin
  ${CMAKE_BINARY_DIR}/_deps/rdma-core/install/bin)

# --- Verbs-level smoke (no GPU needed) --------------

xio_add_script_test(
  NAME rdma-verbs-loopback
  SCRIPT ${_wrapper}
  LABELS hardware rdma verify
  TIMEOUT 60
  ARGS ${_verbs_script}
  ENVIRONMENT
    "RDMA_CORE_BIN=${_rdma_bin}"
    "RDMA_CORE_LIB=${_rdma_lib}"
)
set_tests_properties(rdma-verbs-loopback PROPERTIES
  FIXTURES_REQUIRED RDMA_HW)

# --- RDMA WRITE bandwidth loopback ------------------

xio_add_script_test(
  NAME rdma-write-bw-loopback
  SCRIPT ${_wrapper}
  LABELS hardware rdma verify
  TIMEOUT 60
  ARGS ${_write_bw_script}
  ENVIRONMENT
    "RDMA_CORE_BIN=${_rdma_bin}"
    "RDMA_CORE_LIB=${_rdma_lib}"
)
set_tests_properties(rdma-write-bw-loopback PROPERTIES
  FIXTURES_REQUIRED RDMA_HW)

# --- GPU RDMA loopback (256 B) ----------------------

xio_add_script_test(
  NAME rdma-xio-loopback-256
  SCRIPT ${_wrapper}
  LABELS hardware rdma verify
  TIMEOUT 120
  ARGS ${_xio_script}
  ENVIRONMENT
    "TRANSFER_SIZE=256"
    "LFSR_SEED=0x1234"
    "ITERATIONS=1"
    "TEST_BIN=${_test_bin}"
    "RDMA_CORE_LIB=${_rdma_lib}"
)
set_tests_properties(rdma-xio-loopback-256 PROPERTIES
  FIXTURES_REQUIRED RDMA_HW)

# --- GPU RDMA loopback (4 KB) -----------------------

xio_add_script_test(
  NAME rdma-xio-loopback-4k
  SCRIPT ${_wrapper}
  LABELS hardware rdma verify
  TIMEOUT 120
  ARGS ${_xio_script}
  ENVIRONMENT
    "TRANSFER_SIZE=4096"
    "LFSR_SEED=0x5678"
    "ITERATIONS=1"
    "TEST_BIN=${_test_bin}"
    "RDMA_CORE_LIB=${_rdma_lib}"
)
set_tests_properties(rdma-xio-loopback-4k PROPERTIES
  FIXTURES_REQUIRED RDMA_HW)
