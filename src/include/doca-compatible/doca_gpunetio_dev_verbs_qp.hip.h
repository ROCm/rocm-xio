#include "hip/hip_runtime.h"
/*
 * SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 * list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/**
 * @file doca_gpunetio_dev_verbs_qp.cuh
 * @brief GDAKI CUDA device functions for QP management
 *
 * @{
 */
#ifndef DOCA_GPUNETIO_DEV_VERBS_QP_H
#define DOCA_GPUNETIO_DEV_VERBS_QP_H

#if defined(__clang__) || defined(__HIPCC__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wunneeded-internal-declaration"
#endif

#include <atomic>
#include <cassert>
#include "doca_hip_atomic.hip.h"
#include "doca_gpunetio_dev_verbs_cq.hip.h"

/* *********** WQE UTILS *********** */
__device__ static __forceinline__ void radaki_dev_store_wqe_seg(uint64_t *ptr,
                                                                        uint64_t *val) {
#ifdef __HIP_PLATFORM_AMD__
    __atomic_store_n(&ptr[0], val[0], __ATOMIC_RELEASE);
    __atomic_store_n(&ptr[1], val[1], __ATOMIC_RELEASE);
    __threadfence();
#else
    asm volatile("st.weak.cs.v2.b64 [%0], {%1, %2};" : : "l"(ptr), "l"(val[0]), "l"(val[1]));
#endif
}

/**
 * @brief Get a pointer to the WQE buffer at a specific index
 *
 * @param qp - Queue Pair (QP)
 * @param wqe_idx - Index of the WQE to get
 * @return Pointer to the WQE buffer at the specified index
 */
__device__ static __forceinline__ struct radaki_dev_wqe *radaki_dev_get_wqe_ptr(
    struct radaki_dev_qp *qp, uint16_t wqe_idx) {
    const uint16_t nwqes_mask = qp->sq_wqe_mask;
    const uintptr_t wqe_addr = __ldg((uintptr_t *)&qp->sq_wqe_daddr);
    const uint16_t idx = wqe_idx & nwqes_mask;
    return (struct radaki_dev_wqe *)(wqe_addr +
                                             (idx << DOCA_GPUNETIO_IB_MLX5_WQE_SQ_SHIFT));
}

/* *********** WQE SHARING *********** */

/**
 * @brief Wait until the given WQE slot is available.
 * All prior WQE slots are also guaranteed to be available.
 *
 * @param qp - Queue Pair (QP)
 * @param wqe_idx - WQE slot index
 */
template <enum radaki_dev_resource_sharing_mode resource_sharing_mode =
              DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_qp_type qp_type = DOCA_GPUNETIO_VERBS_QP_SQ>
__device__ static __forceinline__ void radaki_dev_wait_until_slot_available(
    struct radaki_dev_qp *qp, uint64_t wqe_idx) {
    const uint16_t nwqes = qp->sq_wqe_num;
    [[likely]] if (wqe_idx >= nwqes)
        radaki_dev_poll_cq_at<resource_sharing_mode, qp_type>(&(qp->cq_sq),
                                                                      wqe_idx - nwqes);
}

/**
 * @brief Reserve a number of WQE slots.
 *
 * @param qp - Queue Pair (QP)
 * @param count - Number of WQE slots to reserve
 * @return The index of the first reserved WQE slot
 */
template <enum radaki_dev_resource_sharing_mode resource_sharing_mode =
              DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_qp_type qp_type = DOCA_GPUNETIO_VERBS_QP_SQ,
          bool wait_for_availability = true>
__device__ static __forceinline__ uint64_t
radaki_dev_reserve_wq_slots(struct radaki_dev_qp *qp, uint32_t count) {
    uint64_t wqe_idx =
        radaki_dev_atomic_add<uint64_t, resource_sharing_mode>(&qp->sq_rsvd_index, count);
    if (wait_for_availability)
        radaki_dev_wait_until_slot_available<resource_sharing_mode>(qp,
                                                                            wqe_idx + count - 1);
    return wqe_idx;
}

/**
 * @brief Mark the WQEs in the range [from_wqe_idx, to_wqe_idx] as ready.
 *
 * @param qp - Queue Pair (QP)
 * @param from_wqe_idx - Starting WQE index
 * @param to_wqe_idx - Ending WQE index
 */
template <enum radaki_dev_resource_sharing_mode resource_sharing_mode =
              DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_qp_type qp_type = DOCA_GPUNETIO_VERBS_QP_SQ>
__device__ static __forceinline__ void radaki_dev_mark_wqes_ready(
    struct radaki_dev_qp *qp, uint64_t from_wqe_idx, uint64_t to_wqe_idx) {
    if (resource_sharing_mode == DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_EXCLUSIVE)
        qp->sq_ready_index = to_wqe_idx + 1;
    else if (resource_sharing_mode == DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_CTA) {
        radaki_dev_fence_release<DOCA_GPUNETIO_VERBS_SYNC_SCOPE_CTA>();
        doca_hip::atomic_ref<uint64_t, doca_hip::thread_scope_block> ready_index_aref(qp->sq_ready_index);
        while (ready_index_aref.load(doca_hip::memory_order_relaxed) != from_wqe_idx) continue;
        radaki_dev_fence_acquire<DOCA_GPUNETIO_VERBS_SYNC_SCOPE_CTA>();
        ready_index_aref.store(to_wqe_idx + 1, doca_hip::memory_order_relaxed);
    } else if (resource_sharing_mode == DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU) {
        radaki_dev_fence_release<DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU>();
        doca_hip::atomic_ref<uint64_t, doca_hip::thread_scope_device> ready_index_aref(qp->sq_ready_index);
        while (ready_index_aref.load(doca_hip::memory_order_relaxed) != from_wqe_idx) continue;
        radaki_dev_fence_acquire<DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU>();
        ready_index_aref.store(to_wqe_idx + 1, doca_hip::memory_order_relaxed);
    }
}

