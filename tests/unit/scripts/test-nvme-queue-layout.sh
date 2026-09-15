#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Verify that struct nvme_queue's key field offsets match what the
# rocm-xio kernel module's rocm_xio_nvmeq_layout mirror expects.
#
# The module carries a compile-time static_assert that sq_dma_addr is at
# offset 80. This test confirms the same fact at runtime from BTF, so CI
# catches a mismatch on kernels where the assert was not rebuilt.
#
# Requirements: pahole and /sys/kernel/btf/nvme (loaded nvme.ko with BTF).
# If either is absent the test exits SKIP (77) so CTest marks it skipped.

set -euo pipefail

SKIP=77

if ! command -v pahole &>/dev/null; then
    echo "SKIP: pahole not found"
    exit $SKIP
fi

BTF=/sys/kernel/btf/nvme
if [ ! -f "$BTF" ]; then
    echo "SKIP: $BTF not present (nvme.ko not loaded or built without BTF)"
    exit $SKIP
fi

# Expected offsets from our rocm_xio_nvmeq_layout mirror and static_assert.
EXPECTED_SQ_DMA=80
EXPECTED_CQ_DMA=88
EXPECTED_Q_DEPTH=104
EXPECTED_CQ_VECTOR=108

failures=0
check_offset() {
    local field="$1" expected="$2"
    local actual
    actual=$(pahole -C nvme_queue "$BTF" 2>/dev/null \
             | awk -v f="$field" '$0 ~ f {
                 # pahole prints "/* offset_bytes offset_bits */"
                 match($0, /\/\*[[:space:]]+([0-9]+)/, m); print m[1]; exit
               }')
    if [ -z "$actual" ]; then
        echo "FAIL: could not find $field in pahole output"
        failures=$((failures + 1))
        return
    fi
    if [ "$actual" -eq "$expected" ]; then
        echo "PASS: nvme_queue::$field at offset $actual (expected $expected)"
    else
        echo "FAIL: nvme_queue::$field at offset $actual (expected $expected)"
        echo "      Update rocm_xio_nvmeq_layout in kernel/rocm-xio/rocm-xio.c"
        failures=$((failures + 1))
    fi
}

check_offset sq_dma_addr  $EXPECTED_SQ_DMA
check_offset cq_dma_addr  $EXPECTED_CQ_DMA
check_offset q_depth      $EXPECTED_Q_DEPTH
check_offset cq_vector    $EXPECTED_CQ_VECTOR

if [ "$failures" -eq 0 ]; then
    echo "All nvme_queue layout checks passed."
    exit 0
fi
echo "$failures nvme_queue layout check(s) failed."
exit 1
