#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Build rdma-core with Broadcom Direct Verbs patches.
#
# Two modes:
#   fork   - Clone the DV fork branch directly (default,
#            reliable, recommended until DV patches merge
#            upstream).
#   rebase - Clone upstream at a tag, cherry-pick the 4 DV
#            commits on top. May require manual conflict
#            resolution when the tag diverges significantly
#            from the fork's base.
#
# Usage:
#   build-bnxt-dv-rdma-core.sh \
#     <source_dir> <build_dir> <install_dir> \
#     <mode> <dv_repo> <dv_branch> \
#     <upstream_tag> [nproc] [--build-only]
#
# The script is idempotent: if the install directory
# already contains libibverbs.so it exits early.

set -euo pipefail

# Resolve to absolute paths before any cd
SRC_DIR="$(realpath -m "$1")"
BUILD_DIR="$(realpath -m "$2")"
INSTALL_DIR="$(realpath -m "$3")"
MODE="${4:-fork}"
DV_REPO="${5:-https://github.com/sbasavapatna/rdma-core.git}"
DV_BRANCH="${6:-dv-upstream}"
UPSTREAM_TAG="${7:-v62.0}"
NPROC="${8:-$(nproc)}"
BUILD_ONLY=false
if [ "${9:-}" = "--build-only" ]; then
  BUILD_ONLY=true
fi

UPSTREAM_REPO="https://github.com/linux-rdma/rdma-core.git"

# DV commits to cherry-pick in rebase mode (oldest first)
DV_COMMITS=(
  fd4153f190a42a396913117598b29a7f3527fa24
  df9e03cfe155f5fe74bc42913cab09e8c0a6e91c
  3c19fd74731e36cdb3a5f7d0041c7d5fb80d5279
  362804caa52fad94811153962128a1748625b45b
)

echo "=== build-bnxt-dv-rdma-core ==="
echo "  mode         : ${MODE}"
echo "  DV fork      : ${DV_REPO} (${DV_BRANCH})"
echo "  upstream tag : ${UPSTREAM_TAG}"
echo "  source       : ${SRC_DIR}"
echo "  build        : ${BUILD_DIR}"
echo "  install      : ${INSTALL_DIR}"
echo ""

# Skip if already built
if [ -f "${INSTALL_DIR}/lib/libibverbs.so" ]; then
  echo "rdma-core already installed, skipping."
  exit 0
fi

# -------------------------------------------------------
# Mode: fork -- clone DV fork branch directly
# -------------------------------------------------------
setup_fork_mode() {
  if [ ! -d "${SRC_DIR}/.git" ]; then
    echo "Cloning DV fork (${DV_BRANCH})..."
    git clone --branch "${DV_BRANCH}" --depth 50 \
      "${DV_REPO}" "${SRC_DIR}"
  else
    echo "Source directory exists, reusing."
  fi
}

# -------------------------------------------------------
# Mode: rebase -- upstream tag + cherry-pick DV commits
# -------------------------------------------------------
setup_rebase_mode() {
  if [ ! -d "${SRC_DIR}/.git" ]; then
    echo "Cloning upstream rdma-core at ${UPSTREAM_TAG}..."
    git clone --branch "${UPSTREAM_TAG}" --depth 50 \
      "${UPSTREAM_REPO}" "${SRC_DIR}"
  else
    echo "Source directory exists, reusing."
  fi

  cd "${SRC_DIR}"

  # Add DV fork remote and fetch
  if ! git remote get-url bnxt-dv &>/dev/null; then
    echo "Adding bnxt-dv remote..."
    git remote add bnxt-dv "${DV_REPO}"
  fi

  echo "Fetching DV branch (${DV_BRANCH})..."
  git fetch bnxt-dv "${DV_BRANCH}" --depth 50

  # Create working branch and cherry-pick
  WORK_BRANCH="bnxt-dv-${UPSTREAM_TAG}"
  if git show-ref --verify --quiet \
      "refs/heads/${WORK_BRANCH}"; then
    echo "Work branch ${WORK_BRANCH} exists, using it."
    git checkout "${WORK_BRANCH}"
  else
    echo "Creating work branch ${WORK_BRANCH}..."
    git checkout -b "${WORK_BRANCH}" "${UPSTREAM_TAG}"

    echo "Cherry-picking ${#DV_COMMITS[@]} DV commits..."
    for sha in "${DV_COMMITS[@]}"; do
      echo "  cherry-pick ${sha:0:12}..."
      # -Xtheirs resolves conflicting hunks in favor
      # of the DV fork. Non-conflicting additions from
      # both sides are preserved.
      if ! git cherry-pick --no-commit \
          -Xtheirs "${sha}"; then
        echo "ERROR: cherry-pick ${sha} failed."
        echo ""
        echo "The DV patches conflict with" \
          "${UPSTREAM_TAG}."
        echo "Options:"
        echo "  1. Resolve conflicts manually in:"
        echo "     ${SRC_DIR}"
        echo "  2. Use fork mode instead:"
        echo "     -DBNXT_DV_MODE=fork"
        exit 1
      fi
      git commit --no-gpg-sign -C "${sha}"
    done
    echo "All DV commits applied."
  fi
}

