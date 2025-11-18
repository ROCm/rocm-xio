# Verifying Doorbell Rings to Emulated NVMe SSDs in QEMU

This document explains how doorbell rings to emulated NVMe SSDs are
confirmed and verified when using QEMU for testing.

## Overview

Doorbell rings are verified through **QEMU's built-in NVMe tracing
capability**, which captures all MMIO (Memory-Mapped I/O) writes to
doorbell registers. This provides definitive proof that doorbell
operations are reaching the NVMe controller.

## Method 1: QEMU Trace Logging (Primary Method)

### Step 1: Enable Tracing When Launching QEMU

When using `qemu-minimal` infrastructure with QEMU 10.1.2+ (located at
`/opt/qemu-10.1.2-amd-p2p/`), enable doorbell tracing:

```bash
cd /home/stebates/Projects/qemu-minimal/qemu

VM_NAME=rocm-axiio \
NVME=2 \
NVME_TRACE=doorbell \
NVME_TRACE_FILE=/tmp/rocm-axiio-nvme-trace.log \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
./run-vm
```

**Key Environment Variables:**
- `NVME_TRACE=doorbell` - Enables doorbell-specific tracing
- `NVME_TRACE_FILE=/tmp/...` - Specifies trace output file location
- VM images are stored in `qemu-minimal/qemu/images/` directory

**QEMU Requirements:**
- QEMU version 10.1.0+ (required for libvfio-user support)
- Primary installation: `/opt/qemu-10.1.2-amd-p2p/`
- The `qemu-minimal` scripts automatically use the correct QEMU version

### Step 2: Run Tests Inside VM with Trace Verification

Inside the VM, run your NVMe tests with trace verification enabled:

```bash
# Inside VM
cd /mnt/rocm-axiio
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 \
  --verbose --verify-trace --trace-file /tmp/rocm-axiio-nvme-trace.log
```

**New Command-Line Options:**
- `--verify-trace` - Enable automatic trace verification after test completes
- `--trace-file PATH` - Specify trace file path (default: `/tmp/rocm-axiio-nvme-trace.log`)

The trace verification will automatically run after your test completes and
report doorbell operation statistics.

### Step 3: Analyze Trace File (On Host)

On the host machine (in another terminal), check the trace file:

```bash
# Watch trace in real-time
tail -f /tmp/rocm-axiio-nvme-trace.log

# Filter for doorbell operations
cat /tmp/rocm-axiio-nvme-trace.log | grep doorbell

# Count doorbell operations
cat /tmp/rocm-axiio-nvme-trace.log | grep doorbell | wc -l
```

### Expected Trace Output

QEMU outputs trace lines in this format:

```
pci_nvme_mmio_doorbell_sq sq_tail=1 dbl_addr=0x1000
pci_nvme_mmio_doorbell_cq cq_head=1 dbl_addr=0x1004
pci_nvme_mmio_doorbell_sq sq_tail=2 dbl_addr=0x1000
pci_nvme_mmio_doorbell_cq cq_head=2 dbl_addr=0x1004
```

**What Each Field Means:**
- `pci_nvme_mmio_doorbell_sq` - Submission Queue doorbell write
- `pci_nvme_mmio_doorbell_cq` - Completion Queue doorbell write
- `sq_tail=X` - New tail pointer value written
- `cq_head=X` - New head pointer value written
- `dbl_addr=0xXXXX` - MMIO address (BAR0 offset)

## Method 2: Direct QEMU Trace Command

If not using `qemu-minimal`, enable tracing directly in QEMU command:

```bash
qemu-system-x86_64 \
  -trace enable=pci_nvme* \
  -D /tmp/nvme-trace.log \
  [other QEMU options...]
```

Then filter for doorbell operations:

```bash
cat /tmp/nvme-trace.log | grep "pci_nvme_mmio_doorbell"
```

## Verification Checklist

When analyzing trace output, verify:

### ✅ Sequential Tail Progression
- SQ doorbell values should increment sequentially: `sq_tail=12`, `sq_tail=13`, `sq_tail=14`...
- Proper wrap-around at queue boundary: `sq_tail=30`, `sq_tail=31`, `sq_tail=0`, `sq_tail=1`

### ✅ Sequential Head Progression
- CQ doorbell values should increment: `cq_head=9`, `cq_head=11`, `cq_head=12`...
- Note: Head may skip values if multiple completions arrive

### ✅ Correct MMIO Addresses
- Admin SQ doorbell: `dbl_addr=0x1000` (BAR0 + 0x1000)
- Admin CQ doorbell: `dbl_addr=0x1004` (BAR0 + 0x1004)
- I/O queue doorbells: Higher addresses based on queue ID

### ✅ Write Size
- All writes should be 4 bytes (32-bit) per NVMe specification

### ✅ No Gaps or Errors
- No missing sequence numbers
- No error messages in trace
- Consistent timing between operations

## Example: Successful Verification

From `gda-experiments/trace-summary.txt`:

