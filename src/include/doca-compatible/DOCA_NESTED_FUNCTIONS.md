# DOCA Nested Functions (GIN / GDAKI)

These are **nested** DOCA/GPUNetIO functions: they are **not** called directly from NCCL GIN code. They are used only **inside** the DOCA device stack (onesided, QP, CQ, counter, common) or by other DOCA functions.

**Top-level functions** (called from NCCL) are listed in `DOCA_TOP_LEVEL_FUNCTIONS.md`.

---

## Verification: NCCL vs rocm-xio names

- **NCCL** = name as in `nccl/src/transport/net_ib/gdaki/doca-gpunetio/include/device/*.cuh` and `*.cuh` (common, qp, cq, onesided, counter).
- **rocm-xio** = name as in `rocm-xio/src/include/doca-compatible/*.hip.h` (and common).
- **Status:** **Same** = identical name; **Different** = rocm-xio uses `radaki_dev_*` (or other) mapping; **Disappeared** = in NCCL but not in rocm-xio.

---

## 1. Onesided – nested

| NCCL (doca_gpunetio_dev_verbs_onesided.cuh) | rocm-xio (doca_gpunetio_dev_verbs_onesided.hip.h) | Status |
|---------------------------------------------|---------------------------------------------------|--------|
| `doca_gpu_dev_verbs_put_thread` | `radaki_dev_put_thread` | Different |
| `doca_gpu_dev_verbs_put_warp` | `radaki_dev_put_warp` | Different |
| `doca_gpu_dev_verbs_put` (overloads) | `radaki_dev_put` | Different |
| `doca_gpu_dev_verbs_p_thread` | `radaki_dev_p_thread` | Different |
| `doca_gpu_dev_verbs_p_warp` | `radaki_dev_p_warp` | Different |
| `doca_gpu_dev_verbs_p` (overloads) | `radaki_dev_p` | Different |
| `doca_gpu_dev_verbs_put_signal_thread` | `radaki_dev_put_signal_thread` | Different |
| `doca_gpu_dev_verbs_put_signal_warp` | `radaki_dev_put_signal_warp` | Different |
| `doca_gpu_dev_verbs_put_signal` (overloads) | `radaki_dev_put_signal` | Different |
| `doca_gpu_dev_verbs_p_signal` (overloads) | `radaki_dev_p_signal` | Different |
| `doca_gpu_dev_verbs_signal_thread` | `radaki_dev_signal_thread` | Different |
| `doca_gpu_dev_verbs_signal_warp` | `radaki_dev_signal_warp` | Different |
| `doca_gpu_dev_verbs_signal` (overloads) | `radaki_dev_signal` | Different |
| `doca_gpu_dev_verbs_wait` (overloads) | `radaki_dev_wait` | Different |
| `doca_gpu_dev_verbs_fence` | `radaki_dev_fence` | Different (no-op in both) |

All onesided nested functions present in rocm-xio; all names **Different** (radaki_dev_*).

---

## 2. QP – nested

