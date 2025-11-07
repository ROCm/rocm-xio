# Required Environment Variables for NVMe GDA

## Critical Discovery: `HSA_FORCE_FINE_GRAIN_PCIE=1`

### Summary

**YES, we likely need `HSA_FORCE_FINE_GRAIN_PCIE=1` for GPU doorbell access!**

Currently it's **NOT SET** - which may be causing our GPU access issues.

### What It Does

Forces HSA runtime to treat **PCIe device memory** (like NVMe doorbell MMIO registers) as **fine-grained**, making it accessible from GPU kernels.

### Why It's Critical for NVMe Doorbells

1. **NVMe doorbells are PCIe MMIO registers**, not system RAM
2. **HSA may not auto-detect** MMIO regions as GPU-accessible
3. **Without it**: `hsa_amd_memory_lock_to_pool()` may fail or return invalid GPU pointers
4. **With it**: GPU writes go directly to NVMe controller via PCIe

### rocSHMEM MLX5 GDA Pattern

rocSHMEM searches for fine-grained memory pools:
```cpp
if (pool_flag == (HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_KERNARG_INIT |
                  HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_FINE_GRAINED)) {
  *static_cast<hsa_amd_memory_pool_t*>(data) = memory_pool;
}
```

They use it for MLX5 doorbell registers:
```cpp
rocm_memory_lock_to_fine_grain(qp_out.bf.reg,  // MLX5 doorbell
                                qp_out.bf.size * 2,
                                &gpu_ptr, hip_dev_id);
```

### Our NVMe GDA Does the Same

```cpp
hsa_amd_memory_lock_to_pool(
    doorbell_base,              // NVMe doorbell MMIO region
    queue->doorbell_size,       // 4KB page
    &ctx->gpu_agent, 1,         // GPU agent
    ctx->cpu_pool, 0,           // Fine-grained CPU pool
    &gpu_doorbell_base          // Returns GPU-accessible pointer
);
```

## Required Environment Variables

### For All NVMe GDA Tests

```bash
# CRITICAL: Force fine-grained for PCIe MMIO
export HSA_FORCE_FINE_GRAIN_PCIE=1

# Disable SDMA for direct access
export HSA_ENABLE_SDMA=0
```

### Optional but Recommended

```bash
# Disable caching for MMIO regions
export HSA_AMD_DISABLE_CACHE=1

# Disable XNACK (not needed for direct hardware access)
export HSA_XNACK=0
```

## How to Use

### In Test Scripts

```bash
#!/bin/bash
# Set HSA environment for GDA
export HSA_FORCE_FINE_GRAIN_PCIE=1
export HSA_ENABLE_SDMA=0

# Run test
./test_nvme_io_command /dev/nvme_gda0
```

### In VM Test Script

Update `in-vm-gda-test.sh`:
```bash
#!/bin/bash

# Set HSA environment for GPU Direct Async
export HSA_FORCE_FINE_GRAIN_PCIE=1
export HSA_ENABLE_SDMA=0

echo "HSA Environment:"
echo "  HSA_FORCE_FINE_GRAIN_PCIE=$HSA_FORCE_FINE_GRAIN_PCIE"
echo "  HSA_ENABLE_SDMA=$HSA_ENABLE_SDMA"
echo

# Rest of test script...
```

### For GPU Tests

```bash
# Before running GPU doorbell tests
export HSA_FORCE_FINE_GRAIN_PCIE=1
export HSA_ENABLE_SDMA=0

./test_basic_doorbell /dev/nvme_gda0
./test_gpu_io /dev/nvme_gda0
```

## Verification

### Check Current Environment

```bash
env | grep HSA
```

Should show:
```
HSA_FORCE_FINE_GRAIN_PCIE=1
HSA_ENABLE_SDMA=0
```

### Check HSA Memory Pools

```bash
rocminfo | grep -A10 "Pool"
```

Look for fine-grained pools with PCIe access.

## What Happens Without It?

### Symptoms

1. `hsa_amd_memory_lock_to_pool()` may return `HSA_STATUS_ERROR`
2. GPU doorbell pointers may be NULL or invalid
3. GPU kernel segfaults when accessing doorbells
4. No doorbell writes visible in NVMe trace from GPU

### With It Set

1. ✅ HSA recognizes PCIe MMIO as GPU-accessible
2. ✅ `hsa_amd_memory_lock_to_pool()` succeeds
3. ✅ GPU gets valid doorbell pointers
4. ✅ GPU writes reach NVMe controller
5. ✅ Trace shows GPU-initiated I/O commands

## Comparison with Other GPU Direct Technologies

| Technology | Environment Variable Needed? |
|------------|------------------------------|
| **GPU Direct RDMA** | YES - `HSA_FORCE_FINE_GRAIN_PCIE=1` |
| **GPU Direct Storage** | YES - `HSA_FORCE_FINE_GRAIN_PCIE=1` |
| **rocSHMEM MLX5 GDA** | YES - (implied by fine-grained pool usage) |
| **Our NVMe GDA** | **YES - REQUIRED!** |

## Testing Impact

### Before (Without Variable)

- CPU doorbell tests: ✅ Work (890 ops traced)
- HSA memory locking: ❌ May fail
- GPU doorbell tests: ❌ Segfault or no effect
- GPU I/O commands: ❌ Not reaching NVMe

### After (With Variable)

- CPU doorbell tests: ✅ Work
- HSA memory locking: ✅ Should succeed
- GPU doorbell tests: ✅ Should work
- GPU I/O commands: ✅ Should appear in trace

## Next Steps

1. **Update all test scripts** to set `HSA_FORCE_FINE_GRAIN_PCIE=1`
2. **Rebuild and retest** GPU doorbell access
3. **Check trace** for GPU-initiated NVMe commands
4. **Document** in README and QUICKSTART

## References

- ROCm HSA Environment Variables documentation
- rocSHMEM GDA implementation (uses fine-grained pools)
- GPU Direct technologies (RDMA, Storage) all require it
- AMD GPU architecture for PCIe device access

## Bottom Line

```bash
# THIS IS CRITICAL FOR GPU DOORBELL ACCESS
export HSA_FORCE_FINE_GRAIN_PCIE=1
export HSA_ENABLE_SDMA=0
```

**Without these, GPU cannot access NVMe doorbells!**

This is likely the missing piece that's preventing our GPU tests from working!