```
DOORBELL OPERATIONS CAPTURED:
------------------------------
✅ Submission Queue (SQ) doorbell writes: 446
✅ Completion Queue (CQ) doorbell writes: 443
✅ Total doorbell operations: 889

MMIO ADDRESSES CONFIRMED:
-------------------------
✅ Admin SQ doorbell: 0x1000 (BAR0 + 0x1000)
✅ Admin CQ doorbell: 0x1004 (BAR0 + 0x1004)
✅ I/O queue doorbells: Higher addresses
✅ Write size: 4 bytes (32-bit) - CORRECT per NVMe spec

OPERATION SEQUENCE:
------------------
✅ Sequential tail progression (12→13→14→15→16→17...)
✅ Sequential head progression (9→11→12→13→14→15...)
✅ Proper wrap-around at queue boundary (30→31→0→1)
✅ No gaps or errors in sequence
```

## Test Programs That Generate Doorbell Activity

Several test programs in the codebase write to doorbells:

### 1. `gda-experiments/test_doorbell_trace.c`
Purpose: Simple doorbell write test for trace verification

```bash
# Build and run
cd gda-experiments
gcc -o test_doorbell_trace test_doorbell_trace.c
sudo ./test_doorbell_trace /dev/nvme_gda0

# Check trace
cat /tmp/nvme-gda-trace.log | grep doorbell
```

### 2. `gda-experiments/test_nvme_io_command.c`
Purpose: Full NVMe I/O command test with doorbell operations

```bash
# Build and run
cd gda-experiments
gcc -o test_nvme_io_command test_nvme_io_command.c
sudo ./test_nvme_io_command /dev/nvme_gda0

# Check trace for READ/WRITE commands
cat /tmp/nvme-gda-trace.log | grep -E "(doorbell|io_cmd)"
```

### 3. `tester/axiio-tester.hip`
Purpose: Main test harness with doorbell operations

```bash
# Run with verbose output
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 --verbose

# Check trace
cat /tmp/rocm-axiio-nvme-trace.log | grep doorbell
```

## Code Locations

Key code that performs doorbell writes:

### CPU Doorbell Writes

```245:248:gda-experiments/test_nvme_io_command.c
  // Ring SQ doorbell
  sq_tail = (sq_tail + 1) % req.qsize;
  printf("\nRinging SQ doorbell: new_tail=%u\n", sq_tail);
  *sq_doorbell = sq_tail;
```

```1501:1504:tester/axiio-tester.hip
    // Write tail to hardware doorbell register
    // This tells NVMe controller to process the commands
    *cpu_doorbell_ptr = tail_to_write;
    __sync_synchronize(); // Memory barrier to ensure doorbell write completes
```

### Completion Queue Doorbell Writes

```273:275:gda-experiments/test_nvme_io_command.c
      // Ring CQ doorbell
      printf("\nRinging CQ doorbell: new_head=%u\n", cq_head);
      *cq_doorbell = cq_head;
```

```1174:1181:tester/axiio-tester.hip
      // Update CQ doorbell
      if (completions_received > 0 && cpu_doorbell_ptr) {
        volatile uint32_t* cq_doorbell = cpu_doorbell_ptr +
                                         1; // CQ is +1 uint32_t from SQ
        *cq_doorbell = cq_head;
        __sync_synchronize();
        std::cout << "CQ doorbell updated to: " << cq_head << std::endl;
      }
```

## Troubleshooting

### No Doorbell Traces Appearing

**Problem:** Trace file exists but no doorbell operations logged

**Solutions:**
1. Verify tracing is enabled: Check QEMU command includes `NVME_TRACE=doorbell`
2. Check trace file location: Verify `NVME_TRACE_FILE` path is correct
3. Verify tests are running: Check if tests actually write to doorbells
4. Check permissions: Ensure trace file is writable

### Trace File Not Created

**Problem:** Trace file doesn't exist at expected location

**Solutions:**
1. Check QEMU launch: Verify `NVME_TRACE_FILE` environment variable set
2. Check disk space: Ensure host has space for trace file
3. Check QEMU version: Older QEMU may not support tracing
4. Check QEMU logs: Look for trace-related errors in QEMU output

### Incorrect Doorbell Values

**Problem:** Trace shows unexpected doorbell values

**Solutions:**
1. Check queue size: Verify queue size matches expected range
2. Check for stale state: Doorbell may have stale value from previous run
3. Check memory barriers: Ensure `__sync_synchronize()` after doorbell write
4. Review test code: Verify doorbell write logic is correct

## Summary

**How Doorbell Rings Are Confirmed:**

1. **Enable QEMU Tracing** - Set `NVME_TRACE=doorbell` when launching VM
2. **Run Tests** - Execute NVMe tests that write to doorbells
3. **Analyze Trace** - Check trace file for `pci_nvme_mmio_doorbell_*` entries
4. **Verify Sequence** - Confirm sequential tail/head progression
5. **Verify Addresses** - Confirm correct MMIO addresses (0x1000, 0x1004, etc.)

**Key Files:**
- Trace output: `/tmp/rocm-axiio-nvme-trace.log` (or path specified)
- Test programs: `gda-experiments/test_doorbell_trace.c`
- Main tester: `tester/axiio-tester.hip`
- Documentation: `docs/VM_TESTING_WITH_QEMU_MINIMAL.md`

**Confidence Level:** 100% - Hardware trace provides definitive proof that
doorbell operations reach the NVMe controller.

