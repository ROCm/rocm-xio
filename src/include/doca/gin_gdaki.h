/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Single public header for DOCA GIN GDAKI device API (NVIDIA-style path).
 * Include this to use radaki_dev_* types and verbs device API from doca-ep.
 */

#ifndef ROCM_XIO_DOCA_GIN_GDAKI_H
#define ROCM_XIO_DOCA_GIN_GDAKI_H

#include "doca-ep/doca_gpunetio_dev_verbs_structs.hip.h"
#include "hip/hip_runtime.h"

template <enum radaki_dev_resource_sharing_mode, enum radaki_dev_nic_handler,
          enum radaki_dev_exec_scope>
__device__ static __forceinline__ void radaki_dev_put(struct radaki_dev_qp*,
                                                      struct radaki_dev_addr,
                                                      struct radaki_dev_addr);

template <enum radaki_dev_signal_op, enum radaki_dev_resource_sharing_mode,
          enum radaki_dev_nic_handler, enum radaki_dev_exec_scope>
__device__ static __forceinline__ void radaki_dev_put_signal(
  struct radaki_dev_qp*, struct radaki_dev_addr, struct radaki_dev_addr, size_t,
  struct radaki_dev_addr, struct radaki_dev_addr, uint64_t);

template <enum radaki_dev_signal_op, enum radaki_dev_resource_sharing_mode,
          enum radaki_dev_nic_handler nic_handler>
__device__ static __forceinline__ void radaki_dev_signal(struct radaki_dev_qp*,
                                                         struct radaki_dev_addr,
                                                         struct radaki_dev_addr,
                                                         uint64_t);

#include "doca-ep/doca_gpunetio_dev_verbs_counter.hip.h"
#include "doca-ep/doca_gpunetio_dev_verbs_onesided.hip.h"

#endif // ROCM_XIO_DOCA_GIN_GDAKI_H
