#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Thin wrapper for xio-tester nvme-ep KV command set tests.
# Exits 77 (CTest skip) when prerequisites are missing, then execs
# xio-tester with the provided arguments.
#
# Linux does not attach KV command set namespaces (CSI=2) as block
# devices, so there is no /dev/nvme0nX for them. KV commands are issued
# against the controller device (/dev/nvme0) with an explicit NSID.
#
# Required environment variables:
#   ROCXIO_NVME_KV_CTRL   NVMe controller device (e.g. /dev/nvme0)
#   ROCXIO_NVME_KV_NSID   Integer NSID of the KV namespace (e.g. 1)
#
# KV values must be <= 131072 bytes (128 KiB): the vfio-user transport
# rejects any payload longer than max_io_size (32 x 4096), and
# nvme_cmd_map_prps cannot describe more than 33 iovecs regardless of how
# the transport is tuned. This wrapper enforces the ceiling via
# --data-buffer-size / --value-size so callers do not have to remember it.
#
# Usage:
#   run-nvme-kv-test.sh [xio-tester-args...]

set -e

XIO_TESTER="${XIO_TESTER:-./build/xio-tester}"
KV_CTRL="${ROCXIO_NVME_KV_CTRL:-}"
KV_NSID="${ROCXIO_NVME_KV_NSID:-}"

# ---- prerequisite checks -------------------------------------------------

if [ -z "$KV_CTRL" ]; then
    echo "SKIP: ROCXIO_NVME_KV_CTRL not set"
    exit 77
fi

if [ -z "$KV_NSID" ]; then
    echo "SKIP: ROCXIO_NVME_KV_NSID not set"
    exit 77
fi

if [ ! -e "$KV_CTRL" ]; then
    echo "SKIP: NVMe controller $KV_CTRL not found"
    exit 77
fi

if [ "$EUID" -ne 0 ]; then
    echo "SKIP: requires root (run with sudo)"
    exit 77
fi

if [ ! -f "$XIO_TESTER" ]; then
    echo "SKIP: xio-tester not found at $XIO_TESTER"
    exit 77
fi

# ---- run -----------------------------------------------------------------

# Prepend value-size and data-buffer-size caps. An explicit --value-size
# or --data-buffer-size in "$@" overrides these because xio-tester uses
# the last occurrence of a flag.
KV_MAX_VALUE=65536

# Add --pci-mmio-bridge when the rocjitsu/vfio-user CI environment sets
# XIO_FORCE_PCI_MMIO_BRIDGE=1 (or USE_PCI_MMIO_BRIDGE=1). On rocjitsu,
# doorbell writes from the GPU kernel cannot reliably reach the SPDK
# vfio-user controller via direct BAR0 mmap; the pci-mmio-bridge shadow
# buffer path is the supported alternative.
PCI_MMIO_BRIDGE_ARG=""
if [ "${XIO_FORCE_PCI_MMIO_BRIDGE:-0}" = "1" ] || \
   [ "${USE_PCI_MMIO_BRIDGE:-0}" = "1" ]; then
    PCI_MMIO_BRIDGE_ARG="--pci-mmio-bridge"
fi

exec "$XIO_TESTER" nvme-ep \
    --controller "$KV_CTRL" \
    --namespace  "$KV_NSID" \
    --value-size "$KV_MAX_VALUE" \
    --data-buffer-size "$KV_MAX_VALUE" \
    ${PCI_MMIO_BRIDGE_ARG:+"$PCI_MMIO_BRIDGE_ARG"} \
    "$@"
