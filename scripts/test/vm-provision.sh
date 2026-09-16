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
# shape (synthesise an inventory, run a playbook against the live VM)
# but it drives the checked-in playbook at
# scripts/test/ansible/vm-rocjitsu-nvme.yml and authenticates with the
# keypair that shipped alongside the guest disk rather than with a
# password. No Galaxy collection is installed: the guest image now
# carries ROCm, so the playbook uses no roles.
#
# Prerequisites:
#   - VM already booted and accepting SSH
#     (.github/actions/rocjitsu-nvme-vm does this)
#   - ansible-playbook in PATH
#   - docker on the local host: the playbook shells out to the
#     rocjitsu image to generate ip_discovery.bin and the gfx1250
#     firmware stubs
#
# Environment variables:
#   SSH_PORT          Guest SSH port (default: 2222)
#   SSH_USER          Guest username (default: batesste)
#   SSH_KEY           Private key authenticating as SSH_USER
#   ROCJITSU_FIRMWARE_IMAGE
#                     Pinned rocjitsu image used only to synthesise the
#                     gfx1250 firmware stubs (default: ROCJITSU_IMAGE)
#   ROCJITSU_IMAGE    Pinned rocjitsu image (required; used for
#                     rj-ip-discovery and to serve the device)
#   ANSIBLE_PLAYBOOK  Path to ansible-playbook
#
# Any extra arguments are passed through to ansible-playbook, so a
# caller can add -e/--tags without this script knowing about them.

set -euo pipefail

SSH_PORT="${SSH_PORT:-2222}"
SSH_USER="${SSH_USER:-batesste}"
SSH_KEY="${SSH_KEY:?SSH_KEY must point at the guest private key}"
ROCJITSU_IMAGE="${ROCJITSU_IMAGE:?ROCJITSU_IMAGE must be a pinned tag}"
ROCJITSU_FIRMWARE_IMAGE="${ROCJITSU_FIRMWARE_IMAGE:-${ROCJITSU_IMAGE}}"

ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-ansible-playbook}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK="${SCRIPT_DIR}/ansible/vm-rocjitsu-nvme.yml"

if [ ! -f "${PLAYBOOK}" ]; then
    echo "ERROR: playbook not found at ${PLAYBOOK}" >&2
    exit 1
fi

# Several ansible installs can be on PATH at once -- a distro one, a runner
# image one, a pip one -- and controller-side filter dependencies such as
# jmespath have to live in whichever interpreter this resolves to. Print it, so
# a missing-dependency failure later says which environment to look in.
"${ANSIBLE_PLAYBOOK}" --version

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
echo "  firmware: ${ROCJITSU_FIRMWARE_IMAGE}"
echo ""

# Exported rather than passed with -e so the playbook can read it via
# lookup('env', ...) on the controller, where the docker run happens.
export ROCJITSU_IMAGE
export ROCJITSU_FIRMWARE_IMAGE

exec "${ANSIBLE_PLAYBOOK}" \
    -i "${TMPDIR_PROV}/inventory.ini" \
    -e "vm_username=${SSH_USER}" \
    "${PLAYBOOK}" "$@"
