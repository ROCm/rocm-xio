#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Thin wrapper for xio-tester test-ep smoke tests.
# Exits 77 (CTest skip) when xio-tester is not present,
# then execs xio-tester with the provided arguments.
#
# All remaining arguments are passed through to xio-tester
# after the literal "test-ep" subcommand.
#
# Usage:
#   run-test-ep-cli.sh [xio-tester-args...]

set -e

XIO_TESTER="${XIO_TESTER:-./build/xio-tester}"

if [ ! -x "$XIO_TESTER" ]; then
    echo "SKIP: xio-tester not found at $XIO_TESTER"
    exit 77
fi

exec "$XIO_TESTER" test-ep "$@"
