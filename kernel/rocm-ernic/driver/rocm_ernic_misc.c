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

#include <linux/errno.h>
#include <linux/slab.h>
#include <linux/bitmap.h>

#include "rocm_ernic.h"

int rocm_ernic_page_dir_init(struct rocm_ernic_dev *dev,
                             struct rocm_ernic_page_dir *pdir, u64 npages,
                             bool alloc_pages)
{
    u64 i;

    dev_info(&dev->pdev->dev, "page_dir_init: npages=%llu, alloc_pages=%d\n",
             npages, alloc_pages);

    if (npages > ROCM_ERNIC_PAGE_DIR_MAX_PAGES) {
        dev_err(&dev->pdev->dev, "page_dir_init: npages > max (%llu > %d)\n",
                npages, ROCM_ERNIC_PAGE_DIR_MAX_PAGES);
        return -EINVAL;
    }

    memset(pdir, 0, sizeof(*pdir));

    dev_info(&dev->pdev->dev, "page_dir_init: allocating dir (PAGE_SIZE=%lu)\n",
             PAGE_SIZE);
    pdir->dir = dma_alloc_coherent(&dev->pdev->dev, PAGE_SIZE, &pdir->dir_dma,
                                   GFP_KERNEL);
    if (!pdir->dir) {
        dev_err(&dev->pdev->dev,
                "page_dir_init: dma_alloc_coherent for dir failed\n");
        goto err;
    }
    dev_info(&dev->pdev->dev,
             "page_dir_init: dir allocated at %p (dma=0x%llx)\n", pdir->dir,
             (unsigned long long)pdir->dir_dma);

    pdir->ntables = ROCM_ERNIC_PAGE_DIR_TABLE(npages - 1) + 1;
    dev_info(&dev->pdev->dev, "page_dir_init: allocating %u tables\n",
             pdir->ntables);
    pdir->tables = kcalloc(pdir->ntables, sizeof(*pdir->tables), GFP_KERNEL);
    if (!pdir->tables) {
        dev_err(&dev->pdev->dev, "page_dir_init: kcalloc for tables failed\n");
        goto err;
    }

    for (i = 0; i < pdir->ntables; i++) {
        dev_info(&dev->pdev->dev, "page_dir_init: allocating table %llu\n", i);
        pdir->tables[i] =
            dma_alloc_coherent(&dev->pdev->dev, PAGE_SIZE,
                               (dma_addr_t *)&pdir->dir[i], GFP_KERNEL);
        if (!pdir->tables[i]) {
            dev_err(&dev->pdev->dev,
                    "page_dir_init: dma_alloc_coherent for table %llu failed\n",
                    i);
            goto err;
        }
        dev_info(&dev->pdev->dev, "page_dir_init: table %llu allocated at %p\n",
                 i, pdir->tables[i]);
    }

    pdir->npages = npages;

    if (alloc_pages) {
        pdir->pages = kcalloc(npages, sizeof(*pdir->pages), GFP_KERNEL);
        if (!pdir->pages)
            goto err;

        for (i = 0; i < pdir->npages; i++) {
            dma_addr_t page_dma;

            pdir->pages[i] = dma_alloc_coherent(&dev->pdev->dev, PAGE_SIZE,
                                                &page_dma, GFP_KERNEL);
            if (!pdir->pages[i])
                goto err;

            rocm_ernic_page_dir_insert_dma(pdir, i, page_dma);
        }
    }

    return 0;

err:
    rocm_ernic_page_dir_cleanup(dev, pdir);

    return -ENOMEM;
}

static u64 *rocm_ernic_page_dir_table(struct rocm_ernic_page_dir *pdir, u64 idx)
{
    return pdir->tables[ROCM_ERNIC_PAGE_DIR_TABLE(idx)];
}

dma_addr_t rocm_ernic_page_dir_get_dma(struct rocm_ernic_page_dir *pdir,
                                       u64 idx)
{
    return rocm_ernic_page_dir_table(pdir, idx)[ROCM_ERNIC_PAGE_DIR_PAGE(idx)];
}

static void rocm_ernic_page_dir_cleanup_pages(struct rocm_ernic_dev *dev,
                                              struct rocm_ernic_page_dir *pdir)
{
    if (pdir->pages) {
        u64 i;

        for (i = 0; i < pdir->npages && pdir->pages[i]; i++) {
            dma_addr_t page_dma = rocm_ernic_page_dir_get_dma(pdir, i);

            dma_free_coherent(&dev->pdev->dev, PAGE_SIZE, pdir->pages[i],
                              page_dma);
        }

        kfree(pdir->pages);
    }
}

static void rocm_ernic_page_dir_cleanup_tables(struct rocm_ernic_dev *dev,
                                               struct rocm_ernic_page_dir *pdir)
{
    if (pdir->tables) {
        int i;

        rocm_ernic_page_dir_cleanup_pages(dev, pdir);

        for (i = 0; i < pdir->ntables; i++) {
            u64 *table = pdir->tables[i];

            if (table)
                dma_free_coherent(&dev->pdev->dev, PAGE_SIZE, table,
                                  pdir->dir[i]);
        }

        kfree(pdir->tables);
    }
}

void rocm_ernic_page_dir_cleanup(struct rocm_ernic_dev *dev,
                                 struct rocm_ernic_page_dir *pdir)
{
    if (pdir->dir) {
        rocm_ernic_page_dir_cleanup_tables(dev, pdir);
        dma_free_coherent(&dev->pdev->dev, PAGE_SIZE, pdir->dir, pdir->dir_dma);
    }
}

