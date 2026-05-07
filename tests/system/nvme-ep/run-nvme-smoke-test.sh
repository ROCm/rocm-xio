#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Thin wrapper for xio-tester nvme-ep smoke tests.
# Exits 77 (CTest skip) when prerequisites are missing,
# then execs xio-tester with the provided arguments.
#
# The NVMe controller comes from $ROCXIO_NVME_DEVICE.
# All remaining arguments are passed to xio-tester.
#
# For negative tests (expected failures), set
# EXPECT_FAIL=1; the wrapper inverts the exit code.
#
# Usage:
#   run-nvme-smoke-test.sh [xio-tester-args...]

set -e

XIO_TESTER="${XIO_TESTER:-./build/xio-tester}"
CONTROLLER="${ROCXIO_NVME_DEVICE:-$NVME_DEVICE}"

resolve_controller() {
    local device="$1"
    local real
    real="$(readlink -f "$device")" || return 1
    local node
    node="$(basename "$real")"

    if [[ "$node" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
        local controller
        controller="$(basename "$(readlink -f \
            "/sys/class/block/$node/device")")" || return 1
        echo "/dev/$controller"
    else
        echo "$real"
    fi
}

if [ -z "$CONTROLLER" ]; then
    echo "SKIP: ROCXIO_NVME_DEVICE not set"
    exit 77
fi

if [ ! -e "$CONTROLLER" ]; then
    echo "SKIP: NVMe device $CONTROLLER not found"
    exit 77
fi

CONTROLLER_INPUT="$CONTROLLER"
CONTROLLER="$(resolve_controller "$CONTROLLER_INPUT")" || {
    echo "SKIP: failed to resolve NVMe controller from $CONTROLLER_INPUT"
    exit 77
}

if [ "$EUID" -ne 0 ]; then
    echo "SKIP: requires root (run with sudo)"
    exit 77
fi

if [ ! -f "$XIO_TESTER" ]; then
    echo "SKIP: xio-tester not found at $XIO_TESTER"
    exit 77
fi

EXTRA_ARGS=("$@")
if [ -n "${ROCXIO_NVME_QUEUE_ID:-}" ]; then
    EXTRA_ARGS+=(--queue-id "$ROCXIO_NVME_QUEUE_ID")
fi

if [ "${EXPECT_FAIL:-0}" = "1" ]; then
    if "$XIO_TESTER" nvme-ep \
         --controller "$CONTROLLER" "${EXTRA_ARGS[@]}" \
         >/dev/null 2>&1; then
        echo "FAIL: expected failure but command succeeded"
        exit 1
    else
        echo "OK: command failed as expected"
        exit 0
    fi
fi

exec "$XIO_TESTER" nvme-ep \
  --controller "$CONTROLLER" "${EXTRA_ARGS[@]}"
