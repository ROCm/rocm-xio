#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc.
# All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Thin wrapper for RDMA-EP shell-script tests that
# maps missing prerequisites to CTest skip (exit 77)
# instead of hard failure.  Mirrors the NVMe-EP
# wrapper (tests/system/nvme-ep/run-nvme-script-test.sh).
#
# Usage:
#   run-rdma-script-test.sh <script> [extra-args...]
#
# The RDMA device comes from $ROCXIO_RDMA_DEVICE or
# is auto-detected from /sys/class/infiniband/.

set -e

SCRIPT="$1"
shift || true

if [ -z "$SCRIPT" ]; then
    echo "SKIP: no script specified"
    exit 77
fi

if [ ! -f "$SCRIPT" ]; then
    echo "SKIP: script not found: $SCRIPT"
    exit 77
fi

if [ "$EUID" -ne 0 ]; then
    echo "SKIP: requires root (run with sudo)"
    exit 77
fi

# Auto-detect RDMA device if not specified
RDMA_DEV="${ROCXIO_RDMA_DEVICE:-}"
if [ -z "$RDMA_DEV" ]; then
    for ib in /sys/class/infiniband/*; do
        [ -d "$ib" ] || continue
        RDMA_DEV="$(basename "$ib")"
        break
    done
fi

if [ -z "$RDMA_DEV" ]; then
    echo "SKIP: no RDMA device found" \
        "in /sys/class/infiniband/"
    exit 77
fi

if [ ! -d "/sys/class/infiniband/$RDMA_DEV" ]; then
    echo "SKIP: RDMA device $RDMA_DEV not found"
    exit 77
fi

# Verify at least one non-zero GID is populated
# (confirms neighbor-GID loopback setup was done)
GID_OK=0
for gid in \
    /sys/class/infiniband/"$RDMA_DEV"/ports/1/gids/*
do
    [ -f "$gid" ] || continue
    val="$(cat "$gid" 2>/dev/null || true)"
    case "$val" in
        0000:0000:0000:0000:0000:0000:0000:0000)
            continue ;;
        "")
            continue ;;
        *)
            GID_OK=1
            break ;;
    esac
done

if [ "$GID_OK" -ne 1 ]; then
    echo "SKIP: no populated GID on $RDMA_DEV" \
        "(run setup-rdma-loopback.sh first)"
    exit 77
fi

if [ ! -e /dev/kfd ]; then
    echo "SKIP: /dev/kfd not found (no GPU)"
    exit 77
fi

export ROCXIO_RDMA_DEVICE="$RDMA_DEV"
exec bash "$SCRIPT" "$@"
