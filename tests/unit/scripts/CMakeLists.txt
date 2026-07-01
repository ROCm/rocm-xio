# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# CPU-only syntax checks for repository shell scripts.

function(xio_add_bash_syntax_test name script)
  add_test(NAME ${name}
    COMMAND bash -n ${script})
  set_tests_properties(${name} PROPERTIES
    LABELS "unit;scripts"
    TIMEOUT 30)
endfunction()

xio_add_bash_syntax_test(
  test-script-generate-endpoint-files
  ${CMAKE_SOURCE_DIR}/scripts/build/generate-endpoint-files.sh)
xio_add_bash_syntax_test(
  test-script-generate-rdma-vendor-headers
  ${CMAKE_SOURCE_DIR}/scripts/build/generate-rdma-vendor-headers.sh)
xio_add_bash_syntax_test(
  test-script-fetch-rdma-headers
  ${CMAKE_SOURCE_DIR}/scripts/build/fetch-rdma-headers.sh)
xio_add_bash_syntax_test(
  test-script-build-rdma-core
  ${CMAKE_SOURCE_DIR}/scripts/build/build-rdma-core.sh)
xio_add_bash_syntax_test(
  test-script-fetch-nvme-headers
  ${CMAKE_SOURCE_DIR}/scripts/build/fetch-nvme-headers.sh)
xio_add_bash_syntax_test(
  test-script-extract-nvme-defines
  ${CMAKE_SOURCE_DIR}/scripts/build/extract-nvme-defines.sh)
xio_add_bash_syntax_test(
  test-script-test-nvme-random-write-verify
  ${CMAKE_SOURCE_DIR}/scripts/test/test-nvme-ep-random-write-verify.sh)
xio_add_bash_syntax_test(
  test-script-test-xio-tester-nvme-ep
  ${CMAKE_SOURCE_DIR}/scripts/test/test-xio-tester-nvme-ep.sh)
xio_add_bash_syntax_test(
  test-script-test-nvme-data-verification
  ${CMAKE_SOURCE_DIR}/scripts/test/test-nvme-ep-data-verification.sh)
xio_add_bash_syntax_test(
  test-script-test-rdma-write-bw-loopback
  ${CMAKE_SOURCE_DIR}/scripts/test/test-rdma-ep-write-bw-loopback.sh)
xio_add_bash_syntax_test(
  test-script-test-rdma-verbs-loopback
  ${CMAKE_SOURCE_DIR}/scripts/test/test-rdma-ep-verbs-loopback.sh)
xio_add_bash_syntax_test(
  test-script-test-xio-tester-rdma-ep
  ${CMAKE_SOURCE_DIR}/scripts/test/test-xio-tester-rdma-ep.sh)
xio_add_bash_syntax_test(
  test-script-test-rdma-xio-loopback
  ${CMAKE_SOURCE_DIR}/scripts/test/test-rdma-ep-xio-loopback.sh)
xio_add_bash_syntax_test(
  test-script-setup-rdma-loopback
  ${CMAKE_SOURCE_DIR}/scripts/test/setup-rdma-loopback.sh)
xio_add_bash_syntax_test(
  test-script-run-nvme-smoke-test
  ${CMAKE_SOURCE_DIR}/tests/system/nvme-ep/run-nvme-smoke-test.sh)
xio_add_bash_syntax_test(
  test-script-run-nvme-script-test
  ${CMAKE_SOURCE_DIR}/tests/system/nvme-ep/run-nvme-script-test.sh)
xio_add_bash_syntax_test(
  test-script-run-2node-test
  ${CMAKE_SOURCE_DIR}/tests/unit/rdma-ep/run-2node-test.sh)
xio_add_bash_syntax_test(
  test-script-run-rdma-script-test
  ${CMAKE_SOURCE_DIR}/tests/system/rdma-ep/run-rdma-script-test.sh)
xio_add_bash_syntax_test(
  test-script-setup-udev-rules
  ${CMAKE_SOURCE_DIR}/udev/setup-udev-rules.sh)
xio_add_bash_syntax_test(
  test-script-setup-bnxt-re-dkms
  ${CMAKE_SOURCE_DIR}/kernel/bnxt/setup-bnxt-re-dkms.sh)
xio_add_bash_syntax_test(
  test-script-setup-rocm-ernic-eth-rdma-dkms
  ${CMAKE_SOURCE_DIR}/kernel/rocm-ernic/setup-rocm-ernic-eth-rdma-dkms.sh)
xio_add_bash_syntax_test(
  test-script-setup-ionic-eth-rdma-dkms
  ${CMAKE_SOURCE_DIR}/kernel/ionic/setup-ionic-eth-rdma-dkms.sh)
xio_add_bash_syntax_test(
  test-script-dkms-common
  ${CMAKE_SOURCE_DIR}/kernel/dkms-common.sh)
