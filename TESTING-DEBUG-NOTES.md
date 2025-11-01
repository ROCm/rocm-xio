# Testing and Debug Notes for rocm-axiio

## Summary

This document records the debugging process and findings while implementing comprehensive fuzz testing with GPU error detection for the rocm-axiio project.

## Issues Encountered

### 1. GPU Page Fault Errors on Radeon GPUs (gfx1201)

**Symptom**: When running `axiio-tester`, GPU page faults occurred:
```
amdgpu: [gfxhub] page fault (src_id:0 ring:24 vmid:8 pasid:32772)
PERMISSION_FAULTS: 0x3
```

**Investigation Steps**:

1. **Initial Hypothesis**: Memory allocation flags were incorrect
   - Changed from `flags = 0` to `flags = hipHostMallocCoherent`
   - Result: Still failed

2. **Second Hypothesis**: Need both mapping and coherence
   - Changed to `flags = hipHostMallocMapped | hipHostMallocCoherent`
   - Result: Still failed

3. **Third Hypothesis**: Need explicit device pointer mapping
   - Added `hipHostGetDevicePointer()` to get device-side pointer
   - Passed device pointer to GPU kernel, host pointer to CPU thread
   - Result: Still failed

4. **Testing Fundamental Assumption**: Created simple test (`test-hip-mapped-memory.hip`)
   - Test showed that `hipHostMallocMapped` **DOES work** correctly on this system
   - Simple GPU writes and reads to mapped host memory succeeded
   - **Conclusion**: The issue is NOT with basic mapped memory functionality

###  2. nvme-ep Introduction Timing

**User Report**: "The issue only arose when we added the code for the nvme endpoint"

**Investigation**:
- Temporarily disabled nvme-ep by moving it out of `endpoints/` directory
- Rebuilt with only test-ep endpoint
- Result: **Issue persists even with only test-ep**

**Conclusion**: The correlation with nvme-ep addition may be coincidental. The underlying issue exists regardless of which endpoints are compiled.

## Current Status

### What Works

1. ✅ **Build System**:
   - Automatic endpoint discovery
   - Multi-endpoint compilation
   - Clean build process

2. ✅ **Basic HIP Functionality**:
   - `hipHostMallocMapped` works correctly
   - GPU can read/write to mapped host memory
   - Memory coherence with `HSA_FORCE_FINE_GRAIN_PCIE=1` functions

3. ✅ **Testing Infrastructure**:
   - Automatic GPU error detection via dmesg monitoring
   - Comprehensive test suite (`make test-*` targets)
   - Timeout protection
   - Clear error reporting

### What Doesn't Work

1. ❌ **axiio-tester Execution**:
   - Test hangs (timeouts after 30 seconds)
   - GPU page faults occur
   - Both test-ep and nvme-ep endpoints affected

## Possible Root Causes (Still Under Investigation)

1. **Memory Access Pattern Issue**:
   - The emulate/drive pattern uses tight polling loops
   - CPU thread (`emulateEndpoint`) and GPU kernel (`driveEndpoint`) poll shared memory
   - Possible race condition or coherence issue specific to this access pattern

2. **Code Generation with -fgpu-rdc**:
   - Project uses `-fgpu-rdc` (Relocatable Device Code)
   - May affect how `__host__ __device__` functions are compiled
   - Dispatch mechanism through switch statement may have issues

3. **Endpoint Function Compilation**:
   - `emulateEndpoint` is `__host__ __device__` but called only from CPU (std::thread)
   - Compiler may generate both host and device code
   - Possible incorrect code path selection

4. **Memory Visibility**:
   - Even with `__threadfence_system()`, visibility may be delayed
   - Polling loops may not see updates from the other side
   - Could explain timeout behavior

## Testing Infrastructure Created

### 1. Dependency Management

**Makefile Targets**:
- `make check-deps`: Verify all dependencies are installed
- `make install-deps`: Automatically install missing dependencies

