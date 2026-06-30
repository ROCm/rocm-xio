#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Dedicated lib dir var: each lib/*.sh sets its own HERE when sourced, which
# would otherwise clobber this script's.
LIBDIR="$HERE/lib"
# shellcheck source=/dev/null
source "$LIBDIR/common.sh"

stage="${1:-serve}"; shift || true
case "$stage" in
  selftest)
    # shellcheck disable=SC2034  # STAGE is read cross-file by common.sh log()/die()
    STAGE=selftest
    # shellcheck source=/dev/null
    source "$LIBDIR/ceph-up.sh"; ceph_up
    log selftest "running fork self-test: test/nvmf/kv_rados/kv_rados_vfio_user.sh"
    cd "$SPDK_DIR/test/nvmf/kv_rados"
    export CEPH_CONF CEPH_KEYRING RADOS_BIN=rados KV_POOL KV_NS CEPH_USER=admin
    # Patch the fork self-test to --no-huge when hugepages are absent.
    script=kv_rados_vfio_user.sh
    if [ "$(spdk_huge_flags)" != "" ]; then
      sed 's#-m 0x3 --iova-mode=va#-m 0x3 --no-huge -s 1024#' \
        kv_rados_vfio_user.sh > kv_rados_selftest.sh
      chmod +x kv_rados_selftest.sh; script=kv_rados_selftest.sh
    fi
    ./"$script" | tee -a "$LOG_DIR/selftest.log"
    log selftest "DONE (see $LOG_DIR/selftest.log for PASS/FAIL)"
    ;;
  shell)
    # shellcheck source=/dev/null
    source "$LIBDIR/ceph-up.sh"; ceph_up; exec /bin/bash ;;
  build-vm)
    # shellcheck disable=SC2034
    STAGE=build-vm
    # shellcheck source=/dev/null
    source "$LIBDIR/guard.sh"; guard_nvme_bdf
    # shellcheck source=/dev/null
    source "$LIBDIR/vm-build.sh"; vm_build ;;

  serve)
    # shellcheck disable=SC2034
    STAGE=serve
    # shellcheck source=/dev/null
    source "$LIBDIR/guard.sh"; guard_all
    # shellcheck source=/dev/null
    source "$LIBDIR/ceph-up.sh"
    # shellcheck source=/dev/null
    source "$LIBDIR/spdk-kv.sh"
    # shellcheck source=/dev/null
    source "$LIBDIR/vm-build.sh"
    # shellcheck source=/dev/null
    source "$LIBDIR/vm-run.sh"
    # vm_run blocks in the foreground (no exec), so this trap survives to reap the
    # backgrounded nvmf_tgt when QEMU exits or on signal.
    trap 'kill_tracked' EXIT INT TERM
    ceph_up
    spdk_kv_up
    vm_build
    vm_run ;;

  gpu-e2e)
    # shellcheck disable=SC2034
    STAGE=gpu-e2e
    require_var ROCXIO_NVME_DEVICE
    SSHKEY="${SSHKEY:-/root/.ssh/id_ed25519}"
    SSHOPT=(-F /dev/null -i "$SSHKEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
    log gpu-e2e "waiting for guest SSH on $SSH_PORT"
    up=0
    for _ in $(seq 1 90); do
      ssh "${SSHOPT[@]}" "$GUEST_USER@localhost" 'echo ok' >/dev/null 2>&1 && { up=1; break; }
      sleep 2
    done
    [ "$up" = 1 ] || die "guest SSH never came up on $SSH_PORT"
    ssh "${SSHOPT[@]}" "$GUEST_USER@localhost" 'test -d ~/src/rocm-xio && test -e /dev/rocm-xio && lsmod | grep -q rocm' \
      || die "guest not provisioned: ~/src/rocm-xio / /dev/rocm-xio / kmod missing (check build-vm Ansible)"
    log gpu-e2e "running ctest (taskset -c $TASKSET_CPUS, -LE $CTEST_LABEL_EXCLUDE)"
    # shellcheck disable=SC2029  # env vars expand host-side into the remote command intentionally
    ssh "${SSHOPT[@]}" "$GUEST_USER@localhost" \
      "cd ~/src/rocm-xio && sudo env ROCXIO_NVME_DEVICE=$ROCXIO_NVME_DEVICE \
        NVME_DEVICE=$ROCXIO_NVME_DEVICE USE_PCI_MMIO_BRIDGE=$USE_PCI_MMIO_BRIDGE \
        taskset -c $TASKSET_CPUS ctest --test-dir build -LE $CTEST_LABEL_EXCLUDE --output-on-failure" \
      2>&1 | tee -a "$LOG_DIR/gpu-e2e.log"
    log gpu-e2e "DONE (see $LOG_DIR/gpu-e2e.log for the NN/NN result)" ;;

  gpu-e2e-wavefront)
    # shellcheck disable=SC2034
    STAGE=gpu-e2e-wavefront
    # shellcheck source=/dev/null
    source "$LIBDIR/ceph-up.sh"
    SSHKEY="${SSHKEY:-/root/.ssh/id_ed25519}"
    SSHOPT=(-F /dev/null -i "$SSHKEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
    KEYS="$KV_KEYS"; VALSZ="$KV_VALUE_SIZE"
    # shellcheck disable=SC2086  # KEYS is a word list by design
    set -- $KEYS; NKEYS=$#
    BATCH="${KV_BATCH:-$NKEYS}"
    BUFSZ=$((BATCH * VALSZ))
    log gpu-e2e-wavefront "waiting for guest SSH on $SSH_PORT"
    up=0
    for _ in $(seq 1 90); do
      ssh "${SSHOPT[@]}" "$GUEST_USER@localhost" 'echo ok' >/dev/null 2>&1 && { up=1; break; }
      sleep 2
    done
    [ "$up" = 1 ] || die "guest SSH never came up on $SSH_PORT"
    ssh "${SSHOPT[@]}" "$GUEST_USER@localhost" 'test -d ~/src/rocm-xio && test -e /dev/rocm-xio && lsmod | grep -q rocm' \
      || die "guest not provisioned: ~/src/rocm-xio / /dev/rocm-xio / kmod missing (check build-vm Ansible)"
    log gpu-e2e-wavefront "manifest: $NKEYS key(s) [$KEYS], batch=$BATCH, value=$VALSZ B, buffer=$BUFSZ B"
    TESTER='sudo env HSA_FORCE_FINE_GRAIN_PCIE=1 ~/src/rocm-xio/build/xio-tester nvme-ep --controller /dev/nvme0'
    {
      log gpu-e2e-wavefront "batched KV STORE ($NKEYS keys)"
      # shellcheck disable=SC2029  # $KEYS/$BATCH/$VALSZ/$BUFSZ expand host-side intentionally
      ssh "${SSHOPT[@]}" "$GUEST_USER@localhost" \
        "$TESTER --kv-op store --keys $KEYS --batch-size $BATCH --value-size $VALSZ \
          --data-buffer-size $BUFSZ --write-io 1 --pci-mmio-bridge --verbose 2>&1 \
          | grep -iE 'completed|error|exception|fail|KV|Wavefront|Memory Mode'" || true
      log gpu-e2e-wavefront "batched KV RETRIEVE mode 0 (host slots)"
      # shellcheck disable=SC2029
      ssh "${SSHOPT[@]}" "$GUEST_USER@localhost" \
        "$TESTER --kv-op retrieve --keys $KEYS --batch-size $BATCH --value-size $VALSZ \
          --data-buffer-size $BUFSZ --read-io 1 --memory-mode 0 --pci-mmio-bridge --verbose 2>&1 \
          | grep -iE 'completed|error|exception|fail|KV|Wavefront|returned value'" || true
      log gpu-e2e-wavefront "batched KV RETRIEVE mode 8 (values -> VRAM / P2PDMA)"
      # shellcheck disable=SC2029
      ssh "${SSHOPT[@]}" "$GUEST_USER@localhost" \
        "$TESTER --kv-op retrieve --keys $KEYS --batch-size $BATCH --value-size $VALSZ \
          --data-buffer-size $BUFSZ --read-io 1 --memory-mode 8 --pci-mmio-bridge --verbose 2>&1 \
          | grep -iE 'completed|error|exception|fail|KV|Wavefront|returned value|Memory Mode'" || true
    } 2>&1 | tee -a "$LOG_DIR/gpu-e2e-wavefront.log"
    log gpu-e2e-wavefront "RADOS verify: every batched Store landed as an object?"
    ceph_up
    ok=0; miss=0
    for k in $KEYS; do
      oid=$(printf '%s' "$k" | od -An -tx1 | tr -d ' \n')
      if rados -c "$CEPH_CONF" -k "$CEPH_KEYRING" -p "$KV_POOL" -N "$KV_NS" stat "$oid" >/dev/null 2>&1; then
        log gpu-e2e-wavefront "  OK   key='$k' oid=$oid"; ok=$((ok + 1))
      else
        log gpu-e2e-wavefront "  MISS key='$k' oid=$oid"; miss=$((miss + 1))
      fi
    done
    log gpu-e2e-wavefront "-> $ok/$NKEYS objects present, $miss missing (see $LOG_DIR/gpu-e2e-wavefront.log)"
    [ "$miss" = 0 ] || die "$miss/$NKEYS keys missing from RADOS" ;;

  cleanup)
    # shellcheck disable=SC2034
    STAGE=cleanup
    kill_tracked
    log cleanup "done" ;;
  *) die "unknown stage: $stage (use: selftest|shell|build-vm|serve|gpu-e2e|gpu-e2e-wavefront|cleanup)" ;;
esac
