#!/usr/bin/env bash
# Launch the VM via the configurable run-vm launcher, attaching the
# SPDK vfio-user socket + passing through GPU and the real NVMe. Foregrounds QEMU.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/common.sh"
: "${QEMU_BIN:=/opt/qemu/build/qemu-system-x86_64}"

vm_run() {
  # shellcheck disable=SC2034  # STAGE is read cross-file by common.sh log()/die()
  local STAGE=vm-run
  require_var GPU_BDFS NVME_BDF
  local sock; sock="$(cat "$RUN_DIR/vfio_user_sock" 2>/dev/null || true)"
  [ -S "$sock" ] || die "vfio-user socket missing ($sock); run spdk-kv first"
  ensure_tooling
  [ -f "$TOOLING_DIR/$RUNVM_SCRIPT" ] || die "RUNVM_SCRIPT $RUNVM_SCRIPT not in tooling repo"
  log vm-run "launching $RUNVM_SCRIPT (NVMe=$NVME_BDF GPU=$GPU_BDFS port=$SSH_PORT vram_idx=$VRAM_DEV_INDEX)"
  cd "$TOOLING_DIR/$(dirname "$RUNVM_SCRIPT")"
  # No exec: vm_run blocks so the serve stage's `trap kill_tracked` survives to
  # reap nvmf_tgt when QEMU exits.
  # QEMU_PATH is a string prefix in the launcher, so it must be the binary's dir
  # with a trailing slash.
  #TODO: revisit UEFI and if this should be enabled
  VM_NAME="$VM_NAME" SSH_PORT="$SSH_PORT" \
  PCI_HOSTDEV="${NVME_BDF},${GPU_BDFS}" \
  VFIO_USERDEV="$sock" \
  PCI_MMIO_BRIDGE="$PCI_MMIO_BRIDGE" IOMMU="$IOMMU" \
  VRAM_DEV_INDEX="$VRAM_DEV_INDEX" VRAM_BAR="$VRAM_BAR" \
  VCPUS="$VCPUS" VMEM="$VMEM" NVME="$NVME" UEFI=enable \
  FILESYSTEM="${FILESYSTEM:-none}" \
  QEMU_PATH="$(dirname "$QEMU_BIN")/" IMAGES="$IMAGES_DIR" \
    "./$(basename "$RUNVM_SCRIPT")"
}
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then vm_run; fi
