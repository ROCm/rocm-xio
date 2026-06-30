#!/usr/bin/env bash
# Bring up a minimal single-node Ceph cluster (1 mon + 1 mgr + 1 file-backed
# OSD) and create the KV pool/namespace.
#
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/common.sh"

# Ceph daemons read their config from /etc/ceph; common.sh's CEPH_DIR=/data/ceph
# is the bind-mounted data dir and must NOT hold ceph.conf.
: "${CEPH_DIR_SYS:=/etc/ceph}"
CEPH_CONF="${CEPH_DIR_SYS}/ceph.conf"
CEPH_KEYRING="/etc/ceph/ceph.client.admin.keyring"
export CEPH_CONF CEPH_KEYRING

start_ceph() {
    if ceph -c "${CEPH_CONF}" -s >/dev/null 2>&1; then
        log ceph-up "Ceph already running"
        return 0
    fi

    local fsid mon_ip
    fsid="$(uuidgen)"
    mon_ip="127.0.0.1"
    local hn; hn="$(hostname)"

    mkdir -p "${CEPH_DIR_SYS}" /var/lib/ceph/mon/ceph-a \
             /var/lib/ceph/mgr/ceph-x /var/lib/ceph/osd/ceph-0 \
             /var/lib/ceph/bootstrap-osd /var/log/ceph /var/run/ceph

    log ceph-up "Generating ${CEPH_CONF} (fsid=${fsid})"
    cat > "${CEPH_CONF}" <<EOF
[global]
    fsid = ${fsid}
    mon initial members = a
    mon host = ${mon_ip}
    public network = 127.0.0.0/8
    auth cluster required = cephx
    auth service required = cephx
    auth client required = cephx
    osd pool default size = 1
    osd pool default min size = 1
    osd crush chooseleaf type = 0
    osd journal size = 1024
    osd max object name len = 256
    osd max object namespace len = 64
    bluestore block size = 5368709120
    mon allow pool size one = true
    mon warn on pool no redundancy = false
    mon data avail warn = 1
    log file = /var/log/ceph/\$cluster-\$name.log
    run dir = /var/run/ceph

[mon.a]
    host = ${hn}
    mon addr = ${mon_ip}:6789
EOF

    # --- keyrings ---
    ceph-authtool --create-keyring /tmp/ceph.mon.keyring \
        --gen-key -n mon. --cap mon 'allow *'
    ceph-authtool --create-keyring "${CEPH_KEYRING}" \
        --gen-key -n client.admin \
        --cap mon 'allow *' --cap osd 'allow *' \
        --cap mds 'allow *' --cap mgr 'allow *'
    ceph-authtool --create-keyring /var/lib/ceph/bootstrap-osd/ceph.keyring \
        --gen-key -n client.bootstrap-osd \
        --cap mon 'profile bootstrap-osd' --cap mgr 'allow r'
    ceph-authtool /tmp/ceph.mon.keyring --import-keyring "${CEPH_KEYRING}"
    ceph-authtool /tmp/ceph.mon.keyring \
        --import-keyring /var/lib/ceph/bootstrap-osd/ceph.keyring

    # --- monmap + mon ---
    monmaptool --create --add a "${mon_ip}" --fsid "${fsid}" /tmp/monmap
    ceph-mon --mkfs -i a --monmap /tmp/monmap --keyring /tmp/ceph.mon.keyring
    chown -R ceph:ceph /var/lib/ceph/mon/ceph-a 2>/dev/null || true
    ceph-mon -i a --pid-file /var/run/ceph/mon.a.pid \
        --setuser root --setgroup root

    log ceph-up "Waiting for mon quorum..."
    local ok=0
    for _ in $(seq 1 60); do
        if ceph -c "${CEPH_CONF}" -s >/dev/null 2>&1; then ok=1; break; fi
        sleep 0.5
    done
    [ "$ok" = 1 ] || die "mon quorum did not form within 30s (see ceph daemon logs)"

    # disable insecure-global-id warning noise
    ceph -c "${CEPH_CONF}" config set mon auth_allow_insecure_global_id_reclaim false \
        >/dev/null 2>&1 || true

    # --- mgr ---
    ceph -c "${CEPH_CONF}" auth get-or-create mgr.x \
        mon 'allow profile mgr' osd 'allow *' mds 'allow *' \
        > /var/lib/ceph/mgr/ceph-x/keyring
    # TODO: confirm this is inherent to single-node packaged Ceph and not local.
    ceph-mgr -i x -n mgr.x --keyring /var/lib/ceph/mgr/ceph-x/keyring \
        --setuser root --setgroup root

    # --- single OSD (file-backed bluestore via loop-less raw file) ---
    log ceph-up "Creating OSD 0..."
    local osd_uuid osd_id
    osd_uuid="$(uuidgen)"
    osd_id="$(ceph -c "${CEPH_CONF}" osd create "${osd_uuid}")"
    ceph-authtool --create-keyring /var/lib/ceph/osd/ceph-0/keyring \
        --gen-key -n "osd.${osd_id}" --cap mon 'allow profile osd' \
        --cap osd 'allow *' --cap mgr 'allow profile osd'
    ceph -c "${CEPH_CONF}" auth add "osd.${osd_id}" -i /var/lib/ceph/osd/ceph-0/keyring

    # 5 GiB file-backed bluestore block device for the OSD.
    truncate -s 5G /var/lib/ceph/osd/ceph-0/block.img
    ceph-osd -i "${osd_id}" --mkfs --osd-uuid "${osd_uuid}" \
        --osd-data /var/lib/ceph/osd/ceph-0 \
        --bluestore-block-path /var/lib/ceph/osd/ceph-0/block.img \
        -n "osd.${osd_id}" --keyring /var/lib/ceph/osd/ceph-0/keyring \
        --setuser root --setgroup root
    ceph-osd -i "${osd_id}" \
        --osd-data /var/lib/ceph/osd/ceph-0 \
        --bluestore-block-path /var/lib/ceph/osd/ceph-0/block.img \
        -n "osd.${osd_id}" --keyring /var/lib/ceph/osd/ceph-0/keyring \
        --setuser root --setgroup root \
        --pid-file /var/run/ceph/osd.0.pid

    log ceph-up "Waiting for OSD up/in..."
    local osd_ok=0
    for _ in $(seq 1 120); do
        if ceph -c "${CEPH_CONF}" osd stat 2>/dev/null | grep -q '1 up'; then osd_ok=1; break; fi
        sleep 0.5
    done
    [ "$osd_ok" = 1 ] || die "OSD did not come up within 60s (see ceph daemon logs)"
    ceph -c "${CEPH_CONF}" -s || true
}

ensure_pool() {
    if ! ceph -c "${CEPH_CONF}" osd pool ls 2>/dev/null | grep -qx "${KV_POOL}"; then
        log ceph-up "Creating pool ${KV_POOL}"
        ceph -c "${CEPH_CONF}" osd pool create "${KV_POOL}" 32 32
        ceph -c "${CEPH_CONF}" osd pool application enable "${KV_POOL}" rados
    fi
    # PGs must be active before rados ops or they hang.
    local pg_ok=0
    for _ in $(seq 1 120); do
        if ceph -c "${CEPH_CONF}" -s 2>/dev/null | grep -q 'active+clean'; then pg_ok=1; break; fi
        sleep 0.5
    done
    [ "$pg_ok" = 1 ] || die "PGs did not reach active+clean within 60s (see ceph daemon logs)"
    rados -c "${CEPH_CONF}" lspools 2>/dev/null | while read -r p; do
        log ceph-up "  pool: $p"
    done || true
}

ceph_up() { start_ceph; ensure_pool; log ceph-up "Ceph up; pool $KV_POOL/$KV_NS ready"; }

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then ceph_up; fi
