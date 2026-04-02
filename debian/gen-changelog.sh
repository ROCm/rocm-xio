#!/bin/sh
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Generate debian/changelog from CMakeLists.txt version
# and git metadata. Intended for CI use.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

MAJOR=$(sed -n \
  's/^set(ROCM_XIO_LIBRARY_MAJOR \([0-9]*\))/\1/p' \
  "${PROJECT_DIR}/CMakeLists.txt")
MINOR=$(sed -n \
  's/^set(ROCM_XIO_LIBRARY_MINOR \([0-9]*\))/\1/p' \
  "${PROJECT_DIR}/CMakeLists.txt")
PATCH=$(sed -n \
  's/^set(ROCM_XIO_LIBRARY_PATCH \([0-9]*\))/\1/p' \
  "${PROJECT_DIR}/CMakeLists.txt")

VERSION="${MAJOR}.${MINOR}.${PATCH}"

if command -v git >/dev/null 2>&1 && \
   git -C "${PROJECT_DIR}" rev-parse HEAD \
     >/dev/null 2>&1; then
  SHORT_SHA=$(git -C "${PROJECT_DIR}" \
    rev-parse --short HEAD)
  DEB_VERSION="${VERSION}~git${SHORT_SHA}"
else
  DEB_VERSION="${VERSION}"
fi

DIST=$(lsb_release -cs 2>/dev/null || echo "noble")
DATE=$(date -R)

cat > "${SCRIPT_DIR}/changelog" <<EOF
rocm-xio (${DEB_VERSION}) ${DIST}; urgency=low

  * Automated build from git ${SHORT_SHA:-HEAD}

 -- AMD ROCm Build <rocm-xio@amd.com>  ${DATE}
EOF

echo "Generated debian/changelog: ${DEB_VERSION}"
