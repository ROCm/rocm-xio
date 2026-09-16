#!/bin/bash
# Script to fetch NVMe headers from Linux kernel repository
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
# SPDX-License-Identifier: MIT

set -euo pipefail

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
KERNEL_REPO="https://raw.githubusercontent.com/torvalds/linux/${KERNEL_REF}"
OUTPUT_DIR="${1:-}"

if [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: $0 <output_directory>"
    exit 1
fi

# Fetch to a temporary file and only publish it once it looks like the header
# we asked for. Without this a 404 page, a proxy error or a truncated body is
# written straight to the output path and the failure surfaces much later as
# empty enums in the generated header.
fetch_header() {
    local path="$1" dest="$2" anchor="$3"
    local tmp="${dest}.tmp"

    echo "  - Downloading ${path}..."
    if ! curl -sS --fail --location --retry 3 --retry-delay 2 \
              "${KERNEL_REPO}/${path}" -o "${tmp}"; then
        rm -f "${tmp}"
        echo "ERROR: failed to download ${path} from ${KERNEL_REPO}" >&2
        exit 1
    fi

    if ! grep -q "${anchor}" "${tmp}"; then
        rm -f "${tmp}"
        echo "ERROR: ${path} from ${KERNEL_REF} does not contain '${anchor}'." >&2
        echo "       Either the download is corrupt or upstream renamed it;" >&2
        echo "       scripts/build/extract-nvme-defines.sh needs that symbol." >&2
        exit 1
    fi

    mv "${tmp}" "${dest}"
}

mkdir -p "$OUTPUT_DIR"

echo "Fetching NVMe headers from Linux kernel ${KERNEL_REF}..."

# Download the main NVMe header with all structure definitions
fetch_header "include/linux/nvme.h" \
             "${OUTPUT_DIR}/linux-nvme.h" \
             "^struct nvme_common_command {"

# Download the UAPI header with ioctl structures
fetch_header "include/uapi/linux/nvme_ioctl.h" \
             "${OUTPUT_DIR}/linux-nvme_ioctl.h" \
             "^struct nvme_passthru_cmd {"

echo "Successfully downloaded NVMe headers to ${OUTPUT_DIR}/"
echo ""
echo "Downloaded files:"
echo "  - linux-nvme.h (main NVMe definitions)"
echo "  - linux-nvme_ioctl.h (ioctl structures)"