/* *********** QP DBR/DB *********** */

/**
 * @brief Prepare the DBR (Doorbell Record)
 *
 * @param prod_index - Producer index
 * @return DBR value
 */
__device__ static __forceinline__ __be32 radaki_dev_prepare_dbr(uint32_t prod_index) {
    __be32 dbrec_val;

    // This is equivalent to
    // HTOBE32(dbrec_head & 0xffff);
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

/**
 * @brief [Internal] Update the NIC DBR (Doorbell Record).
 * This function does not guarantee the ordering.
 *
 * @param qp - Queue Pair (QP)
 * @param prod_index - Producer index
 */
template <enum radaki_dev_qp_type qp_type = DOCA_GPUNETIO_VERBS_QP_SQ>
__device__ static __forceinline__ void doca_priv_gpu_dev_verbs_update_dbr(
    struct radaki_dev_qp *qp, uint32_t prod_index) {
    __be32 dbrec_val = radaki_dev_prepare_dbr(prod_index);
    __be32 *dbrec_ptr = (__be32 *)__ldg((uintptr_t *)&qp->sq_dbrec);

    doca_hip::atomic_ref<__be32, doca_hip::thread_scope_system> dbrec_ptr_aref(*dbrec_ptr);
    dbrec_ptr_aref.store(dbrec_val, doca_hip::memory_order_relaxed);
}

/**
 * @brief Update the NIC DBR (Doorbell Record)
 *
 * @param qp - Queue Pair (QP)
 * @param prod_index - Producer index
 */
template <enum radaki_dev_sync_scope sync_scope = DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU,
          enum radaki_dev_gpu_code_opt code_opt = DOCA_GPUNETIO_VERBS_GPU_CODE_OPT_DEFAULT,
          enum radaki_dev_qp_type qp_type = DOCA_GPUNETIO_VERBS_QP_SQ>
__device__ static __forceinline__ void radaki_dev_update_dbr(
    struct radaki_dev_qp *qp, uint32_t prod_index) {
    __be32 dbrec_val = radaki_dev_prepare_dbr(prod_index);
    __be32 *dbrec_ptr = (__be32 *)__ldg((uintptr_t *)&qp->sq_dbrec);

#ifdef DOCA_GPUNETIO_VERBS_HAS_ASYNC_STORE_RELEASE
    if (code_opt & DOCA_GPUNETIO_VERBS_GPU_CODE_OPT_ASYNC_STORE_RELEASE) {
        radaki_dev_async_store_release<sync_scope>(dbrec_ptr, dbrec_val);
    } else
#endif
    {
        (void)dbrec_val;
        (void)dbrec_ptr;
        radaki_dev_fence_release<sync_scope>();
        doca_priv_gpu_dev_verbs_update_dbr<qp_type>(qp, prod_index);
    }
}

/**
 * @brief Prepare the DB (Doorbell)
 *
 * @param qp - Queue Pair (QP)
 * @param prod_index - Producer index
 * @return DB value
 */
__device__ static __forceinline__ __be64
radaki_dev_prepare_db(struct radaki_dev_qp *qp, uint64_t prod_index) {
    struct radaki_dev_wqe_ctrl_seg ctrl_seg = {};

    // The only ctrl segment fields that are inspected while ringing
    // the DB are QP number and WQE index
    ctrl_seg.qpn_ds = qp->sq_num_shift8_be;
    ctrl_seg.opmod_idx_opcode =
        radaki_dev_bswap32((prod_index << DOCA_GPUNETIO_VERBS_WQE_IDX_SHIFT));

    return *(uint64_t *)&ctrl_seg;
}

/* *************************** Ring Doorbell *************************** */

/**
 * @brief Ring the DB (Doorbell)
 *
 * @param qp - Queue Pair (QP)
 * @param prod_index - Producer index
 */
template <enum radaki_dev_sync_scope sync_scope = DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU,
          enum radaki_dev_gpu_code_opt code_opt = DOCA_GPUNETIO_VERBS_GPU_CODE_OPT_DEFAULT>
__device__ static __forceinline__ void radaki_dev_ring_db(struct radaki_dev_qp *qp,
                                                                  uint64_t prod_index) {
    __be64 *db_ptr = (__be64 *)__ldg((uintptr_t *)&qp->sq_db);
    __be64 db_val = radaki_dev_prepare_db(qp, prod_index);

#ifdef DOCA_GPUNETIO_VERBS_HAS_ASYNC_STORE_RELEASE
    if (code_opt & DOCA_GPUNETIO_VERBS_GPU_CODE_OPT_ASYNC_STORE_RELEASE) {
        radaki_dev_async_store_release<sync_scope>((uint64_t *)db_ptr, (uint64_t)db_val);
    } else
#endif
#ifdef DOCA_GPUNETIO_VERBS_HAS_STORE_RELAXED_MMIO
    {
        radaki_dev_fence_release<sync_scope>();
        radaki_dev_store_relaxed_mmio((uint64_t *)db_ptr, (uint64_t)db_val);
    }
#else
    {
        doca_hip::atomic_ref<uint64_t, doca_hip::thread_scope_system> db_ptr_aref(*((uint64_t *)db_ptr));
        radaki_dev_fence_release<sync_scope>();
        db_ptr_aref.store(db_val, doca_hip::memory_order_relaxed);
    }
#endif
}

#ifdef DOCA_GPUNETIO_VERBS_HAS_TMA_COPY
/**
 * @brief Ring the BF (BlueFlame). Requires shared memory.
 *
 * @param qp - Queue Pair (QP)
 * @param wqe - WQE to be ringed. This buffer must be in shared memory.
 */
template <enum radaki_dev_sync_scope sync_scope = DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU>
__device__ static __forceinline__ void radaki_dev_ring_bf(
    struct radaki_dev_qp *qp, struct radaki_dev_wqe *wqe_ptr) {
    void *bf_ptr = (void *)__ldg((uintptr_t *)&qp->sq_db);
    uint64_t *wqe = (uint64_t *)wqe_ptr;

    radaki_dev_fence_release<sync_scope>();
    asm volatile("cp.async.bulk.global.shared::cta.bulk_group [%0], [%1], 64;"
                 :
                 : "l"(bf_ptr), "l"(*wqe));
}
#endif

/**
 * @brief Ring the BF (BlueFlame). Requires at least 8 threads in the warp.
 *
 * @param qp - Queue Pair (QP)
 * @param wqe - WQE to be ringed
 */
template <enum radaki_dev_sync_scope sync_scope = DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU>
__device__ static __forceinline__ void radaki_dev_ring_bf_warp(
    struct radaki_dev_qp *qp, struct radaki_dev_wqe *wqe_ptr) {
    unsigned int lane_id = radaki_dev_get_lane_id();
    uint64_t *bf_ptr = (uint64_t *)qp->sq_db;
    uint64_t *wqe = (uint64_t *)wqe_ptr;

    if (lane_id == 0) radaki_dev_fence_release<sync_scope>();
    __syncwarp();

    if (lane_id < 8) {
        bf_ptr[lane_id] = wqe[lane_id];
    }
}

/**
 * @brief Ring the proxy.
 *
 * @param qp - Queue Pair (QP)
 * @param prod_idx - Producer index
 */
template <enum radaki_dev_resource_sharing_mode resource_sharing_mode>
__device__ static __forceinline__ void radaki_dev_ring_proxy(
    struct radaki_dev_qp *qp, uint64_t prod_idx) {
    uint64_t *proxy_ptr = (uint64_t *)__ldg((uintptr_t *)&qp->sq_db);
    doca_hip::atomic_ref<uint64_t, doca_hip::thread_scope_system> proxy_ptr_aref(*proxy_ptr);

    if (resource_sharing_mode == DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_EXCLUSIVE) {
        proxy_ptr_aref.store(prod_idx, doca_hip::memory_order_relaxed);
        *proxy_ptr = prod_idx;
    } else {
        proxy_ptr_aref.fetch_max(prod_idx, doca_hip::memory_order_relaxed);
    }
}

/**
 * @brief Submit a work request to the NIC using the DB protocol.
 *
 * @param qp - Queue Pair (QP)
 * @param prod_index - Producer index
 */
template <enum radaki_dev_resource_sharing_mode resource_sharing_mode =
              DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_sync_scope sync_scope = DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU,
          enum radaki_dev_gpu_code_opt code_opt = DOCA_GPUNETIO_VERBS_GPU_CODE_OPT_DEFAULT,
          enum radaki_dev_qp_type qp_type = DOCA_GPUNETIO_VERBS_QP_SQ>
__device__ static __forceinline__ void radaki_dev_submit_db(
    struct radaki_dev_qp *qp, uint64_t prod_index) {
    radaki_dev_lock<resource_sharing_mode>(&qp->sq_lock);

    uint64_t old_prod_index = radaki_dev_atomic_max<uint64_t, resource_sharing_mode, true>(
        &qp->sq_wqe_pi, prod_index);
    if (old_prod_index < prod_index) {
        // Early rining of the DB to push WQEs to the NIC ASAP.
        radaki_dev_ring_db<sync_scope, code_opt>(qp, prod_index);

        // In case the recovery path is triggered, the later DB ringing will cover for correctness.
        doca_priv_gpu_dev_verbs_update_dbr<qp_type>(qp, prod_index);
        radaki_dev_ring_db<sync_scope, code_opt>(qp, prod_index);
    }

    radaki_dev_unlock<resource_sharing_mode>(&qp->sq_lock);
}

/**
 * @brief Submit a work request to the NIC using the BlueFlame protocol.
 * This function requires a single thread. Users must pass a pointer to a WQE stored in shared
 * memory. Hopper or a newer generation is required to leaverage the BlueFlame protocol.
 *
 * @param qp - Queue Pair (QP)
 * @param prod_index - Producer index
 * @param smem_wqe - WQE to be submitted directly to the NIC. The buffer must be in shared memory.
 */
template <enum radaki_dev_resource_sharing_mode resource_sharing_mode =
              DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_sync_scope sync_scope = DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU,
          enum radaki_dev_gpu_code_opt code_opt = DOCA_GPUNETIO_VERBS_GPU_CODE_OPT_DEFAULT>
__device__ static __forceinline__ void radaki_dev_submit_bf(
    struct radaki_dev_qp *qp, uint64_t prod_index,
    struct radaki_dev_wqe *smem_wqe) {
#ifdef DOCA_GPUNETIO_VERBS_HAS_TMA_COPY
    radaki_dev_lock<resource_sharing_mode>(&qp->sq_lock);
    unsigned long long int old_prod_index =
        radaki_dev_atomic_max<unsigned long long int, resource_sharing_mode, true>(
            (unsigned long long int *)&qp->sq_wqe_pi, (unsigned long long int)prod_index);
    if (old_prod_index < prod_index) {
        radaki_dev_ring_bf<sync_scope>(qp, smem_wqe);
        doca_priv_gpu_dev_verbs_update_dbr<DOCA_GPUNETIO_VERBS_QP_SQ>(qp, prod_index);
        radaki_dev_ring_db<sync_scope, code_opt>(qp, prod_index);
    }
    radaki_dev_unlock<resource_sharing_mode>(&qp->sq_lock);
#else
    radaki_dev_submit_db<resource_sharing_mode, sync_scope, code_opt,
                                 DOCA_GPUNETIO_VERBS_QP_SQ>(qp, prod_index);
#endif
}

/**
 * @brief Submit all the WQEs up to the given producer index to the NIC using the BlueFlame
 * protocol. This function must be called by all threads in the warp. At least 8 threads are
 * required.
 *
 * @param qp - Queue Pair (QP)
 * @param prod_index - Producer index
 * @param wqe - WQE to be submitted directly to the NIC
 */
template <enum radaki_dev_resource_sharing_mode resource_sharing_mode =
              DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_sync_scope sync_scope = DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU,
          enum radaki_dev_gpu_code_opt code_opt = DOCA_GPUNETIO_VERBS_GPU_CODE_OPT_DEFAULT>
__device__ static __forceinline__ void radaki_dev_submit_bf_warp(
    struct radaki_dev_qp *qp, uint64_t prod_index, struct radaki_dev_wqe *wqe) {
    unsigned int lane_id = radaki_dev_get_lane_id();
    unsigned long long int old_prod_index;
    if (lane_id == 0) {
        radaki_dev_lock<resource_sharing_mode>(&qp->sq_lock);
        old_prod_index =
            radaki_dev_atomic_max<unsigned long long int, resource_sharing_mode, true>(
                (unsigned long long int *)&qp->sq_wqe_pi, (unsigned long long int)prod_index);
    }
    __syncwarp();
    old_prod_index = __shfl_sync(0xFFFFFFFF, old_prod_index, 0);
    if (old_prod_index < prod_index) {
        radaki_dev_ring_bf_warp(qp, wqe);
        __syncwarp();
        if (lane_id == 0) {
            doca_priv_gpu_dev_verbs_update_dbr<DOCA_GPUNETIO_VERBS_QP_SQ>(qp, prod_index);
            radaki_dev_ring_db<sync_scope, code_opt>(qp, prod_index);
        }
    }
    if (lane_id == 0) radaki_dev_unlock<resource_sharing_mode>(&qp->sq_lock);
    __syncwarp();
}

/**
 * @brief Submit all the WQEs up to the given producer index to the NIC via the CPU proxy.
 *
 * @param qp - Queue Pair (QP)
 * @param prod_index - Producer index
 */
template <enum radaki_dev_resource_sharing_mode resource_sharing_mode =
              DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_sync_scope sync_scope = DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU>
__device__ static __forceinline__ void radaki_dev_submit_proxy(
    struct radaki_dev_qp *qp, uint64_t prod_index) {
    radaki_dev_fence_release<sync_scope>();
    radaki_dev_ring_proxy<resource_sharing_mode>(qp, prod_index);
}

template <enum radaki_dev_resource_sharing_mode resource_sharing_mode =
              DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_sync_scope sync_scope = DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU,
          enum radaki_dev_nic_handler nic_handler = DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO,
          enum radaki_dev_qp_type qp_type = DOCA_GPUNETIO_VERBS_QP_SQ>
__device__ static __forceinline__ void radaki_dev_submit(struct radaki_dev_qp *qp,
                                                                 uint64_t prod_index) {
    const enum radaki_dev_nic_handler qp_nic_handler =
        (enum radaki_dev_nic_handler)__ldg((int *)&qp->nic_handler);
    if (nic_handler == DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO) {
        if (qp_nic_handler == DOCA_GPUNETIO_VERBS_NIC_HANDLER_GPU_SM_DB)
            radaki_dev_submit_db<resource_sharing_mode, sync_scope,
                                         DOCA_GPUNETIO_VERBS_GPU_CODE_OPT_DEFAULT, qp_type>(
                qp, prod_index);
        else
            radaki_dev_submit_proxy<resource_sharing_mode, sync_scope>(qp, prod_index);
    } else if (nic_handler == DOCA_GPUNETIO_VERBS_NIC_HANDLER_GPU_SM_DB) {
        radaki_dev_submit_db<resource_sharing_mode, sync_scope,
                                     DOCA_GPUNETIO_VERBS_GPU_CODE_OPT_DEFAULT, qp_type>(qp,
                                                                                        prod_index);
    } else {
        radaki_dev_submit_proxy<resource_sharing_mode, sync_scope>(qp, prod_index);
    }
}

/* *********** WQE PREPARATION *********** */
__device__ static __forceinline__ void radaki_dev_wqe_prepare_nop(
    struct radaki_dev_qp *qp, struct radaki_dev_wqe *wqe_ptr,
    const uint16_t wqe_idx, enum radaki_dev_wqe_ctrl_flags ctrl_flags) {
    struct radaki_dev_wqe_ctrl_seg cseg;

    cseg.opmod_idx_opcode =
        radaki_dev_bswap32(((uint32_t)wqe_idx << DOCA_GPUNETIO_VERBS_WQE_IDX_SHIFT) |
                                   DOCA_GPUNETIO_IB_MLX5_OPCODE_NOP);
    cseg.qpn_ds = qp->sq_num_shift8_be_1ds;
    cseg.fm_ce_se = ctrl_flags;

    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg0), (uint64_t *)&(cseg));
}

