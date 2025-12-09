#!/bin/bash
# Script to fetch NVMe headers from Linux kernel repository
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
# SPDX-License-Identifier: MIT

set -e

KERNEL_REPO="https://raw.githubusercontent.com/torvalds/linux/master"
OUTPUT_DIR="$1"

if [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: $0 <output_directory>"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "Fetching NVMe headers from Linux kernel repository..."

# Download the main NVMe header with all structure definitions
echo "  - Downloading include/linux/nvme.h..."
curl -sS "${KERNEL_REPO}/include/linux/nvme.h" -o "${OUTPUT_DIR}/linux-nvme.h"

# Download the UAPI header with ioctl structures
echo "  - Downloading include/uapi/linux/nvme_ioctl.h..."
curl -sS "${KERNEL_REPO}/include/uapi/linux/nvme_ioctl.h" -o "${OUTPUT_DIR}/linux-nvme_ioctl.h"

echo "Successfully downloaded NVMe headers to ${OUTPUT_DIR}/"
echo ""
echo "Downloaded files:"
echo "  - linux-nvme.h (main NVMe definitions)"
echo "  - linux-nvme_ioctl.h (ioctl structures)"

