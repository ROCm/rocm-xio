# Trace Verification Usage Guide

This guide shows how to use the integrated trace verification feature in
`axiio-tester` to confirm doorbell rings are working in QEMU.

## Quick Start

### 1. Launch QEMU with Tracing (On Host)

```bash
cd /home/stebates/Projects/qemu-minimal/qemu

VM_NAME=rocm-axiio \
NVME=2 \
NVME_TRACE=doorbell \
NVME_TRACE_FILE=/tmp/rocm-axiio-nvme-trace.log \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
./run-vm
```

**Important:**
- QEMU 10.1.2+ is located at `/opt/qemu-10.1.2-amd-p2p/`
- VM images are in `qemu-minimal/qemu/images/`
- The `run-vm` script automatically uses the correct QEMU version

### 2. Run Tests with Trace Verification (Inside VM)

```bash
# SSH into VM
ssh -p 2222 ubuntu@localhost

# Mount shared folder (if not already mounted)
sudo mount -t 9p -o trans=virtio,version=9p2000.L hostfs /mnt/rocm-axiio

# Navigate to project
cd /mnt/rocm-axiio

# Build if needed
make clean && make all

# Run test with trace verification
sudo ./bin/axiio-tester \
  --nvme-device /dev/nvme0 \
  --cpu-only \
  -n 100 \
  --verbose \
  --verify-trace \
  --trace-file /tmp/rocm-axiio-nvme-trace.log
```

### 3. View Results

After the test completes, `axiio-tester` will automatically:

1. Parse the QEMU trace log file
2. Extract doorbell operations (SQ and CQ writes)
3. Verify sequential progression
4. Check for proper wrap-around behavior
5. Display a comprehensive verification report

## Example Output

```
========================================
  Verifying QEMU Trace Log
========================================

Trace file: /tmp/rocm-axiio-nvme-trace.log

========================================
  NVMe Doorbell Trace Verification
========================================

QEMU Configuration:
-------------------
QEMU Path: /opt/qemu-10.1.2-amd-p2p/bin/qemu-system-x86_64
✅ QEMU Version: OK (10.1.0+)
Required: QEMU 10.1.0+ (for libvfio-user)

DOORBELL OPERATIONS CAPTURED:
------------------------------
✅ Submission Queue (SQ) doorbell writes: 446
✅ Completion Queue (CQ) doorbell writes: 443
✅ Total doorbell operations: 889

MMIO ADDRESSES CONFIRMED:
-------------------------
✅ Admin SQ doorbell: 0x1000 (BAR0 + 0x1000)
✅ Admin CQ doorbell: 0x1004 (BAR0 + 0x1004)

OPERATION SEQUENCE:
-------------------
SQ tail progression: 12→13→14→15→16→17→...→30→31→0→1
✅ Sequential tail progression
✅ Proper wrap-around at queue boundary

VALIDATION RESULTS:
------------------
✅ SQ doorbell writes detected
✅ CQ doorbell writes detected
✅ Sequential progression verified
✅ Wrap-around behavior verified
✅ No anomalies detected

CONFIDENCE LEVEL: 100%
STATUS: ✅ VALIDATED AND WORKING

The trace definitively proves doorbell operations
are reaching the NVMe controller!
```

## Command-Line Options

### `--verify-trace`

Enable automatic trace verification after test completes. The verification
runs automatically at the end of the test and displays results.

**Example:**
```bash
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --verify-trace
```

### `--trace-file PATH`

Specify the path to the QEMU trace log file. This should match the
`NVME_TRACE_FILE` environment variable used when launching QEMU.

**Default:** `/tmp/rocm-axiio-nvme-trace.log`

**Example:**
```bash
sudo ./bin/axiio-tester \
  --nvme-device /dev/nvme0 \
  --verify-trace \
  --trace-file /tmp/my-custom-trace.log
```

## Troubleshooting

### Trace File Not Found

**Error:**
```
❌ Trace file not found
   Trace file not found: /tmp/rocm-axiio-nvme-trace.log
```

**Solution:**
1. Ensure QEMU was launched with `NVME_TRACE=doorbell`
2. Verify `NVME_TRACE_FILE` path matches `--trace-file` argument
3. Check file permissions (trace file should be readable)

### No Doorbell Operations Found

**Error:**
```
⚠️  WARNING: No doorbell operations found in trace file!
   Make sure QEMU was launched with NVME_TRACE=doorbell
```

**Solution:**
1. Verify QEMU tracing is enabled: `NVME_TRACE=doorbell`
2. Ensure tests actually write to doorbells (use `--verbose` to see activity)
3. Check trace file is being written (watch with `tail -f` on host)

### QEMU Version Warning

**Warning:**
```
⚠️  QEMU Version: Unknown/Too Old
```

**Solution:**
- Ensure QEMU 10.1.0+ is installed at `/opt/qemu-10.1.2-amd-p2p/`
- The `qemu-minimal` scripts should handle this automatically
- Verify QEMU path: `ls -l /opt/qemu-10.1.2-amd-p2p/bin/qemu-system-x86_64`

## Integration with qemu-minimal

The trace verification is designed to work seamlessly with the `qemu-minimal`
infrastructure:

- **VM Images:** Stored in `qemu-minimal/qemu/images/`
- **QEMU Binary:** Automatically uses `/opt/qemu-10.1.2-amd-p2p/bin/qemu-system-x86_64`
- **Trace Files:** Written to host filesystem (accessible from VM via shared folder)
- **Shared Folder:** Project code accessible at `/mnt/rocm-axiio` inside VM

## Advanced Usage

### Custom Trace File Location

If you want to use a different trace file location:

**On Host:**
```bash
VM_NAME=rocm-axiio \
NVME=2 \
NVME_TRACE=doorbell \
NVME_TRACE_FILE=/home/stebates/traces/test-run-$(date +%s).log \
./run-vm
```

**Inside VM:**
```bash
sudo ./bin/axiio-tester \
  --nvme-device /dev/nvme0 \
  --verify-trace \
  --trace-file /mnt/host/traces/test-run-*.log
```

### Real-Time Monitoring

Monitor trace file in real-time from host while test runs:

**Terminal 1 (Host):**
```bash
tail -f /tmp/rocm-axiio-nvme-trace.log | grep doorbell
```

**Terminal 2 (VM):**
```bash
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --verify-trace -n 1000
```

## Summary

The trace verification feature provides:

✅ **Automatic verification** - No manual trace analysis needed  
✅ **Comprehensive reporting** - Detailed doorbell operation statistics  
✅ **QEMU version checking** - Ensures correct QEMU version (10.1.0+)  
✅ **Integration with qemu-minimal** - Works seamlessly with existing infrastructure  
✅ **Clear error messages** - Helpful troubleshooting information  

This makes it easy to confirm that doorbell rings are working correctly in
your QEMU emulated NVMe setup!

