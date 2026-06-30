#!/usr/bin/env bash
# Start SPDK nvmf_tgt + expose a kvdev_rados KV namespace as a vfio-user socket.
# Returns once the socket is up (does NOT foreground). nvmf_tgt's pid is tracked
# for cleanup, but reaping is the caller's job: the serve stage installs the
# `trap kill_tracked` that reaps it.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/common.sh"
: "${SPDK_DIR:=/opt/spdk}"
: "${CEPH_CONF:=/etc/ceph/ceph.conf}"
: "${CEPH_KEYRING:=/etc/ceph/ceph.client.admin.keyring}"
RPC_SOCK="$RUN_DIR/spdk.rpc.sock"
MUSER="$RUN_DIR/muser"; mkdir -p "$MUSER"
# Clean up old files that could conflict.
rm -f "$MUSER/cntrl" "$RPC_SOCK" "$RPC_SOCK.lock" "$RUN_DIR/vfio_user_sock"
rpc() { python3 "$SPDK_DIR/scripts/rpc.py" -s "$RPC_SOCK" "$@"; }

spdk_kv_up() {
  # shellcheck disable=SC2034  # STAGE is read cross-file by common.sh log()/die()
  local STAGE=spdk-kv
  local hugeflags; hugeflags="$(spdk_huge_flags)"
  log spdk-kv "starting nvmf_tgt (-m 0x1 ${hugeflags:-<hugepages>})"
  # shellcheck disable=SC2086  # $hugeflags is a flag list, word-splitting intended
  "$SPDK_DIR/build/bin/nvmf_tgt" -r "$RPC_SOCK" -m 0x1 $hugeflags \
    >"$LOG_DIR/nvmf_tgt.log" 2>&1 &
  track_pid nvmf_tgt $!
  local _
  for _ in $(seq 1 80); do
    [ -S "$RPC_SOCK" ] && rpc rpc_get_methods >/dev/null 2>&1 && break
    sleep 0.25
  done
  rpc rpc_get_methods >/dev/null 2>&1 || die "nvmf_tgt failed to come up (see $LOG_DIR/nvmf_tgt.log)"
  rpc nvmf_create_transport -t VFIOUSER -q 1024 -m 16
  rpc kvdev_rados_register_cluster ceph0 --user admin \
      --config-file "$CEPH_CONF" --key-file "$CEPH_KEYRING" || die "kvdev_rados_register_cluster failed"
  rpc kvdev_rados_create KvRados0 ceph0 "$KV_POOL" --namespace "$KV_NS" || die "kvdev_rados_create failed"
  rpc nvmf_create_subsystem "$NQN" -s SPDKKVR01 -a
  rpc nvmf_subsystem_add_kv_ns "$NQN" KvRados0 || die "nvmf_subsystem_add_kv_ns failed"
  rpc nvmf_subsystem_add_listener "$NQN" -t VFIOUSER -a "$MUSER" -s 0
  for _ in $(seq 1 40); do [ -S "$MUSER/cntrl" ] && break; sleep 0.25; done
  [ -S "$MUSER/cntrl" ] || die "vfio-user cntrl socket never created"
  echo "$MUSER/cntrl" > "$RUN_DIR/vfio_user_sock"
  log spdk-kv "KV namespace up on $NQN; vfio-user socket=$MUSER/cntrl"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then spdk_kv_up; fi
