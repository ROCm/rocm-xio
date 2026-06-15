#!/usr/bin/env bash
#
# Copyright (c) 2026 IBM Corporation
#
# SPDX-License-Identifier: MIT
#
# GPU-initiated WAVEFRONT / BATCHED NVMe KEY-VALUE over RADOS.
#
# Same target as stage2_kv_rados_gpu.sh (SPDK kvdev_rados KV namespace, CSI=KV,
# behind vfio-user + the pci-mmio-bridge), but exercises the cooperative
# multi-key path: the GPU writes B KV SQEs into the SQ, rings the doorbell once,
# and polls B completions (driveEndpointKvWavefront). It stores a manifest of N
# keys in one batched Store, then fetches them all back in one batched Retrieve
# (value of key b lands in buffer slot b * value-size), including the VRAM
# (memory-mode 8 / P2PDMA) variant. RADOS is checked for all N objects.
#
# PREREQ: vstart Ceph up; passthrough boot (+ modprobe vfio-pci); rocm-xio built
# in the guest WITH the KV patch (rsync the tree or rebuild in-guest).
set +u
SPDK="$HOME/src/spdk"
CEPH="$HOME/src/ceph/build"
VMI="$HOME/src/rocm-xio/build/vm-images"
IMG_BASE="$VMI/rocm-xio-vm.qcow2"
VBIOS="${VBIOS:-$VMI/vbios_ours.bin}"
OVMF_CODE=/usr/share/edk2/ovmf/OVMF_CODE.fd
OVMF_VARS_SRC=/usr/share/edk2/ovmf/OVMF_VARS.fd
GPU=0000:bd:00.0; GPUAU=0000:bd:00.1; HDA=0000:bd:00.6
KV_POOL="${KV_POOL:-kvpool}"; KV_NS="${KV_NS:-kvns}"
# Multi-key manifest. KEYS is a space-separated list; BATCH defaults to the key
# count (one doorbell ring). The value buffer must hold BATCH * VALSZ bytes.
KEYS="${KEYS:-wfk0 wfk1 wfk2 wfk3}"; VALSZ="${VALSZ:-4096}"
set -- $KEYS; NKEYS=$#
BATCH="${BATCH:-$NKEYS}"
BUFSZ="${BUFSZ:-$((BATCH * VALSZ))}"
RUN="$(mktemp -d /tmp/stage3kv.XXXX)"; SOCK="$RUN/rpc.sock"; MUSER="$RUN/muser"; mkdir -p "$MUSER"
OVL="$RUN/vm.qcow2"; VARS="$RUN/OVMF_VARS.fd"
NQN="nqn.2026-06.io.spdk:kv-rados0"; TGT_PID=""; QEMU_PID=""
cleanup(){ [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
           [ -n "$TGT_PID" ] && kill "$TGT_PID" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT
rpc(){ python3 "$SPDK/scripts/rpc.py" -s "$SOCK" "$@"; }
ceph_(){ LD_LIBRARY_PATH="$CEPH/lib" "$CEPH/bin/$1" -c "$CEPH/ceph.conf" "${@:2}"; }
SSH="ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 $USER@localhost"

for d in $GPU $GPUAU $HDA; do
  drv=$(basename "$(readlink -f /sys/bus/pci/devices/$d/driver 2>/dev/null)" 2>/dev/null)
  [ "$drv" = vfio-pci ] || { echo "ABORT: $d on '${drv:-none}', not vfio-pci."; exit 1; }
done
ceph_ ceph -s >/dev/null 2>&1 || { echo "ABORT: vstart Ceph not reachable."; exit 1; }
ceph_ ceph osd pool create "$KV_POOL" 32 32 >/dev/null 2>&1 || true
echo "preflight OK: GPU on vfio-pci, Ceph reachable, pool $KV_POOL ready"
echo "  manifest: $NKEYS key(s) [$KEYS], batch=$BATCH, value=$VALSZ B, buffer=$BUFSZ B"
# oid the kvdev will use for each key (hex of the key bytes; matches kvdev_rados_key_to_oid)
oid_of(){ printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
for k in $KEYS; do echo "  key='$k' -> rados oid=$(oid_of "$k") in $KV_POOL/$KV_NS"; done

qemu-img create -f qcow2 -b "$IMG_BASE" -F qcow2 "$OVL" >/dev/null || exit 1
cp "$OVMF_VARS_SRC" "$VARS"

echo "== SPDK vfio-user NVMe-KV namespace backed by RADOS kvdev_rados =="
LD_LIBRARY_PATH="$CEPH/lib" "$SPDK/build/bin/nvmf_tgt" -r "$SOCK" -m 0x1 --no-huge -s 1024 >"$RUN/tgt.log" 2>&1 &
TGT_PID=$!; for i in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.1; done
rpc nvmf_create_transport -t VFIOUSER -q 1024 -m 16 >/dev/null
rpc kvdev_rados_register_cluster ceph0 --user admin --config-file "$CEPH/ceph.conf" --key-file "$CEPH/keyring" >/dev/null || { echo "register_cluster FAILED"; tail -10 "$RUN/tgt.log"; exit 1; }
rpc kvdev_rados_create KvRados0 ceph0 "$KV_POOL" --namespace "$KV_NS" >/dev/null || { echo "kvdev_rados_create FAILED"; tail -10 "$RUN/tgt.log"; exit 1; }
rpc nvmf_create_subsystem "$NQN" -s SPDKKVR01 -a >/dev/null
rpc nvmf_subsystem_add_kv_ns "$NQN" KvRados0 >/dev/null || { echo "add_kv_ns FAILED"; tail -10 "$RUN/tgt.log"; exit 1; }
rpc nvmf_subsystem_add_listener "$NQN" -t VFIOUSER -a "$MUSER" -s 0 >/dev/null
echo "  KV namespace KvRados0 (CSI=KV) on $NQN"

echo "== QEMU: iGPU passthrough + RADOS-backed vfio-user NVMe-KV + bridge =="
"$HOME/src/qemu-xio/build/qemu-system-x86_64" -enable-kvm -machine q35,kernel-irqchip=on -cpu host -smp 8 -m 2048 \
  -object memory-backend-memfd,id=mem,size=2048M,share=on -numa node,memdev=mem \
  -device pci-mmio-bridge,id=mmio-bridge,shadow-gpa=0x100000000,shadow-size=8192,poll-interval-ns=10000,addr=8.0 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$OVL",if=virtio,format=qcow2 \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
  -device pcie-root-port,id=gpubus,bus=pcie.0,chassis=11,slot=11,multifunction=on \
  -device vfio-pci,host=$GPU,bus=gpubus,addr=00.0,multifunction=on,romfile="$VBIOS" \
  -device vfio-pci,host=$GPUAU,bus=gpubus,addr=00.1 \
  -device vfio-pci,host=$HDA,bus=gpubus,addr=00.6 \
  -device "{\"driver\":\"vfio-user-pci\",\"socket\":{\"path\":\"$MUSER/cntrl\",\"type\":\"unix\"}}" \
  -trace 'pci_mmio_bridge*' -D "$RUN/qtrace.log" \
  -nographic -serial file:"$RUN/console.log" -monitor none >"$RUN/qemu.log" 2>&1 &
QEMU_PID=$!
echo "  qemu pid=$QEMU_PID  RUN=$RUN  (waiting for guest SSH)"

up=0
for i in $(seq 1 90); do
  $SSH 'echo ok' >/dev/null 2>&1 && { up=1; break; }
  kill -0 "$QEMU_PID" 2>/dev/null || { echo "QEMU exited early"; tail -30 "$RUN/qemu.log" "$RUN/console.log"; exit 1; }
  sleep 2
done
[ "$up" = 1 ] || { echo "guest SSH never came up"; tail -30 "$RUN/console.log"; exit 1; }
echo "  guest up."

echo "== GUEST: confirm KV controller, then BATCHED GPU KV STORE + RETRIEVE =="
$SSH "S(){ sudo \"\$@\"; }
      if ! S rocminfo 2>/dev/null | grep -qi gfx1; then echo '>>> NO GPU COMPUTE (host reboot needed) <<<'; exit 1; fi
      echo \"GPU: \$(S rocminfo 2>/dev/null | grep -m1 gfx1 | tr -s ' ')\"
      cd ~/rocm-xio/kernel/rocm-xio; make >/tmp/km.log 2>&1 || tail -5 /tmp/km.log
      [ -e /dev/rocm-xio ] || { S insmod rocm-xio.ko 2>&1 || S modprobe rocm_xio 2>&1; }
      echo '--- controller present? (KV ns may have NO block device, that is OK) ---'
      ls -l /dev/nvme0 2>&1 || echo 'NO /dev/nvme0'
      echo '=== WAVEFRONT GPU KV STORE $NKEYS keys, batch=$BATCH, value=$VALSZ B (populate the manifest) ==='
      S env HSA_FORCE_FINE_GRAIN_PCIE=1 ~/rocm-xio/build/xio-tester nvme-ep --controller /dev/nvme0 \
        --kv-op store --keys $KEYS --batch-size $BATCH --value-size $VALSZ \
        --data-buffer-size $BUFSZ --write-io 1 --pci-mmio-bridge --verbose 2>&1 | grep -iE 'completed|error|exception|fail|KV|Wavefront|Memory Mode' | tail -12
      echo '=== WAVEFRONT GPU KV RETRIEVE mode 0 (values -> host buffer slots) ==='
      S env HSA_FORCE_FINE_GRAIN_PCIE=1 ~/rocm-xio/build/xio-tester nvme-ep --controller /dev/nvme0 \
        --kv-op retrieve --keys $KEYS --batch-size $BATCH --value-size $VALSZ \
        --data-buffer-size $BUFSZ --read-io 1 --memory-mode 0 --pci-mmio-bridge --verbose 2>&1 | grep -iE 'completed|error|exception|fail|KV|Wavefront|returned value' | tail -12
      echo '=== *** WAVEFRONT GPU KV RETRIEVE mode 8 -- VALUES LAND IN GPU VRAM (P2PDMA) *** ==='
      S dmesg -C 2>/dev/null
      S env HSA_FORCE_FINE_GRAIN_PCIE=1 ~/rocm-xio/build/xio-tester nvme-ep --controller /dev/nvme0 \
        --kv-op retrieve --keys $KEYS --batch-size $BATCH --value-size $VALSZ \
        --data-buffer-size $BUFSZ --read-io 1 --memory-mode 8 --pci-mmio-bridge --verbose 2>&1 | grep -iE 'completed|error|exception|fail|KV|Wavefront|returned value|Memory Mode' | tail -12
      echo '--- mode-8 dmesg (VRAM dma-buf / P2PDMA / PRP inject) ---'
      S dmesg 2>/dev/null | grep -iE 'rocm-axiio|p2p|dma.?buf|vram|exception|Injected PRP|Registered buffer' | tail -14"

echo ""
echo "== RADOS verify: did every batched KV Store land as an object? =="
ok=0; miss=0
for k in $KEYS; do
  oid=$(oid_of "$k")
  if ceph_ rados -p "$KV_POOL" -N "$KV_NS" stat "$oid" >/dev/null 2>&1; then
    sz=$(ceph_ rados -p "$KV_POOL" -N "$KV_NS" stat "$oid" 2>/dev/null | grep -oE 'size [0-9]+' | awk '{print $2}')
    echo "  OK   key='$k' oid=$oid size=${sz:-?}"
    ok=$((ok+1))
  else
    echo "  MISS key='$k' oid=$oid (not found / kvdev oid mapping differs)"
    miss=$((miss+1))
  fi
done
echo "  -> $ok/$NKEYS objects present, $miss missing"
echo ""
echo "===== bridge trace (GPU KV doorbells) ====="
grep -a pci_mmio_bridge "$RUN/qtrace.log" 2>/dev/null | grep -vE "_init|_realize|_reset" | tail -6 || echo "(none)"
echo "RUN: $RUN"
