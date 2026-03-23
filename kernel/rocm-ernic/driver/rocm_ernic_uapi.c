/*
 * Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: GPL-2.0
 *
 * rocm_ernic Direct Verbs UAPI helpers.
 *
 * Provides DV ABI version reporting and validation
 * helpers used by the CQ and QP creation paths when
 * operating in DV mode (comp_mask-driven).
 */

#include <linux/kernel.h>
#include <linux/module.h>

#include "rocm_ernic.h"
#include "rocm_ernic_dv_uapi.h"

int rocm_ernic_dv_abi_version(void);
int rocm_ernic_dv_validate_qp_sizing(struct rocm_ernic_dev *dev, u32 sq_depth,
                                     u32 sq_wqe_size, u32 rq_depth,
                                     u32 rq_wqe_size);
int rocm_ernic_dv_validate_cq_sizing(struct rocm_ernic_dev *dev, u32 ncqe,
                                     u32 cqe_size);

/**
 * rocm_ernic_dv_abi_version - return DV ABI version
 *
 * Can be used by rdma-core provider to verify
 * compatibility at dlopen time.
 *
 * @return: ROCM_ERNIC_DV_ABI_VERSION
 */
int rocm_ernic_dv_abi_version(void)
{
    return ROCM_ERNIC_DV_ABI_VERSION;
}

/**
 * rocm_ernic_dv_validate_qp_sizing - sanity-check DV
 *   QP sizing parameters from userspace
 * @dev: rocm_ernic device
 * @sq_depth: send queue depth from userspace
 * @sq_wqe_size: send WQE size from userspace
 * @rq_depth: receive queue depth from userspace
 * @rq_wqe_size: receive WQE size from userspace
 *
 * @return: 0 if valid, -EINVAL otherwise
 */
int rocm_ernic_dv_validate_qp_sizing(struct rocm_ernic_dev *dev, u32 sq_depth,
                                     u32 sq_wqe_size, u32 rq_depth,
                                     u32 rq_wqe_size)
{
    if (sq_depth == 0 || sq_wqe_size == 0) {
        dev_warn(&dev->pdev->dev, "DV QP: SQ depth/wqe_size cannot "
                                  "be zero\n");
        return -EINVAL;
    }

    if (sq_depth > dev->dsr->caps.max_qp_wr) {
        dev_warn(&dev->pdev->dev, "DV QP: SQ depth %u exceeds max %u\n",
                 sq_depth, dev->dsr->caps.max_qp_wr);
        return -EINVAL;
    }

    if (!is_power_of_2(sq_wqe_size) ||
        sq_wqe_size < sizeof(struct rocm_ernic_sq_wqe_hdr)) {
        dev_warn(&dev->pdev->dev, "DV QP: invalid SQ WQE size %u\n",
                 sq_wqe_size);
        return -EINVAL;
    }

    if (rq_depth > dev->dsr->caps.max_qp_wr) {
        dev_warn(&dev->pdev->dev, "DV QP: RQ depth %u exceeds max %u\n",
                 rq_depth, dev->dsr->caps.max_qp_wr);
        return -EINVAL;
    }

    return 0;
}

/**
 * rocm_ernic_dv_validate_cq_sizing - sanity-check DV
 *   CQ sizing parameters from userspace
 * @dev: rocm_ernic device
 * @ncqe: number of CQ entries from userspace
 * @cqe_size: CQE size from userspace
 *
 * @return: 0 if valid, -EINVAL otherwise
 */
int rocm_ernic_dv_validate_cq_sizing(struct rocm_ernic_dev *dev, u32 ncqe,
                                     u32 cqe_size)
{
    if (ncqe == 0 || ncqe > dev->dsr->caps.max_cqe) {
        dev_warn(&dev->pdev->dev, "DV CQ: ncqe %u invalid (max=%u)\n", ncqe,
                 dev->dsr->caps.max_cqe);
        return -EINVAL;
    }

    if (cqe_size != 0 && cqe_size != sizeof(struct rocm_ernic_cqe)) {
        dev_warn(&dev->pdev->dev,
                 "DV CQ: invalid CQE size %u "
                 "(expected %zu)\n",
                 cqe_size, sizeof(struct rocm_ernic_cqe));
        return -EINVAL;
    }

    return 0;
}
