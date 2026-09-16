#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# run-vm-nvme.sh
#
# Run the test-vm-nvme workflow outside GitHub Actions, on a machine you
# have already logged in to -- a Slurm storage node, a workstation, anything
# with docker and a usable /dev/kvm.
#
# This exists so a failure seen in CI can be reproduced somewhere you can
# poke at it. To be worth anything it has to run the same thing CI runs, so
# it does not restate any of the inputs:
#
#   - the image pins are read out of .github/workflows/test-vm-nvme.yml, so
#     bumping a tag there moves both at once and neither can drift
#   - the stack comes up from .github/compose/rocjitsu-nvme-vm, the same
#     compose file the CI action uses
#   - provisioning goes through scripts/test/vm-provision.sh and the guest
#     test through scripts/test/vm-guest-test.sh, unchanged
#
# Ansible runs from a throwaway venv rather than whatever is on PATH. CI
# learned this the hard way: ansible-core and jmespath have to land in the
# same interpreter, and a user-level ~/.local/bin/ansible-playbook that
# cannot see them is how you get json_query failing at task-argument
# resolution with nothing useful in the log.
#
# Usage:
#   scripts/test/run-vm-nvme.sh [options]
#
#   --workdir DIR     Scratch directory (default: mktemp under /tmp)
#   --ssh-port PORT   Host port for the guest (default: a free one)
#   --ctest-label RE  ctest label regex in the guest (default: nvme)
#   --skip-gpu        Build-only smoke run
#   --vcpus N         Guest vCPUs (default 16; CI uses 4)
#   --vmem MiB        Guest memory in MiB (default 32768; CI uses 8192)
#   --keep            Leave the stack up and the workdir behind on exit
#   --no-test         Bring up and provision, but stop before the guest test
#
# Image pins are read from the workflow so the two cannot drift, but any of
# QEMU_IMAGE, ROCJITSU_IMAGE, ROCJITSU_FIRMWARE_IMAGE and QCOW2_IMAGE can be
# set in the environment to override one for a single run:
#   QCOW2_IMAGE=...-qcow2-gen:...-basic-... scripts/test/run-vm-nvme.sh
#
# Under Slurm, ask for enough of the node to hold the guest:
#   srun -M cluster -p storage -w ctr-smc-strg-cx68-3 -N1 -n1 \
#        --cpus-per-task=20 --mem=48G -t 120 scripts/test/run-vm-nvme.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/test-vm-nvme.yml"
COMPOSE_FILE="${REPO_ROOT}/.github/compose/rocjitsu-nvme-vm/docker-compose.yml"

WORKDIR=""
SSH_PORT=""
CTEST_LABEL="nvme"
SKIP_GPU="0"
KEEP=0
RUN_TEST=1

# CI runs 4 vCPU / 8 GiB because that is all a GitHub runner has. A storage
# node has ~190 cores and 1.5 TiB, and the slow phases here -- the ROCm
# install and the DKMS rebuild -- are CPU bound, so default bigger and let
# --vcpus/--vmem dial it back to the CI shape when reproducing a CI failure.
VM_VCPUS=16
VM_VMEM=32768

while [ $# -gt 0 ]; do
    case "$1" in
        --workdir) WORKDIR="$2"; shift 2 ;;
        --ssh-port) SSH_PORT="$2"; shift 2 ;;
        --vcpus) VM_VCPUS="$2"; shift 2 ;;
        --vmem) VM_VMEM="$2"; shift 2 ;;
        --ctest-label) CTEST_LABEL="$2"; shift 2 ;;
        --skip-gpu) SKIP_GPU="1"; shift ;;
        --keep) KEEP=1; shift ;;
        --no-test) RUN_TEST=0; shift ;;
        -h|--help) sed -n '7,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# The guest's RAM lives in a shared memfd so the vfio-user server can reach
# it, so /dev/shm has to hold all of it, plus headroom for the NVMe backing.
VM_SHM="$(( VM_VMEM / 1024 + 4 ))g"

# --skip-gpu has to reach provisioning too, not just the guest test: the
# playbook asserts the gfx1250 firmware inventory, and that assertion fails
# the whole run before the NVMe half is ever reached.
PROVISION_ARGS=()
[ "$SKIP_GPU" = "1" ] && PROVISION_ARGS+=(-e assert_gpu_firmware=false)

say() { printf '\n=== %s ===\n' "$*"; }

# ----------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------
say "Preflight"

missing=()
for t in docker ssh rsync python3; do
    command -v "$t" > /dev/null 2>&1 || missing+=("$t")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: missing required tools: ${missing[*]}" >&2
    exit 1
fi

docker compose version > /dev/null 2>&1 || {
    echo "ERROR: 'docker compose' (v2 plugin) is required" >&2
    exit 1
}

