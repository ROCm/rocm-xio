#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Unit checks for the rocm-xio-check utility using a synthetic root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CHECKER="${REPO_ROOT}/scripts/rocm-xio-check"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

ROOT="${TMPDIR}/root"
BIN="${TMPDIR}/bin"

mkdir -p \
  "${ROOT}/opt/rocm" \
  "${ROOT}/dev/dri" \
  "${ROOT}/etc/udev/rules.d" \
  "${ROOT}/sys/class/infiniband" \
  "${BIN}"

touch \
  "${ROOT}/dev/kfd" \
  "${ROOT}/dev/rocm-xio" \
  "${ROOT}/dev/dri/renderD128" \
  "${ROOT}/dev/dri/renderD129" \
  "${ROOT}/dev/nvme0" \
  "${ROOT}/etc/udev/rules.d/99-rocm-xio-rdma.rules"

chmod 666 \
  "${ROOT}/dev/kfd" \
  "${ROOT}/dev/rocm-xio" \
  "${ROOT}/dev/dri/renderD128" \
  "${ROOT}/dev/dri/renderD129" \
  "${ROOT}/dev/nvme0"

cat > "${BIN}/rocminfo" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "${BIN}/rdma" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "link" ] && [ "${2:-}" = "show" ]; then
  echo "link rocm-rdma-bnxt0/1 state ACTIVE physical_state LINK_UP"
  exit 0
fi
exit 1
EOF

cat > "${BIN}/lsmod" <<'EOF'
#!/bin/bash
echo "rocm_xio 16384 0"
EOF

chmod +x "${BIN}/rocminfo" "${BIN}/rdma" "${BIN}/lsmod"

PASS_OUT="${TMPDIR}/pass.out"
PATH="${BIN}:${PATH}" HSA_FORCE_FINE_GRAIN_PCIE=1 \
  "${CHECKER}" --root "${ROOT}" > "${PASS_OUT}"

grep -Eq '^PASS +core/rocm-path +' "${PASS_OUT}"
grep -Eq '^PASS +core/rocminfo-run +' "${PASS_OUT}"
grep -Eq '^PASS +endpoint/nvme-ep +' "${PASS_OUT}"
grep -Eq '^PASS +endpoint/rdma-ep +' "${PASS_OUT}"
grep -Eq '^PASS +endpoint/sdma-ep +' "${PASS_OUT}"
grep -Eq '^Result: compliant$' "${PASS_OUT}"

rm -f "${ROOT}/dev/kfd"

FAIL_OUT="${TMPDIR}/fail.out"
if PATH="${BIN}:${PATH}" HSA_FORCE_FINE_GRAIN_PCIE=1 \
  "${CHECKER}" --root "${ROOT}" > "${FAIL_OUT}" 2>&1; then
  echo "Expected rocm-xio-check to fail without /dev/kfd" >&2
  exit 1
fi

grep -Eq '^FAIL +core/kfd +' "${FAIL_OUT}"
