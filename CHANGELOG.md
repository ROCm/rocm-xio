# Changelog for rocm-xio

## UNRELEASED - rocm-xio 0.0.1

### Added

- `tools/vfu-doorbell`: a vfio-user doorbell test rig. A ringee device whose
  BAR carries configurable doorbell overlays (index, keyed, event) with readable
  per-key counters, a ringer device that writes programmed patterns to any guest
  physical address through `vfu_mmio_write`, and a guest tool that configures
  them and checks what arrived. It also reproduces the single-socket deadlock
  between a guest MMIO read and a server-initiated `DMA_WRITE`.
  An `event` region can carry a match value, so only that value rings, as for
  QEMU's pci-testdev doorbell. `ring` picks who writes (`--ringer`, the ringer
  device or the CPU) and what is rung (`--ringee`, the ringee, QEMU's
  pci-testdev or NVMe, or any PCI device), and `ring --preset` runs a whole
  named scenario, listed with its explicit command by `presets`.

### Changed

### Removed

### Limitations

### Known issues