# -------------------------------------------------------
# Patch dv.c: cqq is NULL when bnxt_re_dv_create_cq
# calls bnxt_re_dv_create_cq_cmd, which dereferences
# cq->cqq->tail.  Allocate a minimal bnxt_re_queue.
# -------------------------------------------------------
patch_dv_source() {
  local dv_file="${SRC_DIR}/providers/bnxt_re/dv.c"
  local dv_hdr="${SRC_DIR}/providers/bnxt_re/bnxt_re_dv.h"

  # 0. Remove UAPI_COMPAT_SUPPORTED gate.
  #    The v11 kernel patches provide DV support
  #    but don't advertise the 0x100 flag yet.
  if grep -q 'BNXT_RE_COMP_MASK_UCNTX_UAPI_COMPAT_SUPPORTED' \
      "$dv_file"; then
    echo "Removing UAPI_COMPAT gate..."
    sed -i '/BNXT_RE_COMP_MASK_UCNTX_UAPI_COMPAT_SUPPORTED/{
      N
      /return NULL/d
    }' "$dv_file"
    echo "  patched: ${dv_file}"
  fi

  # 1. Skip ibv_dontfork_range for dmabuf umems.
  #    GPU memory doesn't need fork protection,
  #    and the addr field carries the dmabuf
  #    offset (not a CPU VA) in dmabuf mode.
  if grep -q 'ret = ibv_dontfork_range(in->addr' \
      "$dv_file"; then
    echo "Patching umem_reg dontfork for dmabuf..."
    perl -i -0pe \
      's|(\tret = ibv_dontfork_range\(in->addr, in->size\);\n\tif \(ret\) \{\n\t\terrno = ret;\n\t\treturn NULL;\n\t\})|if (!(in->comp_mask \& BNXT_RE_DV_UMEM_FLAGS_DMABUF)) {\n$1\n\t}|' \
      "$dv_file"
    echo "  patched: ${dv_file}"
  fi
  if grep -q 'ibv_dofork_range(umem->addr' \
      "$dv_file"; then
    sed -i \
      's|ibv_dofork_range(umem->addr, umem->size);|if (umem->dmabuf_fd < 0) ibv_dofork_range(umem->addr, umem->size);|' \
      "$dv_file"
    echo "  patched umem_dereg: ${dv_file}"
  fi

  # 2. Accept CQ toggle-page support from kernel.
  #    The DV fork rejects it but the v6.17
  #    bnxt_re driver always sets the flag.
  if grep -q 'BNXT_RE_CQ_TOGGLE_PAGE_SUPPORT' \
      "$dv_file"; then
    echo "Removing CQ toggle-page rejection..."
    sed -i '/BNXT_RE_CQ_TOGGLE_PAGE_SUPPORT/{
      N
      s|.*BNXT_RE_CQ_TOGGLE_PAGE_SUPPORT.*\n.*return -EOPNOTSUPP;|\t/* Toggle-page CQs accepted; feature unused by DV. */|
    }' "$dv_file"
    echo "  patched: ${dv_file}"
  fi

  # 3. Fix cqq NULL-dereference in
  #    bnxt_re_dv_create_cq.  (Renumbered.)
  if grep -q 'cq->cqq = NULL;' "$dv_file"; then
    echo "Patching DV cqq NULL-dereference..."
    perl -i -pe \
      's|\tcq->cqq = NULL;|'\
