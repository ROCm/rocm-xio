#!/bin/bash
# Script to fetch NVMe headers from Linux kernel repository
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/build/gh-fetch-lib.sh
. "${SCRIPT_DIR}/gh-fetch-lib.sh"

# Pinned rather than tracking master. extract-nvme-defines.sh greps for
# specific anchors (enum nvme_opcode, NVME_IDENTIFY_DATA_SIZE,
# struct nvme_common_command, ...) and renames some of them on the way into
# nvme-ep-generated.h, so an upstream rename breaks the build with a wall of
# errors in nvme-ep.h rather than anything pointing here. This is the only
# place the ref is stated: cmake's fetch-nvme-headers target runs this script,
# so a local build and CI resolve the same headers by construction.
#
# Override for a one-off check against a newer kernel; do not leave it set.
KERNEL_REF="${KERNEL_REF:-v6.18}"
KERNEL_REPO_SLUG="torvalds/linux"
OUTPUT_DIR="${1:-}"

if [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: $0 <output_directory>"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "Fetching NVMe headers from Linux kernel ${KERNEL_REF}..."

# The anchors below are exactly what extract-nvme-defines.sh keys off. If a
# download does not carry them there is no point running the extractor: it
# would emit empty enums and the failure would land in nvme-ep.h instead.
echo "  - Downloading include/linux/nvme.h..."
gh_fetch "${KERNEL_REPO_SLUG}" "${KERNEL_REF}" \
         "include/linux/nvme.h" \
         "${OUTPUT_DIR}/linux-nvme.h" \
         "^struct nvme_common_command {"

echo "  - Downloading include/uapi/linux/nvme_ioctl.h..."
gh_fetch "${KERNEL_REPO_SLUG}" "${KERNEL_REF}" \
         "include/uapi/linux/nvme_ioctl.h" \
         "${OUTPUT_DIR}/linux-nvme_ioctl.h" \
         "^struct nvme_passthru_cmd {"

echo "Successfully downloaded NVMe headers to ${OUTPUT_DIR}/"
echo ""
echo "Downloaded files:"
echo "  - linux-nvme.h (main NVMe definitions)"
echo "  - linux-nvme_ioctl.h (ioctl structures)"
