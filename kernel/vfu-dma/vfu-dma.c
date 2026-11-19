// SPDX-License-Identifier: GPL-2.0-or-later
/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * vfu-dma: bus addresses for the vfu-doorbell ringer.
 *
 * A device reaches memory, and another device's BAR, only at addresses its
 * driver obtained from the kernel's DMA API. The vfu-doorbell ringer is a
 * vfio-user PCI device with no driver, so under a translating IOMMU its domain
 * is empty and it cannot DMA anywhere. This module is its stand-in driver: it
 * binds to the ringer and gives the vfu-ring tool bus addresses for
 *
 *  - a coherent buffer (the completion word the ringer stores to), and
 *  - the BAR of another PCI device (the doorbell it writes to),
 *
 * using dma_alloc_coherent() and dma_map_resource() for the ringer. With no
 * IOMMU, or an identity domain, those return the physical addresses, so the
 * same tool works unchanged.
 *
 * It does not call pci_request_regions(): the tool reaches the ringer's own
 * registers through sysfs, which a claimed region would not stop, but nothing
 * here needs to claim them. Test use only: root, one ringer.
 */

#define pr_fmt(fmt) "vfu-dma: " fmt

#include <linux/dma-mapping.h>
#include <linux/fs.h>
#include <linux/iommu.h>
#include <linux/kref.h>
#include <linux/list.h>
#include <linux/miscdevice.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/sizes.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#include "vfu-dma-uapi.h"

#define VFU_DMA_VENDOR_ID 0x1de0 /* the vfu-doorbell devices */
#define VFU_DMA_RINGER_ID 0x0002
#define VFU_DMA_MAX_BUF SZ_16M

/* The DMA device. One ringer; a second is refused. */
static struct pci_dev* ringer;
static DEFINE_MUTEX(ringer_lock);

/* A coherent buffer. Held by its handle and by every mapping of it. */
struct vfu_buf {
  struct list_head node;
  struct kref ref;
  struct device* dev;
  u32 handle;
  size_t size;
  void* cpu;
  dma_addr_t dma;
};

/* A peer BAR mapped into the ringer's address space. */
struct vfu_map {
  struct list_head node;
  struct device* dev;
  u32 handle;
  size_t size;
  dma_addr_t dma;
};

/* Everything one open file created, released when it is closed. */
struct vfu_file {
  struct pci_dev* pdev;
  struct mutex lock;
  struct list_head bufs;
  struct list_head maps;
  u32 next_handle;
};

static void vfu_buf_release(struct kref* ref) {
  struct vfu_buf* buf = container_of(ref, struct vfu_buf, ref);

  dma_free_coherent(buf->dev, buf->size, buf->cpu, buf->dma);
  put_device(buf->dev);
  kfree(buf);
}

static void vfu_map_free(struct vfu_map* map) {
  dma_unmap_resource(map->dev, map->dma, map->size, DMA_BIDIRECTIONAL, 0);
  put_device(map->dev);
  kfree(map);
}

static int vfu_dma_open(struct inode* inode, struct file* file) {
  struct vfu_file* f;
  int ret = 0;

  if (!capable(CAP_SYS_ADMIN))
    return -EPERM;

  mutex_lock(&ringer_lock);
  if (!ringer) {
    ret = -ENODEV;
    goto out;
  }
  f = kzalloc(sizeof(*f), GFP_KERNEL);
  if (!f) {
    ret = -ENOMEM;
    goto out;
  }
  f->pdev = pci_dev_get(ringer);
  mutex_init(&f->lock);
  INIT_LIST_HEAD(&f->bufs);
  INIT_LIST_HEAD(&f->maps);
  f->next_handle = 1;
  file->private_data = f;
out:
  mutex_unlock(&ringer_lock);
  return ret;
}

static int vfu_dma_release(struct inode* inode, struct file* file) {
  struct vfu_file* f = file->private_data;
  struct vfu_buf *buf, *btmp;
  struct vfu_map *map, *mtmp;

  list_for_each_entry_safe(buf, btmp, &f->bufs, node) {
    list_del(&buf->node);
    kref_put(&buf->ref, vfu_buf_release);
  }
  list_for_each_entry_safe(map, mtmp, &f->maps, node) {
    list_del(&map->node);
    vfu_map_free(map);
  }
  pci_dev_put(f->pdev);
  kfree(f);
  return 0;
}

static long vfu_dma_get_info(struct vfu_file* f, void __user* argp) {
  struct vfu_dma_info info = {.version = VFU_DMA_VERSION};
  struct iommu_domain* domain = iommu_get_domain_for_dev(&f->pdev->dev);

  if (domain) {
    info.flags |= VFU_DMA_INFO_IOMMU;
    if (domain->type == IOMMU_DOMAIN_IDENTITY)
      info.flags |= VFU_DMA_INFO_IDENTITY;
  }
  return copy_to_user(argp, &info, sizeof(info)) ? -EFAULT : 0;
}

