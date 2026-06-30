#!/usr/bin/env bash
set -Eeuo pipefail

# Refuse any NVMe whose namespace backs a mounted host block device (this is what
# protects your OS drive on any host). Requires lsblk: if it is missing or errors
# we cannot verify the device is unmounted, so we fail closed (refuse) rather than
# pass through a possibly-mounted OS disk.
guard_nvme_bdf() {
  local STAGE=guard
  require_var NVME_BDF
  local bdf="$NVME_BDF"
  command -v lsblk >/dev/null 2>&1 || \
    die "lsblk not found; cannot verify NVME_BDF=$bdf is not a mounted OS disk. Refusing (install util-linux)."
  local blkpath="/sys/bus/pci/devices/$bdf/nvme"
  if [ -d "$blkpath" ]; then
    local dev mp
    for dev in "$blkpath"/nvme*/nvme*n*; do
      [ -e "$dev" ] || continue
      # Fail closed: if lsblk itself errors we treat the device as unverifiable,
      # not as "no mountpoint".
      mp="$(lsblk -no MOUNTPOINT "/dev/$(basename "$dev")")" || \
        die "lsblk failed for $dev; cannot verify NVME_BDF=$bdf is unmounted. Refusing."
      mp="$(printf '%s\n' "$mp" | grep -v '^$' || true)"
      [ -n "$mp" ] && die "NVME_BDF=$bdf backs a MOUNTED device ($dev -> $mp). Refusing."
    done
  fi
  log guard "NVMe BDF $bdf OK (no mounted block device)"
}

guard_ssh_port() {
  local STAGE=guard
  if ss -tlnH "sport = :$SSH_PORT" 2>/dev/null | grep -q .; then
    die "SSH_PORT=$SSH_PORT already in use on this host/container."
  fi
  log guard "SSH port $SSH_PORT OK (free)"
}

guard_devices() {
  # shellcheck disable=SC2034  # STAGE is read cross-file by common.sh log()/die()
  local STAGE=guard
  [ -c /dev/kvm ] || die "/dev/kvm missing. docker run needs: --device /dev/kvm"
  { [ -r /dev/kvm ] && [ -w /dev/kvm ]; } || die "/dev/kvm not rw. Add --group-add kvm."
  [ -c /dev/vfio/vfio ] || die "/dev/vfio/vfio missing. docker run needs: --device /dev/vfio/vfio"
  local found=0 n
  for n in /dev/vfio/[0-9]*; do [ -e "$n" ] && found=1; done
  [ "$found" = 1 ] || die "No numbered /dev/vfio/<N> nodes. docker run needs e.g. --device /dev/vfio/22 --device /dev/vfio/27 --device /dev/vfio/28"
  log guard "device nodes present (/dev/kvm, /dev/vfio/*)"
}

guard_all() { guard_nvme_bdf; guard_ssh_port; guard_devices; }
