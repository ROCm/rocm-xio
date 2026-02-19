/*
 * SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION &
 * AFFILIATES. All rights reserved. SPDX-FileCopyrightText: Modifications
 * Copyright (c) 2025-2026 Advanced Micro Devices, Inc. All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
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
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

/**
 * @file doca_gpunetio_dev_verbs_onesided.cuh
 * @brief GDAKI CUDA device functions for One-sided Shared QP ops
 *
 * @{
 */

#ifndef DOCA_GPUNETIO_DEV_VERBS_ONESIDED_CUH
#define DOCA_GPUNETIO_DEV_VERBS_ONESIDED_CUH

#include "doca_gpunetio_dev_verbs_cq.hip.h"
#include "doca_gpunetio_dev_verbs_qp.hip.h"
#include "doca_gpunetio_dev_verbs_structs.hip.h"

/* **************************************** PUT
 * **************************************** */
template <enum radaki_dev_resource_sharing_mode resource_sharing_mode =
            DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_nic_handler nic_handler =
            DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO>
__device__ static __forceinline__ void radaki_dev_put_thread(
  struct radaki_dev_qp* qp, struct radaki_dev_addr raddr,
  struct radaki_dev_addr laddr, size_t size, radaki_dev_ticket_t* out_ticket) {
  struct radaki_dev_wqe* wqe_ptr;
  uint64_t base_wqe_idx;
  uint64_t wqe_idx;
  size_t remaining_size = size;
  size_t size_;
  uint32_t num_chunks = radaki_dev_div_ceil_aligned_pow2_32bits(
    size, DOCA_GPUNETIO_VERBS_MAX_TRANSFER_SIZE_SHIFT);
  num_chunks = num_chunks > 1 ? num_chunks : 1;

  DOCA_GPUNETIO_VERBS_ASSERT(out_ticket != NULL);
  DOCA_GPUNETIO_VERBS_ASSERT(qp != NULL);
  // DOCA_GPUNETIO_VERBS_ASSERT(qp->mem_type ==
  // DOCA_GPUNETIO_VERBS_MEM_TYPE_GPU);

  base_wqe_idx = radaki_dev_reserve_wq_slots<resource_sharing_mode>(qp,
                                                                    num_chunks);
#pragma unroll 1
  for (uint64_t i = 0; i < num_chunks; i++) {
    wqe_idx = base_wqe_idx + i;
    size_ = remaining_size > DOCA_GPUNETIO_VERBS_MAX_TRANSFER_SIZE
              ? DOCA_GPUNETIO_VERBS_MAX_TRANSFER_SIZE
              : remaining_size;
    wqe_ptr = radaki_dev_get_wqe_ptr(qp, wqe_idx);

    [[likely]] if (size_ > 0) {
      radaki_dev_wqe_prepare_write(
        qp, wqe_ptr, wqe_idx, DOCA_GPUNETIO_IB_MLX5_OPCODE_RDMA_WRITE,
        DOCA_GPUNETIO_IB_MLX5_WQE_CTRL_CQ_UPDATE, 0,
        raddr.addr + (i * DOCA_GPUNETIO_VERBS_MAX_TRANSFER_SIZE), raddr.key,
        laddr.addr + (i * DOCA_GPUNETIO_VERBS_MAX_TRANSFER_SIZE), laddr.key,
        size_);
    } else {
      radaki_dev_wqe_prepare_nop(qp, wqe_ptr, wqe_idx,
                                 DOCA_GPUNETIO_IB_MLX5_WQE_CTRL_CQ_UPDATE);
    }
    remaining_size -= size_;
  }

  radaki_dev_mark_wqes_ready<resource_sharing_mode>(qp, base_wqe_idx, wqe_idx);
  radaki_dev_submit<resource_sharing_mode, DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU,
                    nic_handler>(qp, wqe_idx + 1);

  *out_ticket = wqe_idx;
}

template <enum radaki_dev_resource_sharing_mode resource_sharing_mode =
            DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_nic_handler nic_handler =
            DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO>
