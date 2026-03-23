/*
 * Copyright (c) 2012-2016 VMware, Inc.  All rights reserved.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of EITHER the GNU General Public License
 * version 2 as published by the Free Software Foundation or the BSD
 * 2-Clause License. This program is distributed in the hope that it
 * will be useful, but WITHOUT ANY WARRANTY; WITHOUT EVEN THE IMPLIED
 * WARRANTY OF MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License version 2 for more details at
 * http://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program available in the file COPYING in the main
 * directory of this source tree.
 *
 * The BSD 2-Clause License
 *
 *     Redistribution and use in source and binary forms, with or
 *     without modification, are permitted provided that the following
 *     conditions are met:
 *
 *      - Redistributions of source code must retain the above
 *        copyright notice, this list of conditions and the following
 *        disclaimer.
 *
 *      - Redistributions in binary form must reproduce the above
 *        copyright notice, this list of conditions and the following
 *        disclaimer in the documentation and/or other materials
 *        provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <linux/list.h>

#include "rocm_ernic.h"

#define ROCM_ERNIC_CMD_TIMEOUT 10000 /* ms */

static inline int rocm_ernic_cmd_recv(struct rocm_ernic_dev *dev,
                                      union rocm_ernic_cmd_resp *resp,
                                      unsigned resp_code)
{
    dev_dbg(&dev->pdev->dev, "receive response from device\n");

    /* Response is already available in DSR after interrupt */
    /* No need to wait again - interrupt already completed cmd_done */
    spin_lock(&dev->cmd_lock);
    memcpy(resp, dev->resp_slot, sizeof(*resp));
    spin_unlock(&dev->cmd_lock);

    if (resp->hdr.ack != resp_code) {
        dev_warn(&dev->pdev->dev, "unknown response %#x expected %#x\n",
                 resp->hdr.ack, resp_code);
        return -EFAULT;
    }

    return 0;
}

int rocm_ernic_cmd_post(struct rocm_ernic_dev *dev,
                        union rocm_ernic_cmd_req *req,
                        union rocm_ernic_cmd_resp *resp, unsigned resp_code)
{
    int err;

    dev_info(&dev->pdev->dev,
             "cmd_post: cmd=0x%x resp_code=%u "
             "cmd_slot=%p\n",
             req->hdr.cmd, resp_code,
             dev->cmd_slot);

    /* Serializiation */
    down(&dev->cmd_sema);

    BUILD_BUG_ON(sizeof(union rocm_ernic_cmd_req) !=
                 sizeof(struct rocm_ernic_cmd_modify_qp));

    spin_lock(&dev->cmd_lock);
    memcpy(dev->cmd_slot, req, sizeof(*req));
    spin_unlock(&dev->cmd_lock);

    init_completion(&dev->cmd_done);

    dev_info(&dev->pdev->dev,
             "cmd_post: writing REG_REQUEST, "
             "timeout=%dms msix=%d\n",
             ROCM_ERNIC_CMD_TIMEOUT,
             dev->pdev->msix_enabled);

    rocm_ernic_write_reg(dev, ROCM_ERNIC_REG_REQUEST, 0);

    /* Make sure the request is written before
     * waiting for interrupt. */
    mb();

    /* Wait for interrupt indicating command
     * completion */
    err = wait_for_completion_interruptible_timeout(
        &dev->cmd_done,
        msecs_to_jiffies(ROCM_ERNIC_CMD_TIMEOUT));
    if (err == 0) {
        dev_warn(&dev->pdev->dev,
                 "cmd_post: TIMEOUT waiting "
                 "for interrupt (cmd=0x%x)\n",
                 req->hdr.cmd);
        err = -ETIMEDOUT;
        goto out;
    }
    if (err < 0) {
        dev_warn(&dev->pdev->dev,
                 "cmd_post: interrupted "
                 "(cmd=0x%x err=%d)\n",
                 req->hdr.cmd, err);
        goto out;
    }

    dev_info(&dev->pdev->dev,
             "cmd_post: completion received "
             "(cmd=0x%x)\n",
             req->hdr.cmd);

    /* Read error register after interrupt */
    err = rocm_ernic_read_reg(dev,
                              ROCM_ERNIC_REG_ERR);
    if (err == 0) {
        if (resp != NULL)
            err = rocm_ernic_cmd_recv(dev, resp,
                                      resp_code);
    } else {
        dev_warn(&dev->pdev->dev,
                 "cmd_post: error reg=%d "
                 "(cmd=0x%x)\n",
                 err, req->hdr.cmd);
        err = -EFAULT;
    }

out:

    up(&dev->cmd_sema);

    return err;
}