__device__ static __forceinline__ void radaki_dev_wqe_prepare_write(
    struct radaki_dev_qp *qp, struct radaki_dev_wqe *wqe_ptr,
    const uint16_t wqe_idx, const uint32_t opcode,
    enum radaki_dev_wqe_ctrl_flags ctrl_flags, const uint32_t immediate,
    const uint64_t raddr, const uint32_t rkey, const uint64_t laddr0, const uint32_t lkey0,
    const uint32_t bytes0) {
    struct radaki_dev_wqe_ctrl_seg cseg;
    struct doca_gpunetio_ib_mlx5_wqe_raddr_seg rseg;
    struct doca_gpunetio_ib_mlx5_wqe_data_seg dseg0;

    cseg.opmod_idx_opcode = radaki_dev_bswap32(
        ((uint32_t)wqe_idx << DOCA_GPUNETIO_VERBS_WQE_IDX_SHIFT) | opcode);
    cseg.qpn_ds = qp->sq_num_shift8_be_3ds;
    cseg.fm_ce_se = ctrl_flags;
    cseg.imm = immediate;

    rseg.raddr = radaki_dev_bswap64(raddr);
#if DOCA_GPUNETIO_VERBS_MKEY_SWAPPED == 1
    rseg.rkey = rkey;
#else
    rseg.rkey = radaki_dev_bswap32(rkey);
#endif

    dseg0.byte_count =
        radaki_dev_bswap32(bytes0 & uint32_t(DOCA_GPUNETIO_IB_MLX5_INLINE_SEG - 1));
#if DOCA_GPUNETIO_VERBS_MKEY_SWAPPED == 1
    dseg0.lkey = lkey0;
#else
    dseg0.lkey = radaki_dev_bswap32(lkey0);
#endif
    dseg0.addr = radaki_dev_bswap64(laddr0);

    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg0), (uint64_t *)&(cseg));
    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg1), (uint64_t *)&(rseg));
    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg2), (uint64_t *)&(dseg0));
}