__device__ static __forceinline__ void radaki_dev_put_warp(
  struct radaki_dev_qp* qp, struct radaki_dev_addr raddr,
  struct radaki_dev_addr laddr, size_t size, radaki_dev_ticket_t* out_ticket) {
#if __CUDA_ARCH__ >= 800
  struct radaki_dev_wqe* wqe_ptr;
  uint64_t base_wqe_idx = 0, wqe_idx;
  uint32_t base_wqe_idx_0 = 0, base_wqe_idx_1 = 0;
  uint32_t lane_idx = radaki_dev_get_lane_id();

  DOCA_GPUNETIO_VERBS_ASSERT(size <= DOCA_GPUNETIO_VERBS_MAX_TRANSFER_SIZE);
  DOCA_GPUNETIO_VERBS_ASSERT(out_ticket != NULL);
  DOCA_GPUNETIO_VERBS_ASSERT(qp != NULL);

  if (lane_idx == 0) {
    base_wqe_idx = radaki_dev_reserve_wq_slots<resource_sharing_mode>(
      qp, DOCA_GPUNETIO_VERBS_WARP_SIZE);
    base_wqe_idx_0 = (uint32_t)base_wqe_idx;
    base_wqe_idx_1 = (uint32_t)(base_wqe_idx >> 32);
  }
  __syncwarp();

  base_wqe_idx_0 = __reduce_max_sync(DOCA_GPUNETIO_VERBS_WARP_FULL_MASK,
                                     base_wqe_idx_0);
  base_wqe_idx_1 = __reduce_max_sync(DOCA_GPUNETIO_VERBS_WARP_FULL_MASK,
                                     base_wqe_idx_1);
  base_wqe_idx = ((uint64_t)base_wqe_idx_1) << 32 | base_wqe_idx_0;

  wqe_idx = base_wqe_idx + lane_idx;
  wqe_ptr = radaki_dev_get_wqe_ptr(qp, wqe_idx);

  radaki_dev_wqe_prepare_write(qp, wqe_ptr, wqe_idx,
                               DOCA_GPUNETIO_IB_MLX5_OPCODE_RDMA_WRITE,
                               DOCA_GPUNETIO_IB_MLX5_WQE_CTRL_CQ_UPDATE, 0,
                               raddr.addr, raddr.key, laddr.addr, laddr.key,
                               size);

  __syncwarp();
  if (lane_idx == 0) {
    radaki_dev_mark_wqes_ready<resource_sharing_mode>(
      qp, base_wqe_idx, base_wqe_idx + DOCA_GPUNETIO_VERBS_WARP_SIZE - 1);
    radaki_dev_submit<resource_sharing_mode, DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU,
                      nic_handler>(qp, base_wqe_idx +
                                         DOCA_GPUNETIO_VERBS_WARP_SIZE);
  }
  __syncwarp();

  *out_ticket = wqe_idx;
#else
  printf("__CUDA_ARCH__ < 800, WARP mode not enabled\n");
  *out_ticket = 0;
#endif
}

template <
  enum radaki_dev_resource_sharing_mode resource_sharing_mode =
    DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
  enum radaki_dev_nic_handler nic_handler =
    DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO,
  enum radaki_dev_exec_scope exec_scope = DOCA_GPUNETIO_VERBS_EXEC_SCOPE_THREAD>
__device__ static __forceinline__ void radaki_dev_put(
  struct radaki_dev_qp* qp, struct radaki_dev_addr raddr,
  struct radaki_dev_addr laddr, size_t size, radaki_dev_ticket_t* out_ticket) {
  if (exec_scope == DOCA_GPUNETIO_VERBS_EXEC_SCOPE_THREAD)
    radaki_dev_put_thread<resource_sharing_mode, nic_handler>(qp, raddr, laddr,
                                                              size, out_ticket);
  if (exec_scope == DOCA_GPUNETIO_VERBS_EXEC_SCOPE_WARP)
    radaki_dev_put_warp<resource_sharing_mode, nic_handler>(qp, raddr, laddr,
                                                            size, out_ticket);
}

