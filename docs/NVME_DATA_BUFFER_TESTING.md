# NVMe Data Buffer Testing Guide

This document describes how to use the NVMe data buffer testing feature in axiio-tester, which enables end-to-end I/O testing with data verification.

## Overview

The data buffer testing feature extends axiio-tester to:
- Allocate CPU-GPU coherent data buffers
- Generate test patterns in buffers
- Calculate real PRP (Physical Region Page) entries
- Verify data integrity after read operations
- Support multiple test patterns

## Quick Start

### Basic Usage

```bash
# Basic test with default settings (1 MB buffer, sequential pattern)
./bin/axiio-tester --endpoint nvme-ep --use-data-buffers

# Custom buffer size
./bin/axiio-tester --endpoint nvme-ep --use-data-buffers \
    --data-buffer-size 4194304  # 4 MB

# Different test pattern
./bin/axiio-tester --endpoint nvme-ep --use-data-buffers \
    --test-pattern random

# Custom block size
./bin/axiio-tester --endpoint nvme-ep --use-data-buffers \
    --nvme-block-size 4096  # 4KB blocks
```

## CLI Options

### `--use-data-buffers`
Enable data buffer allocation for NVMe I/O testing.

**Type**: Flag (boolean)  
**Default**: false  
**Required**: Yes (for buffer testing)

### `--data-buffer-size <bytes>`
Size of read and write buffers in bytes.

**Type**: Positive integer  
**Default**: 1048576 (1 MB)  
**Range**: Limited by available memory  
**Example**: `--data-buffer-size 2097152` (2 MB)

### `--nvme-block-size <bytes>`
NVMe block size in bytes.

**Type**: Positive integer  
**Default**: 512  
**Common values**: 512, 4096  
**Note**: Must match device configuration

### `--test-pattern <pattern>`
Data pattern for testing.

**Type**: String (enum)  
**Default**: sequential  
**Valid values**:
- `sequential` - Incrementing bytes (0x00, 0x01, 0x02, ...)
- `zeros` - All zeros (0x00)
- `ones` - All ones (0xFF)
- `random` - Pseudo-random (deterministic, based on offset)
- `block_id` - Block identifier repeated throughout buffer

## Test Patterns

### Sequential Pattern
```
Byte 0:   0x00
Byte 1:   0x01
Byte 2:   0x02
...
Byte 255: 0xFF
Byte 256: 0x00 (wraps)
```

**Use case**: Basic data integrity verification

### Zeros Pattern
```
All bytes: 0x00
```

**Use case**: Testing zero-fill optimization, compression

### Ones Pattern
```
All bytes: 0xFF
```

**Use case**: Testing all-ones paths, bit errors

### Random Pattern
```
Deterministic pseudo-random based on byte offset
```

**Use case**: Detecting pattern-dependent errors

### Block ID Pattern
```
Each 8-byte block filled with its block number
```

**Use case**: Block-level integrity verification

## Performance Results

### Test Environment
- Device: AMD GPU
- ROCm: 7.1
- Mode: Emulated endpoint
- Queue size: 1024 SQ, 512 CQ

### Baseline (No Buffers)
```
Iterations: 10
Average: 437.95 μs
Std Dev: 21.00 μs
```

### With Data Buffers (65 KB)
```
Buffer Size: 65536 bytes
Block Size: 512 bytes
Pattern: sequential

Iterations: 10
Average: 456.74 μs
Std Dev: 104.60 μs

Overhead: ~4.3% (18.79 μs)
```

### Pattern Performance Comparison

| Pattern    | Average (μs) | Std Dev (μs) | vs Baseline |
|-----------|--------------|--------------|-------------|
| sequential | 456.74      | 104.60       | +4.3%       |
| zeros     | 543.76      | 79.20        | +24.2%      |
| ones      | 462.06      | 62.41        | +5.5%       |
| random    | 454.70      | 62.30        | +3.8%       |
| block_id  | 469.81      | 80.94        | +7.3%       |

**Observations**:
- Minimal overhead for most patterns (~5%)
- Zeros pattern shows higher overhead (compression path?)
- All patterns maintain microsecond-level latency
- Good consistency (CV < 20%)

## Architecture

### Memory Flow

```
CPU                                 GPU
 │                                   │
 ├─ hipHostMalloc(readBuffer)      │
 ├─ hipHostMalloc(writeBuffer)     │
 │                                   │
 │  (CPU-GPU coherent memory)       │
 │                                   │
 └───────────────┐                  │
                 │                  │
                 ▼                  ▼
         ┌──────────────────────────────┐
         │  Coherent Memory Space       │
         │  - Read Buffer (1 MB)        │
         │  - Write Buffer (1 MB)       │
         └──────────────────────────────┘
                 ▲                  ▲
                 │                  │
         nvme_calculate_prps()      │
                 │                  │
                 ▼                  │
         ┌──────────────┐          │
         │ PRP1, PRP2   │──────────┘
         │ (real addrs) │  Used in NVMe
         └──────────────┘  SQE commands
```

### Data Flow