int rocm_ernic_page_dir_insert_dma(struct rocm_ernic_page_dir *pdir, u64 idx,
                                   dma_addr_t daddr)
{
    u64 *table;

    if (idx >= pdir->npages)
        return -EINVAL;

    table = rocm_ernic_page_dir_table(pdir, idx);
    table[ROCM_ERNIC_PAGE_DIR_PAGE(idx)] = daddr;

    return 0;
}

int rocm_ernic_page_dir_insert_umem(struct rocm_ernic_page_dir *pdir,
                                    struct ib_umem *umem, u64 offset)
{
    struct ib_block_iter biter;
    u64 i = offset;
    int ret = 0;

    if (offset >= pdir->npages)
        return -EINVAL;

    rdma_umem_for_each_dma_block(umem, &biter, PAGE_SIZE)
    {
        ret = rocm_ernic_page_dir_insert_dma(
            pdir, i, rdma_block_iter_dma_address(&biter));
        if (ret)
            goto exit;

        i++;
    }

exit:
    return ret;
}

int rocm_ernic_page_dir_insert_page_list(struct rocm_ernic_page_dir *pdir,
                                         u64 *page_list, int num_pages)
{
    int i;
    int ret;

    if (num_pages > pdir->npages)
        return -EINVAL;

    for (i = 0; i < num_pages; i++) {
        ret = rocm_ernic_page_dir_insert_dma(pdir, i, page_list[i]);
        if (ret)
            return ret;
    }

    return 0;
}

void rocm_ernic_qp_cap_to_ib(struct ib_qp_cap *dst,
                             const struct rocm_ernic_qp_cap *src)
{
    dst->max_send_wr = src->max_send_wr;
    dst->max_recv_wr = src->max_recv_wr;
    dst->max_send_sge = src->max_send_sge;
    dst->max_recv_sge = src->max_recv_sge;
    dst->max_inline_data = src->max_inline_data;
}

void ib_qp_cap_to_rocm_ernic(struct rocm_ernic_qp_cap *dst,
                             const struct ib_qp_cap *src)
{
    dst->max_send_wr = src->max_send_wr;
    dst->max_recv_wr = src->max_recv_wr;
    dst->max_send_sge = src->max_send_sge;
    dst->max_recv_sge = src->max_recv_sge;
    dst->max_inline_data = src->max_inline_data;
}

void rocm_ernic_gid_to_ib(union ib_gid *dst, const union rocm_ernic_gid *src)
{
    BUILD_BUG_ON(sizeof(union rocm_ernic_gid) != sizeof(union ib_gid));
    memcpy(dst, src, sizeof(*src));
}

void ib_gid_to_rocm_ernic(union rocm_ernic_gid *dst, const union ib_gid *src)
{
    BUILD_BUG_ON(sizeof(union rocm_ernic_gid) != sizeof(union ib_gid));
    memcpy(dst, src, sizeof(*src));
}

void rocm_ernic_global_route_to_ib(struct ib_global_route *dst,
                                   const struct rocm_ernic_global_route *src)
{
    rocm_ernic_gid_to_ib(&dst->dgid, &src->dgid);
    dst->flow_label = src->flow_label;
    dst->sgid_index = src->sgid_index;
    dst->hop_limit = src->hop_limit;
    dst->traffic_class = src->traffic_class;
}

void ib_global_route_to_rocm_ernic(struct rocm_ernic_global_route *dst,
                                   const struct ib_global_route *src)
{
    ib_gid_to_rocm_ernic(&dst->dgid, &src->dgid);
    dst->flow_label = src->flow_label;
    dst->sgid_index = src->sgid_index;
    dst->hop_limit = src->hop_limit;
    dst->traffic_class = src->traffic_class;
}

void rocm_ernic_ah_attr_to_rdma(struct rdma_ah_attr *dst,
                                const struct rocm_ernic_ah_attr *src)
{
    dst->type = RDMA_AH_ATTR_TYPE_ROCE;
    rocm_ernic_global_route_to_ib(rdma_ah_retrieve_grh(dst), &src->grh);
    rdma_ah_set_dlid(dst, src->dlid);
    rdma_ah_set_sl(dst, src->sl);
    rdma_ah_set_path_bits(dst, src->src_path_bits);
    rdma_ah_set_static_rate(dst, src->static_rate);
    rdma_ah_set_ah_flags(dst, src->ah_flags);
    rdma_ah_set_port_num(dst, src->port_num);
    memcpy(dst->roce.dmac, &src->dmac, ETH_ALEN);
}

void rdma_ah_attr_to_rocm_ernic(struct rocm_ernic_ah_attr *dst,
                                const struct rdma_ah_attr *src)
{
    ib_global_route_to_rocm_ernic(&dst->grh, rdma_ah_read_grh(src));
    dst->dlid = rdma_ah_get_dlid(src);
    dst->sl = rdma_ah_get_sl(src);
    dst->src_path_bits = rdma_ah_get_path_bits(src);
    dst->static_rate = rdma_ah_get_static_rate(src);
    dst->ah_flags = rdma_ah_get_ah_flags(src);
    dst->port_num = rdma_ah_get_port_num(src);
    memcpy(&dst->dmac, src->roce.dmac, sizeof(dst->dmac));
}

u8 ib_gid_type_to_rocm_ernic(enum ib_gid_type gid_type)
{
    return (gid_type == IB_GID_TYPE_ROCE_UDP_ENCAP)
               ? ROCM_ERNIC_GID_TYPE_FLAG_ROCE_V2
               : ROCM_ERNIC_GID_TYPE_FLAG_ROCE_V1;
}
