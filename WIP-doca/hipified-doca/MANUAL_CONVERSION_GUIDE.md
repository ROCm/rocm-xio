# Manual Conversion Guide: DOCA → AMD RADAKI

This guide provides specific examples for manually converting the remaining CUDA-specific code to AMD-compatible HIP code.

---

## Quick Reference: CUDA → HIP Conversions

| CUDA Construct | HIP/AMD Equivalent | Difficulty |
|----------------|-------------------|------------|
| `__ldg(ptr)` | `*ptr` or `*(volatile T*)ptr` | Easy |
| `cuda::atomic_ref<T, scope>` | `std::atomic_ref<T>` | Medium |
| `cuda::memory_order_*` | `std::memory_order_*` | Easy |
| `cuda::thread_scope_*` | C++ atomics (no direct scope) | Medium |
| PTX `asm volatile` | GCN asm or HIP built-ins | Hard |
| `__syncwarp()` | `__syncthreads()` (if in wavefront) | Easy |

---

## Example 1: Remove __ldg (Easy)

### Before (CUDA):
```cpp
__device__ static __forceinline__ struct doca_gpu_dev_verbs_wqe *
doca_gpu_dev_verbs_get_wqe_ptr(struct doca_gpu_dev_verbs_qp *qp, uint16_t wqe_idx) {
    const uint16_t nwqes_mask = __ldg(&qp->sq_wqe_mask);
    const uintptr_t wqe_addr = __ldg((uintptr_t *)&qp->sq_wqe_daddr);
    const uint16_t idx = wqe_idx & nwqes_mask;
    return (struct doca_gpu_dev_verbs_wqe *)(wqe_addr + 
                                             (idx << DOCA_GPUNETIO_IB_MLX5_WQE_SQ_SHIFT));
}
```

### After (HIP - Option 1: Direct access):
```cpp
__device__ static __forceinline__ struct radaki_dev_wqe *
radaki_dev_get_wqe_ptr(struct radaki_dev_qp *qp, uint16_t wqe_idx) {
    const uint16_t nwqes_mask = qp->sq_wqe_mask;  // Removed __ldg
    const uintptr_t wqe_addr = qp->sq_wqe_daddr;  // Removed __ldg
    const uint16_t idx = wqe_idx & nwqes_mask;
    return (struct radaki_dev_wqe *)(wqe_addr + 
                                      (idx << RADAKI_IB_WQE_SQ_SHIFT));
}
```

### After (HIP - Option 2: Volatile if needed):
```cpp
__device__ static __forceinline__ struct radaki_dev_wqe *
radaki_dev_get_wqe_ptr(struct radaki_dev_qp *qp, uint16_t wqe_idx) {
    const uint16_t nwqes_mask = *(volatile uint16_t*)&qp->sq_wqe_mask;
    const uintptr_t wqe_addr = *(volatile uintptr_t*)&qp->sq_wqe_daddr;
    const uint16_t idx = wqe_idx & nwqes_mask;
    return (struct radaki_dev_wqe *)(wqe_addr + 
                                      (idx << RADAKI_IB_WQE_SQ_SHIFT));
}
```

**Note:** `__ldg` on NVIDIA is a read-only cache hint. On AMD, direct access is fine. Use volatile if you need to prevent optimization.

---

## Example 2: Convert CUDA Atomics (Medium)

### Before (CUDA):
```cpp
template <resource_sharing_mode>
__device__ static __forceinline__ void 
doca_gpu_dev_verbs_mark_wqes_ready(struct doca_gpu_dev_verbs_qp *qp, 
                                    uint64_t from_wqe_idx, uint64_t to_wqe_idx) {
    if (resource_sharing_mode == DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU) {
        doca_gpu_dev_verbs_fence_release<DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU>();
        cuda::atomic_ref<uint64_t, cuda::thread_scope_device> ready_index_aref(qp->sq_ready_index);
        while (ready_index_aref.load(cuda::memory_order_relaxed) != from_wqe_idx) continue;
        doca_gpu_dev_verbs_fence_acquire<DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU>();
        ready_index_aref.store(to_wqe_idx + 1, cuda::memory_order_relaxed);
    }
}
```

