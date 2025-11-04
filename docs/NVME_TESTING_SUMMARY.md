# NVMe Real Hardware Testing - Implementation Summary

## Overview

Successfully implemented real NVMe hardware support in `axiio-tester`, enabling direct physical memory access to NVMe queues and doorbells.

## Implementation Details

### New Features

1. **Physical Memory Mapping** (`/dev/mem`)
   - Page-aligned memory mapping
   - Proper offset calculation
   - Safe cleanup on errors

2. **Command-Line Arguments**
   - `--real-hardware`: Enable real hardware mode
   - `--nvme-doorbell`: Doorbell physical address
   - `--nvme-sq-base`: Submission queue base address
   - `--nvme-cq-base`: Completion queue base address
   - `--nvme-sq-size`: SQ size in bytes
   - `--nvme-cq-size`: CQ size in bytes

3. **Dual Mode Support**
   - Emulated mode (existing functionality preserved)
   - Real hardware mode (new physical memory mapping)
   - Automatic mode detection and validation

### Code Changes

**File: `tester/axiio-tester.hip`**

1. Added includes for physical memory access:
   ```cpp
   #include <fcntl.h>
   #include <sys/mman.h>
   #include <unistd.h>
   ```

2. Extended `cmdLineArgs` structure with hardware parameters

3. Implemented helper functions:
   - `mapPhysicalMemory()`: Maps physical addresses to virtual space
   - `unmapPhysicalMemory()`: Unmaps and cleans up

4. Modified `run()` function:
   - Conditional memory allocation (emulated vs hardware)
   - Skip initialization for real hardware queues
   - Proper cleanup for both modes

5. Added CLI argument parsing and validation

### Safety Features

- **Validation**: Requires all addresses when `--real-hardware` is used
- **Error Handling**: Graceful failure with descriptive messages
- **Root Check**: Clear messaging about privilege requirements
- **Mode Enforcement**: Automatically switches to `nvme-ep` endpoint

## Testing Status

### ✅ Verified Working

1. **Compilation**: Clean build with no errors
2. **Help Output**: New options appear correctly
3. **Validation**: Missing parameters properly detected
4. **Emulated Mode**: Original functionality unchanged
5. **Error Messages**: Clear and actionable

### Example Outputs

#### Successful Emulated Test
```
./bin/axiio-tester --endpoint nvme-ep --iterations 5
Using endpoint: nvme-ep
Memory allocation: host
Submit queue length: 1024
Complete queue length: 512

Statistics:
  Minimum:           419950.00 ns
  Maximum:           492580.00 ns
  Average:           440654.00 ns
  Standard Dev:       26281.77 ns
```

#### Validation Error (Missing Parameters)
```
./bin/axiio-tester --real-hardware
Error: --real-hardware requires all of the following options:
  --nvme-doorbell <addr>
  --nvme-sq-base <addr>
  --nvme-cq-base <addr>
  --nvme-sq-size <size>
  --nvme-cq-size <size>
```

## Usage Examples

### Example 1: Emulated Mode (Default)
```bash
./bin/axiio-tester --endpoint nvme-ep --iterations 10
```

### Example 2: Real Hardware Mode
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

### Example 3: QEMU Testing
```bash
# Step 1: Run discovery script
sudo ./scripts/test-nvme-qemu.sh

# Step 2: Find addresses in QEMU VM
sudo ./scripts/discover-nvme-addresses.sh

# Step 3: Run test with discovered addresses
sudo ./bin/axiio-tester --real-hardware \
  --nvme-doorbell <discovered_addr> \
  --nvme-sq-base <discovered_addr> \
  --nvme-cq-base <discovered_addr> \
  --nvme-sq-size 4096 \
  --nvme-cq-size 1024 \
  --iterations 5 -v
```

## Documentation

Created comprehensive documentation:

1. **`docs/NVME_HARDWARE_TESTING.md`**
   - Complete usage guide
   - Address discovery methods
   - QEMU testing instructions
   - Safety warnings and troubleshooting
   - Advanced topics and examples

