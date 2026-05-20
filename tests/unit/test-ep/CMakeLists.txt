# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# CPU-only unit tests for the test-ep endpoint.

xio_add_test(
  NAME test-ep-config
  SOURCE test-ep-config.hip
  LABELS unit test-ep
  TIMEOUT 30
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/test-ep
)

# CPU-only test that drives launchCpuThreads() directly,
# playing the role of the GPU producer.  No HIP kernel
# launch occurs, so the test runs cleanly under the
# "unit" label and ships with the CI smoke tests.
xio_add_test(
  NAME test-ep-launch-cpu-threads
  SOURCE test-ep-launch-cpu-threads.hip
  LABELS unit test-ep
  TIMEOUT 60
  INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/endpoints/test-ep
)