### After (HIP with std::atomic):
```cpp
template <radaki_resource_sharing_mode mode>
__device__ static __forceinline__ void 
radaki_dev_mark_wqes_ready(struct radaki_dev_qp *qp, 
                            uint64_t from_wqe_idx, uint64_t to_wqe_idx) {
    if (mode == RADAKI_SHARING_DEVICE) {
        __threadfence();  // Device-scope fence (release)
        
        std::atomic_ref<uint64_t> ready_index_aref(qp->sq_ready_index);
        while (ready_index_aref.load(std::memory_order_relaxed) != from_wqe_idx) 
            continue;
        
        __threadfence();  // Device-scope fence (acquire)
        ready_index_aref.store(to_wqe_idx + 1, std::memory_order_relaxed);
    }
}
```

### After (HIP with atomics - alternative):
```cpp
template <radaki_resource_sharing_mode mode>
__device__ static __forceinline__ void 
radaki_dev_mark_wqes_ready(struct radaki_dev_qp *qp, 
                            uint64_t from_wqe_idx, uint64_t to_wqe_idx) {
    if (mode == RADAKI_SHARING_DEVICE) {
        __threadfence();
        
        // Spin until our turn
        uint64_t current;
        do {
            current = atomicAdd((unsigned long long*)&qp->sq_ready_index, 0ULL);
        } while (current != from_wqe_idx);
        
        __threadfence();
        atomicExch((unsigned long long*)&qp->sq_ready_index, to_wqe_idx + 1);
    }
}
```

**Scope Mapping:**
- `cuda::thread_scope_block` → Use `__threadfence_block()` + `std::atomic_ref`
- `cuda::thread_scope_device` → Use `__threadfence()` + `std::atomic_ref`
- `cuda::thread_scope_system` → Use `__threadfence_system()` + `std::atomic_ref`

---

## Example 3: Replace PTX Assembly (Hard)

### Before (CUDA - WQE Store):
```cpp
__device__ static __forceinline__ void 
doca_gpu_dev_verbs_store_wqe_seg(uint64_t *ptr, uint64_t *val) {
    asm volatile("st.weak.cs.v2.b64 [%0], {%1, %2};" 
                 : : "l"(ptr), "l"(val[0]), "l"(val[1]));
}
```

**PTX Analysis:**
- `st.weak.cs.v2.b64` = Store 2x 64-bit values (128 bits total)
- `.weak` = Weak ordering (can be reordered)
- `.cs` = Cache streaming hint
- `.v2` = Vector of 2 elements

### After (HIP - Option 1: Simple stores):
```cpp
__device__ static __forceinline__ void 
radaki_dev_store_wqe_seg(uint64_t *ptr, uint64_t *val) {
    // AMD: Simple stores with fence if needed
    *(volatile uint64_t*)ptr = val[0];
    *((volatile uint64_t*)ptr + 1) = val[1];
}
```

### After (HIP - Option 2: Non-temporal stores):
```cpp
__device__ static __forceinline__ void 
radaki_dev_store_wqe_seg(uint64_t *ptr, uint64_t *val) {
    // AMD: Non-temporal stores (bypass cache like .cs)
    #if defined(__HIP_PLATFORM_AMD__)
        __builtin_nontemporal_store(val[0], ptr);
        __builtin_nontemporal_store(val[1], ptr + 1);
    #else
        *(volatile uint64_t*)ptr = val[0];
        *((volatile uint64_t*)ptr + 1) = val[1];
    #endif
}
```

### After (HIP - Option 3: Inline assembly for AMD):
```cpp
__device__ static __forceinline__ void 
radaki_dev_store_wqe_seg(uint64_t *ptr, uint64_t *val) {
    #if defined(__HIP_PLATFORM_AMD__)
        // AMD GCN/CDNA assembly (example - verify instruction)
        __asm__ __volatile__(
            "flat_store_dwordx2 %0, %1\n\t"
            "flat_store_dwordx2 %2, %3"
            : 
            : "v"(ptr), "v"(val[0]), "v"(ptr+1), "v"(val[1])
            : "memory"
        );
    #else
        *(volatile uint64_t*)ptr = val[0];
        *((volatile uint64_t*)ptr + 1) = val[1];
    #endif
}
```

---

### Before (CUDA - Byte Swap):
```cpp
__device__ static __forceinline__ __be32 
doca_gpu_dev_verbs_prepare_dbr(uint32_t prod_index) {
    __be32 dbrec_val;
    asm volatile(
        "{\n\t"
        ".reg .b32 mask1;\n\t"
        ".reg .b32 dbrec_head_16b;\n\t"
        ".reg .b32 ign;\n\t"
        ".reg .b32 mask2;\n\t"
        "mov.b32 mask1, 0xffff;\n\t"
        "mov.b32 mask2, 0x123;\n\t"
        "and.b32 dbrec_head_16b, %1, mask1;\n\t"
        "prmt.b32 %0, dbrec_head_16b, ign, mask2;\n\t"
        "}"
        : "=r"(dbrec_val)
        : "r"(prod_index));
    return dbrec_val;
}
```

