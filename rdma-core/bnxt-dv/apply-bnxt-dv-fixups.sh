#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Apply bnxt DV fixup patches to rdma-core source.
# These fixups correct issues in the DV fork commits
# to work with the upstream v6.17+ kernel.
#
# Usage: apply-bnxt-dv-fixups.sh <rdma-core-src-dir>

set -euo pipefail

SRC_DIR="${1:?Usage: $0 <rdma-core-src-dir>}"
DV_FILE="${SRC_DIR}/providers/bnxt_re/dv.c"
DV_HDR="${SRC_DIR}/providers/bnxt_re/bnxt_re_dv.h"
MAP_FILE="${SRC_DIR}/providers/bnxt_re/bnxt_re.map"

echo "=== Applying bnxt DV fixups ==="

# 0. Remove UAPI_COMPAT_SUPPORTED gate.
if grep -q \
  'BNXT_RE_COMP_MASK_UCNTX_UAPI_COMPAT_SUPPORTED' \
  "$DV_FILE"; then
  echo "  [0] Removing UAPI_COMPAT gate..."
  sed -i \
    '/BNXT_RE_COMP_MASK_UCNTX_UAPI_COMPAT_SUPPORTED/{
      N
      /return NULL/d
    }' "$DV_FILE"
fi

# 1. Skip ibv_dontfork_range for dmabuf umems.
if grep -q 'ret = ibv_dontfork_range(in->addr' \
    "$DV_FILE"; then
  echo "  [1] Patching umem_reg dontfork..."
  perl -i -0pe \
    's|(\tret = ibv_dontfork_range'\
'\(in->addr, in->size\);\n'\
'\tif \(ret\) \{\n'\
'\t\terrno = ret;\n'\
'\t\treturn NULL;\n'\
'\t\})|'\
'if (!(in->comp_mask \& '\
'BNXT_RE_DV_UMEM_FLAGS_DMABUF)) {\n$1\n\t}|' \
    "$DV_FILE"
fi
if grep -q 'ibv_dofork_range(umem->addr' \
    "$DV_FILE"; then
  sed -i \
    's|ibv_dofork_range(umem->addr, umem->size);|'\
'if (umem->dmabuf_fd < 0) '\
'ibv_dofork_range(umem->addr, umem->size);|' \
    "$DV_FILE"
fi

# 2. Accept CQ toggle-page support from kernel.
if grep -q 'BNXT_RE_CQ_TOGGLE_PAGE_SUPPORT' \
    "$DV_FILE"; then
  echo "  [2] Removing CQ toggle-page reject..."
  sed -i \
    '/BNXT_RE_CQ_TOGGLE_PAGE_SUPPORT/{
      N
      s|.*BNXT_RE_CQ_TOGGLE_PAGE_SUPPORT.*\n.*return -EOPNOTSUPP;|\t/* Toggle-page CQs accepted. */|
    }' "$DV_FILE"
fi

# 3. Fix cqq NULL-dereference.
if grep -q 'cq->cqq = NULL;' "$DV_FILE"; then
  echo "  [3] Patching DV cqq NULL-deref..."
  perl -i -pe \
    's|\tcq->cqq = NULL;|'\
'\tcq->cqq = calloc(1, '\
'sizeof(struct bnxt_re_queue));\n'\
'\tif (!cq->cqq) {\n'\
'\t\tfree(cq);\n'\
'\t\treturn NULL;\n'\
'\t}\n'\
'\tpthread_spin_init(\&cq->cqq->qlock, '\
'PTHREAD_PROCESS_PRIVATE);|' \
    "$DV_FILE"
fi

# 4. Add bnxt_re_dv_get_cq_id().
if ! grep -q 'bnxt_re_dv_get_cq_id' \
    "$DV_FILE"; then
  echo "  [4] Adding bnxt_re_dv_get_cq_id()..."
  cat >> "$DV_FILE" << 'PATCH_EOF'

uint32_t bnxt_re_dv_get_cq_id(struct ibv_cq *ibvcq)
{
	struct bnxt_re_cq *cq = to_bnxt_re_cq(ibvcq);
	return cq->cqid;
}
PATCH_EOF
fi

if ! grep -q 'bnxt_re_dv_get_cq_id' \
    "$DV_HDR"; then
  sed -i \
    '/bnxt_re_dv_query_qp/a\'\
'uint32_t bnxt_re_dv_get_cq_id'\
'(struct ibv_cq *ibvcq);' \
    "$DV_HDR"
fi

# 5. Add get_cq_id to the version map.
if ! grep -q 'bnxt_re_dv_get_cq_id' \
    "$MAP_FILE"; then
  echo "  [5] Adding get_cq_id to map..."
  sed -i \
    '/bnxt_re_dv_query_qp;/a\\t\tbnxt_re_dv_get_cq_id;' \
    "$MAP_FILE"
fi

# 6. QP creation: rewrite for write-based path.
if grep -q 'ibv_cmd_create_qp_ex3' \
    "$DV_FILE"; then
  echo "  [6] Rewriting create_qp_cmd..."
  python3 - "$DV_FILE" << 'PYEOF'
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

echo "=== bnxt DV fixups applied ==="