template <
  enum radaki_dev_resource_sharing_mode resource_sharing_mode =
    DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
  enum radaki_dev_nic_handler nic_handler =
    DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO,
  enum radaki_dev_exec_scope exec_scope = DOCA_GPUNETIO_VERBS_EXEC_SCOPE_THREAD>
__device__ static __forceinline__ void radaki_dev_put(
  struct radaki_dev_qp* qp, struct radaki_dev_addr raddr,
  struct radaki_dev_addr laddr, size_t size) {
  uint64_t ticket;
  radaki_dev_put<resource_sharing_mode, nic_handler, exec_scope>(qp, raddr,
                                                                 laddr, size,
                                                                 &ticket);
}

/* **************************************** PUT INLINE
 * **************************************** */

template <typename T,
          enum radaki_dev_resource_sharing_mode resource_sharing_mode =
            DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_nic_handler nic_handler =
            DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO>
__device__ static __forceinline__ void radaki_dev_p_thread(
  struct radaki_dev_qp* qp, struct radaki_dev_addr raddr, T value,
  radaki_dev_ticket_t* out_ticket) {
  uint64_t wqe_idx;
  struct radaki_dev_wqe* wqe_ptr;

  DOCA_GPUNETIO_VERBS_ASSERT(out_ticket != NULL);
  DOCA_GPUNETIO_VERBS_ASSERT(qp != NULL);
  // DOCA_GPUNETIO_VERBS_ASSERT(qp->mem_type ==
  // DOCA_GPUNETIO_VERBS_MEM_TYPE_GPU);

  wqe_idx = radaki_dev_reserve_wq_slots<resource_sharing_mode>(qp, 1);
  wqe_ptr = radaki_dev_get_wqe_ptr(qp, wqe_idx);

  radaki_dev_prepare_inl_rdma_write_wqe_header(
    qp, wqe_ptr, wqe_idx, DOCA_GPUNETIO_IB_MLX5_WQE_CTRL_CQ_UPDATE, raddr.addr,
    raddr.key, sizeof(T));
  radaki_dev_prepare_inl_rdma_write_wqe_data<T>(qp, wqe_ptr, value);
  radaki_dev_mark_wqes_ready<resource_sharing_mode>(qp, wqe_idx, wqe_idx);
  radaki_dev_submit<resource_sharing_mode, DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU,
                    nic_handler>(qp, wqe_idx + 1);

  *out_ticket = wqe_idx;
}

template <typename T,
          enum radaki_dev_resource_sharing_mode resource_sharing_mode =
            DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_nic_handler nic_handler =
            DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO>
__device__ static __forceinline__ void radaki_dev_p_warp(
  struct radaki_dev_qp* qp, struct radaki_dev_addr raddr, T value,
  radaki_dev_ticket_t* out_ticket) {
  *out_ticket = 0;
}

template <
  typename T,
  enum radaki_dev_resource_sharing_mode resource_sharing_mode =
    DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
  enum radaki_dev_nic_handler nic_handler =
    DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO,
  enum radaki_dev_exec_scope exec_scope = DOCA_GPUNETIO_VERBS_EXEC_SCOPE_THREAD>
__device__ static __forceinline__ void radaki_dev_p(
  struct radaki_dev_qp* qp, struct radaki_dev_addr raddr, T value,
  radaki_dev_ticket_t* out_ticket) {
  if (exec_scope == DOCA_GPUNETIO_VERBS_EXEC_SCOPE_THREAD)
    radaki_dev_p_thread<T, resource_sharing_mode, nic_handler>(qp, raddr, value,
                                                               out_ticket);
  if (exec_scope == DOCA_GPUNETIO_VERBS_EXEC_SCOPE_WARP)
    radaki_dev_p_warp<T, resource_sharing_mode, nic_handler>(qp, raddr, value,
                                                             out_ticket);
}

template <
  typename T,
  enum radaki_dev_resource_sharing_mode resource_sharing_mode =
    DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
  enum radaki_dev_nic_handler nic_handler =
    DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO,
  enum radaki_dev_exec_scope exec_scope = DOCA_GPUNETIO_VERBS_EXEC_SCOPE_THREAD>