2. **`scripts/test-nvme-qemu.sh`**
   - Automated QEMU setup script
   - Address discovery helper
   - Example commands
   - Safety checklist

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  axiio-tester                       │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Mode Selection:                                    │
│  ┌─────────────┐           ┌──────────────┐       │
│  │  Emulated   │           │ Real Hardware│       │
│  │   Mode      │           │    Mode      │       │
│  └──────┬──────┘           └──────┬───────┘       │
│         │                          │               │
│         v                          v               │
│  hipHostMalloc()           mapPhysicalMemory()    │
│  (HIP memory)              (/dev/mem)             │
│         │                          │               │
│         v                          v               │
│  ┌──────────────────────────────────────────┐    │
│  │        sqQueue / cqQueue / doorbell      │    │
│  └──────────────────────────────────────────┘    │
│         │                          │               │
│         v                          v               │
│  GPU Kernel Access        GPU Kernel Access       │
│  (Virtual memory)         (Physical memory)       │
└─────────────────────────────────────────────────────┘
```

## Memory Mapping Flow

```
1. Physical Address (e.g., 0xfeb10000)
         ↓
2. Page Alignment
   - pageSize = 4096
   - pageBase = 0xfeb10000 & ~4095 = 0xfeb10000
   - offset = 0x0
         ↓
3. mmap() system call
   - fd = open("/dev/mem")
   - virtBase = mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, pageBase)
         ↓
4. Virtual Address (e.g., 0x7f1234567000)
         ↓
5. GPU Access via HIP
   - GPU can read/write through virtual address
   - Direct hardware access
```

## Security Considerations

### Required Privileges
- Root user OR
- `CAP_SYS_RAWIO` capability

### Risks
- **System Crashes**: Wrong addresses can crash system
- **Data Corruption**: Writing to wrong memory
- **Security**: Direct hardware access bypasses OS protections

### Mitigations
- Comprehensive validation
- Clear error messages
- Detailed documentation with warnings
- QEMU testing recommended first
- Read-only initially, then read-write after validation

## Future Enhancements

Potential improvements for future work:

1. **IOMMU Support**: Use VFIO for safer hardware access
2. **PCIe BAR Mapping**: Automatic discovery of NVMe BARs
3. **Multiple Queues**: Support for I/O queue pairs (not just admin)
4. **Queue State Detection**: Read current queue head/tail
5. **NVMe Arbitration**: Support for different arbitration mechanisms
6. **Namespace Support**: Test with multiple NVMe namespaces
7. **Error Injection**: Simulate NVMe errors for testing

## Testing Recommendations

### Pre-Production Testing
1. Test in QEMU VM first
2. Use test NVMe device (not production storage)
3. Small iteration counts initially (1-10)
4. Monitor `dmesg` during tests
5. Have system logs enabled

### Production Testing
1. Only after thorough QEMU testing
2. On isolated test systems
3. With proper backups
4. During maintenance windows
5. With monitoring in place

## Known Limitations

1. **Admin Queue Only**: Current implementation assumes admin queue testing
2. **Single QP**: Only one queue pair at a time
3. **No Queue Initialization**: Assumes queues are already configured by OS
4. **Doorbell Stride**: Assumes default 4-byte stride
5. **Physical Contiguity**: Assumes physically contiguous queue memory

## Conclusion

The real NVMe hardware support is fully implemented, tested (in emulated mode),
and documented. The implementation provides a solid foundation for testing 
GPU-to-NVMe interactions with actual hardware while maintaining backward 
compatibility with the existing emulated mode.

**Status**: ✅ Ready for QEMU and real hardware testing

## Next Steps

To actually test with real hardware:

1. Set up QEMU VM with NVMe device
2. Run `sudo ./scripts/test-nvme-qemu.sh`
3. Discover NVMe addresses inside VM
4. Run axiio-tester with real addresses
5. Monitor for errors and performance
6. Iterate and refine based on results

## References

- Implementation: `tester/axiio-tester.hip`
- Documentation: `docs/NVME_HARDWARE_TESTING.md`
- Test Script: `scripts/test-nvme-qemu.sh`
- NVMe Spec: https://nvmexpress.org/specifications/

