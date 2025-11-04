/* SPDX-License-Identifier: GPL-2.0 */
/*
 * NVMe Doorbell DMA-BUF Export
 *
 * Export NVMe doorbell MMIO as dmabuf for GPU import.
 * This is the standard Linux way for GPU-direct device access!
 *
 * Flow:
 * 1. NVMe driver exports doorbell as dmabuf
 * 2. Returns dmabuf FD to userspace
 * 3. Userspace passes FD to GPU (via HIP/ROCm)
 * 4. GPU driver imports and maps into GPU address space
 * 5. GPU can access doorbell - TRUE GPU-DIRECT!
 */

#ifndef NVME_DOORBELL_DMABUF_H
#define NVME_DOORBELL_DMABUF_H

#include <linux/dma-buf.h>
#include <linux/pci.h>
#include <linux/scatterlist.h>

/*
 * Doorbell dmabuf private data
 */
struct nvme_doorbell_dmabuf_priv {
  struct pci_dev* pdev;          /* NVMe controller */
  resource_size_t doorbell_phys; /* Physical address */
  size_t size;                   /* Size (typically PAGE_SIZE) */
  void __iomem* doorbell_va;     /* Kernel VA (ioremap) */
};

/*
 * dmabuf ops: attach
 */
static int nvme_doorbell_dmabuf_attach(struct dma_buf* dmabuf,
                                       struct dma_buf_attachment* attach) {
  struct nvme_doorbell_dmabuf_priv* priv = dmabuf->priv;

  pci_info(priv->pdev, "nvme_axiio: dmabuf attach from device %s\n",
           dev_name(attach->dev));

  return 0;
}

/*
 * dmabuf ops: detach
 */
static void nvme_doorbell_dmabuf_detach(struct dma_buf* dmabuf,
                                        struct dma_buf_attachment* attach) {
  struct nvme_doorbell_dmabuf_priv* priv = dmabuf->priv;

  pci_info(priv->pdev, "nvme_axiio: dmabuf detach from device %s\n",
           dev_name(attach->dev));
}

/*
 * dmabuf ops: map_dma_buf
 *
 * This is called when GPU driver wants to map the doorbell.
 * We return a scatter-gather table pointing to our MMIO region.
 */
static struct sg_table* nvme_doorbell_dmabuf_map(
  struct dma_buf_attachment* attach, enum dma_data_direction dir) {
  struct nvme_doorbell_dmabuf_priv* priv = attach->dmabuf->priv;
  struct sg_table* sgt;
  int ret;

  pci_info(priv->pdev, "nvme_axiio: dmabuf map request from %s\n",
           dev_name(attach->dev));
  pci_info(priv->pdev, "  Doorbell phys: 0x%llx, size: %zu\n",
           (u64)priv->doorbell_phys, priv->size);

  /* Allocate scatter-gather table */
  sgt = kzalloc(sizeof(*sgt), GFP_KERNEL);
  if (!sgt)
    return ERR_PTR(-ENOMEM);

  /* Create single-entry SG table for MMIO region */
  ret = sg_alloc_table(sgt, 1, GFP_KERNEL);
  if (ret) {
    kfree(sgt);
    return ERR_PTR(ret);
  }

  /* Point SG entry to our doorbell MMIO */
  sg_set_page(sgt->sgl, pfn_to_page(priv->doorbell_phys >> PAGE_SHIFT),
              priv->size, 0);
  sg_dma_address(sgt->sgl) = priv->doorbell_phys;
  sg_dma_len(sgt->sgl) = priv->size;

  pci_info(priv->pdev, "nvme_axiio: ✓ dmabuf SG table created for GPU\n");
  pci_info(priv->pdev, "  DMA addr: 0x%llx\n", (u64)sg_dma_address(sgt->sgl));

  return sgt;
}

/*
 * dmabuf ops: unmap_dma_buf
 */
static void nvme_doorbell_dmabuf_unmap(struct dma_buf_attachment* attach,
                                       struct sg_table* sgt,
                                       enum dma_data_direction dir) {
  struct nvme_doorbell_dmabuf_priv* priv = attach->dmabuf->priv;

  pci_info(priv->pdev, "nvme_axiio: dmabuf unmap\n");

  sg_free_table(sgt);
  kfree(sgt);
}

/*
 * dmabuf ops: release
 */
