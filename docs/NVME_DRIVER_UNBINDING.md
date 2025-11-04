# NVMe Driver Unbinding and VM Setup Guide

This guide explains how to unbind the NVMe driver from a device and configure QEMU VMs to prevent automatic driver binding, enabling direct hardware access for testing.

---

## Table of Contents

1. [Overview](#overview)
2. [Safety Warnings](#safety-warnings)
3. [Method 1: Runtime Unbinding](#method-1-runtime-unbinding)
4. [Method 2: Boot-Time Prevention](#method-2-boot-time-prevention)
5. [Method 3: QEMU VM Configuration](#method-3-qemu-vm-configuration)
6. [Method 4: VFIO Binding](#method-4-vfio-binding-recommended)
7. [Rebinding the Driver](#rebinding-the-driver)
8. [Troubleshooting](#troubleshooting)

---

## Overview

To access NVMe hardware directly (for testing or development), you need to prevent or remove the Linux kernel NVMe driver from managing the device. This allows user-space programs to interact with the device registers directly.

**Why unbind?**
- Direct access to NVMe registers (doorbells, queues)
- Testing custom NVMe implementations
- Bypassing kernel driver for performance testing
- Development and debugging

---

## Safety Warnings

⚠️ **CRITICAL WARNINGS** ⚠️

1. **Data Loss Risk**: Unbinding a device with mounted filesystems will cause data loss and system instability.
2. **System Instability**: Never unbind your boot device or system drives.
3. **No Recovery**: Improper unbinding can require a system reboot to recover.
4. **Use Test Devices**: Only use dedicated test NVMe devices or emulated devices in VMs.

**Best Practice**: Always test in a QEMU VM with an emulated NVMe device first.

---

## Method 1: Runtime Unbinding

### Step 1: Identify the Device

```bash
# List all NVMe devices
lsblk | grep nvme

# Get PCI address of device
readlink -f /sys/class/nvme/nvme0/device
# Example output: /sys/devices/pci0000:00/0000:00:04.0
```

### Step 2: Check for Mounted Filesystems

```bash
# Check if device has mounted filesystems
mount | grep nvme0

# Check for active I/O
lsof | grep nvme0
```

**STOP HERE** if any filesystems are mounted or processes are using the device!

### Step 3: Unbind the Driver

```bash
# Unbind from kernel driver
echo "0000:00:04.0" > /sys/bus/pci/drivers/nvme/unbind

# Verify unbind
ls /sys/bus/pci/drivers/nvme/
# The device should no longer appear
```

### Step 4: Verify Unbinding

```bash
# Check that /dev/nvme0 no longer exists
ls -l /dev/nvme*

# Verify no driver is bound
ls -l /sys/devices/pci0000:00/0000:00:04.0/driver
# Should show: No such file or directory
```

### Using the Test Script

The `test-nvme-local.sh` script automates this:

```bash
# Safe mode (driver stays bound, limited functionality)
sudo ./scripts/test-nvme-local.sh

# Unbind mode (full hardware access)
sudo ./scripts/test-nvme-local.sh --unbind

# Unbind without automatic rebind
sudo ./scripts/test-nvme-local.sh --unbind --no-rebind
```

---

## Method 2: Boot-Time Prevention

### Blacklist the NVMe Driver

Create a blacklist file to prevent the nvme module from loading:

```bash
# Create blacklist configuration
sudo tee /etc/modprobe.d/blacklist-nvme.conf << EOF
# Blacklist NVMe driver for direct hardware access testing
blacklist nvme
blacklist nvme_core
EOF

# Update initramfs
sudo update-initramfs -u

# Reboot
sudo reboot
```

### Kernel Command Line

Add to GRUB configuration:

```bash
# Edit GRUB configuration
sudo vim /etc/default/grub

# Add to GRUB_CMDLINE_LINUX:
GRUB_CMDLINE_LINUX="... modprobe.blacklist=nvme,nvme_core"

# Update GRUB
sudo update-grub

# Reboot
sudo reboot
```

### Verify Driver is Not Loaded

```bash
# Check if nvme module is loaded
lsmod | grep nvme
# Should return nothing

# Check if devices are visible to kernel
ls /dev/nvme*
# Should return nothing or "No such file or directory"
```

---

## Method 3: QEMU VM Configuration

### Basic QEMU Setup

Create a QEMU VM with an emulated NVMe device and blacklisted driver:

```bash
#!/bin/bash
# QEMU VM with NVMe driver blacklisted

# Create test disk image
qemu-img create -f qcow2 nvme-test.qcow2 8G

# Boot QEMU with NVMe device and driver blacklisted
qemu-system-x86_64 \
  -machine q35 \
  -cpu host \
  -enable-kvm \
  -m 4G \
  -smp 4 \
  -device nvme,drive=nvme0,serial=deadbeef,max_ioqpairs=4 \
  -drive if=none,id=nvme0,file=nvme-test.qcow2,format=qcow2 \
  -kernel /boot/vmlinuz-$(uname -r) \
  -initrd /boot/initrd.img-$(uname -r) \
  -append "root=/dev/sda1 ro console=ttyS0 modprobe.blacklist=nvme,nvme_core" \
  -nographic
```

### Advanced QEMU Setup with Passthrough

For PCI passthrough (real hardware in VM):

```bash
#!/bin/bash
# Bind device to VFIO first
echo "0000:01:00.0" > /sys/bus/pci/drivers/nvme/unbind
echo "144d 0x0001" > /sys/bus/pci/drivers/vfio-pci/new_id

# Start QEMU with PCI passthrough
qemu-system-x86_64 \
  -machine q35 \
  -cpu host \
  -enable-kvm \
  -m 4G \
  -device vfio-pci,host=01:00.0 \
  -kernel /boot/vmlinuz-$(uname -r) \
  -append "root=/dev/sda1 ro modprobe.blacklist=nvme,nvme_core" \
  ...
```

### Testing in QEMU

Once inside the VM:

```bash
# Verify NVMe device is visible via PCI but no driver
lspci | grep NVMe
# Should show the device

ls /dev/nvme*
# Should show nothing (driver not loaded)

# Access device directly
ls -l /sys/devices/pci*/*/
# Device should be visible but no driver subdirectory

# Run the test
sudo ./scripts/test-nvme-local.sh
```

---

## Method 4: VFIO Binding (Recommended)

VFIO is the safest method for userspace device access. It provides DMA protection via IOMMU.

### Step 1: Enable IOMMU

Add to kernel command line:

```bash
# For Intel CPUs
intel_iommu=on iommu=pt

# For AMD CPUs
amd_iommu=on iommu=pt
```

### Step 2: Bind to VFIO

```bash
# Get device vendor and device ID
lspci -n -s 0000:00:04.0
# Example: 00:04.0 0108: 1b36:0010

# Unbind from nvme driver
echo "0000:00:04.0" > /sys/bus/pci/drivers/nvme/unbind

# Bind to vfio-pci driver
echo "1b36 0010" > /sys/bus/pci/drivers/vfio-pci/new_id
echo "0000:00:04.0" > /sys/bus/pci/drivers/vfio-pci/bind

# Verify
ls -l /dev/vfio/
# Should show device group
```

### Step 3: Access via VFIO

Programs can now access the device through `/dev/vfio/` with DMA protection.

```bash
# Check VFIO group
ls -l /sys/bus/pci/devices/0000:00:04.0/iommu_group/devices/

# Access device
# Your program uses /dev/vfio/<group_number>
```

---

## Rebinding the Driver

### Automatic Rebind

The test script automatically rebinds by default:

```bash
# This will rebind automatically on exit
sudo ./scripts/test-nvme-local.sh --unbind
```

### Manual Rebind

```bash
# Method 1: Rescan PCI bus
echo 1 > /sys/bus/pci/rescan

# Method 2: Bind directly
echo "0000:00:04.0" > /sys/bus/pci/drivers/nvme/bind

# Method 3: Remove and rescan
echo 1 > /sys/bus/pci/devices/0000:00:04.0/remove
echo 1 > /sys/bus/pci/rescan

# Verify device is back
ls -l /dev/nvme*
```

### If Rebind Fails

```bash
# Check dmesg for errors
dmesg | tail -50

# Try manual module reload
sudo modprobe -r nvme
sudo modprobe nvme

# Last resort: reboot
sudo reboot
```

---

## Troubleshooting

### Device Still Bound After Unbind Command

```bash
# Check for errors
dmesg | grep nvme | tail

# Force unbind
echo "0000:00:04.0" > /sys/bus/pci/devices/0000:00:04.0/driver/unbind

# Try via PCI
echo 1 > /sys/bus/pci/devices/0000:00:04.0/remove
echo 1 > /sys/bus/pci/rescan
```

### Permission Denied Errors

```bash
# Ensure you're root
sudo -i

# Or grant capability
sudo setcap cap_sys_rawio=ep ./bin/axiio-tester

# Check SELinux/AppArmor
sudo setenforce 0  # For SELinux
```

### Device Not Accessible After Unbind

```bash
# Check if device removed
lspci | grep -i nvme

# Check PCI power state
cat /sys/bus/pci/devices/0000:00:04.0/power/runtime_status

# Check BAR mappings
cat /sys/bus/pci/devices/0000:00:04.0/resource
```

### System Freezes

**Prevention**:
- Never unbind boot device
- Never unbind device with mounted filesystems
- Always test in VM first

**Recovery**:
- If system freezes, hard reboot may be required
- Use watchdog timer for automatic recovery
- Use serial console for debugging

---

## Complete Example Workflow

### For QEMU VM Testing

```bash
# 1. Create VM with NVMe emulation
./scripts/test-nvme-qemu.sh --create

# 2. Boot VM (driver blacklisted automatically)
./scripts/test-nvme-qemu.sh --boot

# 3. Inside VM, run test
sudo ./scripts/test-nvme-local.sh

# 4. Test with full unbinding
sudo ./scripts/test-nvme-local.sh --unbind
```

### For Real Hardware Testing

```bash
# 1. Verify device is test device (NOT boot/system drive!)
lsblk
mount | grep nvme

# 2. Run safe test first
sudo ./scripts/test-nvme-local.sh

# 3. If safe test works, try unbind mode
sudo ./scripts/test-nvme-local.sh --unbind

# 4. Device automatically rebinds on exit
```

---

## Additional Resources

- [Linux NVMe Driver Documentation](https://www.kernel.org/doc/html/latest/driver-api/nvme.html)
- [VFIO User Guide](https://www.kernel.org/doc/Documentation/vfio.txt)
- [PCI Sysfs Documentation](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-bus-pci)
- [QEMU NVMe Emulation](https://qemu.readthedocs.io/en/latest/system/devices/nvme.html)

---

## Summary

| Method | Safety | Complexity | Use Case |
|--------|--------|------------|----------|
| Runtime Unbind | ⚠️ Medium | Low | Quick testing |
| Boot Blacklist | ⚠️ Medium | Medium | Dedicated test system |
| QEMU VM | ✅ High | Medium | Development & testing |
| VFIO | ✅ High | High | Production userspace drivers |

**Recommendation**: Start with QEMU VM testing, then progress to VFIO for real hardware testing.