static long vfu_dma_alloc(struct vfu_file* f, void __user* argp) {
  struct vfu_dma_alloc a;
  struct vfu_buf* buf;

  if (copy_from_user(&a, argp, sizeof(a)))
    return -EFAULT;
  if (!a.size || a.size > VFU_DMA_MAX_BUF || !PAGE_ALIGNED(a.size))
    return -EINVAL;

  buf = kzalloc(sizeof(*buf), GFP_KERNEL);
  if (!buf)
    return -ENOMEM;
  buf->cpu = dma_alloc_coherent(&f->pdev->dev, a.size, &buf->dma, GFP_KERNEL);
  if (!buf->cpu) {
    kfree(buf);
    return -ENOMEM;
  }
  kref_init(&buf->ref);
  buf->dev = get_device(&f->pdev->dev);
  buf->size = a.size;

  mutex_lock(&f->lock);
  buf->handle = f->next_handle++;
  list_add_tail(&buf->node, &f->bufs);
  mutex_unlock(&f->lock);

  a.dma_addr = buf->dma;
  a.mmap_offset = (u64)buf->handle << PAGE_SHIFT;
  a.handle = buf->handle;
  if (copy_to_user(argp, &a, sizeof(a)))
    return -EFAULT; /* the buffer stays until close, or an UNMAP */
  return 0;
}

static long vfu_dma_map_peer(struct vfu_file* f, void __user* argp) {
  struct vfu_dma_peer p;
  struct pci_dev* peer;
  struct vfu_map* map;
  resource_size_t start, len;

  if (copy_from_user(&p, argp, sizeof(p)))
    return -EFAULT;
  if (p.bar >= PCI_STD_NUM_BARS)
    return -EINVAL;

  peer = pci_get_domain_bus_and_slot(p.bdf >> 16, (p.bdf >> 8) & 0xff,
                                     p.bdf & 0xff);
  if (!peer)
    return -ENODEV;
  if (!(pci_resource_flags(peer, p.bar) & IORESOURCE_MEM) ||
      !pci_resource_len(peer, p.bar)) {
    pci_dev_put(peer);
    return -EINVAL;
  }
  start = pci_resource_start(peer, p.bar);
  len = pci_resource_len(peer, p.bar);
  pci_dev_put(peer);

  map = kzalloc(sizeof(*map), GFP_KERNEL);
  if (!map)
    return -ENOMEM;
  map->dma = dma_map_resource(&f->pdev->dev, start, len, DMA_BIDIRECTIONAL, 0);
  if (dma_mapping_error(&f->pdev->dev, map->dma)) {
    kfree(map);
    return -EOPNOTSUPP;
  }
  map->dev = get_device(&f->pdev->dev);
  map->size = len;

  mutex_lock(&f->lock);
  map->handle = f->next_handle++;
  list_add_tail(&map->node, &f->maps);
  mutex_unlock(&f->lock);

  p.dma_addr = map->dma;
  p.size = len;
  p.handle = map->handle;
  if (copy_to_user(argp, &p, sizeof(p)))
    return -EFAULT; /* the mapping stays until close, or an UNMAP */
  return 0;
}

static long vfu_dma_unmap(struct vfu_file* f, void __user* argp) {
  struct vfu_dma_unmap u;
  struct vfu_buf* buf;
  struct vfu_map* map;
  long ret = -ENOENT;

  if (copy_from_user(&u, argp, sizeof(u)))
    return -EFAULT;

  mutex_lock(&f->lock);
  list_for_each_entry(buf, &f->bufs, node) {
    if (buf->handle == u.handle) {
      list_del(&buf->node);
      /* A mapping of it in userspace keeps it alive. */
      kref_put(&buf->ref, vfu_buf_release);
      ret = 0;
      goto out;
    }
  }
  list_for_each_entry(map, &f->maps, node) {
    if (map->handle == u.handle) {
      list_del(&map->node);
      vfu_map_free(map);
      ret = 0;
      goto out;
    }
  }
out:
  mutex_unlock(&f->lock);
  return ret;
}

static long vfu_dma_ioctl(struct file* file, unsigned int cmd,
                          unsigned long arg) {
  struct vfu_file* f = file->private_data;
  void __user* argp = (void __user*)arg;

  switch (cmd) {
    case VFU_DMA_IOC_GET_INFO:
      return vfu_dma_get_info(f, argp);
    case VFU_DMA_IOC_ALLOC_PAGE:
      return vfu_dma_alloc(f, argp);
    case VFU_DMA_IOC_MAP_PEER:
      return vfu_dma_map_peer(f, argp);
    case VFU_DMA_IOC_UNMAP:
      return vfu_dma_unmap(f, argp);
  }
  return -ENOTTY;
}

