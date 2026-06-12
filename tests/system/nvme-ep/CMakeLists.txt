# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

# NVMe endpoint system tests.
#
# Wrappers exit 77 (CTest skip) when prerequisites are missing. The NVMe
# device comes from $ROCXIO_NVME_DEVICE at runtime.
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

# Host memory with PRP list support: per-page physical
# addresses are resolved via pagemap so multi-LBA
# transfers across non-contiguous pages work correctly.
xio_add_script_test(
  NAME nvme-verify-seq-host-mem
  SCRIPT ${_verify_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 120
  ARGS ${_seq_script}
  ENVIRONMENT
    "MEMORY_MODE=0"
    "WRITE_IO=4"
    "LFSR_SEED=0x1234"
    "USE_PCI_MMIO_BRIDGE=0"
    "XIO_TESTER=${_xio_tester}"
)

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
  TIMEOUT 120
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
  TIMEOUT 120
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

# --- Multi-LBA PRP list smoke tests ---------------------
# Exercise PRP list construction for transfers spanning
# more than two NVMe pages.  Uses device memory (VRAM)
# which is physically contiguous.

set(_smoke_multi_lba
  --access-pattern random --lfsr-seed 42
  --read-io 16 --queue-length 128)

xio_add_script_test(
  NAME nvme-smoke-lbas-per-io-8-device
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 30
  ARGS ${_smoke_multi_lba}
    --lbas-per-io 8 -m 8
    --data-buffer-size 524288
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-smoke-lbas-per-io-32-device
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 30
  ARGS ${_smoke_multi_lba}
    --lbas-per-io 32 -m 8
    --data-buffer-size 2097152
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-smoke-lbas-per-io-8-host
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 30
  ARGS ${_smoke_multi_lba}
    --lbas-per-io 8 -m 0
    --data-buffer-size 524288
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-smoke-lbas-per-io-32-host
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 30
  ARGS ${_smoke_multi_lba}
    --lbas-per-io 32 -m 0
    --data-buffer-size 2097152
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

# Multi-LBA data verification with device memory
xio_add_script_test(
  NAME nvme-verify-seq-device-mem-multi-lba
  SCRIPT ${_verify_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 120
  ARGS ${_seq_script}
  ENVIRONMENT
    "MEMORY_MODE=8"
    "WRITE_IO=4"
    "BLOCKS_PER_CMD=32"
    "LFSR_SEED=0xCAFE"
    "BASE_LBA=2048"
    "USE_PCI_MMIO_BRIDGE=0"
    "XIO_TESTER=${_xio_tester}"
)

# --- Per-command I/O strictly greater than 8 KiB ----------
# Most verify tests above use 1 or 8 LBAs per command (8 * 512 B = 4 KiB
# on 512-byte namespaces), which does not span more than two 4 KiB PRP
# pages.  BLOCKS_PER_CMD=20 yields 20 * 512 B = 10240 B (> 8192 B) on
# typical 512e/512 namespaces; on 4 KiB LBAs the transfer is even larger.
# Inline --verify tests use --lbas-per-io 20 for the same guarantee.

xio_add_script_test(
  NAME nvme-verify-seq-host-mem-gt8k
  SCRIPT ${_verify_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 120
  ARGS ${_seq_script}
  ENVIRONMENT
    "MEMORY_MODE=0"
    "WRITE_IO=4"
    "BLOCKS_PER_CMD=20"
    "LFSR_SEED=0xD001"
    "BASE_LBA=2048"
    "USE_PCI_MMIO_BRIDGE=0"
    "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-verify-seq-device-mem-gt8k
  SCRIPT ${_verify_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 120
  ARGS ${_seq_script}
  ENVIRONMENT
    "MEMORY_MODE=8"
    "WRITE_IO=4"
    "BLOCKS_PER_CMD=20"
    "LFSR_SEED=0xD002"
    "BASE_LBA=2048"
    "USE_PCI_MMIO_BRIDGE=0"
    "XIO_TESTER=${_xio_tester}"
)

# --- Inline read-back verification (--verify) ----------
# Write-then-read with LFSR verification in a single
# xio-tester invocation.  Requires --batch-size 1
# (default) and --write-io >= --read-io.

xio_add_script_test(
  NAME nvme-verify-inline-host-mem
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 30
  ARGS --access-pattern random -m 0
    --lbas-per-io 1 --lfsr-seed 0xA1
    --write-io 16 --read-io 16
    --queue-length 128 --verify
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-verify-inline-device-mem
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 30
  ARGS --access-pattern random -m 8
    --lbas-per-io 1 --lfsr-seed 0xA2
    --write-io 16 --read-io 16
    --queue-length 128 --less-timing --verify
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-verify-inline-seq
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 30
  ARGS --access-pattern sequential -m 0
    --lbas-per-io 8 --lfsr-seed 0xA3
    --write-io 4 --read-io 4
    --queue-length 128
    --data-buffer-size 1048576 --verify
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-verify-inline-multi-lba
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 30
  ARGS --access-pattern random -m 0
    --lbas-per-io 8 --lfsr-seed 0xA4
    --write-io 8 --read-io 8
    --queue-length 128
    --data-buffer-size 524288 --verify
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-verify-inline-gt8k-host-mem
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 60
  ARGS --access-pattern sequential -m 0
    --lbas-per-io 20 --lfsr-seed 0xB1
    --write-io 8 --read-io 8
    --queue-length 128
    --data-buffer-size 2097152 --verify
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

xio_add_script_test(
  NAME nvme-verify-inline-gt8k-device-mem
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 60
  ARGS --access-pattern sequential -m 8
    --lbas-per-io 20 --lfsr-seed 0xB2
    --write-io 8 --read-io 8
    --queue-length 128 --less-timing
    --data-buffer-size 2097152 --verify
  ENVIRONMENT "XIO_TESTER=${_xio_tester}"
)

# --- Negative tests (expected failures) -----------------

xio_add_script_test(
  NAME nvme-reject-verify-no-writes
  SCRIPT ${_smoke_wrapper}
  LABELS hardware nvme negative
  TIMEOUT 15
  ARGS --read-io 10 --verify
  ENVIRONMENT
    "XIO_TESTER=${_xio_tester}"
    "EXPECT_FAIL=1"
)

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

# --- xio-tester wrapper smoke tests ---------------------
# Exercise the xio-tester nvme-ep wrapper script with
# various batch-size and queue configurations.

set(_nvme_tester_script
  ${CMAKE_SOURCE_DIR}/scripts/test/test-xio-tester-nvme-ep.sh)

xio_add_script_test(
  NAME nvme-ep-batch-16
  SCRIPT ${_verify_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 120
  ARGS ${_nvme_tester_script}
  ENVIRONMENT
    "BATCH_SIZE=16"
    "READ_IO=128"
    "BUILD_DIR=${CMAKE_BINARY_DIR}"
)

xio_add_script_test(
  NAME nvme-ep-num-queues-4
  SCRIPT ${_verify_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 120
  ARGS ${_nvme_tester_script}
  ENVIRONMENT
    "NUM_QUEUES=4"
    "READ_IO=128"
    "BUILD_DIR=${CMAKE_BINARY_DIR}"
)

xio_add_script_test(
  NAME nvme-ep-batch-16-queues-4
  SCRIPT ${_verify_wrapper}
  LABELS hardware nvme smoke
  TIMEOUT 120
  ARGS ${_nvme_tester_script}
  ENVIRONMENT
    "BATCH_SIZE=16"
    "NUM_QUEUES=4"
    "READ_IO=128"
    "BUILD_DIR=${CMAKE_BINARY_DIR}"
)

# --- QID-8 ring-wrap resurrect stress test --------------
# Proves the kernel-module resurrect path resets the host-side NVMe
# ring pointers (sq_tail/last_sq_tail/cq_head/cq_phase) after a deleted
# queue is recreated. Drives an odd number of half-ring-wraps so
# cq_phase flips to 0, deletes + resurrects QID 8, then verifies a
# CPU-7-pinned write/read round-trips. Without the fix the first
# post-resurrect I/O hangs and the controller resets.
#
# Default driver is GPU-free (nvme admin-passthru DELETE + the
# test-only ROCM_XIO_DEBUG_RESURRECT_QID ioctl), so it runs even where
# the Navi 21 GPU is wedged by the AMD reset bug. The helper binary
# issues that ioctl.
# Compile the tiny C helper as CXX: the top-level project only enables
# CXX and HIP (not C), and the helper is plain C that is valid C++.
set_source_files_properties(
  ${CMAKE_SOURCE_DIR}/scripts/test/resurrect-qid.c
  PROPERTIES LANGUAGE CXX)
add_executable(resurrect-qid
  ${CMAKE_SOURCE_DIR}/scripts/test/resurrect-qid.c)
set_target_properties(resurrect-qid PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

set(_qid8_stress
  ${CMAKE_SOURCE_DIR}/scripts/test/test-qid8-ring-wrap-stress.sh)

xio_add_script_test(
  NAME nvme-qid8-ring-wrap-stress
  SCRIPT ${_verify_wrapper}
  LABELS hardware nvme verify
  TIMEOUT 300
  ARGS ${_qid8_stress}
  ENVIRONMENT
    "STRESS_ITERS=5"
    "STRESS_HALF_WRAPS=3"
    "RESURRECT_HELPER=${CMAKE_BINARY_DIR}/resurrect-qid"
)

# --- QID quiesce isolation + delete/create stress tests --------------
# Two GPU-free CPU-only stress tests that exercise rocm-xio queue
# manipulation against a WARM kernel (after heavy prior I/O):
#   nvme-qid-quiesce-stress  -- proves QUIESCE_NS stops dispatch to the
#       target hctx under load while other queues keep flowing, and that
#       UNQUIESCE_NS cleanly resumes it (ordering-proven, not just slow).
#   nvme-qid-recreate-stress -- proves a DELETE + resurrect cycle leaves
#       the recreated queue usable under a sustained post-create hammer.
#
# Both drive the PRODUCTION rocm-xio ioctls via tiny C helpers. As with
# resurrect-qid above, the helpers are plain C compiled as CXX (the
# top-level project enables only CXX/HIP). quiesce-qid/unquiesce-qid
# issue QUIESCE_NS/UNQUIESCE_NS; hold-quiesce holds the controlling fd
# open for a fixed window (the module auto-restarts a quiesced hctx the
# instant that fd closes, so a fire-and-exit quiesce would not hold).
set_source_files_properties(
  ${CMAKE_SOURCE_DIR}/scripts/test/quiesce-qid.c
  ${CMAKE_SOURCE_DIR}/scripts/test/unquiesce-qid.c
  ${CMAKE_SOURCE_DIR}/scripts/test/hold-quiesce.c
  PROPERTIES LANGUAGE CXX)
add_executable(quiesce-qid
  ${CMAKE_SOURCE_DIR}/scripts/test/quiesce-qid.c)
add_executable(unquiesce-qid
  ${CMAKE_SOURCE_DIR}/scripts/test/unquiesce-qid.c)
add_executable(hold-quiesce
  ${CMAKE_SOURCE_DIR}/scripts/test/hold-quiesce.c)
set_target_properties(quiesce-qid unquiesce-qid hold-quiesce PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

set(_qid_quiesce_stress
  ${CMAKE_SOURCE_DIR}/scripts/test/test-qid-quiesce-stress.sh)
set(_qid_recreate_stress
  ${CMAKE_SOURCE_DIR}/scripts/test/test-qid-recreate-stress.sh)

# Quiesce isolation: needs the hold-quiesce helper to keep the window
# open; QUIESCE_HOLD_S must exceed FIRST_IO_TIMEOUT_S+3 (hardened
# preflight), so pass 12 against the default 8s first-IO timeout.
xio_add_script_test(
  NAME nvme-qid-quiesce-stress
  SCRIPT ${_verify_wrapper}
  LABELS hardware nvme stress
  TIMEOUT 600
  ARGS ${_qid_quiesce_stress}
  ENVIRONMENT
    "STRESS_ITERS=3"
    "QUIESCE_HOLD_S=12"
    "HOLD_HELPER=${CMAKE_BINARY_DIR}/hold-quiesce"
    "QUIESCE_HELPER=${CMAKE_BINARY_DIR}/quiesce-qid"
    "UNQUIESCE_HELPER=${CMAKE_BINARY_DIR}/unquiesce-qid"
)

# Delete/create resilience: reuses the resurrect-qid helper built above.
xio_add_script_test(
  NAME nvme-qid-recreate-stress
  SCRIPT ${_verify_wrapper}
  LABELS hardware nvme stress
  TIMEOUT 600
  ARGS ${_qid_recreate_stress}
  ENVIRONMENT
    "STRESS_ITERS=5"
    "STRESS_HALF_WRAPS=3"
    "RESURRECT_HELPER=${CMAKE_BINARY_DIR}/resurrect-qid"
)
