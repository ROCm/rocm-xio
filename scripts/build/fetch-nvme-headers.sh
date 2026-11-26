#!/bin/bash
# Script to fetch NVMe headers from Linux kernel repository
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
# SPDX-License-Identifier: MIT

set -e

KERNEL_REPO="https://raw.githubusercontent.com/torvalds/linux/v6.11"
OUTPUT_DIR="$1"

if [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: $0 <output_directory>"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "Fetching NVMe headers from Linux kernel repository..."

# Download the main NVMe header with all structure definitions
echo "  - Downloading include/linux/nvme.h..."
for attempt in 1 2 3 4 5; do
  curl -sSf "${KERNEL_REPO}/include/linux/nvme.h" -o "${OUTPUT_DIR}/linux-nvme.h" && break
  echo "  Attempt $attempt failed, retrying in $((attempt * 10))s..."
  sleep "$((attempt * 10))"
done
[ -s "${OUTPUT_DIR}/linux-nvme.h" ] || { echo "ERROR: linux-nvme.h is empty after retries"; exit 1; }

# Download the UAPI header with ioctl structures
echo "  - Downloading include/uapi/linux/nvme_ioctl.h..."
for attempt in 1 2 3 4 5; do
  curl -sSf "${KERNEL_REPO}/include/uapi/linux/nvme_ioctl.h" -o "${OUTPUT_DIR}/linux-nvme_ioctl.h" && break
  echo "  Attempt $attempt failed, retrying in $((attempt * 10))s..."
  sleep "$((attempt * 10))"
done
[ -s "${OUTPUT_DIR}/linux-nvme_ioctl.h" ] || { echo "ERROR: linux-nvme_ioctl.h is empty after retries"; exit 1; }

echo "Successfully downloaded NVMe headers to ${OUTPUT_DIR}/"
echo ""
echo "Downloaded files:"
echo "  - linux-nvme.h (main NVMe definitions)"
echo "  - linux-nvme_ioctl.h (ioctl structures)"

