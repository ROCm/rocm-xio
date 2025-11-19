# Emulated NVMe Testing Guide

This guide explains how to test with your **emulated NVMe device** 
(`/dev/nvme0` in QEMU) using two different approaches.

## The Key Difference

When testing emulated NVMe in QEMU with IOVA mapping support, you have
two options that handle the device binding differently:

### Option 1: Standard Driver (Device Remains Accessible)

Uses the normal `nvme` driver, device stays at `/dev/nvme0` and 
`/dev/nvme0n1`:

```bash
./build-and-test.sh --test emulated-nvme --nvme /dev/nvme0 \
    --iterations 100 --verbose
```

**When `/dev/nvme0n1` exists**: Use this method

### Option 2: Kernel Module with IOVA (Device Bound to nvme_axiio)

Binds device to `nvme_axiio` driver, `/dev/nvme0` and `/dev/nvme0n1` 
**disappear**:

```bash
# First, bind the device (only once)
sudo insmod kernel-module/nvme_axiio.ko
sudo ./scripts/bind-nvme-to-axiio.sh /dev/nvme0

# Then test (no --nvme-device needed!)
./build-and-test.sh --test emulated-kernel --iterations 100 --verbose
```

**When `/dev/nvme0n1` is gone**: Use this method

## Why Does /dev/nvme0n1 Disappear?

When you bind `/dev/nvme0` to the `nvme_axiio` kernel module:

1. Device is **unbound** from standard `nvme` driver
2. Standard driver creates `/dev/nvme0` and `/dev/nvme0n1`
3. When unbound, these devices **disappear**
4. Device is **bound** to `nvme_axiio` driver
5. New device `/dev/nvme-axiio` is created for axiio access

## Complete Workflows

### Workflow 1: Testing with Standard Driver

```bash
# Ensure device is bound to standard nvme driver
sudo ./scripts/bind-nvme-to-axiio.sh --unbind /dev/nvme0

# Verify devices exist
ls -l /dev/nvme0*
# Should see: /dev/nvme0 /dev/nvme0n1 /dev/nvme0n1p*

# Test
export HSA_FORCE_FINE_GRAIN_PCIE=1
./build-and-test.sh --test emulated-nvme --nvme /dev/nvme0 \
    --iterations 100 --verbose
```

**Advantages**:
- Device accessible normally
- Can mount filesystems
- Simpler setup

**Disadvantages**:
- No IOVA vendor command support
- No kernel module GPU-direct features

### Workflow 2: Testing with Kernel Module (IOVA)

```bash
# Load kernel module
cd /home/stebates/Projects/rocm-axiio
sudo insmod kernel-module/nvme_axiio.ko

# Verify module loaded
lsmod | grep nvme_axiio

# Bind device to axiio driver
sudo ./scripts/bind-nvme-to-axiio.sh /dev/nvme0

# Verify devices
ls -l /dev/nvme-axiio  # Should exist
ls -l /dev/nvme0n1     # Should NOT exist (that's expected!)

# Test (no --nvme-device argument!)
export HSA_FORCE_FINE_GRAIN_PCIE=1
./build-and-test.sh --test emulated-kernel --iterations 100 --verbose

# Or manually:
sudo ./bin/axiio-tester \
  --use-kernel-module \
  --nvme-queue-id 63 \
  -n 100 \
  --verbose
```

**Advantages**:
- Uses IOVA vendor command (0xC0) to QEMU
- GPU-direct doorbell access via HSA memory locking
- True peer-to-peer I/O testing
- Matches production use case

**Disadvantages**:
- Device not accessible to normal I/O
- Can't mount filesystems while bound
- Requires kernel module

### Switching Between Modes

```bash
# Unbind from axiio, return to standard driver
sudo ./scripts/bind-nvme-to-axiio.sh --unbind /dev/nvme0

# Verify back to normal
ls -l /dev/nvme0*  # Should see /dev/nvme0n1 again

# Rebind to axiio when needed
sudo ./scripts/bind-nvme-to-axiio.sh /dev/nvme0
```

## Quick Reference Commands

### Check Current State

```bash
# List all NVMe devices and their drivers
sudo ./scripts/bind-nvme-to-axiio.sh --list

# Check which driver owns the device
ls -l /sys/class/nvme/nvme0/device/driver
# Will show either "nvme" or "nvme_axiio"

# Check for block devices
ls -l /dev/nvme0*

# Check for axiio device
ls -l /dev/nvme-axiio
```

### Standard Driver Mode

```bash
# /dev/nvme0n1 EXISTS - use this command
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester \
  --nvme-device /dev/nvme0 \
  -n 100 \
  --verbose
```

### Kernel Module Mode

```bash
# /dev/nvme0n1 GONE - use this command
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester \
  --use-kernel-module \
  --nvme-queue-id 63 \
  -n 100 \
  --verbose
```

## QEMU Configuration Required

For kernel module mode with IOVA to work, your QEMU must be configured
with P2P support:

```bash
# Your QEMU command should include:
-device nvme,serial=deadbeef,drive=nvm,p2p-gpu=vfio-pci:XX:XX.X
```

Where `XX:XX.X` is your GPU's PCI address.

The P2P property enables:
- Vendor-specific admin command 0xC0
- IOVA address allocation
- VFIO IOMMU mapping for GPU access

## Troubleshooting

### /dev/nvme0n1 disappeared but I need it back

```bash
sudo ./scripts/bind-nvme-to-axiio.sh --unbind /dev/nvme0
sleep 2
ls -l /dev/nvme0*  # Should reappear
```

### Can't find /dev/nvme-axiio

```bash
# Check if module is loaded
lsmod | grep nvme_axiio

# Load if needed
sudo insmod kernel-module/nvme_axiio.ko

# Check if device is bound
ls -l /sys/bus/pci/drivers/nvme_axiio/
# Should show your NVMe device's PCI address
```

### Device already in use

```bash
# Check what's using it
lsof /dev/nvme0*

# Unmount any filesystems first
sudo umount /dev/nvme0n1p*

# Then bind
sudo ./scripts/bind-nvme-to-axiio.sh /dev/nvme0
```

### Testing fails with "device not found"

If using kernel module mode, **don't specify `--nvme-device`**:

```bash
# WRONG (will fail):
sudo ./bin/axiio-tester --use-kernel-module --nvme-device /dev/nvme0

# CORRECT (device already known to kernel module):
sudo ./bin/axiio-tester --use-kernel-module --nvme-queue-id 63
```

## Summary

**Two modes, two different commands:**

| Mode | Device Files | Command |
|------|--------------|---------|
| **Standard Driver** | `/dev/nvme0n1` exists | `--nvme-device /dev/nvme0` |
| **Kernel Module** | `/dev/nvme0n1` gone | `--use-kernel-module` (no device arg) |

**Choose based on what you see:**

```bash
ls -l /dev/nvme0n1
```

- **File exists**: Use `--test emulated-nvme --nvme /dev/nvme0`
- **File not found**: Use `--test emulated-kernel` (no nvme arg)

The kernel module mode is what you want for testing IOVA vendor-specific 
commands with QEMU!