**PTX Analysis:**
- Extracts lower 16 bits: `prod_index & 0xffff`
- Uses `prmt` (permute) to byte-swap

### After (HIP - Simple version):
```cpp
__device__ static __forceinline__ __be32 
radaki_dev_prepare_dbr(uint32_t prod_index) {
    // Extract lower 16 bits and byte-swap
    uint32_t val_16b = prod_index & 0xffff;
    __be32 dbrec_val = __builtin_bswap32(val_16b);
    return dbrec_val;
}
```

### After (HIP - Inline if needed):
```cpp
__device__ static __forceinline__ __be32 
radaki_dev_prepare_dbr(uint32_t prod_index) {
    uint16_t val_16b = (uint16_t)(prod_index & 0xffff);
    // Byte swap 16-bit value and place in 32-bit big-endian
    return (__be32)(__builtin_bswap16(val_16b) << 16);
}
```

---

### Before (CUDA - TMA Copy for BlueFlame):
```cpp
#ifdef DOCA_GPUNETIO_VERBS_HAS_TMA_COPY
template <sync_scope>
__device__ static __forceinline__ void 
doca_gpu_dev_verbs_ring_bf(struct doca_gpu_dev_verbs_qp *qp, 
                           struct doca_gpu_dev_verbs_wqe *wqe_ptr) {
    void *bf_ptr = (void *)__ldg((uintptr_t *)&qp->sq_db);
    uint64_t *wqe = (uint64_t *)wqe_ptr;
    
    doca_gpu_dev_verbs_fence_release<sync_scope>();
    asm volatile("cp.async.bulk.global.shared::cta.bulk_group [%0], [%1], 64;"
                 : : "l"(bf_ptr), "l"(*wqe));
}
#endif
```

**PTX Analysis:**
- `cp.async.bulk` = Hopper+ tensor memory accelerator
- Copies 64 bytes from shared memory to global (NIC BAR)
- BlueFlame: Write WQE directly to NIC for lowest latency

### After (HIP - Disable BlueFlame):
```cpp
// AMD: BlueFlame not supported, fall back to doorbell
template <radaki_sync_scope scope>
__device__ static __forceinline__ void 
radaki_dev_ring_bf(struct radaki_dev_qp *qp, 
                   struct radaki_dev_wqe *wqe_ptr) {
    // AMD GPUs don't have equivalent to BlueFlame/TMA
    // Fall back to regular doorbell ringing
    radaki_dev_ring_db<scope>(qp, prod_index);
}
```

### After (HIP - Memcpy alternative):
```cpp
template <radaki_sync_scope scope>
__device__ static __forceinline__ void 
radaki_dev_ring_bf(struct radaki_dev_qp *qp, 
                   struct radaki_dev_wqe *wqe_ptr) {
    void *bf_ptr = (void *)qp->sq_db;
    
    __threadfence();  // Ensure prior stores visible
    
    // Copy WQE to doorbell region (64 bytes)
    // AMD: Use vector loads/stores or loop
    uint64_t *wqe = (uint64_t *)wqe_ptr;
    uint64_t *db = (uint64_t *)bf_ptr;
    
    #pragma unroll
    for (int i = 0; i < 8; i++) {  // 64 bytes = 8x 8-byte stores
        db[i] = wqe[i];
    }
}
```

---

## Example 4: Memory Fences (Medium)

### Before (CUDA):
```cpp
template <doca_gpu_dev_verbs_sync_scope sync_scope>
__device__ static __forceinline__ void 
doca_gpu_dev_verbs_fence_release() {
    if (sync_scope == DOCA_GPUNETIO_VERBS_SYNC_SCOPE_CTA)
        __threadfence_block();
    else if (sync_scope == DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU)
        __threadfence();
    else if (sync_scope == DOCA_GPUNETIO_VERBS_SYNC_SCOPE_SYS)
        __threadfence_system();
}
```

### After (HIP - Same!):
```cpp
template <radaki_sync_scope scope>
__device__ static __forceinline__ void 
radaki_fence_release() {
    if (scope == RADAKI_SYNC_WORKGROUP)
        __threadfence_block();  // Same in HIP
    else if (scope == RADAKI_SYNC_DEVICE)
        __threadfence();        // Same in HIP
    else if (scope == RADAKI_SYNC_SYSTEM)
        __threadfence_system(); // Same in HIP
}
```

