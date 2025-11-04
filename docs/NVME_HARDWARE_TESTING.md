# NVMe Hardware Testing Guide

This guide explains how to test `axiio-tester` with real NVMe hardware using physical memory mapping.

## Overview

The `axiio-tester` now supports testing with real NVMe SSD hardware by directly accessing physical memory addresses of NVMe queues and doorbells. This allows for realistic testing of NVMe command submission and completion without emulation.

## Prerequisites

- Linux system with NVMe SSD (physical or QEMU-emulated)
- Root privileges or `CAP_SYS_RAWIO` capability
- Access to `/dev/mem` (may require `iomem=relaxed` kernel parameter)
- Built `axiio-tester` binary

## Architecture

### Memory Mapping

The tester uses `/dev/mem` to map physical NVMe queue memory into user space:

```
Physical Address → mmap() → Virtual Address → GPU Access
```

### Required Addresses

1. **Doorbell Register**: NVMe submission queue tail doorbell
2. **Submission Queue (SQ)**: Physical base address of SQ
3. **Completion Queue (CQ)**: Physical base address of CQ

## Finding NVMe Addresses

### Method 1: Using lspci

```bash
# Find NVMe controller
sudo lspci | grep "Non-Volatile memory controller"

# Get detailed info (replace XX:YY.Z with your device)
sudo lspci -vvv -s XX:YY.Z | grep -A 5 "Memory at"
```

Example output:
```
Memory at feb00000 (64-bit, non-prefetchable) [size=16K]
```

### Method 2: Using sysfs

```bash
# Find NVMe device
ls /sys/class/nvme/

# Check resources
cat /sys/class/nvme/nvme0/device/resource
```

### Method 3: Using Discovery Script

```bash
sudo ./scripts/discover-nvme-addresses.sh
```

## NVMe Register Offsets

Standard NVMe register offsets (from BAR0):

| Register | Offset | Description |
|----------|--------|-------------|
| CAP | 0x0000 | Controller Capabilities |
| VS | 0x0008 | Version |
| CC | 0x0014 | Controller Configuration |
| CSTS | 0x001C | Controller Status |
| AQA | 0x0024 | Admin Queue Attributes |
| ASQ | 0x0028 | Admin Submission Queue Base |
| ACQ | 0x0030 | Admin Completion Queue Base |
| Doorbells | 0x1000 | Doorbell registers start |

### Doorbell Calculation

```
SQ Doorbell Address = BAR0 + 0x1000 + (2 * queue_id * doorbell_stride)
CQ Doorbell Address = BAR0 + 0x1000 + ((2 * queue_id + 1) * doorbell_stride)
```

Default doorbell stride is 4 bytes (configurable via CAP register).

## Command-Line Options

New options for real hardware testing:

```bash
--real-hardware              Enable real NVMe hardware mode
--nvme-doorbell <addr>      Physical address of doorbell register (hex)
--nvme-sq-base <addr>       Physical base address of submission queue (hex)
--nvme-cq-base <addr>       Physical base address of completion queue (hex)
--nvme-sq-size <bytes>      Size of submission queue in bytes
--nvme-cq-size <bytes>      Size of completion queue in bytes
```

## Example Usage

### Basic Test (Emulated Mode)

```bash
./bin/axiio-tester --endpoint nvme-ep --iterations 10
```

### Real Hardware Test

```bash
sudo ./bin/axiio-tester \
  --endpoint nvme-ep \
  --real-hardware \
  --nvme-doorbell 0xfeb01000 \
  --nvme-sq-base 0xfeb10000 \
  --nvme-cq-base 0xfeb20000 \
  --nvme-sq-size 4096 \
  --nvme-cq-size 4096 \
  --iterations 10 \
  --verbose
```

### Queue Size Calculation

```
Queue Size (bytes) = Queue Depth × Entry Size
```

For NVMe:
- Submission Queue Entry (SQE): 64 bytes
- Completion Queue Entry (CQE): 16 bytes

Examples:
```
Queue Depth 16: SQ = 16 × 64 = 1024 bytes, CQ = 16 × 16 = 256 bytes
Queue Depth 64: SQ = 64 × 64 = 4096 bytes, CQ = 64 × 16 = 1024 bytes
```

## Testing with QEMU

### Step 1: Create NVMe Image

```bash
qemu-img create -f raw nvme-test.img 1G
```

### Step 2: Launch QEMU VM

```bash
qemu-system-x86_64 \
  -enable-kvm \
  -cpu host \
  -m 4G \
  -smp 4 \
  -drive file=ubuntu.qcow2,if=virtio \
  -drive file=nvme-test.img,if=none,id=nvme0 \
  -device nvme,serial=deadbeef,drive=nvme0 \
  -net nic -net user \
  -display none \
  -serial mon:stdio
```

### Step 3: Inside VM - Find Addresses

```bash
# Find NVMe device
lspci | grep NVMe

# Get BAR address
sudo lspci -vvv -s 00:04.0 | grep "Memory at"

# Read NVMe registers
sudo ./scripts/discover-nvme-addresses.sh
```