__device__ static __forceinline__ void radaki_dev_wqe_prepare_write(
    struct radaki_dev_qp *qp, struct radaki_dev_wqe *wqe_ptr,
    const uint16_t wqe_idx, const uint32_t opcode,
    enum radaki_dev_wqe_ctrl_flags ctrl_flags, const uint32_t immediate,
    const uint64_t raddr, const uint32_t rkey, const uint64_t laddr0, const uint32_t lkey0,
    const uint32_t bytes0, const uint64_t laddr1, const uint32_t lkey1, const uint32_t bytes1) {
    struct radaki_dev_wqe_ctrl_seg cseg;
    struct doca_gpunetio_ib_mlx5_wqe_raddr_seg rseg;
    struct doca_gpunetio_ib_mlx5_wqe_data_seg dseg0;
    struct doca_gpunetio_ib_mlx5_wqe_data_seg dseg1;

    cseg.opmod_idx_opcode = radaki_dev_bswap32(
        ((uint32_t)wqe_idx << DOCA_GPUNETIO_VERBS_WQE_IDX_SHIFT) | opcode);
    cseg.qpn_ds = qp->sq_num_shift8_be_4ds;
    cseg.fm_ce_se = ctrl_flags;
    cseg.imm = immediate;

    rseg.raddr = radaki_dev_bswap64(raddr);
#if DOCA_GPUNETIO_VERBS_MKEY_SWAPPED == 1
    rseg.rkey = rkey;
#else
    rseg.rkey = radaki_dev_bswap32(rkey);
#endif

    dseg0.byte_count =
        radaki_dev_bswap32(bytes0 & uint32_t(DOCA_GPUNETIO_IB_MLX5_INLINE_SEG - 1));
#if DOCA_GPUNETIO_VERBS_MKEY_SWAPPED == 1
    dseg0.lkey = lkey0;
#else
    dseg0.lkey = radaki_dev_bswap32(lkey0);
#endif
    dseg0.addr = radaki_dev_bswap64(laddr0);

    dseg1.byte_count =
        radaki_dev_bswap32(bytes1 & uint32_t(DOCA_GPUNETIO_IB_MLX5_INLINE_SEG - 1));
#if DOCA_GPUNETIO_VERBS_MKEY_SWAPPED == 1
    dseg1.lkey = lkey1;
#else
    dseg1.lkey = radaki_dev_bswap32(lkey1);
#endif
    dseg1.addr = radaki_dev_bswap64(laddr1);

    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg0), (uint64_t *)&(cseg));
    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg1), (uint64_t *)&(rseg));
    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg2), (uint64_t *)&(dseg0));
    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg3), (uint64_t *)&(dseg1));
}