__device__ static __forceinline__ void radaki_dev_p(
  struct radaki_dev_qp* qp, struct radaki_dev_addr raddr, T value) {
  uint64_t ticket;
  radaki_dev_p<T, resource_sharing_mode, nic_handler, exec_scope>(qp, raddr,
                                                                  value,
                                                                  &ticket);
}

/* **************************************** PUT SIGNAL
 * **************************************** */

template <enum radaki_dev_signal_op sig_op,
          enum radaki_dev_resource_sharing_mode resource_sharing_mode =
            DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_nic_handler nic_handler =
            DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO>
__device__ static __forceinline__ void radaki_dev_put_signal_thread(
  struct radaki_dev_qp* qp, struct radaki_dev_addr raddr,
  struct radaki_dev_addr laddr, size_t size, struct radaki_dev_addr sig_raddr,
  struct radaki_dev_addr sig_laddr, uint64_t sig_val,
  radaki_dev_ticket_t* out_ticket) {
  struct radaki_dev_wqe* wqe_ptr;
  uint64_t base_wqe_idx;
  uint64_t wqe_idx;
  size_t remaining_size = size;
  size_t size_;

  uint32_t num_chunks = radaki_dev_div_ceil_aligned_pow2_32bits(
    size, DOCA_GPUNETIO_VERBS_MAX_TRANSFER_SIZE_SHIFT);
  num_chunks = num_chunks > 1 ? num_chunks : 1;

  DOCA_GPUNETIO_VERBS_ASSERT(out_ticket != NULL);
  DOCA_GPUNETIO_VERBS_ASSERT(qp != NULL);
  // DOCA_GPUNETIO_VERBS_ASSERT(qp->mem_type ==
  // DOCA_GPUNETIO_VERBS_MEM_TYPE_GPU);

  base_wqe_idx = radaki_dev_reserve_wq_slots<resource_sharing_mode>(qp,
                                                                    num_chunks +
                                                                      1);

#pragma unroll 1
  for (uint64_t i = 0; i < num_chunks; i++) {
    wqe_idx = base_wqe_idx + i;
    size_ = remaining_size > DOCA_GPUNETIO_VERBS_MAX_TRANSFER_SIZE
              ? DOCA_GPUNETIO_VERBS_MAX_TRANSFER_SIZE
              : remaining_size;

    wqe_ptr = radaki_dev_get_wqe_ptr(qp, wqe_idx);

    [[likely]] if (size_ > 0) {
      radaki_dev_wqe_prepare_write(
        qp, wqe_ptr, wqe_idx, DOCA_GPUNETIO_IB_MLX5_OPCODE_RDMA_WRITE,
        DOCA_GPUNETIO_IB_MLX5_WQE_CTRL_CQ_UPDATE, 0,
        raddr.addr + (i * DOCA_GPUNETIO_VERBS_MAX_TRANSFER_SIZE), raddr.key,
        laddr.addr + (i * DOCA_GPUNETIO_VERBS_MAX_TRANSFER_SIZE), laddr.key,
        size_);
    } else {
      radaki_dev_wqe_prepare_nop(qp, wqe_ptr, wqe_idx,
                                 DOCA_GPUNETIO_IB_MLX5_WQE_CTRL_CQ_UPDATE);
    }
    remaining_size -= size_;
  }

  ++wqe_idx;

  wqe_ptr = radaki_dev_get_wqe_ptr(qp, wqe_idx);

  radaki_dev_wqe_prepare_atomic(qp, wqe_ptr, wqe_idx,
                                DOCA_GPUNETIO_IB_MLX5_OPCODE_ATOMIC_FA,
                                DOCA_GPUNETIO_IB_MLX5_WQE_CTRL_CQ_UPDATE,
                                sig_raddr.addr, sig_raddr.key, sig_laddr.addr,
                                sig_laddr.key, sizeof(uint64_t), sig_val, 0);

  radaki_dev_mark_wqes_ready<resource_sharing_mode>(qp, base_wqe_idx, wqe_idx);

  radaki_dev_submit<resource_sharing_mode, DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU,
                    nic_handler>(qp, wqe_idx + 1);

  *out_ticket = wqe_idx;
}

