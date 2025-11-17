# NVMe Driver Unbinding Guide

This document explains how to unbind NVMe drivers for direct GPU access testing with rocm-axiio.

## Overview

For GPU-direct NVMe testing, you may need to unbind the default NVMe driver to allow direct device access. This guide covers three scenarios:

1. **Runtime Unbinding** - Temporarily unbind for testing
2. **QEMU/Emulated NVMe** - Using QEMU for development and testing
3. **VFIO Binding** - For advanced GPU-direct operations

## Runtime Unbinding

### Identify NVMe Device

```bash
# List all NVMe devices
lspci -nn | grep -i nvme

# Example output:
# 01:00.0 Non-Volatile memory controller [0108]: Samsung Electronics Co Ltd NVMe SSD Controller [144d:a808]
```

### Unbind Kernel Driver

```bash
# Get the PCI address (e.g., 0000:01:00.0)
PCI_ADDR="0000:01:00.0"

# Unbind from nvme driver
echo $PCI_ADDR | sudo tee /sys/bus/pci/drivers/nvme/unbind

# Verify it's unbound
lspci -v -s $PCI_ADDR | grep "Kernel driver"
```

### Rebind Driver

```bash
# Rebind when done testing
echo $PCI_ADDR | sudo tee /sys/bus/pci/drivers/nvme/bind

# Verify block devices are back
lsblk
```

## QEMU Emulated NVMe

For development and testing without physical NVMe hardware:

### Setup QEMU with NVMe

```bash
# Create a disk image for emulated NVMe
qemu-img create -f raw nvme.img 1G

# Launch QEMU with emulated NVMe device
qemu-system-x86_64 \
  -enable-kvm \
  -m 4G \
  -smp 4 \
  -drive file=nvme.img,if=none,id=nvm \
  -device nvme,serial=deadbeef,drive=nvm \
  -nographic
```

### QEMU Benefits

- **No hardware required**: Test NVMe operations without physical device
- **Safe testing**: No risk of data loss on real drives
- **Easy debugging**: QEMU tracing and debugging features
- **CI/CD friendly**: Automated testing in GitHub Actions

### QEMU Tracing

Enable NVMe tracing to debug operations:

```bash
qemu-system-x86_64 \
  -trace 'nvme_*' \
  -D /tmp/qemu-nvme-trace.log \
  [other options...]
```

## VFIO Binding

For advanced GPU-direct access with IOMMU isolation:

### Prerequisites

```bash
# Enable IOMMU in kernel parameters (add to GRUB)
# Intel: intel_iommu=on iommu=pt
# AMD: amd_iommu=on iommu=pt

# Load VFIO modules
sudo modprobe vfio-pci
```

### Bind to VFIO

```bash
# Get device vendor:device IDs
PCI_ADDR="0000:01:00.0"
VENDOR_DEVICE=$(lspci -n -s $PCI_ADDR | awk '{print $3}')

# Unbind from nvme driver
echo $PCI_ADDR | sudo tee /sys/bus/pci/drivers/nvme/unbind

# Bind to vfio-pci
echo $VENDOR_DEVICE | sudo tee /sys/bus/pci/drivers/vfio-pci/new_id
echo $PCI_ADDR | sudo tee /sys/bus/pci/drivers/vfio-pci/bind
```

### Access via VFIO

```bash
# VFIO device will be available at:
ls -l /dev/vfio/

# Use with rocm-axiio in real hardware mode
./bin/axiio-tester --endpoint nvme-ep --real-hardware \
  --pci-address $PCI_ADDR
```

## Testing with rocm-axiio

### Emulated Mode (Default)

```bash
# No driver unbinding needed
./bin/axiio-tester --endpoint nvme-ep
```

### Real Hardware Mode

```bash
# Requires driver unbinding or VFIO
./bin/axiio-tester --endpoint nvme-ep --real-hardware \
  --pci-address 0000:01:00.0 \
  --nvme-doorbell 0xdeadbeef \
  --nvme-cap 0xcafe1234
```

### GPU-Direct Mode

```bash
# Requires kernel module for DMA buffer allocation
./bin/axiio-tester --endpoint nvme-ep --real-hardware \
  --gpu-direct \
  --pci-address 0000:01:00.0
```

## Safety Considerations

### ⚠️ Warnings

1. **Data Loss Risk**: Unbinding may cause data loss on mounted filesystems
2. **System Instability**: Don't unbind boot drive
3. **Backup First**: Always backup important data before testing
4. **Test in VM**: Use QEMU for initial development

### Safe Practice

```bash
# 1. Verify device is not in use
lsblk | grep nvme
df -h | grep nvme

# 2. Unmount any filesystems
sudo umount /dev/nvme0n1p1

# 3. Then unbind
echo "0000:01:00.0" | sudo tee /sys/bus/pci/drivers/nvme/unbind
```

## Troubleshooting

### Can't Unbind

```bash
# Check if device is in use
lsof | grep nvme

# Check for mounted filesystems
mount | grep nvme

# Force unbind (dangerous!)
echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/remove
```

### Permission Denied

```bash
# May need root or specific permissions
sudo -i
# or add user to disk group
sudo usermod -a -G disk $USER
```

### Device Not Found After Reboot

```bash
# Rescan PCI bus
echo 1 | sudo tee /sys/bus/pci/rescan
```

## References

- [Linux NVMe Driver Documentation](https://www.kernel.org/doc/html/latest/driver-api/nvme.html)
- [VFIO Documentation](https://www.kernel.org/doc/html/latest/driver-api/vfio.html)
- [QEMU NVMe Documentation](https://qemu.readthedocs.io/en/latest/specs/nvme.html)
- [rocm-axiio Real Hardware Testing](NVME_HARDWARE_TESTING.md)

## Quick Reference Scripts

See `scripts/` directory for automation:

- `scripts/bind-nvme-to-axiio.sh` - Automated binding helper
- `scripts/test-nvme-qemu.sh` - QEMU testing
- `scripts/test-nvme-local.sh` - Local emulated testing
- `scripts/test-nvme-io.sh` - I/O performance testing