/**
 * @brief Prepare the header segment of an inline RDMA Write WQE.
 * The data segment is prepared separately.
 *
 * @param qp - Queue Pair (QP)
 * @param send_wr - Send Work Request to be prepared
 * @param wqe_idx - Index of the WQE to be prepared
 * @param out_wqes - Pointer to the WQE buffer to write the prepared WQE to
 */
__device__ static __forceinline__ void radaki_dev_prepare_inl_rdma_write_wqe_header(
    struct radaki_dev_qp *qp, struct radaki_dev_wqe *wqe_ptr,
    const uint16_t wqe_idx, enum radaki_dev_wqe_ctrl_flags ctrl_flags, const uint64_t raddr,
    const uint32_t rkey, const uint32_t bytes) {
    int ds;
    struct radaki_dev_wqe_ctrl_seg cseg;
    struct doca_gpunetio_ib_mlx5_wqe_raddr_seg rseg;

    if (bytes > sizeof(struct doca_gpunetio_ib_mlx5_wqe_data_seg) -
                    sizeof(struct doca_gpunetio_ib_mlx5_wqe_inl_data_seg))
        ds = DOCA_GPUNETIO_VERBS_WQE_SEG_CNT_RDMA_WRITE_INL_MAX;
    else
        ds = DOCA_GPUNETIO_VERBS_WQE_SEG_CNT_RDMA_WRITE_INL_MIN;

    assert(bytes <= DOCA_GPUNETIO_VERBS_MAX_INLINE_SIZE);

    cseg.opmod_idx_opcode =
        radaki_dev_bswap32(((uint32_t)wqe_idx << DOCA_GPUNETIO_VERBS_WQE_IDX_SHIFT) |
                                   DOCA_GPUNETIO_IB_MLX5_OPCODE_RDMA_WRITE);
    cseg.qpn_ds = radaki_dev_bswap32(qp->sq_num_shift8 | ds);
    cseg.fm_ce_se = ctrl_flags;
    // cseg.imm = 0;

    rseg.raddr = radaki_dev_bswap64(raddr);
#if DOCA_GPUNETIO_VERBS_MKEY_SWAPPED == 1
    rseg.rkey = rkey;
#else
    rseg.rkey = radaki_dev_bswap32(rkey);
#endif

    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg0), (uint64_t *)&(cseg));
    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg1), (uint64_t *)&(rseg));
}