template <enum radaki_dev_signal_op sig_op,
          enum radaki_dev_resource_sharing_mode resource_sharing_mode =
            DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_nic_handler nic_handler =
            DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO>
__device__ static __forceinline__ void radaki_dev_put_signal_warp(
  struct radaki_dev_qp* qp, struct radaki_dev_addr raddr,
  struct radaki_dev_addr laddr, size_t size, struct radaki_dev_addr sig_raddr,
  struct radaki_dev_addr sig_laddr, uint64_t sig_val,
  radaki_dev_ticket_t* out_ticket) {
  *out_ticket = 0;
}

template <
  enum radaki_dev_signal_op sig_op,
  enum radaki_dev_resource_sharing_mode resource_sharing_mode =
    DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
  enum radaki_dev_nic_handler nic_handler =
    DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO,
  enum radaki_dev_exec_scope exec_scope = DOCA_GPUNETIO_VERBS_EXEC_SCOPE_THREAD>
__device__ static __forceinline__ void radaki_dev_put_signal(
  struct radaki_dev_qp* qp, struct radaki_dev_addr raddr,
  struct radaki_dev_addr laddr, size_t size, struct radaki_dev_addr sig_raddr,
  struct radaki_dev_addr sig_laddr, uint64_t sig_val,
  radaki_dev_ticket_t* out_ticket) {
  if (exec_scope == DOCA_GPUNETIO_VERBS_EXEC_SCOPE_THREAD)
    radaki_dev_put_signal_thread<sig_op, resource_sharing_mode, nic_handler>(
      qp, raddr, laddr, size, sig_raddr, sig_laddr, sig_val, out_ticket);
  if (exec_scope == DOCA_GPUNETIO_VERBS_EXEC_SCOPE_WARP)
    radaki_dev_put_signal_warp<sig_op, resource_sharing_mode, nic_handler>(
      qp, raddr, laddr, size, sig_raddr, sig_laddr, sig_val, out_ticket);
}

template <
  enum radaki_dev_signal_op sig_op,
  enum radaki_dev_resource_sharing_mode resource_sharing_mode =
    DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
  enum radaki_dev_nic_handler nic_handler =
    DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO,
  enum radaki_dev_exec_scope exec_scope = DOCA_GPUNETIO_VERBS_EXEC_SCOPE_THREAD>
__device__ static __forceinline__ void radaki_dev_put_signal(
  struct radaki_dev_qp* qp, struct radaki_dev_addr raddr,
  struct radaki_dev_addr laddr, size_t size, struct radaki_dev_addr sig_raddr,
  struct radaki_dev_addr sig_laddr, uint64_t sig_val) {
  uint64_t ticket;
  radaki_dev_put_signal<sig_op, resource_sharing_mode, nic_handler, exec_scope>(
    qp, raddr, laddr, size, sig_raddr, sig_laddr, sig_val, &ticket);
}

template <typename T, enum radaki_dev_signal_op sig_op,
          enum radaki_dev_resource_sharing_mode resource_sharing_mode =
            DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_nic_handler nic_handler =
            DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO>