**Note:** Memory fence functions are identical in CUDA and HIP!

---

## Example 5: Warp Functions (Easy)

### Before (CUDA):
```cpp
__device__ static __forceinline__ unsigned int 
doca_gpu_dev_verbs_get_lane_id() {
    unsigned int lane_id;
    asm volatile("mov.u32 %0, %%laneid;" : "=r"(lane_id));
    return lane_id;
}
```

### After (HIP):
```cpp
__device__ static __forceinline__ unsigned int 
radaki_dev_get_lane_id() {
    // HIP has built-in
    return __lane_id();  // Returns lane within wavefront (0-63 on AMD)
}
```

**Note:** AMD wavefronts are 64-wide (vs. NVIDIA's 32-wide warps).

---

## Example 6: Atomic Operations (Medium)

### Before (CUDA - Atomic Add):
```cpp
template <typename T, resource_sharing_mode mode>
__device__ static __forceinline__ T 
doca_gpu_dev_verbs_atomic_add(T *addr, T value) {
    if (mode == DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_EXCLUSIVE) {
        T old = *addr;
        *addr = old + value;
        return old;
    } else {
        cuda::atomic_ref<T, cuda::thread_scope_device> aref(*addr);
        return aref.fetch_add(value, cuda::memory_order_relaxed);
    }
}
```

### After (HIP - Option 1: std::atomic):
```cpp
template <typename T, radaki_resource_sharing_mode mode>
__device__ static __forceinline__ T 
radaki_dev_atomic_add(T *addr, T value) {
    if (mode == RADAKI_SHARING_EXCLUSIVE) {
        T old = *addr;
        *addr = old + value;
        return old;
    } else {
        std::atomic_ref<T> aref(*addr);
        return aref.fetch_add(value, std::memory_order_relaxed);
    }
}
```

### After (HIP - Option 2: atomicAdd):
```cpp
template <typename T, radaki_resource_sharing_mode mode>
__device__ static __forceinline__ T 
radaki_dev_atomic_add(T *addr, T value) {
    if (mode == RADAKI_SHARING_EXCLUSIVE) {
        T old = *addr;
        *addr = old + value;
        return old;
    } else {
        // Use HIP atomic built-ins
        if constexpr (sizeof(T) == 4)
            return atomicAdd((unsigned int*)addr, (unsigned int)value);
        else if constexpr (sizeof(T) == 8)
            return atomicAdd((unsigned long long*)addr, (unsigned long long)value);
    }
}
```

---

## Example 7: Complete Function Conversion

### Before (CUDA - Submit via Doorbell):
```cpp
template <resource_sharing_mode, sync_scope, code_opt, qp_type>
__device__ static __forceinline__ void 
doca_gpu_dev_verbs_submit_db(struct doca_gpu_dev_verbs_qp *qp, uint64_t prod_index) {
    doca_gpu_dev_verbs_lock<resource_sharing_mode>(&qp->sq_lock);
    
    uint64_t old_prod_index = doca_gpu_dev_verbs_atomic_max<uint64_t, resource_sharing_mode, true>(
        &qp->sq_wqe_pi, prod_index);
    
    if (old_prod_index < prod_index) {
        doca_gpu_dev_verbs_ring_db<sync_scope, code_opt>(qp, prod_index);
        doca_priv_gpu_dev_verbs_update_dbr<qp_type>(qp, prod_index);
        doca_gpu_dev_verbs_ring_db<sync_scope, code_opt>(qp, prod_index);
    }
    
    doca_gpu_dev_verbs_unlock<resource_sharing_mode>(&qp->sq_lock);
}
```

### After (HIP - Fully converted):
```cpp
template <radaki_resource_sharing_mode mode, 
          radaki_sync_scope scope, 
          radaki_qp_type qp_type>
__device__ static __forceinline__ void 
radaki_dev_submit_db(struct radaki_dev_qp *qp, uint64_t prod_index) {
    // Lock QP for submission
    radaki_dev_lock<mode>(&qp->sq_lock);
    
    // Atomically update producer index
    uint64_t old_prod_index;
    if (mode == RADAKI_SHARING_EXCLUSIVE) {
        old_prod_index = qp->sq_wqe_pi;
        qp->sq_wqe_pi = (prod_index > old_prod_index) ? prod_index : old_prod_index;
    } else {
        old_prod_index = atomicMax((unsigned long long*)&qp->sq_wqe_pi, prod_index);
    }
    
    if (old_prod_index < prod_index) {
        // Ring doorbell to notify NIC
        radaki_dev_ring_db<scope>(qp, prod_index);
        
        // Update doorbell record
        radaki_dev_update_dbr<qp_type>(qp, prod_index);
        
        // Ring again (recovery path)
        radaki_dev_ring_db<scope>(qp, prod_index);
    }
    
    radaki_dev_unlock<mode>(&qp->sq_lock);
}
```

---

## Conversion Checklist

Use this checklist to track manual conversion progress:

### File: doca_gpunetio_dev_verbs_qp.hip.h
- [ ] Remove all `__ldg` calls (18 instances)
- [ ] Convert `cuda::atomic_ref` to `std::atomic_ref` (13 instances)
- [ ] Fix `#include <cuda/atomic>` → `#include <atomic>`
- [ ] Replace PTX in `doca_gpu_dev_verbs_store_wqe_seg()` (line 47)
- [ ] Replace PTX in `doca_gpu_dev_verbs_prepare_dbr()` (line 149)
- [ ] Replace PTX in `doca_gpu_dev_verbs_ring_bf()` (line 276)
- [ ] Verify all memory fence operations
- [ ] Test atomic operations
- [ ] Rename functions: `doca_*` → `radaki_*`
- [ ] Update structure names: `doca_gpu_dev_verbs_*` → `radaki_dev_*`

### File: doca_gpunetio_dev_verbs_onesided.hip.h
- [ ] Convert CUDA atomics
- [ ] Remove `__ldg` calls
- [ ] Verify PUT operations
- [ ] Verify signal operations
- [ ] Test wait operations
- [ ] Rename functions

### File: doca_gpunetio_dev_verbs_cq.hip.h
- [ ] Convert CUDA atomics in polling
- [ ] Remove `__ldg` calls
- [ ] Verify CQ operations
- [ ] Rename functions

### File: doca_gpunetio_dev_verbs_common.hip.h
- [ ] Convert atomic operations
- [ ] Verify fence operations
- [ ] Test lock/unlock
- [ ] Rename functions

### File: doca_gpunetio_dev_verbs_counter.hip.h
- [ ] Convert counter atomics
- [ ] Verify memory ordering
- [ ] Test counter operations
- [ ] Rename functions

### File: doca_gpunetio_host.hip.h
- [ ] Verify CUDA runtime calls → HIP runtime
- [ ] Test memory allocation
- [ ] Test QP export
- [ ] Rename functions

### File: doca_gpunetio_verbs_def.hip.h
- [ ] Verify enum values
- [ ] Update structure definitions
- [ ] Rename types

---

## Testing Strategy

For each converted function:

1. **Unit Test:**
   ```cpp
   __global__ void test_kernel() {
       // Test individual function
       radaki_dev_qp *qp = ...;
       radaki_dev_reserve_wqe_slots(qp, 1);
       // Verify result
   }
   ```

2. **Integration Test:**
   ```cpp
   __global__ void test_put_kernel() {
       // Test complete operation
       radaki_dev_qp *qp = ...;
       radaki_dev_put(qp, raddr, laddr, size, &ticket);
       radaki_dev_wait(qp, ticket);
   }
   ```

3. **Correctness:**
   - Use host-side verification
   - Compare results with CPU RDMA
   - Validate memory contents

4. **Performance:**
   - Benchmark latency
   - Measure bandwidth
   - Profile with rocprof

---

## Tools for Conversion

```bash
# Find all instances of a pattern
grep -rn "__ldg" *.hip.h

# Replace pattern (verify first!)
sed -i 's/__ldg(&\([^)]*\))/\1/g' *.hip.h

# Count CUDA-specific constructs
grep -c "cuda::" *.hip.h

# List PTX assembly
grep -n "asm volatile" *.hip.h
```

---

## Summary

**Easy conversions:**
- `__ldg` removal
- Memory fences (identical)
- Warp functions

**Medium conversions:**
- CUDA atomics → std::atomic or HIP atomics
- Memory ordering verification

**Hard conversions:**
- PTX assembly replacement
- BlueFlame alternative
- Performance optimization

**Estimated time:** 2-4 weeks for experienced developer

---

**Next:** Start with easy conversions, then tackle medium difficulty, save hard ones for last.
