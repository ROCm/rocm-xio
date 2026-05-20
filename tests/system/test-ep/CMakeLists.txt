# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# System-level tests for test-ep (``tests/system/test-ep``).  They link
# against the full library; emulate paths exercise the endpoint without a
# HIP GPU at runtime, so omit the ``system`` label (that label is reserved
# for tests that require a ROCm device, such as coherence stress).

xio_add_test(
  NAME test-ep-emulate
  SOURCE test-ep-emulate.hip
  LABELS test-ep
  TIMEOUT 120
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/test-ep
)

# Multi-thread emulation: hits the per-thread SQ/CQ indexing.
xio_add_test(
  NAME test-ep-emulate-multithread
  SOURCE test-ep-emulate-multithread.hip
  LABELS test-ep
  TIMEOUT 120
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/test-ep
)

# Doorbell-mode emulation: hits the shared atomic sequence
# counter and the multi-thread barrier.
xio_add_test(
  NAME test-ep-emulate-doorbell
  SOURCE test-ep-emulate-doorbell.hip
  LABELS test-ep
  TIMEOUT 120
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/test-ep
)

# Asserts that startTimes / endTimes / XioTimingStats are
# populated by the emulation path (the timing harness self-test).
xio_add_test(
  NAME test-ep-emulate-timing
  SOURCE test-ep-emulate-timing.hip
  LABELS test-ep
  TIMEOUT 120
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/test-ep
)

# Asserts that a fixed CPU response delay is actually honoured.
xio_add_test(
  NAME test-ep-emulate-delay
  SOURCE test-ep-emulate-delay.hip
  LABELS test-ep
  TIMEOUT 120
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/test-ep
)

# --- xio-tester CLI smoke tests --------------------------------
# Drive the test-ep subcommand through the compiled xio-tester
# binary.  The wrapper exits 77 (CTest skip) when the binary is
# missing, which keeps these entries harmless in tree-only or
# install-only checkouts.

set(_test_ep_cli_wrapper
  ${CMAKE_CURRENT_SOURCE_DIR}/run-test-ep-cli.sh)
set(_xio_tester
  ${CMAKE_BINARY_DIR}/xio-tester)

xio_add_script_test(
  NAME test-ep-cli-emulate
  SCRIPT ${_test_ep_cli_wrapper}
  LABELS test-ep cli
  TIMEOUT 60
  ARGS --emulate -n 16
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME test-ep-cli-emulate-threads
  SCRIPT ${_test_ep_cli_wrapper}
  LABELS test-ep cli
  TIMEOUT 60
  ARGS --emulate -n 8 --threads 4
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME test-ep-cli-emulate-doorbell
  SCRIPT ${_test_ep_cli_wrapper}
  LABELS test-ep cli
  TIMEOUT 120
  # Doorbell depth must be >= n * threads (8 * 4 = 32) so the ring does not
  # reuse slots while SQEs are still in flight under a slow poller.
  ARGS --emulate -n 8 --threads 4 --doorbell 32
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME test-ep-cli-emulate-less-timing
  SCRIPT ${_test_ep_cli_wrapper}
  LABELS test-ep cli
  TIMEOUT 120
  ARGS --emulate -n 64 --less-timing
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)