__device__ static __forceinline__ void radaki_dev_p_signal(
  struct radaki_dev_qp* qp, struct radaki_dev_addr raddr, T value,
  struct radaki_dev_addr sig_raddr, struct radaki_dev_addr sig_laddr,
  uint64_t sig_val, radaki_dev_ticket_t* out_ticket) {
  struct radaki_dev_wqe* wqe_ptr;
  uint64_t base_wqe_idx;
  uint64_t wqe_idx;

  DOCA_GPUNETIO_VERBS_ASSERT(out_ticket != NULL);
  DOCA_GPUNETIO_VERBS_ASSERT(qp != NULL);
  // DOCA_GPUNETIO_VERBS_ASSERT(qp->mem_type ==
  // DOCA_GPUNETIO_VERBS_MEM_TYPE_GPU);

  base_wqe_idx = radaki_dev_reserve_wq_slots<resource_sharing_mode>(qp, 2);
  wqe_idx = base_wqe_idx;
  wqe_ptr = radaki_dev_get_wqe_ptr(qp, wqe_idx);

  radaki_dev_prepare_inl_rdma_write_wqe_header(
    qp, wqe_ptr, wqe_idx, DOCA_GPUNETIO_IB_MLX5_WQE_CTRL_CQ_UPDATE, raddr.addr,
    raddr.key, sizeof(T));
  radaki_dev_prepare_inl_rdma_write_wqe_data<T>(qp, wqe_ptr, value);

  ++wqe_idx;
  wqe_ptr = radaki_dev_get_wqe_ptr(qp, wqe_idx);
  radaki_dev_wqe_prepare_atomic(qp, wqe_ptr, wqe_idx,
                                DOCA_GPUNETIO_IB_MLX5_OPCODE_ATOMIC_FA,
                                DOCA_GPUNETIO_IB_MLX5_WQE_CTRL_CQ_UPDATE,
                                sig_raddr.addr, sig_raddr.key, sig_laddr.addr,
                                sig_laddr.key, sizeof(uint64_t), sig_val, 0);

  radaki_dev_mark_wqes_ready<resource_sharing_mode>(qp, base_wqe_idx, wqe_idx);
  radaki_dev_submit<resource_sharing_mode, DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU,
                    nic_handler>(qp, wqe_idx + 1);

  *out_ticket = wqe_idx;
}

template <typename T, enum radaki_dev_signal_op sig_op,
          enum radaki_dev_resource_sharing_mode resource_sharing_mode =
            DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_nic_handler nic_handler =
            DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO>
__device__ static __forceinline__ void radaki_dev_p_signal(
  struct radaki_dev_qp* qp, struct radaki_dev_addr raddr, T value,
  struct radaki_dev_addr sig_raddr, struct radaki_dev_addr sig_laddr,
  uint64_t sig_val) {
  uint64_t ticket;
  radaki_dev_p_signal<T, sig_op, resource_sharing_mode, nic_handler>(
    qp, raddr, value, sig_raddr, sig_laddr, sig_val, &ticket);
}

/* **************************************** SIGNAL
 * **************************************** */

template <enum radaki_dev_signal_op sig_op,
          enum radaki_dev_resource_sharing_mode resource_sharing_mode =
            DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_nic_handler nic_handler =
            DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO>
__device__ static __forceinline__ void radaki_dev_signal_thread(
  struct radaki_dev_qp* qp, struct radaki_dev_addr sig_raddr,
  struct radaki_dev_addr sig_laddr, uint64_t sig_val,
  radaki_dev_ticket_t* out_ticket) {
  uint64_t wqe_idx;
  struct radaki_dev_wqe* wqe_ptr;

  DOCA_GPUNETIO_VERBS_ASSERT(out_ticket != NULL);
  DOCA_GPUNETIO_VERBS_ASSERT(qp != NULL);
  // DOCA_GPUNETIO_VERBS_ASSERT(qp->mem_type ==
  // DOCA_GPUNETIO_VERBS_MEM_TYPE_GPU);

  wqe_idx = radaki_dev_reserve_wq_slots<resource_sharing_mode>(qp, 1);
  wqe_ptr = radaki_dev_get_wqe_ptr(qp, wqe_idx);

  radaki_dev_wqe_prepare_atomic(qp, wqe_ptr, wqe_idx,
                                DOCA_GPUNETIO_IB_MLX5_OPCODE_ATOMIC_FA,
                                DOCA_GPUNETIO_IB_MLX5_WQE_CTRL_CQ_UPDATE,
                                sig_raddr.addr, sig_raddr.key, sig_laddr.addr,
                                sig_laddr.key, sizeof(uint64_t), sig_val, 0);

  radaki_dev_mark_wqes_ready<resource_sharing_mode>(qp, wqe_idx, wqe_idx);
  radaki_dev_submit<resource_sharing_mode, DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU,
                    nic_handler>(qp, wqe_idx + 1);

  *out_ticket = wqe_idx;
}

