#!/usr/bin/env bash
# Shared library: env defaults, logging, data-dir layout, pidfile tracking.
# Sourced (not executed) by entrypoint.sh and lib/*.sh.
set -Eeuo pipefail

# ---- Data dir layout (bind-mounted from host) ----
: "${DATA_DIR:=/data}"
export IMAGES_DIR="$DATA_DIR/images"
export LOG_DIR="$DATA_DIR/log"
export CEPH_DIR="$DATA_DIR/ceph"
export RUN_DIR="$DATA_DIR/run"
export TOOLING_DIR="$DATA_DIR/qemu-minimal"
mkdir -p "$IMAGES_DIR" "$LOG_DIR" "$CEPH_DIR" "$RUN_DIR"

# ---- VM tooling source (launcher + gen-vm) ----
# Default: Stephen Bates' upstream qemu-minimal.
: "${QEMU_MINIMAL_REMOTE:=https://github.com/sbates130272/qemu-minimal}"
: "${QEMU_MINIMAL_BRANCH:=main}"
: "${GENVM_SCRIPT:=qemu/gen-vm}"
: "${RUNVM_SCRIPT:=qemu/run-vm}"

# ---- Guest provisioning (Ansible) source ----
# Default branch is the GENERAL-PURPOSE minimal branch.
# TODO: update with Stephen's remote when PR is upstreamed
: "${ANSIBLE_REMOTE:=https://github.com/john00003/batesste-ansible}"
: "${ANSIBLE_BRANCH:=users/john00003/rocm-xio-kv-docker-minimal}"
: "${ANSIBLE_PLAYBOOK:=playbooks/rocm-xio-kv-guest.yml}"
: "${ANSIBLE_INVENTORY:=playbooks/rocm-xio-kv-hosts.yml}"

# ---- Hardware (host-specific; REQUIRED for the GPU E2E, set on `docker run -e`) ----
# No defaults: require_var below fails loudly if a device-touching stage runs
# without these. selftest needs none of them.
: "${GPU_BDFS:=}"            # GPU VGA + audio function BDFs, comma-separated
: "${NVME_BDF:=}"            # spare NVMe BDF to pass through (never the root disk)
: "${ROCXIO_NVME_DEVICE:=}"  # guest /dev/disk/by-id path of that NVMe
: "${GPU_ARCH:=}"            # guest GPU arch passed to ansible as guest_gpu_arch

# ---- Guest login user (cloud image convention; gen-vm default is 'ubuntu') ----
: "${GUEST_USER:=ubuntu}"

# ---- VM shape + passthrough knobs ----
: "${SSH_PORT:=2223}"
: "${VCPUS:=8}"
: "${VMEM:=15360}"
: "${NVME:=2}"
: "${IOMMU:=disable}"
: "${PCI_MMIO_BRIDGE:=enable}"
: "${VM_NAME:=kv-ceph-vm}"
# TODO: update VRAM_DEV_INDEX AS REQUIRED PARAMETER PASSED BY USER IF USING MY FORK OF PCI-MMIO-BRIDGE
# VRAM peer-DMA target for the launcher. ORDER-SENSITIVE & 1-based: indexes into
# PCI_HOSTDEV, which vm-run builds as "NVME_BDF,GPU_BDFS" -> 2 = GPU VGA function.
: "${VRAM_DEV_INDEX:=2}"
: "${VRAM_BAR:=0}"

# ---- Guest test knobs ----
: "${USE_PCI_MMIO_BRIDGE:=1}"
: "${TASKSET_CPUS:=0-4}"  # TODO: remove once workaround no longer required
: "${CTEST_LABEL_EXCLUDE:=rdma}"

# ---- Wavefront/batched KV E2E knobs (gpu-e2e-wavefront stage) ----
# Exercises the cooperative multi-key path added in PR #177
# (driveEndpointKvWavefront): one batched Store of N keys, then a batched
# Retrieve into host slots and into VRAM (P2PDMA). KV_KEYS is space-separated;
# KV_BATCH defaults to the key count (one doorbell ring per batch).
: "${KV_KEYS:=wfk0 wfk1 wfk2 wfk3}"
: "${KV_VALUE_SIZE:=4096}"
: "${KV_BATCH:=}"          # default = number of keys in KV_KEYS

# ---- KV / Ceph names ----
: "${KV_POOL:=kvpool}"
: "${KV_NS:=kvns}"
: "${NQN:=nqn.2026-06.io.spdk:kv-rados0}"
: "${SPDK_HUGE:=auto}"

# ---- Logging ----
# log <stage> <message...> -> timestamped line to stderr + $LOG_DIR/<stage>.log
log() {
  local stage="$1"; shift
  local line
  line="[$(date -u +%H:%M:%S)] [$stage] $*"
  printf '%s\n' "$line" | tee -a "$LOG_DIR/$stage.log" >&2 || true
}
die() { log "${STAGE:-error}" "FATAL: $*"; exit 1; }

# require_var <NAME>... -> die if any named var is empty.
require_var() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || die "$v is required for this stage. Set it with: docker run -e $v=..."
  done
}

# ---- Pidfile tracking (cleanup only kills what we started) ----
track_pid() { echo "$2" > "$RUN_DIR/$1.pid"; }
kill_tracked() {
  local name pid f
  for f in "$RUN_DIR"/*.pid; do
    [ -e "$f" ] || continue
    name="$(basename "$f" .pid)"; pid="$(cat "$f" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log cleanup "killing $name (pid $pid)"; kill "$pid" 2>/dev/null || true
    fi
    rm -f "$f"
  done
}

# ---- VM tooling clone (shared by build-vm + vm-run; persists on the bind mount) ----
ensure_tooling() {
  if [ ! -d "$TOOLING_DIR/.git" ]; then
    log "${STAGE:-tooling}" "cloning tooling $QEMU_MINIMAL_REMOTE@$QEMU_MINIMAL_BRANCH -> $TOOLING_DIR"
    GIT_TERMINAL_PROMPT=0 git clone --branch "$QEMU_MINIMAL_BRANCH" "$QEMU_MINIMAL_REMOTE" "$TOOLING_DIR" \
      || die "tooling clone failed (private fork? mount an SSH key -- see README)"
  fi
}

# ---- SPDK hugepage flag selection ----
# TODO: remove once workaround no longer required
spdk_huge_flags() {
  case "$SPDK_HUGE" in
    no|none|false|0) echo "--no-huge -s 1024"; return;;
    yes|true|1)      echo ""; return;;
  esac
  local nr; nr="$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)"
  if [ "${nr:-0}" -gt 0 ] 2>/dev/null; then echo ""; else echo "--no-huge -s 1024"; fi
}