### Step 4: Run Test

Use discovered addresses with `axiio-tester` as shown above.

## Testing Script

Use the provided automated script:

```bash
sudo ./scripts/test-nvme-qemu.sh
```

This script:
1. Creates an NVMe test image
2. Provides instructions for address discovery
3. Generates helper scripts
4. Shows example commands

## Safety and Warnings

### ⚠️ CRITICAL WARNINGS

1. **System Crashes**: Incorrect addresses can crash the system
2. **Data Loss**: Writing to wrong memory can corrupt data
3. **Hardware Damage**: Improper access patterns may damage hardware
4. **Test Environment**: Always test in a VM first

### Safety Checklist

- ✅ Test in QEMU VM before real hardware
- ✅ Verify all addresses are correct
- ✅ Ensure queues are not actively used by OS
- ✅ Have system backups
- ✅ Use on test systems, not production
- ✅ Monitor system logs (`dmesg`)

### Enabling /dev/mem Access

Some systems restrict `/dev/mem` access. To enable:

```bash
# Temporary (until reboot)
echo "iomem=relaxed" | sudo tee /proc/cmdline

# Permanent (add to GRUB config)
# Edit /etc/default/grub:
GRUB_CMDLINE_LINUX="iomem=relaxed"

# Update GRUB
sudo update-grub
sudo reboot
```

## Troubleshooting

### Error: "Failed to open /dev/mem"

**Cause**: Insufficient privileges

**Solution**: Run with `sudo` or set `CAP_SYS_RAWIO` capability:
```bash
sudo setcap cap_sys_rawio+ep ./bin/axiio-tester
```

### Error: "Failed to mmap physical address"

**Cause**: Invalid address or restricted memory region

**Solution**:
1. Verify address is correct (`lspci -vvv`)
2. Check kernel restrictions (`dmesg | grep mem`)
3. Add `iomem=relaxed` kernel parameter

### System Hangs or Crashes

**Cause**: Writing to wrong memory location

**Solution**:
1. Verify all addresses triple-check
2. Test in QEMU first
3. Use smaller iteration counts initially
4. Monitor with `dmesg -w` in another terminal

### NVMe Timeouts

**Cause**: Queue addresses don't match actual hardware configuration

**Solution**:
1. Read ASQ/ACQ registers directly
2. Verify queue sizes match controller configuration
3. Ensure doorbell stride is correct

## Advanced Topics

### Multiple Queue Pairs

To test I/O queues (not just admin queues):

```bash
# I/O Queue 1 doorbells (stride = 4 bytes)
SQ1_DB = BAR0 + 0x1000 + (2 * 1 * 4) = BAR0 + 0x1008
CQ1_DB = BAR0 + 0x1000 + (3 * 4)     = BAR0 + 0x100C
```

### Reading NVMe Registers

```bash
# Map BAR0
sudo dd if=/dev/mem bs=4 count=1 skip=$((0xfeb00000/4)) | hexdump -C

# Or use devmem2 tool
sudo apt-get install devmem2
sudo devmem2 0xfeb00028  # Read ASQ register
```

### GPU Direct Access

The tester maps physical memory to both CPU and GPU address spaces,
allowing the GPU kernel to directly read/write NVMe queues without
CPU involvement.

## References

- [NVMe Specification](https://nvmexpress.org/specifications/)
- [Linux NVMe Driver Documentation](https://www.kernel.org/doc/html/latest/block/nvme.html)
- [QEMU NVMe Device Documentation](https://qemu.readthedocs.io/en/latest/system/devices/nvme.html)

## Examples

### Example 1: Admin Queue Testing

```bash
# Get admin queue addresses
ASQ=$(sudo cat /sys/class/nvme/nvme0/device/asq)
ACQ=$(sudo cat /sys/class/nvme/nvme0/device/acq)
DB=$((BAR0 + 0x1000))

sudo ./bin/axiio-tester \
  --endpoint nvme-ep \
  --real-hardware \
  --nvme-doorbell $DB \
  --nvme-sq-base $ASQ \
  --nvme-cq-base $ACQ \
  --nvme-sq-size 4096 \
  --nvme-cq-size 4096 \
  --iterations 5
```

### Example 2: Monitoring During Test

```bash
# Terminal 1: Watch dmesg
watch -n 1 'dmesg | tail -20'

# Terminal 2: Run test
sudo ./bin/axiio-tester --endpoint nvme-ep --real-hardware ...
```

### Example 3: QEMU with Debug

```bash
qemu-system-x86_64 \
  -enable-kvm \
  -device nvme,serial=test,drive=nvme0 \
  -drive file=nvme.img,if=none,id=nvme0 \
  -d guest_errors \
  -D qemu-debug.log
```

## Conclusion

Real NVMe hardware testing provides valuable insights into GPU-NVMe
interactions and validates the endpoint implementation against actual
hardware behavior. Always prioritize safety and test thoroughly in
controlled environments.

## Contact

For issues or questions, please file a GitHub issue with:
- Hardware configuration
- NVMe device model
- Complete command line used
- Error messages and `dmesg` output

