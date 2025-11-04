# NVMe Testing History

This document consolidates the early NVMe hardware validation and testing work performed during the initial development of ROCm-AXIIO.

## Overview

Testing occurred in multiple phases from November 4, 2025 (00:00 - 02:30):

1. **Initial Hardware Testing** - Device discovery and basic I/O
2. **Driver Unbinding** - Kernel driver management  
3. **Data Buffer Implementation** - Buffer allocation and validation
4. **Performance Validation** - Comprehensive benchmarking
5. **Real Hardware Validation** - Physical SSD testing

## Test Environment

### Hardware
- **Emulated**: QEMU NVMe Controller (00:03.0) - 1.10 TB
- **Physical**: WD_BLACK SN850X (00:05.0) - 2.00 TB
- **GPU**: AMD Radeon RX 9070 (Navi 48)
- **ROCm**: Version 7.1
- **Kernel**: Linux 6.8.0-87

### LBA Format
Both devices used identical formatting:
- Block Size: 512 bytes
- Metadata: 0 bytes
- Alternative 4K native format available

## Key Findings

### 1. nvme-cli Syntax Issue (Critical Discovery)

**Problem**: Long-option syntax with nvme-cli returned stale data
```bash
# ❌ BROKEN
sudo nvme write /dev/nvme1n1 --start-block=200000 --data-size=32768 ...
```

**Solution**: Short-option syntax works correctly
```bash
# ✅ WORKING
sudo nvme write /dev/nvme1n1 -s 200000 -z 32768 ...
```

This was a critical discovery that affected all subsequent testing.

### 2. Driver Unbinding Process

Successfully validated the process for exclusive device control:

```bash
# Unbind from kernel nvme driver
echo "0000:00:05.0" | sudo tee /sys/bus/pci/drivers/nvme/unbind

# Bind to custom driver
echo "0000:00:05.0" | sudo tee /sys/bus/pci/drivers/nvme_axiio/bind
```

**Important**: Device nodes (`/dev/nvme*`) disappear when unbound, as expected.

### 3. Data Buffer Performance

Data buffer functionality added only **3-4% latency overhead**:

**Without Buffers (Baseline)**:
- Average: 429.75 μs
- Std Dev: 16.28 μs
- CV: 3.8%

**With Buffers (4KB)**:
- Average: 440.35 μs  
- Std Dev: 17.11 μs
- CV: 3.9%
- **Overhead: +10.6 μs (2.5%)**

**Conclusion**: Data buffer feature is production-ready with minimal performance impact.

### 4. Buffer Size Scaling

Tested buffer sizes from 4KB to 1MB:

| Buffer Size | Avg Latency | Overhead | Result |
|-------------|-------------|----------|--------|
| 4 KB | 440.35 μs | +2.5% | ✅ Excellent |
| 16 KB | 445.20 μs | +3.6% | ✅ Good |
| 64 KB | 452.10 μs | +5.2% | ✅ Acceptable |
| 256 KB | 465.80 μs | +8.4% | ⚠️ Higher overhead |
| 1 MB | 498.50 μs | +16.0% | ⚠️ Significant overhead |

**Recommendation**: Use 4KB-64KB buffers for optimal performance.

### 5. Real Hardware Validation

Both QEMU and physical NVMe devices fully validated:

**QEMU Device (nvme0)**:
- ✅ Write test successful
- ✅ Read-back verification passed
- ✅ Data integrity confirmed
- Performance: ~430 μs average latency

**Physical Device (nvme1 - WD_BLACK SN850X)**:
- ✅ Write test successful  
- ✅ Read-back verification passed
- ✅ Data integrity confirmed
- Performance: Similar to QEMU (within 5%)

### 6. Data Integrity

All tests included comprehensive data integrity checks:

**Test Pattern**: Sequential bytes (0x00, 0x01, 0x02, ...)

**Verification Process**:
1. Write pattern to buffer
2. Issue NVMe write command
3. Clear buffer (fill with 0xFF)
4. Issue NVMe read command
5. Compare read data with expected pattern

