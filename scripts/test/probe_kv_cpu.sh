#!/usr/bin/env bash
#
# Copyright (c) 2026 IBM Corporation
#
# SPDX-License-Identifier: MIT
#
# GPU-FREE, reboot-FREE test of the NVMe Key-Value path. Boots the guest with NO
# GPU but WITH an SPDK kvdev_rados KV namespace (CSI=KV) over vfio-user, reports
# what the guest Linux NVMe driver does with a KV-only controller, then runs
# kv_cpu_probe (KV Store+Retrieve via /dev/nvme0 passthrough). Answers: does the
# guest enumerate the controller, and is our KV SQE format correct?
#
# PREREQ: vstart Ceph up (kvpool created by this script).
set +u
SPDK="$HOME/src/spdk"
CEPH="$HOME/src/ceph/build"
VMI="$HOME/src/rocm-xio/build/vm-images"
IMG_BASE="$VMI/rocm-xio-vm.qcow2"
QEMU="$HOME/src/qemu-xio/build/qemu-system-x86_64"
KV_POOL="${KV_POOL:-kvpool}"; KV_NS="${KV_NS:-kvns}"; KVKEY="${KVKEY:-cpukey01}"
RUN="$(mktemp -d /tmp/kvcpu.XXXX)"; SOCK="$RUN/rpc.sock"; MUSER="$RUN/muser"; mkdir -p "$MUSER"
OVL="$RUN/vm.qcow2"
NQN="nqn.2026-06.io.spdk:kv-rados0"; TGT_PID=""; QEMU_PID=""
cleanup(){ [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
           [ -n "$TGT_PID" ] && kill "$TGT_PID" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT
rpc(){ python3 "$SPDK/scripts/rpc.py" -s "$SOCK" "$@"; }
ceph_(){ LD_LIBRARY_PATH="$CEPH/lib" "$CEPH/bin/$1" -c "$CEPH/ceph.conf" "${@:2}"; }
SSH="ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 $USER@localhost"
SCP="scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

if (exec 3<>/dev/tcp/127.0.0.1/2222) 2>/dev/null; then exec 3>&- 3<&-; echo "ABORT: port 2222 in use"; exit 1; fi
ceph_ ceph -s >/dev/null 2>&1 || { echo "ABORT: vstart Ceph not reachable."; exit 1; }
ceph_ ceph osd pool create "$KV_POOL" 32 32 >/dev/null 2>&1 || true
OID_HEX=$(printf '%s' "$KVKEY" | od -An -tx1 | tr -d ' \n')
echo "preflight OK: Ceph reachable, pool $KV_POOL; key='$KVKEY' -> oid=$OID_HEX"

qemu-img create -f qcow2 -b "$IMG_BASE" -F qcow2 "$OVL" >/dev/null || exit 1

echo "== SPDK vfio-user NVMe-KV namespace (kvdev_rados, CSI=KV) =="
LD_LIBRARY_PATH="$CEPH/lib" "$SPDK/build/bin/nvmf_tgt" -r "$SOCK" -m 0x1 --no-huge -s 1024 >"$RUN/tgt.log" 2>&1 &
TGT_PID=$!; for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.1; done
rpc nvmf_create_transport -t VFIOUSER -q 1024 -m 16 >/dev/null
rpc kvdev_rados_register_cluster ceph0 --user admin --config-file "$CEPH/ceph.conf" --key-file "$CEPH/keyring" >/dev/null || { echo "register_cluster FAILED"; tail -8 "$RUN/tgt.log"; exit 1; }
rpc kvdev_rados_create KvRados0 ceph0 "$KV_POOL" --namespace "$KV_NS" >/dev/null || { echo "kvdev_create FAILED"; tail -8 "$RUN/tgt.log"; exit 1; }
rpc nvmf_create_subsystem "$NQN" -s SPDKKVR01 -a >/dev/null
rpc nvmf_subsystem_add_kv_ns "$NQN" KvRados0 >/dev/null || { echo "add_kv_ns FAILED"; tail -8 "$RUN/tgt.log"; exit 1; }
rpc nvmf_subsystem_add_listener "$NQN" -t VFIOUSER -a "$MUSER" -s 0 >/dev/null
echo "  KV namespace up on $NQN"

echo "== QEMU (NO GPU): vfio-user NVMe-KV controller =="
"$QEMU" -enable-kvm -machine q35,kernel-irqchip=on -cpu host -smp 4 -m 2048 \
  -object memory-backend-memfd,id=mem,size=2048M,share=on -numa node,memdev=mem \
  -drive file="$OVL",if=virtio,format=qcow2 \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
  -device "{\"driver\":\"vfio-user-pci\",\"socket\":{\"path\":\"$MUSER/cntrl\",\"type\":\"unix\"}}" \
  -nographic -serial file:"$RUN/console.log" -monitor none >"$RUN/qemu.log" 2>&1 &
QEMU_PID=$!
echo "  qemu pid=$QEMU_PID  RUN=$RUN  (waiting for guest SSH)"

up=0
for _ in $(seq 1 90); do
  $SSH 'echo ok' >/dev/null 2>&1 && { up=1; break; }
  kill -0 "$QEMU_PID" 2>/dev/null || { echo "QEMU exited early"; tail -30 "$RUN/qemu.log" "$RUN/console.log"; exit 1; }
  sleep 2
done
[ "$up" = 1 ] || { echo "guest SSH never came up"; tail -30 "$RUN/console.log"; exit 1; }
echo "  guest up."

$SCP "$HOME/src/rocm-xio/examples/nvme-kv/kv_cpu_probe.c" "$USER@localhost:/tmp/kv_cpu_probe.c" >/dev/null 2>&1
echo "== GUEST: what did the NVMe driver do with a KV-only controller? =="
$SSH "S(){ sudo \"\$@\"; }
      echo '--- nvme dmesg ---'; S dmesg 2>/dev/null | grep -iE 'nvme' | tail -15
      echo '--- /dev/nvme* ---'; ls -l /dev/nvme* 2>&1
      echo '--- /sys/class/nvme/nvme0 (cntltype, model, state) ---'
      for f in /sys/class/nvme/nvme0/{model,cntltype,state,subsysnqn}; do [ -e \"\$f\" ] && echo \"  \$(basename \$f)=\$(cat \$f 2>/dev/null)\"; done
      echo '--- namespaces seen ---'; ls -ld /sys/class/nvme/nvme0/nvme0n* 2>&1 | head; S nvme list 2>/dev/null | tail -5 || echo '(no nvme-cli)'
      echo '=== build + run kv_cpu_probe (KV Store+Retrieve via passthrough) ==='
      gcc -O2 -o /tmp/kv_cpu_probe /tmp/kv_cpu_probe.c && echo built
      S /tmp/kv_cpu_probe /dev/nvme0 1 '$KVKEY'; echo \"probe exit=\$?\""

echo ""
echo "== RADOS verify: did the Store land as an object? =="
ceph_ rados -p "$KV_POOL" -N "$KV_NS" stat "$OID_HEX" 2>&1 | head -2 || echo "  (not found)"
echo ""
echo "== SPDK KV target log (tail) =="; grep -iE "kvdev|kv_ns|store|retrieve|error|enable" "$RUN/tgt.log" | grep -ivE "Telemetry|rpc_decode" | tail -8
echo "RUN: $RUN"
