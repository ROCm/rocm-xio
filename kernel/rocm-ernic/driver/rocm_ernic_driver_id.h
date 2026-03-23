/* SPDX-License-Identifier: ((GPL-2.0 WITH Linux-syscall-note) OR
 *                          BSD-2-Clause)
 */
/*
 * Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * Custom rdma_driver_id for the rocm_ernic out-of-tree
 * driver.  Value 100 is well above the upstream range
 * (0-22 as of kernel 6.14) and prevents the stock pvrdma
 * rdma-core provider from matching this device.
 *
 * Shared between the kernel module and the rdma-core
 * provider (librocm_ernic.so).
 */

#ifndef __ROCM_ERNIC_DRIVER_ID_H__
#define __ROCM_ERNIC_DRIVER_ID_H__

#define RDMA_DRIVER_ROCM_ERNIC 100

#endif /* __ROCM_ERNIC_DRIVER_ID_H__ */