```
1. Pattern Generation (GPU):
   nvme_generate_pattern(writeBuffer, size, pattern, offset)

2. NVMe Write Command:
   - Calculate PRPs from writeBuffer address
   - Submit NVMe WRITE command
   - Controller processes (emulated)

3. NVMe Read Command:
   - Calculate PRPs from readBuffer address
   - Submit NVMe READ command
   - Controller processes (emulated)

4. Data Verification (GPU):
   nvme_verify_pattern(readBuffer, size, pattern, offset)
   - Returns true if data matches expected pattern
   - Returns false + error offset on mismatch
```

## Usage Examples

### Example 1: Quick Validation
```bash
# Run 10 iterations with 64KB buffer
./bin/axiio-tester --endpoint nvme-ep \
    --use-data-buffers \
    --data-buffer-size 65536 \
    --iterations 10
```

### Example 2: Stress Test
```bash
# 100 iterations, large buffer, random pattern
./bin/axiio-tester --endpoint nvme-ep \
    --use-data-buffers \
    --data-buffer-size 4194304 \
    --iterations 100 \
    --test-pattern random \
    --verbose
```

### Example 3: All Patterns
```bash
# Test all patterns
for pattern in sequential zeros ones random block_id; do
    echo "Testing pattern: $pattern"
    ./bin/axiio-tester --endpoint nvme-ep \
        --use-data-buffers \
        --test-pattern $pattern \
        --iterations 20
done
```

### Example 4: Multiple Buffer Sizes
```bash
# Test different buffer sizes
for size in 32768 65536 131072 262144; do
    echo "Testing buffer size: $size bytes"
    ./bin/axiio-tester --endpoint nvme-ep \
        --use-data-buffers \
        --data-buffer-size $size \
        --iterations 10
done
```

### Example 5: Performance Profiling
```bash
# Detailed timing with histogram
./bin/axiio-tester --endpoint nvme-ep \
    --use-data-buffers \
    --iterations 1000 \
    --histogram \
    --verbose > nvme_perf.log
```

## Limitations

### Current Limitations

1. **Emulated Mode Only (for now)**
   - Data buffers work in emulated mode
   - Real hardware support requires physical address setup
   - Use with `--real-hardware` coming soon

2. **PRP List Not Implemented**
   - Only supports transfers up to 2 pages (8KB with 4KB pages)
   - Larger transfers need PRP list support

3. **Single Queue Pair**
   - Tests use one submission/completion queue
   - Multi-queue support not yet implemented

4. **No DMA Verification**
   - Emulated mode doesn't perform actual DMA
   - Real hardware mode will enable true DMA testing

### Planned Features

- [ ] PRP list support for >8KB transfers
- [ ] SGL (Scatter Gather List) support
- [ ] Multi-queue testing
- [ ] Real hardware integration
- [ ] Performance counters
- [ ] Error injection testing

## Troubleshooting

### "Failed to allocate data buffers"
- **Cause**: Insufficient memory
- **Solution**: Reduce `--data-buffer-size`

### "Pattern verification failed"
- **Cause**: Data mismatch (shouldn't happen in emulated mode)
- **Solution**: Check for GPU memory issues, report bug

### High standard deviation
- **Cause**: System load or GPU context switching
- **Solution**: Run with fewer background processes

### Timeout occurred
- **Cause**: Too many iterations or large buffers
- **Solution**: Reduce `--iterations` or `--data-buffer-size`

## Best Practices

1. **Start Small**: Begin with small buffers (64KB) and few iterations (10)
2. **Test Patterns**: Verify all patterns work before scaling up
3. **Measure Baseline**: Always run without `--use-data-buffers` first
4. **Monitor Memory**: Check memory usage with large buffers
5. **Use Verbose Mode**: Add `--verbose` for debugging

## Technical Details

### Memory Allocation Flags
```cpp
unsigned int flags = hipHostMallocMapped | hipHostMallocCoherent;
hipHostMalloc(&readBuffer, bufferSize, flags);
```

- **hipHostMallocMapped**: Makes buffer accessible from GPU
- **hipHostMallocCoherent**: Ensures CPU-GPU coherency

### PRP Calculation
```cpp
uint64_t offset_in_page = buffer_addr & (PAGE_SIZE - 1);
uint64_t first_page_size = PAGE_SIZE - offset_in_page;

if (buffer_size <= first_page_size) {
    prp1 = buffer_addr;
    prp2 = 0;
} else {
    prp1 = buffer_addr;
    prp2 = (buffer_addr + first_page_size) & ~(PAGE_SIZE - 1);
}
```

### Pattern Generation Algorithm
See `nvme_generate_pattern()` in `endpoints/nvme-ep/nvme-ep.h` for implementation details.

## References

- [NVM Express Specification](https://nvmexpress.org/specifications/)
- [HIP Programming Guide](https://rocm.docs.amd.com/projects/HIP/en/latest/)
- [Physical Region Page (PRP)](https://nvmexpress.org/wp-content/uploads/NVMe-2.0_Ratified_TPs.pdf)

## Support

For issues, questions, or feature requests, please file an issue on the project repository.