'\tcq->cqq = calloc(1, sizeof(struct bnxt_re_queue));\n'\
'\tif (!cq->cqq) {\n'\
'\t\tfree(cq);\n'\
'\t\treturn NULL;\n'\
'\t}\n'\
'\tpthread_spin_init(\&cq->cqq->qlock, PTHREAD_PROCESS_PRIVATE);|' \
      "$dv_file"
    echo "  patched: ${dv_file}"
  fi

  # 4. Add bnxt_re_dv_get_cq_id() -- there is no
  #    public API to extract HW CQN from ibv_cq.
  if ! grep -q 'bnxt_re_dv_get_cq_id' \
      "$dv_file"; then
    echo "Adding bnxt_re_dv_get_cq_id()..."
    cat >> "$dv_file" << 'PATCH_EOF'

uint32_t bnxt_re_dv_get_cq_id(struct ibv_cq *ibvcq)
{
	struct bnxt_re_cq *cq = to_bnxt_re_cq(ibvcq);
	return cq->cqid;
}
PATCH_EOF
    echo "  appended to: ${dv_file}"
  fi

  if ! grep -q 'bnxt_re_dv_get_cq_id' \
      "$dv_hdr"; then
    echo "Adding get_cq_id to DV header..."
    sed -i \
      '/bnxt_re_dv_query_qp/a\uint32_t bnxt_re_dv_get_cq_id(struct ibv_cq *ibvcq);' \
      "$dv_hdr"
    echo "  patched: ${dv_hdr}"
  fi

  # 5. Add get_cq_id to the version map so
  #    it's exported from the .so.
  local map_file="${SRC_DIR}/providers/bnxt_re/bnxt_re.map"
  if ! grep -q 'bnxt_re_dv_get_cq_id' \
      "$map_file"; then
    echo "Adding get_cq_id to version map..."
    sed -i \
      '/bnxt_re_dv_query_qp;/a\\t\tbnxt_re_dv_get_cq_id;' \
      "$map_file"
    echo "  patched: ${map_file}"
  fi

  # 6. QP creation: rewrite bnxt_re_dv_create_qp_cmd
  #    to use the write-based ibv_cmd_create_qp_ex2
  #    with qpsva/qprva instead of the ioctl-based
  #    ibv_cmd_create_qp_ex3 with buffer attributes.
  if grep -q 'ibv_cmd_create_qp_ex3' \
      "$dv_file"; then
    echo "Rewriting create_qp_cmd for write path..."
    python3 - "$dv_file" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    src = f.read()

m = re.search(
    r'(static\s+int\s*\n'
    r'bnxt_re_dv_create_qp_cmd\([^)]*\)\s*\{)'
    r'.*?'
    r'(\nstruct ibv_qp \*bnxt_re_dv_create_qp)',
    src, re.DOTALL)
if not m:
    print("  WARN: function not found",
          file=sys.stderr)
    sys.exit(0)

