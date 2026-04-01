#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Thin wrapper for NVMe shell-script tests that maps
# missing prerequisites to CTest skip (exit 77) instead
# of hard failure. This avoids modifying the scripts in
# scripts/test/ while giving CTest proper skip semantics.
#
# Usage:
#   run-nvme-script-test.sh <script> [extra-args...]
#
# The NVMe controller comes from $ROCXIO_NVME_DEVICE
# (or legacy $NVME_DEVICE).

set -e

SCRIPT="$1"
shift || true

CONTROLLER="${ROCXIO_NVME_DEVICE:-$NVME_DEVICE}"

if [ -z "$SCRIPT" ]; then
    echo "SKIP: no script specified"
    exit 77
fi

if [ ! -f "$SCRIPT" ]; then
    echo "SKIP: script not found: $SCRIPT"
    exit 77
fi

if [ -z "$CONTROLLER" ]; then
    echo "SKIP: ROCXIO_NVME_DEVICE not set"
    exit 77
fi

if [ ! -e "$CONTROLLER" ]; then
    echo "SKIP: NVMe device $CONTROLLER not found"
    exit 77
fi

if [ "$EUID" -ne 0 ]; then
    echo "SKIP: requires root (run with sudo)"
    exit 77
fi

if ! command -v python3 &>/dev/null; then
    echo "SKIP: python3 not found"
    exit 77
fi

if ! command -v nvme &>/dev/null; then
    echo "SKIP: nvme-cli not found"
    exit 77
fi

exec bash "$SCRIPT" "$CONTROLLER" "$@"