static void vfu_vma_open(struct vm_area_struct* vma) {
  struct vfu_buf* buf = vma->vm_private_data;

  kref_get(&buf->ref);
}

static void vfu_vma_close(struct vm_area_struct* vma) {
  struct vfu_buf* buf = vma->vm_private_data;

  kref_put(&buf->ref, vfu_buf_release);
}

static const struct vm_operations_struct vfu_vma_ops = {
  .open = vfu_vma_open,
  .close = vfu_vma_close,
};

/* mmap(fd, size, offset from ALLOC_PAGE): the buffer, shared with the device.
 */
static int vfu_dma_mmap(struct file* file, struct vm_area_struct* vma) {
  struct vfu_file* f = file->private_data;
  struct vfu_buf *buf, *found = NULL;
  u32 handle = vma->vm_pgoff;
  int ret;

  mutex_lock(&f->lock);
  list_for_each_entry(buf, &f->bufs, node) {
    if (buf->handle == handle) {
      found = buf;
      kref_get(&found->ref);
      break;
    }
  }
  mutex_unlock(&f->lock);
  if (!found)
    return -ENOENT;
  if (vma->vm_end - vma->vm_start > found->size) {
    ret = -EINVAL;
    goto put;
  }

  /* dma_mmap_coherent() counts the offset from the start of the buffer. */
  vma->vm_pgoff = 0;
  ret = dma_mmap_coherent(found->dev, vma, found->cpu, found->dma, found->size);
  if (ret)
    goto put;

  vma->vm_private_data = found; /* keeps the reference taken above */
  vma->vm_ops = &vfu_vma_ops;
  return 0;
put:
  kref_put(&found->ref, vfu_buf_release);
  return ret;
}

static const struct file_operations vfu_dma_fops = {
  .owner = THIS_MODULE,
  .open = vfu_dma_open,
  .release = vfu_dma_release,
  .unlocked_ioctl = vfu_dma_ioctl,
  .compat_ioctl = compat_ptr_ioctl,
  .mmap = vfu_dma_mmap,
};

static struct miscdevice vfu_dma_misc = {
  .minor = MISC_DYNAMIC_MINOR,
  .name = "vfu-dma",
  .fops = &vfu_dma_fops,
  .mode = 0600,
};

/*
 * ringer_lock is never held across misc_register() or misc_deregister(): open()
 * runs under the misc layer's own mutex and then takes ringer_lock, so holding
 * it the other way round would deadlock an unbind against an open.
 */
static int vfu_dma_probe(struct pci_dev* pdev, const struct pci_device_id* id) {
  bool busy;
  int ret;

  mutex_lock(&ringer_lock);
  busy = ringer != NULL;
  mutex_unlock(&ringer_lock);
  if (busy)
    return -EBUSY;

  ret = pcim_enable_device(pdev);
  if (ret)
    return ret;
  pci_set_master(pdev); /* a device may DMA only with bus mastering on */

  ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
  if (ret)
    ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
  if (ret)
    return ret;

  ret = misc_register(&vfu_dma_misc);
  if (ret)
    return ret;

  mutex_lock(&ringer_lock);
  ringer = pdev;
  mutex_unlock(&ringer_lock);
  pci_info(pdev, "DMA device for /dev/vfu-dma\n");
  return 0;
}

static void vfu_dma_remove(struct pci_dev* pdev) {
  bool ours;

  mutex_lock(&ringer_lock);
  ours = ringer == pdev;
  if (ours)
    ringer = NULL;
  mutex_unlock(&ringer_lock);

  if (ours)
    misc_deregister(&vfu_dma_misc);
}

static const struct pci_device_id vfu_dma_ids[] = {
  {PCI_DEVICE(VFU_DMA_VENDOR_ID, VFU_DMA_RINGER_ID)}, {}};
MODULE_DEVICE_TABLE(pci, vfu_dma_ids);

static struct pci_driver vfu_dma_driver = {
  .name = "vfu-dma",
  .id_table = vfu_dma_ids,
  .probe = vfu_dma_probe,
  .remove = vfu_dma_remove,
};
module_pci_driver(vfu_dma_driver);

MODULE_DESCRIPTION("Bus addresses for the vfu-doorbell ringer");
MODULE_AUTHOR("Advanced Micro Devices, Inc.");
MODULE_LICENSE("GPL");
MODULE_VERSION("0.1");
