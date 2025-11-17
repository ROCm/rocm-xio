# Critical Fix: HSA Memory Pool Selection

## The Bug

**Our code was selecting the WRONG memory pool!**

### What We Were Doing

```cpp
// Our buggy version
if (flags & HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_FINE_GRAINED) {
    *ret = pool;
    return HSA_STATUS_INFO_BREAK;
}
```

This checks if FINE_GRAINED flag is SET, but doesn't check for KERNARG_INIT!

### What rocSHMEM Does (Correct)

```cpp
// rocSHMEM working version
if (pool_flag == (HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_KERNARG_INIT |
                  HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_FINE_GRAINED)) {
    *static_cast<hsa_amd_memory_pool_t*>(data) = memory_pool;
}
```

This requires **EXACT match** with BOTH flags!

## Why This Matters

### HSA Memory Pool Types

1. **System Memory Pools** - Various types:
   - Coarse-grained (not cache coherent)
   - Fine-grained (cache coherent)
   - Fine-grained + KERNARG (cache coherent + kernel argument capable)

2. **GPU Memory Pools** - Device memory

### The Correct Pool

For `hsa_amd_memory_lock_to_pool()` to work with PCIe MMIO regions (like NVMe doorbells and DMA buffers), we need:

- `HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_KERNARG_INIT` - Pool can hold kernel arguments
- `HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_FINE_GRAINED` - Cache coherent

**BOTH flags required!**

## Impact on Our Tests

### Why SQE/CQE Locking Was Failing

```cpp
// Memory locking was using wrong pool!
hsa_amd_memory_lock_to_pool(
    queue->sqes, queue->sqes_size,
    &ctx->gpu_agent, 1,
    ctx->cpu_pool, 0,  // ← WRONG POOL!
    &gpu_sqe_base
);
```

If `ctx->cpu_pool` was the wrong pool (missing KERNARG_INIT), then:
- `hsa_amd_memory_lock_to_pool()` would fail
- Or return invalid GPU pointers
- GPU couldn't access the memory

### Why Doorbell Access "Worked"

Doorbells are MMIO registers - they may be more forgiving or use different code paths in HSA runtime.

## The Fix

### Updated Pool Selection

```cpp
/* rocSHMEM pattern: require BOTH KERNARG_INIT and FINE_GRAINED */
const uint32_t required_flags = HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_KERNARG_INIT |
                                HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_FINE_GRAINED;

if (flags == required_flags) {
    hsa_amd_memory_pool_t *ret = (hsa_amd_memory_pool_t*)data;
    *ret = pool;
    return HSA_STATUS_INFO_BREAK;
}
```

### What This Should Fix

1. ✅ SQE memory locking for GPU
2. ✅ CQE memory locking for GPU
3. ✅ Doorbell memory locking (already working, but now using correct pool)
4. ✅ GPU can write NVMe commands to SQE
5. ✅ GPU can read completions from CQE

## Testing Impact

### Before Fix
- HSA memory locking: ❌ Using wrong pool
- GPU SQE/CQE access: ❌ Failed or invalid pointers
- GPU doorbell: ✅ Worked (maybe by luck)

### After Fix
- HSA memory locking: ✅ Using correct pool with both flags
- GPU SQE/CQE access: ✅ Should work!
- GPU doorbell: ✅ Works properly
- Full GPU I/O: ✅ Should work!

## Additional Considerations

### `HSA_FORCE_FINE_GRAIN_PCIE` Environment Variable

With correct pool selection, this variable may:
- Still be needed for optimal performance
- Help with edge cases
- Force fine-grained behavior for PCIe regions

But the **primary issue** was wrong pool selection!

## Comparison Summary

| Aspect | Our Code (Before) | rocSHMEM (Correct) | Our Code (After) |
|--------|-------------------|-------------------|------------------|
| **Flag Check** | `flags & FINE_GRAINED` | `flags == (KERNARG \| FINE_GRAINED)` | `flags == (KERNARG \| FINE_GRAINED)` |
| **Operator** | Bitwise AND (`&`) | Equality (`==`) | Equality (`==`) |
| **KERNARG Required** | ❌ No | ✅ Yes | ✅ Yes |
| **FINE_GRAINED Required** | ✅ Yes | ✅ Yes | ✅ Yes |
| **Pool Selection** | ❌ Wrong | ✅ Correct | ✅ Correct |

## Next Steps

1. Rebuild with correct pool selection
2. Test SQE/CQE locking (should succeed now)
3. Test GPU writing to SQE
4. Test GPU reading from CQE
5. Run full I/O test with GPU-posted commands

**This was likely the root cause of our GPU memory access issues!**

