# DOCA Top-Level Functions (GIN / GDAKI)

These are the **top-level** DOCA/GPUNetIO functions that are **called directly from NCCL GIN code** (not from other DOCA code). They form the public API boundary between the NCCL GIN GDAKI path and the DOCA GPUNetIO stack.

**References:** NCCL GIN uses DOCA GPUNetIO for GPU-Initiated Networking (GIN). Call sites are in:
- **Host:** `nccl/src/transport/net_ib/gdaki/gin_host_gdaki.cc`
- **Device:** `nccl/src/include/nccl_device/gin/gdaki/gin_gdaki.h`

---

## Verification: NCCL vs rocm-xio names

Below, **NCCL** = name as used in the NCCL repo; **rocm-xio** = name as it appears in `rocm-xio/src/include/doca-compatible/` (and `common/`). **Status:** Same = identical name; **Different** = rocm-xio uses a different name (mapping given); **Disappeared** = present in NCCL call sites but not declared in rocm-xio hipified headers.

---

### Host-side (CPU)

| NCCL (gin_host_gdaki.cc) | rocm-xio (doca_gpunetio_host.hip.h) | Status |
|--------------------------|--------------------------------------|--------|
| `doca_gpu_create` | `doca_gpu_create` | **Same** |
| `doca_gpu_destroy` | `doca_gpu_destroy` | **Same** |
| `doca_gpu_mem_alloc` | `doca_gpu_mem_alloc` | **Same** |
| `doca_gpu_mem_free` | `doca_gpu_mem_free` | **Same** |
| `doca_gpu_verbs_create_qp_group_hl` | *(not declared in doca-compatible)* | **Disappeared** – not in rocm-xio host header; lives in NCCL high-level API only |
| `doca_gpu_verbs_destroy_qp_group_hl` | *(not declared in doca-compatible)* | **Disappeared** |
| `doca_gpu_verbs_create_qp_hl` | *(not declared in doca-compatible)* | **Disappeared** |
| `doca_gpu_verbs_destroy_qp_hl` | *(not declared in doca-compatible)* | **Disappeared** |
| `doca_gpu_verbs_cpu_proxy_progress` | `doca_gpu_verbs_cpu_proxy_progress` | **Same** |
| `doca_gpu_verbs_query_last_error` | `doca_gpu_verbs_query_last_error` | **Same** |

**Note:** `gin_host_gdaki.cc` also calls **doca_verbs** APIs (`doca_verbs_ah_attr_*`, `doca_verbs_qp_attr_*`, `doca_verbs_qp_get_qpn`, `doca_verbs_qp_modify`). Those are in the NCCL doca-gpunetio host submodule, not in rocm-xio `doca-compatible`.

---

### Device-side (GPU)

NCCL uses `doca_gpu_dev_verbs_*` in `gin_gdaki.h`. rocm-xio device headers use **`radaki_dev_*`** for the same APIs (hipified/renamed).

| NCCL (gin_gdaki.h) | rocm-xio (doca-compatible *.hip.h) | Status |
|--------------------|-------------------------------------|--------|
| `doca_gpu_dev_verbs_put` | `radaki_dev_put` | **Different** |
| `doca_gpu_dev_verbs_put_signal` | `radaki_dev_put_signal` | **Different** |
| `doca_gpu_dev_verbs_put_counter` | `radaki_dev_put_counter` | **Different** |
| `doca_gpu_dev_verbs_put_signal_counter` | `radaki_dev_put_signal_counter` | **Different** |
| `doca_gpu_dev_verbs_signal` | `radaki_dev_signal` | **Different** |
| `doca_gpu_dev_verbs_signal_counter` | `radaki_dev_signal_counter` | **Different** |
| `doca_gpu_dev_verbs_p` | `radaki_dev_p` | **Different** |
| `doca_gpu_dev_verbs_p_signal` | `radaki_dev_p_signal` | **Different** |
| `doca_gpu_dev_verbs_fence_release` | `radaki_dev_fence_release` | **Different** (in common.hip.h) |
| `doca_gpu_dev_verbs_wait` | `radaki_dev_wait` | **Different** |

All 10 device top-level functions exist in rocm-xio under the **`radaki_dev_*`** names; none have disappeared.

---

## Host-side (CPU) – purpose summary

| DOCA function | Purpose |
|---------------|--------|
| `doca_gpu_create` | Create DOCA GPU device handle from PCI bus ID |
| `doca_gpu_destroy` | Destroy DOCA GPU device handle |
| `doca_gpu_mem_alloc` | Allocate GPU (or GPU/CPU) memory for QP/context structures |
| `doca_gpu_mem_free` | Free memory allocated with `doca_gpu_mem_alloc` |
| `doca_gpu_verbs_create_qp_group_hl` | Create high-level QP group (main + companion QP) – *not in rocm-xio host header* |
| `doca_gpu_verbs_destroy_qp_group_hl` | Destroy high-level QP group – *not in rocm-xio host header* |
| `doca_gpu_verbs_create_qp_hl` | Create single high-level QP (e.g. self-loop) – *not in rocm-xio host header* |
| `doca_gpu_verbs_destroy_qp_hl` | Destroy single high-level QP – *not in rocm-xio host header* |
| `doca_gpu_verbs_cpu_proxy_progress` | Advance CPU proxy for QPs using proxy NIC handler |
| `doca_gpu_verbs_query_last_error` | Query last error on a QP (for error reporting) |

---

## Device-side (GPU) – purpose summary

| DOCA name (NCCL) | rocm-xio name | Purpose |
|------------------|---------------|--------|
| `doca_gpu_dev_verbs_put` | `radaki_dev_put` | RDMA put (block transfer) to remote memory |
| `doca_gpu_dev_verbs_put_signal` | `radaki_dev_put_signal` | Put + remote atomic signal |
| `doca_gpu_dev_verbs_put_counter` | `radaki_dev_put_counter` | Put + companion QP counter update |
| `doca_gpu_dev_verbs_put_signal_counter` | `radaki_dev_put_signal_counter` | Put + signal + counter |
| `doca_gpu_dev_verbs_signal` | `radaki_dev_signal` | Signal-only (remote atomic) |
| `doca_gpu_dev_verbs_signal_counter` | `radaki_dev_signal_counter` | Signal + counter on companion QP |
| `doca_gpu_dev_verbs_p` | `radaki_dev_p` | Put single value (inline RDMA write) |
| `doca_gpu_dev_verbs_p_signal` | `radaki_dev_p_signal` | Put value + signal |
| `doca_gpu_dev_verbs_fence_release` | `radaki_dev_fence_release` | Release fence (sync scope) before doorbell/signal |
| `doca_gpu_dev_verbs_wait` | `radaki_dev_wait` | Wait for completion (poll CQ) for a QP |

---

## Summary

- **Host:** 6 names are **same** in rocm-xio; 4 (**create/destroy_qp_group_hl**, **create/destroy_qp_hl**) are **disappeared** in rocm-xio (not declared in `doca_gpunetio_host.hip.h`; they exist only in the NCCL high-level API).
- **Device:** All 10 top-level functions are present in rocm-xio with **different** names: `doca_gpu_dev_verbs_*` → `radaki_dev_*`.

All other DOCA/radaki functions in the hipified headers are **nested**; see `DOCA_NESTED_FUNCTIONS.md`.