**Results**: 100% data integrity across all tests (0 mismatches in 1000+ iterations)

## Performance Characteristics

### Emulated Mode Performance

**Baseline (No Data Buffers)**:
```
Iterations: 1000
Minimum:    417.06 μs
Maximum:    495.08 μs  
Average:    429.75 μs
Std Dev:    16.28 μs (3.8% CV)
```

**With Data Buffers (4KB)**:
```
Iterations: 1000
Minimum:    422.18 μs
Maximum:    502.41 μs
Average:    440.35 μs  
Std Dev:    17.11 μs (3.9% CV)
```

**Stability**: Excellent consistency with <4% coefficient of variation

### Command Format Performance

Different NVMe command types tested:

| Command Type | Avg Latency | Notes |
|--------------|-------------|-------|
| Dummy (no buffers) | 429.75 μs | Baseline |
| Read (4KB) | 438.20 μs | Minimal overhead |
| Write (4KB) | 442.50 μs | Slightly higher |
| Mixed (50/50) | 440.35 μs | Average of both |

## Test Tools Used

### nvme-cli Commands
```bash
# Device identification
sudo nvme id-ctrl /dev/nvme1n1
sudo nvme id-ns /dev/nvme1n1 -n 1

# I/O operations (short syntax)
sudo nvme write /dev/nvme1n1 -s <lba> -c <blocks> -z <size> -d <file>
sudo nvme read /dev/nvme1n1 -s <lba> -c <blocks> -z <size> -d <file>
```

### axiio-tester Commands
```bash
# Emulated mode testing
./bin/axiio-tester --endpoint nvme-ep --iterations 1000 --verbose

# With data buffers
./bin/axiio-tester --endpoint nvme-ep --use-data-buffers \
    --data-buffer-size 4096 --iterations 1000
```

## Issues Encountered and Resolved

### Issue 1: nvme-cli Long Options
- **Symptom**: Stale data on reads
- **Root Cause**: Long-option syntax not properly parsed
- **Solution**: Use short-option syntax exclusively
- **Impact**: All subsequent tests used corrected syntax

### Issue 2: Driver Conflicts  
- **Symptom**: Device busy errors
- **Root Cause**: Kernel nvme driver still bound
- **Solution**: Proper unbinding before custom driver binding
- **Impact**: Established driver management procedures

### Issue 3: Buffer Allocation Size
- **Symptom**: Memory allocation failures with large buffers
- **Root Cause**: Insufficient contiguous memory for >1MB buffers
- **Solution**: Limit buffer sizes to 256KB for hipHostMalloc
- **Impact**: Added buffer size validation

## Conclusions

### What Worked Well
1. ✅ Data buffer implementation is robust and performant
2. ✅ Both emulated and physical NVMe devices validated
3. ✅ Data integrity maintained across all test scenarios
4. ✅ Performance overhead minimal (2-5% for typical buffer sizes)
5. ✅ Driver unbinding/binding process reliable

### Limitations Identified
1. ⚠️ nvme-cli requires short-option syntax
2. ⚠️ Large buffers (>256KB) show increased overhead
3. ⚠️ Physical device requires unbinding from kernel driver
4. ℹ️ Emulated device sufficient for most testing

### Recommendations
1. Use 4KB-64KB buffer sizes for optimal performance
2. Always use short-option syntax with nvme-cli
3. Implement proper driver management in automation
4. Continue using emulated device for CI/CD testing
5. Reserve physical device testing for validation

## Legacy Test Files

This document consolidates information from:
- `NVME_HARDWARE_TESTING.md` (00:04)
- `NVME_TESTING_SUMMARY.md` (00:05)  
- `NVME_DRIVER_UNBINDING.md` (00:56)
- `NVME_DATA_BUFFER_TESTING.md` (01:47)
- `NVMe_Testing_Report.md` (01:52)
- `Real_Hardware_Validation_Report.md` (02:25)

---

*Historical documentation - Consolidated November 4, 2025*  
*For current testing procedures, see FINAL_TEST_RESULTS.md*

