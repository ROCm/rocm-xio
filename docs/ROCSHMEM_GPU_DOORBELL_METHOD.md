# rocSHMEM GPU Doorbell Method - Key Insights

## Discovery from rocSHMEM GDA Code

After analyzing the rocSHMEM GDA (GPU Direct Acceleration) implementation, here's the key insight:

### The Secret: No HSA Lock Needed!

**The doorbell pointer from mmap() can be used DIRECTLY from GPU kernels!**

```cpp
// From rocSHMEM mlx5/queue_pair_mlx5.cpp
__device__ void QueuePair::mlx5_ring_doorbell(uint64_t db_val, uint64_t my_sq_counter) {
  __hip_atomic_store(db.ptr, db_val, __ATOMIC_SEQ_CST, __HIP_MEMORY_SCOPE_SYSTEM);
}
```

Where `db.ptr` is a `uint64_t*` that comes from:
- `struct mlx5dv_qp` has a `bf.reg` field (BlueFlame register = doorbell)
- This pointer is created by ibverbs via `mmap()` of the NIC's PCIe BAR
- **No `hsa_amd_memory_lock()`** needed
- **No KFD IOCTL** needed
-  **No special GPU mapping** needed

### Why It Works

1. **Unified Virtual Address Space**: On AMD GPUs with large BAR support, the GPU shares the same virtual address space as the CPU

2. **System-Scope Atomics**: The key is using `__HIP_MEMORY_SCOPE_SYSTEM` which:
   - Forces the GPU to go through the system interconnect  
   - Routes the write to the PCIe device (NVMe controller)
   - Does NOT need the memory to be in GPU's page tables!

3. **PCIe Peer-to-Peer**: The AMD GPU can write to other PCIe devices' MMIO space when:
   - Using system-scope memory operations
   - PCIe atomics are enabled (which we have!)
   - The address is in the CPU's virtual address space

### What We Need To Change

Instead of trying to use `hsa_amd_memory_lock()` or KFD IOCTLs, we should:

1. Use the CPU-mapped doorbell pointer from `/dev/mem` or kernel module
2. Pass this pointer DIRECTLY to the GPU kernel
3. Use `__hip_atomic_store()` with `__HIP_MEMORY_SCOPE_SYSTEM`

```cpp
// In GPU kernel
__device__ void ring_nvme_doorbell(volatile uint32_t* doorbell, uint32_t value) {
  __hip_atomic_store(doorbell, value, __ATOMIC_SEQ_CST, __HIP_MEMORY_SCOPE_SYSTEM);
  __threadfence_system();
}
```

### Architecture

```
CPU Process:
  1. mmap() doorbell via /dev/mem or kernel module
  2. Get virtual address ptr (e.g., 0x7f4df695d1f8)
  3. Pass ptr directly to GPU kernel

GPU Kernel:
  4. Write to ptr with __HIP_MEMORY_SCOPE_SYSTEM
  5. AMD GPU routes write through PCIe to NVMe controller
  6. NVMe controller sees doorbell ring!
```

### Key Requirements

- ✅ PCIe Atomics enabled (we have this!)
- ✅ Large BAR or resizable BAR (modern AMD GPUs)
- ✅ Unified virtual address space (ROCm provides this)
- ✅ System-scope atomic operations

### References

- `rocSHMEM/src/gda/mlx5/queue_pair_mlx5.cpp` - Shows doorbell ringing
- `rocSHMEM/src/gda/mlx5/mlx5dv.h` - Shows `bf.reg` doorbell pointer structure
- MLX5 uses this exact pattern for InfiniBand NIC doorbells
- **We should use the same pattern for NVMe doorbells!**

## Implementation Plan

1. ✅ Remove all HSA/KFD doorbell mapping code
2. ✅ Use CPU-mapped doorbell pointer directly
3. ✅ Update GPU kernel to use `__hip_atomic_store()` with `__HIP_MEMORY_SCOPE_SYSTEM`
4. ✅ Test on real hardware

This is the AMD-approved method for GPU-direct I/O!