/**
 * @brief Prepare the data segment of an inline RDMA Write WQE.
 *
 * @param qp - Queue Pair (QP)
 * @param data - Data to be written
 * @param out_wqes - Pointer to the WQE buffer to write the prepared WQE to
 */
template <typename T>
__device__ static __forceinline__ void radaki_dev_prepare_inl_rdma_write_wqe_data(
    struct radaki_dev_qp *qp, struct radaki_dev_wqe *wqe_ptr, T data) {
    struct doca_gpunetio_ib_mlx5_wqe_inl_data_seg *data_seg_ptr =
        (struct doca_gpunetio_ib_mlx5_wqe_inl_data_seg
             *)((uintptr_t)wqe_ptr + sizeof(struct radaki_dev_wqe_ctrl_seg) +
                sizeof(struct doca_gpunetio_ib_mlx5_wqe_raddr_seg));
    struct doca_gpunetio_ib_mlx5_wqe_inl_data_seg data_seg;
    uint32_t bytes = sizeof(T);

    data_seg.byte_count = radaki_dev_bswap32(bytes | DOCA_GPUNETIO_IB_MLX5_INLINE_SEG);
    *(uint32_t *)data_seg_ptr = data_seg.byte_count;
    if (bytes <= sizeof(uint32_t)) {
        T *dst = (T *)((uintptr_t)data_seg_ptr + sizeof(data_seg));
        *dst = data;
    } else {
        uint32_t *dst32 = (uint32_t *)((uintptr_t)data_seg_ptr + sizeof(data_seg));
        dst32[0] = ((uint32_t *)&data)[0];
        dst32[1] = ((uint32_t *)&data)[1];
    }
}

/**
 * @brief Prepare a RDMA Write WQE with inline data
 *
 * @param qp - Queue Pair (QP)
 * @param send_wr - Send Work Request to be prepared
 * @param wqe_idx - Index of the WQE to be prepared
 * @param out_wqes - Pointer to the WQE buffer to write the prepared WQE to
 */