# The host node may well have /dev/kvm as 0660 root:kvm with the login user
# outside that group. That is fine: the qemu container runs as root with the
# device passed through, which is the only access that matters. Test that
# rather than the host-side permission bit.
[ -c /dev/kvm ] || { echo "ERROR: /dev/kvm is not present" >&2; exit 1; }
if ! docker run --rm --device /dev/kvm busybox test -w /dev/kvm 2>/dev/null; then
    echo "ERROR: /dev/kvm is not writable from inside a container" >&2
    echo "       qemu-tool has no TCG fallback, so the guest cannot start." >&2
    exit 1
fi
echo "kvm usable from a container: yes"

# ----------------------------------------------------------------------
# Inputs, taken from the workflow so the two cannot drift
# ----------------------------------------------------------------------
pin() {
    local key="$1" val
    val="$(grep -E "^[[:space:]]+${key}:[[:space:]]" "$WORKFLOW" | head -1 \
           | sed -E "s/^[[:space:]]+${key}:[[:space:]]*//" | tr -d '"'"'"'')"
    [ -n "$val" ] || { echo "ERROR: no ${key} in ${WORKFLOW}" >&2; exit 1; }
    printf '%s' "$val"
}

# Default to the workflow's pins so local runs and CI cannot drift, but let the
# environment win, which is how one image is swapped for another to find out
# whether a failure belongs to the image or to the code under test.
QEMU_IMAGE="${QEMU_IMAGE:-$(pin QEMU_IMAGE)}"
ROCJITSU_IMAGE="${ROCJITSU_IMAGE:-$(pin ROCJITSU_IMAGE)}"
ROCJITSU_FIRMWARE_IMAGE="${ROCJITSU_FIRMWARE_IMAGE:-$(pin ROCJITSU_FIRMWARE_IMAGE)}"
QCOW2_IMAGE="${QCOW2_IMAGE:-$(pin QCOW2_IMAGE)}"

note() { [ "$2" = "$(pin "$1")" ] || printf ' (overridden)'; }
echo "qemu:     ${QEMU_IMAGE}$(note QEMU_IMAGE "$QEMU_IMAGE")"
echo "rocjitsu: ${ROCJITSU_IMAGE}$(note ROCJITSU_IMAGE "$ROCJITSU_IMAGE")"
echo "firmware: ${ROCJITSU_FIRMWARE_IMAGE}$(note ROCJITSU_FIRMWARE_IMAGE "$ROCJITSU_FIRMWARE_IMAGE")"
echo "qcow2:    ${QCOW2_IMAGE}$(note QCOW2_IMAGE "$QCOW2_IMAGE")"

if [ -z "$WORKDIR" ]; then
    WORKDIR="$(mktemp -d "/tmp/rocm-xio-vm-${USER}-XXXXXX")"
fi
mkdir -p "$WORKDIR"
IMAGES_DIR="${WORKDIR}/images"
mkdir -p "$IMAGES_DIR"

# A shared node may already have something on 2222, and two runs of this
# script must not fight over a port or a compose project name.
if [ -z "$SSH_PORT" ]; then
    SSH_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')"
fi
PROJECT="xio-vm-$(basename "$WORKDIR" | tr -cd 'a-z0-9')"

echo "workdir:  ${WORKDIR}"
echo "ssh port: ${SSH_PORT}"
echo "project:  ${PROJECT}"
echo "guest:    ${VM_VCPUS} vcpu, ${VM_VMEM} MiB, ${VM_SHM} shm"

ENV_FILE="${WORKDIR}/compose.env"
dc() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    local rc=$?
    if [ "$KEEP" -eq 1 ]; then
        say "Leaving the stack up (--keep)"
        echo "  compose: docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} -p ${PROJECT} <cmd>"
        echo "  ssh:     ssh -i ${IMAGES_DIR}/id_rsa -p ${SSH_PORT} ${VM_USER:-<user>}@localhost"
        return "$rc"
    fi
    say "Tearing down"
    dc logs --no-color > "${WORKDIR}/compose.log" 2>&1 || true
    dc down --volumes --timeout 10 > /dev/null 2>&1 || true
    echo "compose log kept at ${WORKDIR}/compose.log"
    return "$rc"
}
trap cleanup EXIT

# ----------------------------------------------------------------------
# Bring-up
# ----------------------------------------------------------------------
say "Pulling pinned images"
docker pull -q "$QEMU_IMAGE"
docker pull -q "$ROCJITSU_IMAGE"
docker pull -q "$ROCJITSU_FIRMWARE_IMAGE"
docker pull -q "$QCOW2_IMAGE"

say "Extracting guest disk payload"
# ubuntu-qcow2-gen is FROM scratch with nothing but /output, so there is
# nothing to run -- create a container purely to copy out of.
cid="$(docker create "$QCOW2_IMAGE")"
docker cp "$cid:/output/." "$IMAGES_DIR"
docker rm -f "$cid" > /dev/null 2>&1 || true

INFO="${IMAGES_DIR}/vm-info.json"
[ -f "$INFO" ] || { echo "ERROR: no vm-info.json in payload" >&2; exit 1; }

