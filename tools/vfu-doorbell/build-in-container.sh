#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Build vfu-doorbell and xio-doorbell inside the libvfio-user fork image, so a
# host without libvfio-user needs nothing installed. The binaries land in
# OUT_DIR (default /tmp/vfu-doorbell/bin).
#
#   IMAGE       container image with a toolchain and the libvfio-user fork
#   OUT_DIR     where the binaries are copied
#   BUILD_TYPE  CMake build type, Release by default. Use Debug for call-path
#               tracing: -g -O0 keeps every function, static ones included, as
#               a symbol a uprobe or gdb can name, and frame pointers are on.

set -euo pipefail

IMAGE="${IMAGE:-batesste-ci-images-ubuntu-libvfio-user-sbates-fork:vfu.3719c3a}"
OUT_DIR="${OUT_DIR:-/tmp/vfu-doorbell/bin}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "${OUT_DIR}"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${SRC_DIR}:/src:ro" \
  -v "${OUT_DIR}:/out" \
  "${IMAGE}" \
  bash -c 'set -e
    cmake -S /src -B /tmp/build -DCMAKE_BUILD_TYPE='"'${BUILD_TYPE}'"' \
          -DCMAKE_C_FLAGS=-fno-omit-frame-pointer >/dev/null
    cmake --build /tmp/build -j"$(nproc)"
    cp --remove-destination /tmp/build/vfu-doorbell /tmp/build/xio-doorbell /out/'
ls -l "${OUT_DIR}"