static void nvme_doorbell_dmabuf_release(struct dma_buf* dmabuf) {
  struct nvme_doorbell_dmabuf_priv* priv = dmabuf->priv;

  pci_info(priv->pdev, "nvme_axiio: dmabuf released\n");

  /* Unmap doorbell */
  if (priv->doorbell_va)
    iounmap(priv->doorbell_va);

  kfree(priv);
}

/*
 * dmabuf ops: mmap
 *
 * Allow userspace to mmap the dmabuf (for CPU access)
 */
static int nvme_doorbell_dmabuf_mmap(struct dma_buf* dmabuf,
                                     struct vm_area_struct* vma) {
  struct nvme_doorbell_dmabuf_priv* priv = dmabuf->priv;
  unsigned long pfn = priv->doorbell_phys >> PAGE_SHIFT;

  pci_info(priv->pdev, "nvme_axiio: dmabuf mmap\n");

  /* GPU-friendly flags */
  vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
  vm_flags_set(vma, VM_IO | VM_PFNMAP | VM_DONTEXPAND);

  return remap_pfn_range(vma, vma->vm_start, pfn, vma->vm_end - vma->vm_start,
                         vma->vm_page_prot);
}

/*
 * dmabuf operations table
 */
static const struct dma_buf_ops nvme_doorbell_dmabuf_ops = {
  .attach = nvme_doorbell_dmabuf_attach,
  .detach = nvme_doorbell_dmabuf_detach,
  .map_dma_buf = nvme_doorbell_dmabuf_map,
  .unmap_dma_buf = nvme_doorbell_dmabuf_unmap,
  .release = nvme_doorbell_dmabuf_release,
  .mmap = nvme_doorbell_dmabuf_mmap,
};

/*
 * Export NVMe doorbell as dmabuf
 *
 * Returns dmabuf FD that userspace can pass to GPU
 */
static inline int nvme_export_doorbell_dmabuf(struct pci_dev* pdev,
                                              resource_size_t doorbell_phys,
                                              size_t size, int* dmabuf_fd_out) {
  struct nvme_doorbell_dmabuf_priv* priv;
  struct dma_buf* dmabuf;
  DEFINE_DMA_BUF_EXPORT_INFO(exp_info);
  int fd;

  pci_info(pdev, "nvme_axiio: Exporting doorbell as dmabuf\n");
  pci_info(pdev, "  Doorbell phys: 0x%llx\n", (u64)doorbell_phys);
  pci_info(pdev, "  Size: %zu bytes\n", size);

  /* Allocate private data */
  priv = kzalloc(sizeof(*priv), GFP_KERNEL);
  if (!priv)
    return -ENOMEM;

  priv->pdev = pdev;
  priv->doorbell_phys = doorbell_phys;
  priv->size = size;

  /* ioremap the doorbell for kernel access */
  priv->doorbell_va = ioremap_wc(doorbell_phys, size);
  if (!priv->doorbell_va) {
    pci_err(pdev, "nvme_axiio: Failed to ioremap doorbell\n");
    kfree(priv);
    return -ENOMEM;
  }

  /* Setup dmabuf export info */
  exp_info.ops = &nvme_doorbell_dmabuf_ops;
  exp_info.size = size;
  exp_info.flags = O_RDWR | O_CLOEXEC;
  exp_info.priv = priv;

  /* Export as dmabuf */
  dmabuf = dma_buf_export(&exp_info);
  if (IS_ERR(dmabuf)) {
    pci_err(pdev, "nvme_axiio: dma_buf_export failed: %ld\n", PTR_ERR(dmabuf));
    iounmap(priv->doorbell_va);
    kfree(priv);
    return PTR_ERR(dmabuf);
  }

  /* Get file descriptor for userspace */
  fd = dma_buf_fd(dmabuf, O_RDWR | O_CLOEXEC);
  if (fd < 0) {
    pci_err(pdev, "nvme_axiio: dma_buf_fd failed: %d\n", fd);
    dma_buf_put(dmabuf);
    return fd;
  }

  *dmabuf_fd_out = fd;

  pci_info(pdev, "nvme_axiio: ✓✓✓ Doorbell exported as dmabuf! ✓✓✓\n");
  pci_info(pdev, "  dmabuf FD: %d\n", fd);
  pci_info(pdev, "  🚀 Userspace can now pass this to GPU!\n");
  pci_info(pdev, "  GPU driver will map into GPU address space!\n");

  return 0;
}

#endif /* NVME_DOORBELL_DMABUF_H */