**Dependencies**:
- `libcli11-dev`: Command-line parsing library
- `rocminfo`: GPU information utility
- Environment: `HSA_FORCE_FINE_GRAIN_PCIE=1` (required for Radeon GPUs)

### 2. GPU Error Monitoring

**Script**: `scripts/test-with-dmesg-monitor.sh`
- Records dmesg baseline before test
- Runs test with timeout protection
- Checks for new GPU errors after test
- Provides diagnostic suggestions
- Returns appropriate exit codes

**Features**:
- Colored output for easy reading
- Configurable timeout (default: 30s)
- Environment variable verification
- Automatic error detection

### 3. Test Targets

```bash
# Basic test
make test                  # 128 iterations

# Fuzz tests (increasing load)
make test-quick            # 128 iterations, 30s timeout
make test-medium           # 1000 iterations, 60s timeout
make test-large            # 10000 iterations, 120s timeout
make test-huge             # 100000 iterations, 300s timeout

# Special tests
make test-verbose          # Detailed per-iteration output
make test-histogram        # Performance histogram

# Test suites
make test-fuzz             # Run all fuzz tests
make test-all              # Complete test suite
```

### 4. Documentation Updates

**README.md**:
- Added comprehensive Prerequisites section
- Documented environment variable requirements
- Added Testing section with all test targets
- Added Troubleshooting section

## Environment Setup

### For Radeon GPUs (Required)

```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
```

Make permanent:
```bash
echo 'export HSA_FORCE_FINE_GRAIN_PCIE=1' >> ~/.bashrc
source ~/.bashrc
```

### Verification

```bash
make check-deps
rocminfo | grep gfx
```

## Next Steps for Resolution

1. **Investigate Polling Loop Behavior**:
   - Add debug output to see where code hangs
   - Check if emulate or drive side is stuck
   - Verify memory addresses being accessed

2. **Test Alternative Memory Allocation**:
   - Try hipMallocManaged (Unified Memory)
   - Test with pure device memory + explicit copies
   - Compare behavior with different allocation strategies

3. **Simplify Test Case**:
   - Create minimal repro without endpoint dispatch
   - Test direct function calls vs. switch dispatch
   - Remove threading to isolate concurrent access issues

4. **Compiler Flags Investigation**:
   - Test without `-fgpu-rdc`
   - Try different optimization levels
   - Check generated assembly for anomalies

5. **ROCm Version Check**:
   - Verify ROCm version compatibility
   - Test on different ROCm versions if possible
   - Check for known issues with gfx1201 + current ROCm

## Files Modified

- `README.md`: Added prerequisites, testing, and troubleshooting sections
- `Makefile`: Added check-deps, install-deps, and test-* targets
- `tester/axiio-tester.hip`: Updated memory allocation flags and device pointer handling
- `scripts/test-with-dmesg-monitor.sh`: New test monitoring script (created)
- `test-hip-mapped-memory.hip`: Simple validation test (created)
- `TESTING-DEBUG-NOTES.md`: This file (created)

## Useful Commands

```bash
# Clean kernel log
sudo dmesg -c

# Watch for GPU errors in real-time
sudo dmesg -w | grep -i amdgpu

# Check GPU info
rocminfo

# Run test with custom timeout
TIMEOUT=60 ./scripts/test-with-dmesg-monitor.sh -n 1000

# Build and test quickly
make clean && make all && make test-quick
```

## References

- [AMD Confluence: Cache Coherence Summary](https://amd.atlassian.net/wiki/spaces/AMDGPU/pages/777526553/Cache+coherence+summary+by+Joseph+Greathouse)
- HIP API Documentation: hipHostMalloc flags
- ROCm Documentation: Fine-grained memory access

---

**Last Updated**: 2025-11-04
**System**: gfx1201 (Radeon GPU)
**ROCm Version**: 7.1.0

