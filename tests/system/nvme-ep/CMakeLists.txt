# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# NVMe endpoint system tests.
#
# Wrappers exit 77 (CTest skip) when prerequisites are
# missing.  The NVMe device comes from
# $ROCXIO_NVME_DEVICE at runtime.
#
# Label convention:
#   hardware  - requires real NVMe device + root
#   nvme      - NVMe endpoint tests
#   verify    - data-integrity verification
#   smoke     - fast completion-only checks
#   negative  - expected-failure validation

set(_verify_wrapper
  ${CMAKE_CURRENT_SOURCE_DIR}/run-nvme-script-test.sh)
set(_smoke_wrapper
  ${CMAKE_CURRENT_SOURCE_DIR}/run-nvme-smoke-test.sh)
set(_seq_script
  ${CMAKE_SOURCE_DIR}/scripts/test/test-nvme-ep-data-verification.sh)
set(_rand_script
  ${CMAKE_SOURCE_DIR}/scripts/test/test-nvme-ep-random-write-verify.sh)
set(_xio_tester
  ${CMAKE_BINARY_DIR}/xio-tester)

# --- Sequential data verification -----------------------

# Known failure: MEMORY_MODE=0 (host memory) with
# lbas-per-io > page_size/lba_size uses linear DMA
# address arithmetic (writeBufferDma + offset) which
# breaks across page boundaries because hipHostMalloc
# does not guarantee physical contiguity.  The NVMe
# controller reads stale data from the wrong physical
# page for commands beyond the first.  Device memory
# modes (8, 11) are unaffected because GPU VRAM is
# physically contiguous.
xio_add_script_test(
  NAME nvme-verify-seq-host-mem
  SCRIPT ${_verify_wrapper}
  LABELS hardware nvme verify known-fail
  TIMEOUT 120
  ARGS ${_seq_script}
  ENVIRONMENT
    "MEMORY_MODE=0"
    "WRITE_IO=4"
    "LFSR_SEED=0x1234"
    "USE_PCI_MMIO_BRIDGE=0"
    "XIO_TESTER=${_xio_tester}"
)
set_tests_properties(nvme-verify-seq-host-mem
  PROPERTIES DISABLED TRUE)

xio_add_script_test(
  NAME nvme-verify-seq-device-mem
  SCRIPT ${_verify_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 120
  ARGS ${_seq_script}
  ENVIRONMENT
    "MEMORY_MODE=8"
    "WRITE_IO=4"
    "LFSR_SEED=0x5678"
    "BASE_LBA=1024"
    "USE_PCI_MMIO_BRIDGE=0"
    "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-verify-seq-device-mem-queues
  SCRIPT ${_verify_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 120
  ARGS ${_seq_script}
  ENVIRONMENT
    "MEMORY_MODE=11"
    "WRITE_IO=4"
    "LFSR_SEED=0x9abc"
    "BASE_LBA=1024"
    "USE_PCI_MMIO_BRIDGE=0"
    "XIO_TESTER=${_xio_tester}"
)

# --- Random write verification --------------------------

xio_add_script_test(
  NAME nvme-verify-rand-host-mem
  SCRIPT ${_verify_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 30
  ARGS ${_rand_script}
  ENVIRONMENT
    "MEMORY_MODE=0"
    "NUM_WRITES=8"
    "LFSR_SEED=0xdead"
    "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-verify-rand-device-mem
  SCRIPT ${_verify_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 30
  ARGS ${_rand_script}
  ENVIRONMENT
    "MEMORY_MODE=8"
    "NUM_WRITES=8"
    "LFSR_SEED=0xbeef"
    "XIO_TESTER=${_xio_tester}"
)

# --- Batch-size smoke tests -----------------------------
# Verify the kernel completes for various doorbell
# batching configurations.  All use random access with
# single-LBA I/Os to stay within one DMA page.

set(_smoke_common
  --access-pattern random --lbas-per-io 1
  --lfsr-seed 32 --read-io 23 --queue-length 128)

xio_add_script_test(
  NAME nvme-smoke-batch-1
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 30
  ARGS ${_smoke_common} --batch-size 1
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-smoke-batch-4
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 30
  ARGS ${_smoke_common} --batch-size 4
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-smoke-batch-16
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 30
  ARGS ${_smoke_common} --batch-size 16
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-smoke-batch-0
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 30
  ARGS ${_smoke_common} --batch-size 0
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-smoke-batch-128
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 30
  ARGS --access-pattern random --lbas-per-io 1
    --lfsr-seed 32 --read-io 256
    --queue-length 256 --batch-size 128
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

# --- Multi-queue smoke tests ----------------------------

xio_add_script_test(
  NAME nvme-smoke-queues-2
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 30
  ARGS ${_smoke_common} --num-queues 2
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-smoke-queues-4
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 30
  ARGS ${_smoke_common} --num-queues 4
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-smoke-queues-2-batch-16
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 30
  ARGS --access-pattern random --lbas-per-io 1
    --lfsr-seed 32 --read-io 64
    --queue-length 128 --num-queues 2
    --batch-size 16
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

# --- Memory-mode smoke tests ---------------------------
# Mode 3 (device queues, host data) is not covered by
# the verify tests.

xio_add_script_test(
  NAME nvme-smoke-memmode-3
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 30
  ARGS ${_smoke_common} -m 3 --less-timing
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-smoke-memmode-3-batch-4
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 30
  ARGS ${_smoke_common}
    -m 3 --less-timing --batch-size 4
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

# --- Negative tests (expected failures) -----------------

xio_add_script_test(
  NAME nvme-reject-threads-2
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme negative
  TIMEOUT 15
  ARGS --threads 2 --read-io 1
  ENVIRONMENT
    "XIO_TESTER=${_xio_tester}"
    "EXPECT_FAIL=1"
)

xio_add_script_test(
  NAME nvme-reject-batch-too-large
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme negative
  TIMEOUT 15
  ARGS --batch-size 1024 --read-io 1
  ENVIRONMENT
    "XIO_TESTER=${_xio_tester}"
    "EXPECT_FAIL=1"
)