__device__ static __forceinline__ void radaki_dev_wqe_prepare_write_inl(
    struct radaki_dev_qp *qp, struct radaki_dev_wqe *wqe_ptr,
    const uint16_t wqe_idx, enum radaki_dev_wqe_ctrl_flags ctrl_flags, const uint64_t raddr,
    const uint32_t rkey, const uint64_t laddr, const uint32_t bytes) {
    struct doca_gpunetio_ib_mlx5_wqe_inl_data_seg data_seg;
    struct doca_gpunetio_ib_mlx5_wqe_inl_data_seg *data_seg_ptr =
        (struct doca_gpunetio_ib_mlx5_wqe_inl_data_seg
             *)((uintptr_t)wqe_ptr + sizeof(struct radaki_dev_wqe_ctrl_seg) +
                sizeof(struct doca_gpunetio_ib_mlx5_wqe_raddr_seg));

    radaki_dev_prepare_inl_rdma_write_wqe_header(qp, wqe_ptr, wqe_idx, ctrl_flags, raddr,
                                                         rkey, bytes);

    data_seg.byte_count = radaki_dev_bswap32(bytes | DOCA_GPUNETIO_IB_MLX5_INLINE_SEG);
    *(uint32_t *)data_seg_ptr = data_seg.byte_count;

    radaki_dev_memcpy_data((void *)((uintptr_t)data_seg_ptr + sizeof(data_seg)),
                                   (void *)(uintptr_t)laddr, bytes);
}

__device__ static __forceinline__ void radaki_dev_wqe_prepare_read(
    struct radaki_dev_qp *qp, struct radaki_dev_wqe *wqe_ptr,
    const uint16_t wqe_idx, enum radaki_dev_wqe_ctrl_flags ctrl_flags, const uint64_t raddr,
    const uint32_t rkey, const uint64_t laddr0, const uint32_t lkey0, const uint32_t bytes0) {
    struct radaki_dev_wqe_ctrl_seg cseg;
    struct doca_gpunetio_ib_mlx5_wqe_raddr_seg rseg;
    struct doca_gpunetio_ib_mlx5_wqe_data_seg dseg0;

    cseg.opmod_idx_opcode =
        radaki_dev_bswap32(((uint32_t)wqe_idx << DOCA_GPUNETIO_VERBS_WQE_IDX_SHIFT) |
                                   DOCA_GPUNETIO_IB_MLX5_OPCODE_RDMA_READ);
    cseg.qpn_ds = qp->sq_num_shift8_be_3ds;
    cseg.fm_ce_se = ctrl_flags;

    rseg.raddr = radaki_dev_bswap64(raddr);
#if DOCA_GPUNETIO_VERBS_MKEY_SWAPPED == 1
    rseg.rkey = rkey;
#else
    rseg.rkey = radaki_dev_bswap32(rkey);
#endif

    dseg0.byte_count = radaki_dev_bswap32(bytes0);
#if DOCA_GPUNETIO_VERBS_MKEY_SWAPPED == 1
    dseg0.lkey = lkey0;
#else
    dseg0.lkey = radaki_dev_bswap32(lkey0);
#endif
    dseg0.addr = radaki_dev_bswap64(laddr0);

    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg0), (uint64_t *)&(cseg));
    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg1), (uint64_t *)&(rseg));
    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg2), (uint64_t *)&(dseg0));
}

__device__ static __forceinline__ void radaki_dev_wqe_prepare_read(
    struct radaki_dev_qp *qp, struct radaki_dev_wqe *wqe_ptr,
    const uint16_t wqe_idx, enum radaki_dev_wqe_ctrl_flags ctrl_flags, const uint64_t raddr,
    const uint32_t rkey, const uint64_t laddr0, const uint32_t lkey0, const uint32_t bytes0,
    const uint64_t laddr1, const uint32_t lkey1, const uint32_t bytes1) {
    struct radaki_dev_wqe_ctrl_seg cseg;
    struct doca_gpunetio_ib_mlx5_wqe_raddr_seg rseg;
    struct doca_gpunetio_ib_mlx5_wqe_data_seg dseg0;
    struct doca_gpunetio_ib_mlx5_wqe_data_seg dseg1;

    cseg.opmod_idx_opcode =
        radaki_dev_bswap32(((uint32_t)wqe_idx << DOCA_GPUNETIO_VERBS_WQE_IDX_SHIFT) |
                                   DOCA_GPUNETIO_IB_MLX5_OPCODE_RDMA_READ);
    cseg.qpn_ds = radaki_dev_bswap32(qp->sq_num_shift8 | 4);
    cseg.fm_ce_se = ctrl_flags;
    // cseg.imm = 0;

    rseg.raddr = radaki_dev_bswap64(raddr);
#if DOCA_GPUNETIO_VERBS_MKEY_SWAPPED == 1
    rseg.rkey = rkey;
#else
    rseg.rkey = radaki_dev_bswap32(rkey);
#endif

    dseg0.byte_count =
        radaki_dev_bswap32(bytes0 & uint32_t(DOCA_GPUNETIO_IB_MLX5_INLINE_SEG - 1));
#if DOCA_GPUNETIO_VERBS_MKEY_SWAPPED == 1
    dseg0.lkey = lkey0;
#else
    dseg0.lkey = radaki_dev_bswap32(lkey0);
#endif
    dseg0.addr = radaki_dev_bswap64(laddr0);

    dseg1.byte_count =
        radaki_dev_bswap32(bytes1 & uint32_t(DOCA_GPUNETIO_IB_MLX5_INLINE_SEG - 1));
#if DOCA_GPUNETIO_VERBS_MKEY_SWAPPED == 1
    dseg1.lkey = lkey1;
#else
    dseg1.lkey = radaki_dev_bswap32(lkey1);
#endif
    dseg1.addr = radaki_dev_bswap64(laddr1);

    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg0), (uint64_t *)&(cseg));
    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg1), (uint64_t *)&(rseg));
    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg2), (uint64_t *)&(dseg0));
    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg3), (uint64_t *)&(dseg1));
}

