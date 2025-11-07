# HSA Environment Variables for NVMe GDA

## Key Environment Variable: HSA_FORCE_FINE_GRAIN_PCIE

### What It Does

`HSA_FORCE_FINE_GRAIN_PCIE=1` forces HSA to expose PCIe-accessible memory (like our NVMe doorbell registers) as fine-grained memory accessible from the GPU.

### Why It Might Be Needed

When we use `hsa_amd_memory_lock_to_pool()` on memory-mapped I/O regions (like NVMe doorbells):
- The memory is from a PCIe device (NVMe controller)
- It's not system RAM
- HSA needs to know it should treat it as fine-grained for GPU access
- This ensures writes go directly to the PCIe device

### rocSHMEM and GDA Usage

rocSHMEM code searches for fine-grained memory pools:
```cpp
if (pool_flag == (HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_KERNARG_INIT |
                  HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_FINE_GRAINED)) {
  *static_cast<hsa_amd_memory_pool_t*>(data) = memory_pool;
}
```

Then uses it for locking doorbell memory:
```cpp
hsa_amd_memory_lock_to_pool(qp_out.bf.reg,  // MLX5 doorbell register
                            qp_out.bf.size * 2,
                            &gpu_agents[gpu_id].agent, 1,
                            cpu_agents[0].pool, 0,  // CPU fine-grained pool
                            &gpu_ptr);
```

### Our NVMe GDA Usage

We do the same thing:
```cpp
hsa_amd_memory_lock_to_pool(
    doorbell_base,              // NVMe doorbell MMIO region
    queue->doorbell_size,
    &ctx->gpu_agent, 1,
    ctx->cpu_pool, 0,           // CPU fine-grained pool
    &gpu_doorbell_base
);
```

## Other Relevant HSA Environment Variables

### HSA_ENABLE_SDMA
- Controls System DMA engine usage
- Usually set to `0` for GDA (direct access, no DMA)

### HSA_AMD_DISABLE_CACHE
- Disables caching for certain memory types
- May help with MMIO regions

### HSA_XNACK
- Controls recoverable page faults
- Usually `0` for direct hardware access

## Testing With/Without the Variable

### Test 1: Without HSA_FORCE_FINE_GRAIN_PCIE

```bash
# Run test normally
./test_nvme_io_command /dev/nvme_gda0
```

**Expected**: May work if HSA auto-detects, or may fail with errors

### Test 2: With HSA_FORCE_FINE_GRAIN_PCIE

```bash
# Force fine-grained for PCIe regions
export HSA_FORCE_FINE_GRAIN_PCIE=1
./test_nvme_io_command /dev/nvme_gda0
```

**Expected**: Should ensure GPU can access NVMe doorbells

## How to Check

### Check if variable is needed:
```bash
# Try without
./test_hsa_doorbell

# Try with
HSA_FORCE_FINE_GRAIN_PCIE=1 ./test_hsa_doorbell
```

### Check HSA memory pool info:
```bash
# Use rocminfo to see memory pools
rocminfo | grep -A10 "Pool"
```

Look for:
- `Segment: GLOBAL; FLAGS: FINE GRAINED`
- `Accessible by: GPU` 
- `Alloc Granule: 4KB`

## For Our Tests

### Update test scripts to set:
```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
export HSA_ENABLE_SDMA=0  # Disable SDMA for direct access
```

### In VM test script:
```bash
#!/bin/bash
# Set HSA environment for GDA
export HSA_FORCE_FINE_GRAIN_PCIE=1
export HSA_ENABLE_SDMA=0

# Load driver
sudo insmod nvme_gda.ko ...

# Run tests
./test_nvme_io_command /dev/nvme_gda0
```

## Documentation References

From ROCm documentation:
- `HSA_FORCE_FINE_GRAIN_PCIE`: Forces fine-grained treatment of PCIe memory regions
- Used for GPU Direct technologies (RDMA, Storage, etc.)
- Critical for device MMIO access from GPU

## Summary

**Do we need it?** Likely YES for NVMe doorbells!

**Why?** Because:
1. NVMe doorbells are PCIe MMIO registers
2. Not system RAM
3. Need fine-grained semantics for GPU access
4. HSA may not auto-detect MMIO regions as fine-grained

**How to use:**
```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
```

**When?** Set before running any test that:
- Maps NVMe doorbells
- Calls `hsa_amd_memory_lock_to_pool()` on MMIO regions
- Has GPU write to device registers

This is likely why our GPU tests are having issues - we may need this environment variable set!

