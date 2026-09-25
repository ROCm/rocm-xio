#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# spdk-enable-logging.sh
#
# Turn on SPDK's log flags and print level on a running SPDK vfio-user
# NVMe/KV server via the RPC socket, so the compose logs CI already
# collects (see .github/workflows/test-vm-nvme-kv.yml "Collect compose
# logs") carry whatever extra log lines that unlocks.
#
# What this actually unlocks on the pinned CI image -- verified
# 2026-09-25 against
# sbates130272/batesste-ci-images-ubuntu-spdk-libvfio-user:
# 20260917.g857483b-spdk.18d1d8d -- is narrower than the first version
# of this script (2026-09-25, commit c05119e) claimed:
#
#   - mk/config.mk pins CONFIG_DEBUG?=n on this image, so SPDK_DEBUGLOG
#     (include/spdk/log.h) compiles to `do {} while (0)` everywhere.
#     `strings build/bin/nvmf_tgt` confirms it: a SPDK_NOTICELOG format
#     string ("requested shadow doorbells") is present in the binary, a
#     SPDK_DEBUGLOG one from lib/nvmf/vfio_user.c ("destroy endpoint %s")
#     is not. Every SPDK_DEBUGLOG call in lib/nvmf/vfio_user.c (62
#     sites), lib/nvmf/ctrlr_kvdev.c (2), lib/kvdev (1) and
#     module/kvdev/mem (3) is dead code on this build. log_set_level
#     DEBUG cannot resurrect it -- there is nothing there to gate.
#   - SPDK_INFOLOG *is* always compiled (log.h), and its flag check
#     (`SPDK_LOG_<flag>.enabled`) is read fresh on every call, so
#     log_set_flag done at any time -- including after the target is
#     already serving -- does reach it. But lib/nvmf/vfio_user.c has
#     exactly one INFOLOG site (vfio_user_log(), line ~2990), and it
#     only fires when libvfio-user's own vfu_ctx decides to call back
#     into it. That decision uses a threshold libvfio-user is handed
#     once, in vfu_setup_log(endpoint->vfu_ctx, vfio_user_log,
#     vfio_user_get_log_level()) (vfio_user.c, ~line 3723), which runs
#     when entrypoint.sh's `rpc nvmf_subsystem_add_listener` creates the
#     vfio-user endpoint (see entrypoint.sh) -- i.e. before this script,
#     or the CI step that calls it, can possibly run (the compose action
#     only runs this after SPDK reports healthy, which is after the
#     listener already exists). So this script cannot unlock the
#     vfio_user.c-side INFOLOG message either.
#   - The one thing left that this script demonstrably does unlock: the
#     `nvmf` flag's INFOLOG sites in lib/nvmf/ctrlr.c (10 call sites,
#     e.g. "Unsupported admin opcode 0x%x", "Unsupported IO opcode
#     0x%x", "Invalid offset 0x%x") -- these check SPDK_LOG_nvmf.enabled
#     directly at call time, are not routed through vfio_user_log(), and
#     so are not affected by the frozen-threshold problem above. They
#     only fire on invalid/unsupported commands, not on ordinary
#     successful KV or block I/O, so this is a narrow net: it surfaces
#     malformed/unexpected-opcode traffic, not a trace of every command.
#
# Full per-command DEBUGLOG tracing of the KV/vfio-user path needs an
# SPDK built with `./configure --enable-debug`. That is a one-line
# change to the pinned image's own build
# (sbates130272/batesste-ci-images), owned by Stephen, not something
# this repository's compose/action files can produce from the release
# build alone.
#
# Usage:
#   SPDK_CONTAINER=spdk-kv-nvme-vm-spdk-nvme-1 \
#   SPDK_LOG_FLAGS=nvmf,nvmf_vfio,vfio_user,vfio_user_db,vfu,kvdev,kvdev_mem \
#     scripts/test/spdk-enable-logging.sh
#
# Environment variables:
#   XIO_SPDK_DEBUG_LOG   "1" (default) to enable, "0" to no-op and leave
#                        the target's default (NOTICE) logging in place.
#   SPDK_CONTAINER       compose container name (default matches the
#                        spdk-kv-nvme-vm compose project's service name).
#   SPDK_LOG_FLAGS       comma-separated spdk_log flag names to enable.
#                        Kept broad (not narrowed to just "nvmf") so
#                        that running this same script against a future
#                        --enable-debug image unlocks the vfio_user/kvdev
#                        DEBUGLOG sites too, with no script change.
#   SPDK_RPC_SOCK        RPC socket path inside the container.

set -euo pipefail

XIO_SPDK_DEBUG_LOG="${XIO_SPDK_DEBUG_LOG:-1}"
SPDK_CONTAINER="${SPDK_CONTAINER:-spdk-kv-nvme-vm-spdk-nvme-1}"
SPDK_LOG_FLAGS="${SPDK_LOG_FLAGS:-nvmf,nvmf_vfio,vfio_user,vfio_user_db,vfu,kvdev,kvdev_mem}"
SPDK_RPC_SOCK="${SPDK_RPC_SOCK:-/var/tmp/spdk.sock}"

if [ "${XIO_SPDK_DEBUG_LOG}" != "1" ]; then
    echo "spdk-enable-logging: XIO_SPDK_DEBUG_LOG=${XIO_SPDK_DEBUG_LOG}, leaving default logging in place"
    exit 0
fi

rpc() {
    docker exec "${SPDK_CONTAINER}" \
        rpc.py -s "${SPDK_RPC_SOCK}" "$@"
}

echo "spdk-enable-logging: enabling flags [${SPDK_LOG_FLAGS}] and level DEBUG on ${SPDK_CONTAINER}"
echo "spdk-enable-logging: on this pinned (CONFIG_DEBUG=n) image this only surfaces INFOLOG-level"
echo "spdk-enable-logging: nvmf ctrlr.c messages on invalid/unsupported commands -- see header for why"

IFS=',' read -r -a flags <<< "${SPDK_LOG_FLAGS}"
for flag in "${flags[@]}"; do
    [ -n "${flag}" ] || continue
    rpc log_set_flag "${flag}"
done

# Console/log-file print threshold. Harmless to request DEBUG even though
# this build has no DEBUGLOG call sites left to print -- it costs nothing
# and means this script needs no change the day the image is built with
# --enable-debug.
rpc log_set_level DEBUG

echo "spdk-enable-logging: active flags:"
rpc log_get_flags