/**
 * @brief Prepare an Atomic WQE
 *
 * @param qp - Queue Pair (QP)
 * @param send_wr - Send Work Request to be prepared
 * @param wqe_idx - Index of the WQE to be prepared
 * @param out_wqes - Pointer to the WQE buffer to write the prepared WQE to
 */
__device__ static __forceinline__ void radaki_dev_wqe_prepare_atomic(
    struct radaki_dev_qp *qp, struct radaki_dev_wqe *wqe_ptr,
    const uint16_t wqe_idx, const uint32_t opcode,
    enum radaki_dev_wqe_ctrl_flags ctrl_flags, const uint64_t raddr, const uint32_t rkey,
    const uint64_t laddr, const uint32_t lkey, const uint32_t bytes, const uint64_t compare_add,
    const uint64_t swap_add) {
    struct radaki_dev_wqe_ctrl_seg cseg;
    struct doca_gpunetio_ib_mlx5_wqe_raddr_seg rseg;
    struct doca_gpunetio_ib_mlx5_wqe_atomic_seg atseg;
    struct doca_gpunetio_ib_mlx5_wqe_data_seg dseg;

    cseg.opmod_idx_opcode = radaki_dev_bswap32(
        ((uint32_t)wqe_idx << DOCA_GPUNETIO_VERBS_WQE_IDX_SHIFT) | opcode);
    cseg.qpn_ds = qp->sq_num_shift8_be_4ds;
    cseg.fm_ce_se = ctrl_flags;

    rseg.raddr = radaki_dev_bswap64(raddr);
#if DOCA_GPUNETIO_VERBS_MKEY_SWAPPED == 1
    rseg.rkey = rkey;
#else
    rseg.rkey = radaki_dev_bswap32(rkey);
#endif

    atseg.swap_add = radaki_dev_bswap64(
        opcode == DOCA_GPUNETIO_IB_MLX5_OPCODE_ATOMIC_FA ? compare_add : swap_add);
    atseg.compare = radaki_dev_bswap64(compare_add);

    dseg.byte_count = radaki_dev_bswap32(bytes);
#if DOCA_GPUNETIO_VERBS_MKEY_SWAPPED == 1
    dseg.lkey = lkey;
#else
    dseg.lkey = radaki_dev_bswap32(lkey);
#endif
    dseg.addr = radaki_dev_bswap64(laddr);

    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg0), (uint64_t *)&(cseg));
    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg1), (uint64_t *)&(rseg));
    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg2), (uint64_t *)&(atseg));
    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg3), (uint64_t *)&(dseg));
}

/**
 * @brief Prepare a Wait WQE
 *
 * @param qp - Queue Pair (QP)
 * @param send_wr - Send Work Request to be prepared
 * @param wqe_idx - Index of the WQE to be prepared
 * @param out_wqes - Pointer to the WQE buffer to write the prepared WQE to
 */
__device__ static __forceinline__ void radaki_dev_wqe_prepare_wait(
    struct radaki_dev_qp *qp, struct radaki_dev_wqe *wqe_ptr, uint16_t wqe_idx,
    enum radaki_dev_wqe_ctrl_flags ctrl_flags, const uint32_t max_index,
    const uint32_t qpn_cqn) {
    struct radaki_dev_wqe_ctrl_seg cseg;
    struct radaki_dev_wqe_wait_seg wseg;

    cseg.opmod_idx_opcode =
        radaki_dev_bswap32(((uint32_t)wqe_idx << DOCA_GPUNETIO_VERBS_WQE_IDX_SHIFT) |
                                   DOCA_GPUNETIO_IB_MLX5_OPCODE_WAIT);
    cseg.qpn_ds = radaki_dev_bswap32(qp->sq_num_shift8 |
                                             DOCA_GPUNETIO_VERBS_WQE_SEG_CNT_WAIT);
    cseg.fm_ce_se = ctrl_flags;
    // cseg.imm = 0;

    wseg.max_index = radaki_dev_bswap32(max_index);
    wseg.qpn_cqn = radaki_dev_bswap32(qpn_cqn);

    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg0), (uint64_t *)&(cseg));
    radaki_dev_store_wqe_seg((uint64_t *)&(wqe_ptr->dseg1), (uint64_t *)&(wseg));
}

#if defined(__clang__) || defined(__HIPCC__)
#pragma clang diagnostic pop
#endif

#endif /* DOCA_GPUNETIO_DEV_VERBS_QP_H */

/** @} */