| NCCL (doca_gpunetio_dev_verbs_qp.cuh) | rocm-xio (doca_gpunetio_dev_verbs_qp.hip.h) | Status |
|---------------------------------------|---------------------------------------------|--------|
| `doca_gpu_dev_verbs_store_wqe_seg` | `radaki_dev_store_wqe_seg` | Different |
| `doca_gpu_dev_verbs_get_wqe_ptr` | `radaki_dev_get_wqe_ptr` | Different |
| `doca_gpu_dev_verbs_wait_until_slot_available` | `radaki_dev_wait_until_slot_available` | Different |
| `doca_gpu_dev_verbs_reserve_wq_slots` | `radaki_dev_reserve_wq_slots` | Different |
| `doca_gpu_dev_verbs_mark_wqes_ready` | `radaki_dev_mark_wqes_ready` | Different |
| `doca_gpu_dev_verbs_prepare_dbr` | `radaki_dev_prepare_dbr` | Different |
| `doca_priv_gpu_dev_verbs_update_dbr` | `doca_priv_gpu_dev_verbs_update_dbr` | **Same** |
| `doca_gpu_dev_verbs_update_dbr` | `radaki_dev_update_dbr` | Different |
| `doca_gpu_dev_verbs_prepare_db` | `radaki_dev_prepare_db` | Different |
| `doca_gpu_dev_verbs_ring_db` | `radaki_dev_ring_db` | Different |
| `doca_gpu_dev_verbs_ring_bf` | `radaki_dev_ring_bf` | Different |
| `doca_gpu_dev_verbs_ring_bf_warp` | `radaki_dev_ring_bf_warp` | Different |
| `doca_gpu_dev_verbs_ring_proxy` | `radaki_dev_ring_proxy` | Different |
| `doca_gpu_dev_verbs_submit_db` | `radaki_dev_submit_db` | Different |
| `doca_gpu_dev_verbs_submit_bf` | `radaki_dev_submit_bf` | Different |
| `doca_gpu_dev_verbs_submit_bf_warp` | `radaki_dev_submit_bf_warp` | Different |
| `doca_gpu_dev_verbs_submit_proxy` | `radaki_dev_submit_proxy` | Different |
| `doca_gpu_dev_verbs_submit` | `radaki_dev_submit` | Different |
| `doca_gpu_dev_verbs_wqe_prepare_nop` | `radaki_dev_wqe_prepare_nop` | Different |
| `doca_gpu_dev_verbs_wqe_prepare_write` (2 overloads) | `radaki_dev_wqe_prepare_write` | Different |
| `doca_gpu_dev_verbs_prepare_inl_rdma_write_wqe_header` | `radaki_dev_prepare_inl_rdma_write_wqe_header` | Different |
| `doca_gpu_dev_verbs_prepare_inl_rdma_write_wqe_data` | `radaki_dev_prepare_inl_rdma_write_wqe_data` | Different |
| `doca_gpu_dev_verbs_wqe_prepare_write_inl` | `radaki_dev_wqe_prepare_write_inl` | Different |
| `doca_gpu_dev_verbs_wqe_prepare_read` (2 overloads) | `radaki_dev_wqe_prepare_read` | Different |
| `doca_gpu_dev_verbs_wqe_prepare_atomic` | `radaki_dev_wqe_prepare_atomic` | Different |
| `doca_gpu_dev_verbs_wqe_prepare_wait` | `radaki_dev_wqe_prepare_wait` | Different |

All QP nested functions present in rocm-xio. Only **`doca_priv_gpu_dev_verbs_update_dbr`** is **Same**; all other QP names **Different** (radaki_dev_*).

---

## 3. CQ – nested

| NCCL (doca_gpunetio_dev_verbs_cq.cuh) | rocm-xio (doca_gpunetio_dev_verbs_cq.hip.h) | Status |
|---------------------------------------|---------------------------------------------|--------|
| `doca_gpu_dev_verbs_qp_get_cq_sq` | `radaki_dev_qp_get_cq_sq` | Different |
| `doca_gpu_dev_verbs_cqe_idx_inc_mask` | `radaki_dev_cqe_idx_inc_mask` | Different |
| `doca_gpu_dev_verbs_cq_print_cqe_err` | `radaki_dev_cq_print_cqe_err` | Different |
| `doca_priv_gpu_dev_verbs_poll_one_cq_at` | `doca_priv_gpu_dev_verbs_poll_one_cq_at` | **Same** |
| `doca_gpu_dev_verbs_poll_one_cq_at` | `radaki_dev_poll_one_cq_at` | Different |
| `doca_priv_gpu_dev_verbs_poll_cq_at` | `doca_priv_gpu_dev_verbs_poll_cq_at` | **Same** |
| `doca_gpu_dev_verbs_poll_cq_at` | `radaki_dev_poll_cq_at` | Different |
| `doca_gpu_dev_verbs_poll_cq` | `radaki_dev_poll_cq` | Different |
| `doca_gpu_dev_verbs_cq_update_dbrec` | `radaki_dev_cq_update_dbrec` | Different |

All CQ nested functions present in rocm-xio. **Same:** `doca_priv_gpu_dev_verbs_poll_one_cq_at`, `doca_priv_gpu_dev_verbs_poll_cq_at`. Rest **Different** (radaki_dev_*).

---

## 4. Counter – nested

| NCCL (doca_gpunetio_dev_verbs_counter.cuh) | rocm-xio (doca_gpunetio_dev_verbs_counter.hip.h) | Status |
|-------------------------------------------|--------------------------------------------------|--------|
| `doca_gpu_dev_verbs_submit_db_multi_qps` | `radaki_dev_submit_db_multi_qps` | Different |
| `doca_gpu_dev_verbs_submit_proxy_multi_qps` | `radaki_dev_submit_proxy_multi_qps` | Different |
| `doca_gpu_dev_verbs_submit_multi_qps` | `radaki_dev_submit_multi_qps` | Different |
| `doca_gpu_dev_verbs_put_counter` | `radaki_dev_put_counter` | Different |
| `doca_gpu_dev_verbs_p_counter` | `radaki_dev_p_counter` | Different |
| `doca_gpu_dev_verbs_put_signal_counter` | `radaki_dev_put_signal_counter` | Different |
| `doca_gpu_dev_verbs_signal_counter` | `radaki_dev_signal_counter` | Different |

