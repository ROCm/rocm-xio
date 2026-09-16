#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# vm-provision.sh
#
# Provision a booted rocm-xio test VM that is attached to a rocjitsu
# emulated GPU and an emulated NVMe controller.
#
# This is the rocjitsu/NVMe sibling of scripts/test/setup-vm: same
# shape (install the Galaxy collection, synthesise an inventory,
# run a playbook against the live VM) but it drives the checked-in
# playbook at scripts/test/ansible/vm-rocjitsu-nvme.yml and
# authenticates with the keypair that shipped alongside the guest
# disk rather than with a password.
#
# Prerequisites:
#   - VM already booted and accepting SSH
#     (.github/actions/rocjitsu-nvme-vm does this)
#   - ansible-playbook and ansible-galaxy in PATH
#   - docker on the local host: the playbook shells out to the
#     rocjitsu image to generate ip_discovery.bin
#
# Environment variables:
#   SSH_PORT          Guest SSH port (default: 2222)
#   SSH_USER          Guest username (default: batesste)
#   SSH_KEY           Private key authenticating as SSH_USER
#   ROCJITSU_IMAGE    Pinned rocjitsu image (required; used for
#                     rj-ip-discovery)
#   ANSIBLE_PLAYBOOK  Path to ansible-playbook
#   ANSIBLE_GALAXY    Path to ansible-galaxy

set -euo pipefail

SSH_PORT="${SSH_PORT:-2222}"
SSH_USER="${SSH_USER:-batesste}"
SSH_KEY="${SSH_KEY:?SSH_KEY must point at the guest private key}"
ROCJITSU_IMAGE="${ROCJITSU_IMAGE:?ROCJITSU_IMAGE must be a pinned tag}"

ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-ansible-playbook}"
ANSIBLE_GALAXY="${ANSIBLE_GALAXY:-ansible-galaxy}"

COLLECTION="sbates130272.batesste"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK="${SCRIPT_DIR}/ansible/vm-rocjitsu-nvme.yml"

if [ ! -f "${PLAYBOOK}" ]; then
    echo "ERROR: playbook not found at ${PLAYBOOK}" >&2
    exit 1
fi

echo "Installing Ansible Galaxy collection ${COLLECTION}..."
"${ANSIBLE_GALAXY}" collection install "${COLLECTION}"

TMPDIR_PROV="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_PROV}"' EXIT

SSH_ARGS="-o StrictHostKeyChecking=no"
SSH_ARGS="${SSH_ARGS} -o UserKnownHostsFile=/dev/null"
SSH_ARGS="${SSH_ARGS} -o NoHostAuthenticationForLocalhost=yes"

cat > "${TMPDIR_PROV}/inventory.ini" <<EOF
[testvm]
rocm-xio-vm ansible_host=localhost ansible_port=${SSH_PORT} ansible_user=${SSH_USER} ansible_ssh_private_key_file=${SSH_KEY} ansible_become=true ansible_ssh_common_args='${SSH_ARGS}'
EOF

echo "Provisioning VM..."
echo "  SSH port: ${SSH_PORT}"
echo "  User:     ${SSH_USER}"
echo "  rocjitsu: ${ROCJITSU_IMAGE}"
echo ""

# Exported rather than passed with -e so the playbook can read it via
# lookup('env', ...) on the controller, where the docker run happens.
export ROCJITSU_IMAGE

exec "${ANSIBLE_PLAYBOOK}" \
    -i "${TMPDIR_PROV}/inventory.ini" \
    -e "vm_username=${SSH_USER}" \
    "${PLAYBOOK}"
