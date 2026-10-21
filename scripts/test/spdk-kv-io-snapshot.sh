#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# spdk-kv-io-snapshot.sh
#
# Capture SPDK's own view of NVMe-oF/vfio-user KV traffic via RPC, on
# whatever build is running -- release or --enable-debug alike. Unlike
# scripts/test/spdk-enable-logging.sh (whose usefulness on the pinned
# release image is limited to a handful of invalid/unsupported-command
# INFOLOG lines, see that script's header), the RPCs used here
# (nvmf_get_stats, nvmf_subsystem_get_qpairs,
# nvmf_subsystem_get_controllers, kvdev_mem_get_entry) are ordinary
# target-state queries, not log-gated: they return real numbers
# (admin/io qpair and queue-pair counts, per-controller stats, the
# actual stored value for a key) regardless of CONFIG_DEBUG. This is the
# RPC-callable equivalent of the poll_reqs counter that gave WF its only
# SPDK-side signal on 2026-09-23: a way to see, from outside the guest,
# whether SPDK's own state changed the way a KV store/retrieve should
# have changed it, without needing any log line at all.
#
# Usage:
#   SPDK_CONTAINER=spdk-kv-nvme-vm-spdk-nvme-1 \
#   NQN=nqn.2019-07.io.spdk:cnode1 \
#   KVDEV=KvMem0 \
#     scripts/test/spdk-kv-io-snapshot.sh <label> [key ...]
#
# With no keys given, snapshots the fixed set spdk-kv-check.sh uses
# (kvverify0..3). Writes one JSON file per RPC to
# ${SNAPSHOT_DIR:-.}/spdk-snapshot-<label>.json (a single object keyed
# by RPC/key name). Call it more than once with different labels (e.g.
# before-store, after-store, after-retrieve) and diff the files, or run
# with SNAPSHOT_DIFF_AGAINST=<earlier label> to get a diff against an
# earlier snapshot appended to the same output.
#
# Environment variables:
#   SPDK_CONTAINER        compose container name (default matches the
#                         spdk-kv-nvme-vm compose project's service name).
#   SPDK_RPC_SOCK         RPC socket path inside the container.
#   NQN                   subsystem NQN (default matches entrypoint.sh's
#                         own default, nqn.2019-07.io.spdk:cnode1).
#   KVDEV                 in-memory kvdev name (default matches
#                         entrypoint.sh's first kv:mem namespace, KvMem0).
#   SNAPSHOT_DIR          directory to write JSON files to (default: .).
#   SNAPSHOT_DIFF_AGAINST label of an earlier snapshot in SNAPSHOT_DIR to
#                         diff the new one against (optional).

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <label> [key ...]" >&2
    exit 1
fi
LABEL="$1"
shift

SPDK_CONTAINER="${SPDK_CONTAINER:-spdk-kv-nvme-vm-spdk-nvme-1}"
SPDK_RPC_SOCK="${SPDK_RPC_SOCK:-/var/tmp/spdk.sock}"
NQN="${NQN:-nqn.2019-07.io.spdk:cnode1}"
KVDEV="${KVDEV:-KvMem0}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-.}"

if [ "$#" -gt 0 ]; then
    KEYS=("$@")
else
    KEYS=(kvverify0 kvverify1 kvverify2 kvverify3)
fi

mkdir -p "${SNAPSHOT_DIR}"
OUT="${SNAPSHOT_DIR}/spdk-snapshot-${LABEL}.json"

rpc() {
    docker exec "${SPDK_CONTAINER}" \
        rpc.py -s "${SPDK_RPC_SOCK}" "$@"
}

echo "spdk-kv-io-snapshot: capturing '${LABEL}' from ${SPDK_CONTAINER} (nqn=${NQN}, kvdev=${KVDEV})"

stats_json=$(rpc nvmf_get_stats)
qpairs_json=$(rpc nvmf_subsystem_get_qpairs "${NQN}")
ctrlrs_json=$(rpc nvmf_subsystem_get_controllers "${NQN}")

entries_json="{}"
for key in "${KEYS[@]}"; do
    entry=$(rpc kvdev_mem_get_entry "${KVDEV}" "${key}" 2>&1) || entry='{"error": "not found"}'
    entries_json=$(python3 -c '
import json, sys
merged = json.loads(sys.argv[1])
key = sys.argv[2]
raw = sys.argv[3]
try:
    val = json.loads(raw)
except json.JSONDecodeError:
    val = {"error": raw.strip()}
merged[key] = val
print(json.dumps(merged))
' "${entries_json}" "${key}" "${entry}")
done

python3 -c '
import json, sys
label, nqn, kvdev = sys.argv[1], sys.argv[2], sys.argv[3]
stats, qpairs, ctrlrs, entries = sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]
def parse(raw):
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"error": raw.strip()}
doc = {
    "label": label,
    "nqn": nqn,
    "kvdev": kvdev,
    "nvmf_get_stats": parse(stats),
    "nvmf_subsystem_get_qpairs": parse(qpairs),
    "nvmf_subsystem_get_controllers": parse(ctrlrs),
    "kvdev_mem_get_entry": json.loads(entries),
}
print(json.dumps(doc, indent=2))
' "${LABEL}" "${NQN}" "${KVDEV}" "${stats_json}" "${qpairs_json}" "${ctrlrs_json}" "${entries_json}" > "${OUT}"

echo "spdk-kv-io-snapshot: wrote ${OUT}"

if [ -n "${SNAPSHOT_DIFF_AGAINST:-}" ]; then
    PREV="${SNAPSHOT_DIR}/spdk-snapshot-${SNAPSHOT_DIFF_AGAINST}.json"
    if [ -f "${PREV}" ]; then
        echo "spdk-kv-io-snapshot: diff (${SNAPSHOT_DIFF_AGAINST} -> ${LABEL}):"
        diff -u "${PREV}" "${OUT}" || true
    else
        echo "spdk-kv-io-snapshot: no earlier snapshot '${SNAPSHOT_DIFF_AGAINST}' found at ${PREV}, skipping diff"
    fi
fi
