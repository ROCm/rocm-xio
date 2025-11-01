#!/bin/bash
# Extract NVMe definitions from Linux kernel headers
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
# SPDX-License-Identifier: MIT

set -e

KERNEL_HEADER="$1"
OUTPUT_FILE="$2"

if [ -z "$KERNEL_HEADER" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "Usage: $0 <kernel_header> <output_file>"
    exit 1
fi

if [ ! -f "$KERNEL_HEADER" ]; then
    echo "Error: Input file $KERNEL_HEADER not found"
    exit 1
fi

cat > "$OUTPUT_FILE" << 'HEADER_START'
/* SPDX-License-Identifier: MIT */
/*
 * NVMe definitions extracted from Linux kernel headers
 * Source: https://github.com/torvalds/linux/blob/master/include/linux/nvme.h
 * 
 * This file is auto-generated from the Linux kernel NVMe headers.
 * Do not edit manually - run 'make fetch-nvme-headers' to regenerate.
 */

#ifndef NVME_DEFS_FROM_KERNEL_H
#define NVME_DEFS_FROM_KERNEL_H

#include <cstdint>

HEADER_START

echo "" >> "$OUTPUT_FILE"
echo "// NVM Express I/O Command Opcodes" >> "$OUTPUT_FILE"
echo "// Extracted from enum nvme_opcode" >> "$OUTPUT_FILE"

# Extract NVM command opcodes and convert to #define
sed -n '/enum nvme_opcode {/,/^};/p' "$KERNEL_HEADER" | \
    grep "nvme_cmd" | \
    sed 's/^\t*//' | \
    sed 's/nvme_cmd_/#define NVME_CMD_/' | \
    sed 's/ = / /' | \
    sed 's/,$//' >> "$OUTPUT_FILE" || true

echo "" >> "$OUTPUT_FILE"
echo "// NVM Express Admin Command Opcodes" >> "$OUTPUT_FILE"
echo "// Extracted from enum nvme_admin_opcode" >> "$OUTPUT_FILE"

# Extract Admin command opcodes and convert to #define  
sed -n '/enum nvme_admin_opcode {/,/^};/p' "$KERNEL_HEADER" | \
    grep "nvme_admin" | \
    sed 's/^\t*//' | \
    sed 's/nvme_admin_/#define NVME_ADMIN_/' | \
    sed 's/ = / /' | \
    sed 's/,$//' >> "$OUTPUT_FILE" || true

echo "" >> "$OUTPUT_FILE"
echo "// NVMe Status Code Types" >> "$OUTPUT_FILE"
echo "// Status Code Type values (bits 11:9 of status field)" >> "$OUTPUT_FILE"

# Extract status code types - look for the specific enum
grep -A20 "enum {" "$KERNEL_HEADER" | \
    grep "NVME_SCT_" | head -10 | \
    sed 's/^\t*//' | \
    sed 's/ = /#define &/' | \
    sed 's/,$//' >> "$OUTPUT_FILE" || true

echo "" >> "$OUTPUT_FILE"
echo "// NVMe Generic Command Status Codes" >> "$OUTPUT_FILE"
echo "// Status Code values (bits 8:1 of status field)" >> "$OUTPUT_FILE"

# Extract status codes - more targeted search
grep -B2 -A1 "NVME_SC_SUCCESS\|NVME_SC_INVALID\|NVME_SC_ABORT\|NVME_SC_LBA_RANGE\|NVME_SC_INTERNAL\|NVME_SC_NS_NOT_READY" "$KERNEL_HEADER" | \
    grep "NVME_SC_" | \
    sed 's/^\t*//' | \
    sed 's/^#define //' | \
    sed 's/ = /#define &/' | \
    sed 's/,$//' | \
    sort -u >> "$OUTPUT_FILE" || true

cat >> "$OUTPUT_FILE" << 'FOOTER'

#endif // NVME_DEFS_FROM_KERNEL_H
FOOTER

echo "Extracted NVMe definitions to $OUTPUT_FILE"

