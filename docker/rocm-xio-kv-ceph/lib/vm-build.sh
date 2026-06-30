#!/usr/bin/env bash
# Clone qemu-minimal tooling + batesste-ansible, install the batesste collection,
# then run gen-vm WITH Ansible provisioning to build the guest qcow (rocm-xio @
# nvme-kv + kmod). Cached in /data/images; skip unless FORCE=1.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/common.sh"
# Tooling clone is shared via $TOOLING_DIR (bind mount); ANSIBLE_SRC is
# build-time only (ephemeral /opt).
ANSIBLE_SRC=/opt/batesste-ansible
: "${QEMU_BIN:=/opt/qemu/build/qemu-system-x86_64}"
QCOW="$IMAGES_DIR/$VM_NAME.qcow2"

vm_build() {
  # shellcheck disable=SC2034  # STAGE is read cross-file by common.sh log()/die()
  local STAGE=build-vm
  if [ -f "$QCOW" ] && [ "${FORCE:-0}" != "1" ]; then
    log build-vm "qcow exists ($QCOW); skip (FORCE=1 to rebuild)"; return 0
  fi
  ensure_tooling
  [ -f "$TOOLING_DIR/$GENVM_SCRIPT" ] || die "GENVM_SCRIPT $GENVM_SCRIPT not in tooling repo"
  if [ ! -d "$ANSIBLE_SRC/.git" ]; then
    log build-vm "cloning ansible $ANSIBLE_REMOTE@$ANSIBLE_BRANCH"
    GIT_TERMINAL_PROMPT=0 git clone --branch "$ANSIBLE_BRANCH" "$ANSIBLE_REMOTE" "$ANSIBLE_SRC" \
      || die "ansible clone failed"
  fi
  [ -f "$ANSIBLE_SRC/$ANSIBLE_PLAYBOOK" ]  || die "playbook $ANSIBLE_PLAYBOOK missing in ansible repo"
  [ -f "$ANSIBLE_SRC/$ANSIBLE_INVENTORY" ] || die "inventory $ANSIBLE_INVENTORY missing in ansible repo"
  [ -f "$ANSIBLE_SRC/requirements.yml" ] || die "requirements.yml missing in ansible repo (gen-vm requires it)"
  log build-vm "installing batesste collection + requirements"
  ansible-galaxy collection install "$ANSIBLE_SRC" --force >>"$LOG_DIR/gen-vm.log" 2>&1 \
    || die "batesste collection install failed (see $LOG_DIR/gen-vm.log)"
  ansible-galaxy collection install -r "$ANSIBLE_SRC/requirements.yml" >>"$LOG_DIR/gen-vm.log" 2>&1 || true
  if [ ! -f "$ANSIBLE_SRC/ansible.cfg" ]; then
    cat >"$ANSIBLE_SRC/ansible.cfg" <<EOF
[defaults]
roles_path = $ANSIBLE_SRC/roles
collections_path = $HOME/.ansible/collections
host_key_checking = False
remote_tmp = /tmp/.ansible-tmp
EOF
  fi
  # gen-vm requires SSH_KEY_FILE (public key) and SSHes the guest with the default
  # identity, so generate an ed25519 keypair if absent. Never overwrite existing keys.
  local sshkey="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
  if [ ! -f "$sshkey" ]; then
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -q
    sshkey="$HOME/.ssh/id_ed25519.pub"
    log build-vm "generated ephemeral SSH keypair for guest provisioning"
  fi
  # WORKAROUND: the host ~/.ssh is bind-mounted read-only and drags in a config
  # not owned by the in-container root, so OpenSSH aborts every connection ("Bad
  # owner or permissions"). Stage a clean root-owned ~/.ssh (keys only, no config)
  # and repoint root's passwd home at it (ssh resolves config via getpwuid, not
  # $HOME, so exporting HOME is not enough). .ansible is symlinked back so the
  # collection installed above stays visible.
  local genvm_home="$RUN_DIR/genvm-home"
  rm -rf "$genvm_home"; mkdir -p "$genvm_home/.ssh"; chmod 700 "$genvm_home/.ssh"
  cp "$sshkey" "$genvm_home/.ssh/"
  local privkey="${sshkey%.pub}"
  [ -f "$privkey" ] && { cp "$privkey" "$genvm_home/.ssh/"; chmod 600 "$genvm_home/.ssh/$(basename "$privkey")"; }
  [ -d "$HOME/.ansible" ] && ln -sfn "$HOME/.ansible" "$genvm_home/.ansible"
  local genvm_sshkey
  genvm_sshkey="$genvm_home/.ssh/$(basename "$sshkey")"
  if [ -w /etc/passwd ]; then
    sed -i "s#^\(root:[^:]*:[^:]*:[^:]*:[^:]*\):[^:]*:#\1:${genvm_home}:#" /etc/passwd
  else
    log build-vm "WARN: /etc/passwd not writable; ssh may abort on mounted ~/.ssh/config"
  fi
  # The gen-vm builder VM has no GPU, so disable the GPU-dependent provisioning
  # checks (rocminfo/hipcc/unit-tests/test-endpoint); the guest still gets
  # rocm-xio built and the kmod installed. Those are validated at runtime by gpu-e2e.
  # Gates MUST be real JSON booleans, not "var=false" strings: with jinja2_native
  # off, a bare `when: var` treats the string "false" as truthy. Compact JSON (no
  # spaces) survives gen-vm's word-split of ANSIBLE_EXTRA_ARGS as one token.
  if [ -z "${BUILD_TIME_ANSIBLE_VARS:-}" ]; then
    BUILD_TIME_ANSIBLE_VARS='-e {"rocm_setup_run_checks":false,"rocm_xio_setup_run_basic_checks":false,"rocm_xio_setup_run_unit_tests":false,"rocm_xio_setup_run_test_endpoint":false}'
  fi
  # Feed the guest GPU arch to the play as a second compact-JSON -e token (the
  # general/minimal ANSIBLE_BRANCH asserts guest_gpu_arch is set; the author
  # overlay branch defaults it). If GPU_ARCH is unset we deliberately pass
  # nothing so the minimal branch fails loudly rather than baking a wrong arch.
  if [ -n "${GPU_ARCH:-}" ]; then
    BUILD_TIME_ANSIBLE_VARS="$BUILD_TIME_ANSIBLE_VARS -e {\"guest_gpu_arch\":\"$GPU_ARCH\"}"
  fi
  # Pin the checkout to the login user's home.
  BUILD_TIME_ANSIBLE_VARS="$BUILD_TIME_ANSIBLE_VARS -e {\"rocm_xio_setup_source_dir\":\"/home/$GUEST_USER/src/rocm-xio\"}"
  log build-vm "running $GENVM_SCRIPT with Ansible (playbook=$ANSIBLE_PLAYBOOK)"
  ( cd "$TOOLING_DIR/$(dirname "$GENVM_SCRIPT")" && \
    HOME="$genvm_home" \
    VM_NAME="$VM_NAME" RELEASE=noble VCPUS="$VCPUS" VMEM="$VMEM" \
    SSH_KEY_FILE="$genvm_sshkey" \
    QEMU_PATH="$(dirname "$QEMU_BIN")/" \
    SSH_PORT="$SSH_PORT" IMAGES="$IMAGES_DIR" \
    ANSIBLE_SETUP=true ANSIBLE_DIR="$ANSIBLE_SRC" \
    ANSIBLE_PLAYBOOK="$ANSIBLE_PLAYBOOK" ANSIBLE_INVENTORY="$ANSIBLE_INVENTORY" \
    ANSIBLE_EXTRA_ARGS="$BUILD_TIME_ANSIBLE_VARS" \
      "./$(basename "$GENVM_SCRIPT")" >>"$LOG_DIR/gen-vm.log" 2>&1 ) \
    || die "gen-vm failed (see $LOG_DIR/gen-vm.log)"
  [ -f "$QCOW" ] || die "gen-vm did not produce $QCOW (check IMAGES/VM_NAME in gen-vm.log)"
  log build-vm "qcow ready: $QCOW"
}
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then vm_build; fi