All counter nested functions present in rocm-xio; all names **Different** (radaki_dev_*).

---

## 5. Common – nested

| NCCL (doca_gpunetio_dev_verbs_common.cuh) | rocm-xio (doca_gpunetio_dev_verbs_common.hip.h) | Status |
|------------------------------------------|-------------------------------------------------|--------|
| `doca_gpu_dev_verbs_query_globaltimer` | `radaki_dev_query_globaltimer` | Different |
| `doca_gpu_dev_verbs_get_lane_id` | `radaki_dev_get_lane_id` | Different |
| `doca_gpu_dev_verbs_bswap64` | `radaki_dev_bswap64` | Different |
| `doca_gpu_dev_verbs_bswap32` | `radaki_dev_bswap32` | Different |
| `doca_gpu_dev_verbs_bswap16` | `radaki_dev_bswap16` | Different |
| `doca_gpu_dev_verbs_store_relaxed_mmio` | `radaki_dev_store_relaxed_mmio` | Different |
| `doca_gpu_dev_verbs_fence_acquire` | `radaki_dev_fence_acquire` | Different |
| `doca_gpu_dev_verbs_fence_release` | `radaki_dev_fence_release` | Different |
| `doca_gpu_dev_verbs_async_store_release` (uint32/uint64) | `radaki_dev_async_store_release` | Different |
| `doca_gpu_dev_verbs_isaligned` | `radaki_dev_isaligned` | Different |
| `doca_gpu_dev_verbs_memcpy_aligned_data` | `radaki_dev_memcpy_aligned_data` | Different |
| `doca_gpu_dev_verbs_memcpy_data` | `radaki_dev_memcpy_data` | Different |
| `doca_gpu_dev_verbs_memcpy_inl_aligned_data` | `radaki_dev_memcpy_inl_aligned_data` | Different |
| `doca_gpu_dev_verbs_atomic_max` | `radaki_dev_atomic_max` | Different |
| `doca_gpu_dev_verbs_atomic_add` | `radaki_dev_atomic_add` | Different |
| `doca_gpu_dev_verbs_atomic_read` | `radaki_dev_atomic_read` | Different |
| `doca_gpu_dev_verbs_lock` | `radaki_dev_lock` | Different |
| `doca_gpu_dev_verbs_unlock` | `radaki_dev_unlock` | Different |
| `doca_gpu_dev_verbs_load_relaxed_sys_global` (u8/u32/u64) | `radaki_dev_load_relaxed_sys_global` | Different |
| `doca_gpu_dev_verbs_load_relaxed` | `radaki_dev_load_relaxed` | Different |
| `doca_gpu_dev_verbs_div_ceil_aligned_pow2` | `radaki_dev_div_ceil_aligned_pow2` | Different |
| `doca_gpu_dev_verbs_div_ceil_aligned_pow2_32bits` | `radaki_dev_div_ceil_aligned_pow2_32bits` | Different |

All common nested functions present in rocm-xio; all names **Different** (radaki_dev_*).  
*(prepare_inl_rdma_write_wqe_data template lives in QP in both; listed under QP above.)*

---

## 6. HIP atomics (doca_hip_atomic)

| NCCL | rocm-xio (doca_hip_atomic.hip.h) | Status |
|------|----------------------------------|--------|
| *(NCCL uses CUDA atomics; no doca_hip_* in NCCL)* | `doca_hip_atomic_cas_block` | rocm-xio only (HIP replacement) |
| *(NCCL uses CUDA atomics)* | `doca_hip_atomic_cas` | rocm-xio only (HIP replacement) |

**Same** in the sense that these are the HIP-side names; NCCL has no equivalent symbol (uses CUDA `atomicCAS` etc.).

---

## Summary

- **Onesided:** 15 nested; all present in rocm-xio, all **Different** (radaki_dev_*).
- **QP:** 26 nested; all present; **Same** only `doca_priv_gpu_dev_verbs_update_dbr`; rest **Different**.
- **CQ:** 9 nested; all present; **Same** only the two `doca_priv_gpu_dev_verbs_poll_*_cq_at`; rest **Different**.
- **Counter:** 7 nested; all present; all **Different**.
- **Common:** 22 nested; all present; all **Different**.
- **doca_hip_atomic:** 2 functions; rocm-xio only (no NCCL counterpart).

**Disappeared:** No nested device function that exists in NCCL doca-gpunetio device headers is missing from rocm-xio. The only **disappeared** items in this stack are the **host** high-level QP APIs (create/destroy_qp_hl, create/destroy_qp_group_hl), which are listed in `DOCA_TOP_LEVEL_FUNCTIONS.md`.
