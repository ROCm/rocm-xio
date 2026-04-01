# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# NVMe endpoint data-verification tests.
#
# Each test invokes one of the shell scripts in
# scripts/test/ via a thin wrapper that exits 77 (CTest
# skip) when prerequisites are missing.  The NVMe device
# is taken from $ROCXIO_NVME_DEVICE at runtime.
#
# Labels: hardware, nvme, verify

set(_wrapper
  ${CMAKE_CURRENT_SOURCE_DIR}/run-nvme-script-test.sh)
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
  SCRIPT ${_wrapper}
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
  SCRIPT ${_wrapper}
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
  SCRIPT ${_wrapper}
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
  SCRIPT ${_wrapper}
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
  SCRIPT ${_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 30
  ARGS ${_rand_script}
  ENVIRONMENT
    "MEMORY_MODE=8"
    "NUM_WRITES=8"
    "LFSR_SEED=0xbeef"
    "XIO_TESTER=${_xio_tester}"
)
