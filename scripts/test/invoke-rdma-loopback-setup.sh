#!/usr/bin/env bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# CTest entry for rdma-hw-setup: forwards VENDOR into the sudo environment so
# setup-rdma-loopback.sh sees the same vendor selection as the parent ctest
# process (default sudo env_reset drops inherited variables).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec sudo env "VENDOR=${VENDOR:-all}" bash "${SCRIPT_DIR}/setup-rdma-loopback.sh"