VM_NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["vm_name"])' "$INFO")"
VM_USER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["username"])' "$INFO")"
SSH_KEY="${IMAGES_DIR}/id_rsa"
chmod 600 "$SSH_KEY"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("guest:", d["vm_name"], "release:", d["release"], "kernel:", d["kernel_release"])' "$INFO"

cat > "$ENV_FILE" <<EOF
QEMU_IMAGE=${QEMU_IMAGE}
ROCJITSU_IMAGE=${ROCJITSU_IMAGE}
VM_IMAGES_DIR=${IMAGES_DIR}
VM_NAME=${VM_NAME}
VM_VCPUS=${VM_VCPUS}
VM_VMEM=${VM_VMEM}
VM_SHM_SIZE=${VM_SHM}
VM_NVME_COUNT=1
VM_SSH_PORT=${SSH_PORT}
EOF

say "Bringing up rocjitsu + QEMU"
dc up --detach

say "Waiting for the rocjitsu GPU server"
for _ in $(seq 1 30); do
    health="$(dc ps --format json rocjitsu 2>/dev/null \
              | python3 -c 'import sys,json; print(json.load(sys.stdin).get("Health",""))' 2>/dev/null || true)"
    [ "$health" = "healthy" ] && { echo "rocjitsu healthy"; break; }
    sleep 2
done
[ "${health:-}" = "healthy" ] || {
    echo "ERROR: rocjitsu did not become healthy" >&2
    dc logs --no-color rocjitsu
    exit 1
}

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=2
          -o NoHostAuthenticationForLocalhost=yes
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

say "Waiting for guest SSH"
elapsed=0
until ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_OPTS[@]}" "$VM_USER@localhost" true 2>/dev/null; do
    [ "$elapsed" -lt 300 ] || { echo "ERROR: guest did not accept SSH" >&2; dc logs --no-color qemu | tail -50; exit 1; }
    sleep 5
    elapsed=$((elapsed + 5))
done
echo "guest ready after ${elapsed}s"

say "Verifying emulated devices"
ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_OPTS[@]}" "$VM_USER@localhost" 'bash -s' <<'GUEST'
set -euo pipefail
lspci -nn
lspci -d ::0108 | grep -q . || { echo "no NVMe controller in guest"; exit 1; }
lspci -d 1002: | grep -q . || { echo "no AMD vfio-user device in guest"; exit 1; }
GUEST

# ----------------------------------------------------------------------
# Provision
# ----------------------------------------------------------------------
say "Building an ansible venv"
# Deliberately not reusing whatever ansible is on PATH: jmespath has to be
# importable by the same interpreter that runs the playbook.
VENV="${WORKDIR}/venv"
python3 -m venv "$VENV"
"${VENV}/bin/pip" install --quiet --upgrade pip
"${VENV}/bin/pip" install --quiet ansible-core jmespath
"${VENV}/bin/ansible-playbook" --version | head -3

say "Provisioning the guest"
SSH_PORT="$SSH_PORT" \
SSH_USER="$VM_USER" \
SSH_KEY="$SSH_KEY" \
ROCJITSU_IMAGE="$ROCJITSU_IMAGE" \
ROCJITSU_FIRMWARE_IMAGE="$ROCJITSU_FIRMWARE_IMAGE" \
ANSIBLE_HOST_KEY_CHECKING=False \
ANSIBLE_PLAYBOOK="${VENV}/bin/ansible-playbook" \
ANSIBLE_GALAXY="${VENV}/bin/ansible-galaxy" \
    "${REPO_ROOT}/scripts/test/vm-provision.sh" "${PROVISION_ARGS[@]}"

# ----------------------------------------------------------------------
# Build and test in the guest
# ----------------------------------------------------------------------
say "Copying the checkout into the guest"
rsync -az --delete \
    --exclude build --exclude build-alola --exclude .venv --exclude .git \
    -e "ssh -i $SSH_KEY -p $SSH_PORT ${SSH_OPTS[*]}" \
    "${REPO_ROOT}/" "$VM_USER@localhost:rocm-xio/"

if [ "$RUN_TEST" -eq 0 ]; then
    say "Stopping before the guest test (--no-test)"
    exit 0
fi

say "Building and running nvme-ep tests in the guest"
set +e
ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_OPTS[@]}" "$VM_USER@localhost" \
    "CTEST_LABEL='${CTEST_LABEL}' SKIP_GPU='${SKIP_GPU}' ./rocm-xio/scripts/test/vm-guest-test.sh"
test_rc=$?
set -e

say "Collecting diagnostics"
ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_OPTS[@]}" "$VM_USER@localhost" \
    'sudo dmesg' > "${WORKDIR}/guest-dmesg.txt" 2>&1 || true
ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_OPTS[@]}" "$VM_USER@localhost" \
    'cat rocm-xio/build/Testing/Temporary/LastTest.log' \
    > "${WORKDIR}/ctest-last.log" 2>&1 || true
echo "diagnostics in ${WORKDIR}"

say "Result: $([ $test_rc -eq 0 ] && echo PASS || echo "FAIL (rc=${test_rc})")"
exit "$test_rc"