new_fn = m.group(1) + """
\tstruct bnxt_re_context *cntx = to_bnxt_re_context(ibvctx);
\tstruct bnxt_re_dv_db_region_attr *db_attr = NULL;
\tstruct bnxt_re_dv_umem *sq_umem = NULL;
\tstruct bnxt_re_dv_umem *rq_umem = NULL;
\tstruct ubnxt_re_qp req = {};
\tuint64_t offset;
\tuint32_t size;
\tint ret;

\treq.qp_handle = dv_qp_attr->qp_handle;

\t/* SQ buffer VA through udata (qpsva). */
\tsq_umem = dv_qp_attr->sq_umem_handle;
\toffset = dv_qp_attr->sq_umem_offset;
\tsize = dv_qp_attr->sq_len;
\tif (!bnxt_re_dv_is_valid_umem(cntx->rdev, sq_umem, offset, size)) {
\t\tfprintf(stderr,
\t\t\t"Invalid sq_umem: %" PRIuPTR " offset: %" PRIx64 " size: 0x%x\\n",
\t\t\t(uintptr_t)sq_umem, offset, size);
\t\treturn -EINVAL;
\t}
\treq.qpsva = (uintptr_t)(sq_umem->addr) + offset;
\treq.sq_slots = dv_qp_attr->sq_slots;
\treq.sq_wqe_sz = dv_qp_attr->sq_wqe_sz;
\treq.sq_psn_sz = dv_qp_attr->sq_psn_sz;
\treq.sq_npsn = dv_qp_attr->sq_npsn;

\t/* RQ buffer VA through udata (qprva).
\t * Skip when rq_slots==0 (no RQ needed) to avoid
\t * kernel ib_umem_get(size=0) returning -EINVAL.
\t */
\tif (!dv_qp_attr->srq && dv_qp_attr->rq_slots > 0) {
\t\trq_umem = dv_qp_attr->rq_umem_handle;
\t\toffset = dv_qp_attr->rq_umem_offset;
\t\tsize = dv_qp_attr->rq_len;
\t\tif (!bnxt_re_dv_is_valid_umem(cntx->rdev, rq_umem, offset, size)) {
\t\t\tfprintf(stderr,
\t\t\t\t"Invalid rq_umem: %" PRIuPTR "  offset: %" PRIx64 " size: 0x%x\\n",
\t\t\t\t(uintptr_t)rq_umem, offset, size);
\t\t\treturn -EINVAL;
\t\t}
\t\treq.qprva = (uintptr_t)(rq_umem->addr) + offset;
\t\treq.rq_slots = dv_qp_attr->rq_slots;
\t\treq.rq_wqe_sz = dv_qp_attr->rq_wqe_sz;
\t}

\treq.comp_mask = BNXT_RE_QP_REQ_MASK_DV_QP_ENABLE;
\tif (dv_qp_attr->dbr_handle) {
\t\tdb_attr = dv_qp_attr->dbr_handle;
\t\tqp->dv_dpi.dbpage = db_attr->dbr;
\t\tqp->dv_dpi.dpindx = db_attr->dpi;
\t\tqp->udpi = &qp->dv_dpi;
\t} else {
\t\tqp->udpi = &cntx->udpi;
\t}
\tret = ibv_cmd_create_qp_ex2(ibvctx, &qp->vqp, attr_ex,
\t\t\t\t    &req.ibv_cmd, sizeof(req),
\t\t\t\t    &resp->ibv_resp, sizeof(*resp));
\tif (ret) {
\t\tfprintf(stderr,
\t\t\t"%s: ibv_cmd_create_qp_ex2() failed: %d\\n",
\t\t\t__func__, ret);
\t\treturn ret;
\t}
\treturn 0;
}

""" + m.group(2)

out = src[:m.start()] + new_fn + src[m.end():]
with open(path, 'w') as f:
    f.write(out)
print("  patched: " + path)
PYEOF
  fi
}

# --- Dispatch mode ---
case "${MODE}" in
  fork)
    setup_fork_mode
    ;;
  rebase)
    setup_rebase_mode
    ;;
  *)
    echo "ERROR: Unknown mode '${MODE}'." \
      "Use 'fork' or 'rebase'."
    exit 1
    ;;
esac

# Apply source patches before building
patch_dv_source

# --- Build with cmake ---
echo ""
echo "Configuring rdma-core..."
mkdir -p "${BUILD_DIR}"
cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DIOCTL_MODE=both \
  -DNO_PYVERBS=1 \
  -DNO_MAN_PAGES=1 \
  -DENABLE_STATIC=0

echo "Building rdma-core (${NPROC} jobs)..."
cmake --build "${BUILD_DIR}" -j "${NPROC}"

if $BUILD_ONLY; then
  echo ""
  echo "=== rdma-core with bnxt DV built ==="
  echo "  build dir : ${BUILD_DIR}"
  echo ""
  echo "To install, re-run without --build-only."
  exit 0
fi

echo "Installing rdma-core to ${INSTALL_DIR}..."
cmake --install "${BUILD_DIR}"

echo ""
echo "=== rdma-core with bnxt DV installed ==="
echo "  libibverbs : ${INSTALL_DIR}/lib/"
echo "  libbnxt_re : ${INSTALL_DIR}/lib/"
echo "  headers    : ${INSTALL_DIR}/include/"
