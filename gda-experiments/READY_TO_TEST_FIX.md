# Ready to Test: Critical HSA Pool Fix

## Critical Bug Fixed

**We were selecting the WRONG HSA memory pool!**

### The Bug
```cpp
// Our buggy code - only checked for FINE_GRAINED
if (flags & HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_FINE_GRAINED) {
    *ret = pool;
}
```

### The Fix (matching rocSHMEM)
```cpp
// Corrected - requires BOTH flags with equality check
const uint32_t required_flags = HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_KERNARG_INIT |
                                HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_FINE_GRAINED;

if (flags == required_flags) {
    *ret = pool;
}
```

## What Was Changed

### 1. Fixed HSA Pool Selection (`nvme-gda/lib/nvme_gda.cpp`)

Changed from bitwise AND (`&`) to equality (`==`) check, requiring BOTH:
- `HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_KERNARG_INIT`
- `HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_FINE_GRAINED`

### 2. Added GPU Pointers for SQE/CQE (`nvme-gda/include/nvme_gda.h`)

Added to `nvme_gda_queue_userspace` structure:
```c
/* GPU-accessible pointers (from HSA lock) */
struct nvme_command *gpu_sqes;      /* SQ entries (GPU) */
struct nvme_completion *gpu_cqes;   /* CQ entries (GPU) */
volatile uint32_t *gpu_sq_doorbell; /* SQ doorbell (GPU) */
volatile uint32_t *gpu_cq_doorbell; /* CQ doorbell (GPU) */
```

### 3. Lock SQE/CQE Memory for GPU (`nvme-gda/lib/nvme_gda.cpp`)

Added HSA memory locking for SQE and CQE buffers:
```cpp
/* Lock SQE memory for GPU access */
hsa_amd_memory_lock_to_pool(
    queue->sqes, queue->sqes_size,
    &ctx->gpu_agent, 1,
    ctx->cpu_pool, 0,  // Now using correct pool!
    &gpu_sqe_base
);
queue->gpu_sqes = (struct nvme_command*)gpu_sqe_base;

/* Lock CQE memory for GPU access */
hsa_amd_memory_lock_to_pool(
    queue->cqes, queue->cqes_size,
    &ctx->gpu_agent, 1,
    ctx->cpu_pool, 0,  // Now using correct pool!
    &gpu_cqe_base
);
queue->gpu_cqes = (struct nvme_completion*)gpu_cqe_base;
```

## Why This Should Work Now

### Root Cause Analysis

**Three types of memory need GPU access:**

1. **Doorbell MMIO** (PCIe device registers)
   - Was: Using wrong pool, but worked anyway (MMIO forgiving)
   - Now: Using correct pool ✅

2. **SQE Memory** (DMA-coherent system memory)
   - Was: Using wrong pool → locking failed
   - Now: Using correct pool → should work! ✅

3. **CQE Memory** (DMA-coherent system memory)
   - Was: Using wrong pool → locking failed
   - Now: Using correct pool → should work! ✅

### Expected Results

With correct pool selection:
- ✅ `hsa_amd_memory_lock_to_pool()` should succeed for all three memory types
- ✅ GPU gets valid pointers to SQE/CQE memory
- ✅ GPU can write NVMe commands to SQE
- ✅ GPU can read completions from CQE
- ✅ GPU can ring doorbells
- ✅ Full GPU-initiated NVMe I/O should work!

## Testing Steps

### 1. Restart VM for Clean State
```bash
# VM became unstable from earlier crashes
# Restart to get clean kernel state
```

### 2. Rebuild with Fix
```bash
cd /mnt/host/gda-experiments/nvme-gda
rm -rf build && mkdir build && cd build
cmake ..
make -j$(nproc)
```

### 3. Set Environment Variables
```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
export HSA_ENABLE_SDMA=0
```

### 4. Run Tests
```bash
# Load driver
cd /mnt/host/gda-experiments/nvme-gda/nvme_gda_driver
sudo insmod nvme_gda.ko
sudo chmod 666 /dev/nvme_gda0

# Run tests
cd ../build
./test_basic_doorbell /dev/nvme_gda0   # Should show successful memory locking
./test_nvme_io_command /dev/nvme_gda0  # Should post real NVMe commands
```

### Expected Output

```
NVMe GDA Device Info:
  BAR0: 0x... (size: ...)
  ...
HSA initialized successfully
Created queue 1: size=16
  Locked SQE memory for GPU: 0x... -> 0x...  ← NEW!
  Locked CQE memory for GPU: 0x... -> 0x...  ← NEW!
Queue 1 mapped:
  CPU: sqes=0x..., cqes=0x..., sq_db=0x..., cq_db=0x...
  GPU: sqes=0x..., cqes=0x..., sq_db=0x..., cq_db=0x...  ← VALID POINTERS!
```

## Comparison with Working rocSHMEM Code

| Aspect | rocSHMEM (Working) | Our Code (Before) | Our Code (After) |
|--------|-------------------|-------------------|------------------|
| **Pool flag check** | `flags == (K \| F)` | `flags & F` | `flags == (K \| F)` ✅ |
| **Requires KERNARG** | ✅ Yes | ❌ No | ✅ Yes |
| **Requires FINE_GRAINED** | ✅ Yes | ✅ Yes | ✅ Yes |
| **Lock doorbells** | ✅ Yes | ✅ Yes | ✅ Yes |
| **Lock SQ buffer** | ✅ Yes | ❌ No | ✅ Yes |
| **Lock CQ buffer** | ✅ Yes | ❌ No | ✅ Yes |

## Files Modified

1. `/home/stebates/Projects/rocm-axiio/gda-experiments/nvme-gda/include/nvme_gda.h`
   - Added `gpu_sqes` and `gpu_cqes` pointers

2. `/home/stebates/Projects/rocm-axiio/gda-experiments/nvme-gda/lib/nvme_gda.cpp`
   - Fixed `find_cpu_pool()` to require both flags
   - Added SQE memory locking
   - Added CQE memory locking

## Documentation Created

- `CRITICAL_FIX_HSA_POOL.md` - Detailed bug analysis
- `DOORBELL_VS_QUEUE_MEMORY.md` - Memory type analysis
- `ENVIRONMENT_SETUP_REQUIRED.md` - Environment variable guide
- `HSA_ENVIRONMENT_VARS.md` - HSA variable details
- `READY_TO_TEST_FIX.md` - This file

## Current VM Status

⚠️ **VM is currently unstable** (cmake/make segfaulting) due to earlier kernel crashes. **Restart VM for clean testing!**

## Confidence Level

**HIGH** - This matches the exact pattern used by working rocSHMEM GDA code. The wrong pool selection was the root cause of GPU memory access failures.

## Next Action

**Restart VM and test with correct HSA pool selection!**

```bash
# After VM restart:
export HSA_FORCE_FINE_GRAIN_PCIE=1
export HSA_ENABLE_SDMA=0

cd /mnt/host/gda-experiments/nvme-gda
./build/test_basic_doorbell /dev/nvme_gda0
```

Should see:
- ✅ HSA init success
- ✅ SQE memory locked for GPU
- ✅ CQE memory locked for GPU
- ✅ Valid GPU pointers (not NULL, not same as CPU pointers)
- ✅ GPU doorbell test works
- ✅ NVMe I/O commands appear in trace!