template <enum radaki_dev_signal_op sig_op,
          enum radaki_dev_resource_sharing_mode resource_sharing_mode =
            DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_nic_handler nic_handler =
            DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO>
__device__ static __forceinline__ void radaki_dev_signal_warp(
  struct radaki_dev_qp* qp, struct radaki_dev_addr sig_raddr,
  struct radaki_dev_addr sig_laddr, uint64_t sig_val,
  radaki_dev_ticket_t* out_ticket) {
  *out_ticket = 0;
}

template <
  enum radaki_dev_signal_op sig_op,
  enum radaki_dev_resource_sharing_mode resource_sharing_mode =
    DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
  enum radaki_dev_nic_handler nic_handler =
    DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO,
  enum radaki_dev_exec_scope exec_scope = DOCA_GPUNETIO_VERBS_EXEC_SCOPE_THREAD>
__device__ static __forceinline__ void radaki_dev_signal(
  struct radaki_dev_qp* qp, struct radaki_dev_addr sig_raddr,
  struct radaki_dev_addr sig_laddr, uint64_t sig_val,
  radaki_dev_ticket_t* out_ticket) {
  if (exec_scope == DOCA_GPUNETIO_VERBS_EXEC_SCOPE_THREAD)
    radaki_dev_signal_thread<sig_op, resource_sharing_mode, nic_handler>(
      qp, sig_raddr, sig_laddr, sig_val, out_ticket);
  if (exec_scope == DOCA_GPUNETIO_VERBS_EXEC_SCOPE_WARP)
    radaki_dev_signal_warp<sig_op, resource_sharing_mode, nic_handler>(
      qp, sig_raddr, sig_laddr, sig_val, out_ticket);
}

template <enum radaki_dev_signal_op sig_op,
          enum radaki_dev_resource_sharing_mode resource_sharing_mode =
            DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_nic_handler nic_handler =
            DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO>
__device__ static __forceinline__ void radaki_dev_signal(
  struct radaki_dev_qp* qp, struct radaki_dev_addr sig_raddr,
  struct radaki_dev_addr sig_laddr, uint64_t sig_val) {
  uint64_t ticket;
  radaki_dev_signal<sig_op, resource_sharing_mode, nic_handler>(qp, sig_raddr,
                                                                sig_laddr,
                                                                sig_val,
                                                                &ticket);
}

/* **************************************** OTHERS
 * **************************************** */

template <enum radaki_dev_resource_sharing_mode resource_sharing_mode =
            DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_nic_handler nic_handler =
            DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO>
__device__ static __forceinline__ void radaki_dev_wait(
  struct radaki_dev_qp* qp, radaki_dev_ticket_t ticket) {
  radaki_dev_poll_cq_at<resource_sharing_mode>(radaki_dev_qp_get_cq_sq(qp),
                                               ticket);
}

template <enum radaki_dev_resource_sharing_mode resource_sharing_mode =
            DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_nic_handler nic_handler =
            DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO>
__device__ static __forceinline__ void radaki_dev_wait(
  struct radaki_dev_qp* qp) {
  uint64_t ticket = radaki_dev_atomic_read<uint64_t, resource_sharing_mode>(
    &qp->sq_rsvd_index);
  [[unlikely]] if (ticket == 0)
    return;
  --ticket;
  radaki_dev_poll_cq_at<resource_sharing_mode>(radaki_dev_qp_get_cq_sq(qp),
                                               ticket);
}

template <enum radaki_dev_resource_sharing_mode resource_sharing_mode =
            DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
          enum radaki_dev_nic_handler nic_handler =
            DOCA_GPUNETIO_VERBS_NIC_HANDLER_AUTO>
__device__ static __forceinline__ void radaki_dev_fence(
  struct radaki_dev_qp* qp) {
  // This is no-op in the current implementation
  return;
}

#endif /* DOCA_GPUNETIO_DEV_VERBS_ONESIDED_CUH */
