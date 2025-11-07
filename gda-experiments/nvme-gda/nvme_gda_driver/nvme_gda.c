// SPDX-License-Identifier: MIT
/*
 * NVMe GPU Direct Async Kernel Driver
 *
 * This driver exposes NVMe doorbell registers and queue memory to userspace
 * for GPU direct access via PCIe peer-to-peer.
 *
 * Based on concepts from mlx5 direct verbs and rocSHMEM GDA.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/device.h>
#include <linux/cdev.h>
#include <linux/pci.h>
#include <linux/dma-mapping.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/mm.h>
#include <linux/nvme.h>
#include "nvme_gda.h"

#define DRIVER_NAME "nvme_gda"
#define DRIVER_VERSION "0.1"

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Research Project");
MODULE_DESCRIPTION("NVMe GPU Direct Async Driver");
MODULE_VERSION(DRIVER_VERSION);

/* Module parameters */
static char *nvme_pci_dev = NULL;
module_param(nvme_pci_dev, charp, 0644);
MODULE_PARM_DESC(nvme_pci_dev, "PCI device address (e.g., 0000:01:00.0)");

/* Driver state */
static dev_t nvme_gda_devt;
static struct class *nvme_gda_class;
static struct cdev nvme_gda_cdev;
static struct device *nvme_gda_device;

/* NVMe device state */
struct nvme_gda_dev {
	struct pci_dev *pdev;
	void __iomem *bar0;
	u64 bar0_phys;
	u64 bar0_size;
	u32 doorbell_stride;
	u32 max_queue_entries;
	
	/* Queue management */
	struct nvme_gda_queue *queues[256];
	u16 num_queues;
	spinlock_t queue_lock;
};

static struct nvme_gda_dev *gda_dev = NULL;

/* Per-queue state */
struct nvme_gda_queue {
	u16 qid;
	u16 qsize;
	
	/* Submission queue */
	void *sqes;           /* Kernel virtual address */
	dma_addr_t sqes_dma;  /* DMA address */
	
	/* Completion queue */
	void *cqes;
	dma_addr_t cqes_dma;
	
	/* Doorbell registers */
	volatile u32 __iomem *sq_doorbell;
	volatile u32 __iomem *cq_doorbell;
	u32 sq_doorbell_offset;
	u32 cq_doorbell_offset;
	
	/* State */
	u16 sq_head;
	u16 sq_tail;
	u16 cq_head;
	u16 cq_phase;
};

/* Forward declarations */
static int nvme_gda_open(struct inode *inode, struct file *file);
static int nvme_gda_release(struct inode *inode, struct file *file);
static long nvme_gda_ioctl(struct file *file, unsigned int cmd, unsigned long arg);
static int nvme_gda_mmap(struct file *file, struct vm_area_struct *vma);

static struct file_operations nvme_gda_fops = {
	.owner = THIS_MODULE,
	.open = nvme_gda_open,
	.release = nvme_gda_release,
	.unlocked_ioctl = nvme_gda_ioctl,
	.mmap = nvme_gda_mmap,
};

/*
 * Calculate doorbell register address
 */
static void __iomem *nvme_doorbell(struct nvme_gda_dev *dev, u16 qid, bool is_sq)
{
	u32 offset = 0x1000 + ((2 * qid + (is_sq ? 0 : 1)) * 
	                       (4 << dev->doorbell_stride));
	return dev->bar0 + offset;
}

/*
 * Create a new queue pair
 */
static struct nvme_gda_queue *nvme_gda_create_queue_internal(
	struct nvme_gda_dev *dev, u16 qsize)
{
	struct nvme_gda_queue *queue;
	u16 qid;
	unsigned long flags;
	
	if (qsize < NVME_GDA_MIN_QUEUE_SIZE || 
	    qsize > NVME_GDA_MAX_QUEUE_SIZE ||
	    !is_power_of_2(qsize)) {
		pr_err("Invalid queue size: %u\n", qsize);
		return ERR_PTR(-EINVAL);
	}
	
	queue = kzalloc(sizeof(*queue), GFP_KERNEL);
	if (!queue)
		return ERR_PTR(-ENOMEM);
	
	/* Allocate queue ID */
	spin_lock_irqsave(&dev->queue_lock, flags);
	for (qid = 1; qid < 256; qid++) {
		if (!dev->queues[qid]) {
			dev->queues[qid] = queue;
			dev->num_queues++;
			break;
		}
	}
	spin_unlock_irqrestore(&dev->queue_lock, flags);
	
	if (qid >= 256) {
		pr_err("No free queue IDs\n");
		kfree(queue);
		return ERR_PTR(-ENOSPC);
	}
	
	queue->qid = qid;
	queue->qsize = qsize;
	
	/* Allocate submission queue */
	queue->sqes = dma_alloc_coherent(&dev->pdev->dev,
	                                  qsize * NVME_SQE_SIZE,
	                                  &queue->sqes_dma,
	                                  GFP_KERNEL);
	if (!queue->sqes) {
		pr_err("Failed to allocate SQ\n");
		goto err_free_queue;
	}
	
	/* Allocate completion queue */
	queue->cqes = dma_alloc_coherent(&dev->pdev->dev,
	                                  qsize * NVME_CQE_SIZE,
	                                  &queue->cqes_dma,
	                                  GFP_KERNEL);
	if (!queue->cqes) {
		pr_err("Failed to allocate CQ\n");
		goto err_free_sqes;
	}
	
	/* Setup doorbell pointers */
	queue->sq_doorbell = nvme_doorbell(dev, qid, true);
	queue->cq_doorbell = nvme_doorbell(dev, qid, false);
	queue->sq_doorbell_offset = (unsigned long)queue->sq_doorbell - 
	                             (unsigned long)dev->bar0;
	queue->cq_doorbell_offset = (unsigned long)queue->cq_doorbell - 
	                             (unsigned long)dev->bar0;
	
	/* Initialize state */
	queue->sq_head = 0;
	queue->sq_tail = 0;
	queue->cq_head = 0;
	queue->cq_phase = 1;
	
	pr_info("Created queue %u: size=%u, sqes_dma=0x%llx, cqes_dma=0x%llx\n",
	        qid, qsize, queue->sqes_dma, queue->cqes_dma);
	
	return queue;

err_free_sqes:
	dma_free_coherent(&dev->pdev->dev, qsize * NVME_SQE_SIZE,
	                  queue->sqes, queue->sqes_dma);
err_free_queue:
	spin_lock_irqsave(&dev->queue_lock, flags);
	dev->queues[qid] = NULL;
	dev->num_queues--;
	spin_unlock_irqrestore(&dev->queue_lock, flags);
	kfree(queue);
	return ERR_PTR(-ENOMEM);
}

/*
 * Destroy a queue
 */
static void nvme_gda_destroy_queue_internal(struct nvme_gda_dev *dev, u16 qid)
{
	struct nvme_gda_queue *queue;
	unsigned long flags;
	
	if (qid == 0 || qid >= 256)
		return;
	
	spin_lock_irqsave(&dev->queue_lock, flags);
	queue = dev->queues[qid];
	dev->queues[qid] = NULL;
	if (queue)
		dev->num_queues--;
	spin_unlock_irqrestore(&dev->queue_lock, flags);
	
	if (!queue)
		return;
	
	/* Free DMA memory */
	if (queue->sqes)
		dma_free_coherent(&dev->pdev->dev, 
		                  queue->qsize * NVME_SQE_SIZE,
		                  queue->sqes, queue->sqes_dma);
	
	if (queue->cqes)
		dma_free_coherent(&dev->pdev->dev,
		                  queue->qsize * NVME_CQE_SIZE,
		                  queue->cqes, queue->cqes_dma);
	
	kfree(queue);
	pr_info("Destroyed queue %u\n", qid);
}

/*
 * File operations
 */
static int nvme_gda_open(struct inode *inode, struct file *file)
{
	if (!gda_dev) {
		pr_err("No NVMe device attached\n");
		return -ENODEV;
	}
	
	file->private_data = NULL;
	pr_debug("Device opened\n");
	return 0;
}

static int nvme_gda_release(struct inode *inode, struct file *file)
{
	/* Clean up any queues created by this file descriptor */
	pr_debug("Device released\n");
	return 0;
}

static long nvme_gda_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	void __user *argp = (void __user *)arg;
	
	if (!gda_dev)
		return -ENODEV;
	
	switch (cmd) {
	case NVME_GDA_GET_DEVICE_INFO: {
		struct nvme_gda_device_info info;
		memset(&info, 0, sizeof(info));
		
		info.bar0_addr = gda_dev->bar0_phys;
		info.bar0_size = gda_dev->bar0_size;
		info.doorbell_stride = gda_dev->doorbell_stride;
		info.max_queue_entries = gda_dev->max_queue_entries;
		info.vendor_id = gda_dev->pdev->vendor;
		info.device_id = gda_dev->pdev->device;
		info.subsystem_vendor_id = gda_dev->pdev->subsystem_vendor;
		info.subsystem_device_id = gda_dev->pdev->subsystem_device;
		
		if (copy_to_user(argp, &info, sizeof(info)))
			return -EFAULT;
		return 0;
	}
	
	case NVME_GDA_CREATE_QUEUE: {
		struct nvme_gda_create_queue req;
		struct nvme_gda_queue *queue;
		
		if (copy_from_user(&req, argp, sizeof(req)))
			return -EFAULT;
		
		queue = nvme_gda_create_queue_internal(gda_dev, req.qsize);
		if (IS_ERR(queue))
			return PTR_ERR(queue);
		
		file->private_data = queue;
		req.flags = queue->qid;  /* Return QID in flags */
		
		if (copy_to_user(argp, &req, sizeof(req)))
			return -EFAULT;
		
		return 0;
	}
	
	case NVME_GDA_GET_QUEUE_INFO: {
		struct nvme_gda_queue_info info;
		struct nvme_gda_queue *queue = file->private_data;
		
		if (!queue)
			return -EINVAL;
		
		memset(&info, 0, sizeof(info));
		info.qid = queue->qid;
		info.qsize = queue->qsize;
		info.sqe_dma_addr = queue->sqes_dma;
		info.cqe_dma_addr = queue->cqes_dma;
		info.sq_doorbell_offset = queue->sq_doorbell_offset;
		info.cq_doorbell_offset = queue->cq_doorbell_offset;
		info.sqe_mmap_offset = NVME_GDA_MMAP_SQE;
		info.cqe_mmap_offset = NVME_GDA_MMAP_CQE;
		info.doorbell_mmap_offset = NVME_GDA_MMAP_DOORBELL;
		
		if (copy_to_user(argp, &info, sizeof(info)))
			return -EFAULT;
		
		return 0;
	}
	
	case NVME_GDA_DESTROY_QUEUE: {
		u16 qid;
		if (copy_from_user(&qid, argp, sizeof(qid)))
			return -EFAULT;
		
		nvme_gda_destroy_queue_internal(gda_dev, qid);
		file->private_data = NULL;
		return 0;
	}
	
	default:
		return -ENOTTY;
	}
}

static int nvme_gda_mmap(struct file *file, struct vm_area_struct *vma)
{
	struct nvme_gda_queue *queue = file->private_data;
	unsigned long size = vma->vm_end - vma->vm_start;
	unsigned long pfn;
	int region = vma->vm_pgoff;
	
	pr_info("mmap called: region=%d, size=%lu, qsize=%u\n", region, size, queue ? queue->qsize : 0);
	
	if (!queue) {
		pr_err("No queue associated with file\n");
		return -EINVAL;
	}
	
	/* Set memory attributes for fine-grained GPU access */
	vm_flags_set(vma, VM_IO | VM_DONTEXPAND | VM_DONTDUMP);
	vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
	
	switch (region) {
	case NVME_GDA_MMAP_SQE:
		/* Map submission queue - allow page-aligned size */
		pr_info("SQE mmap: requested=%lu, buffer_size=%lu (page-aligned=%lu)\n", 
		        size, (unsigned long)(queue->qsize * NVME_SQE_SIZE),
		        PAGE_ALIGN(queue->qsize * NVME_SQE_SIZE));
		if (size != PAGE_ALIGN(queue->qsize * NVME_SQE_SIZE)) {
			pr_err("SQE mmap size mismatch: got %lu, expected %lu\n", 
			       size, PAGE_ALIGN(queue->qsize * NVME_SQE_SIZE));
			return -EINVAL;
		}
		pfn = virt_to_phys(queue->sqes) >> PAGE_SHIFT;
		break;
		
	case NVME_GDA_MMAP_CQE:
		/* Map completion queue */
		if (size != PAGE_ALIGN(queue->qsize * NVME_CQE_SIZE)) {
			pr_err("CQE mmap size mismatch\n");
			return -EINVAL;
		}
		pfn = virt_to_phys(queue->cqes) >> PAGE_SHIFT;
		break;
		
	case NVME_GDA_MMAP_DOORBELL:
		/* Map doorbell registers (BAR0 region) */
		if (size > PAGE_SIZE) {
			pr_err("Doorbell mmap size too large\n");
			return -EINVAL;
		}
		pfn = (gda_dev->bar0_phys + 0x1000) >> PAGE_SHIFT;
		vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);
		break;
		
	default:
		pr_err("Invalid mmap region: %d\n", region);
		return -EINVAL;
	}
	
	if (remap_pfn_range(vma, vma->vm_start, pfn, size, vma->vm_page_prot)) {
		pr_err("remap_pfn_range failed\n");
		return -EAGAIN;
	}
	
	pr_debug("Mapped region %d: pfn=0x%lx, size=0x%lx\n", region, pfn, size);
	return 0;
}

/*
 * PCI probe
 */
static int nvme_gda_pci_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	int err;
	u64 cap;
	
	pr_info("Probing NVMe device %s\n", pci_name(pdev));
	
	if (gda_dev) {
		pr_err("Only one NVMe device supported\n");
		return -EBUSY;
	}
	
	gda_dev = kzalloc(sizeof(*gda_dev), GFP_KERNEL);
	if (!gda_dev)
		return -ENOMEM;
	
	gda_dev->pdev = pdev;
	spin_lock_init(&gda_dev->queue_lock);
	
	/* Enable PCI device */
	err = pci_enable_device_mem(pdev);
	if (err) {
		pr_err("Failed to enable PCI device\n");
		goto err_free_dev;
	}
	
	pci_set_master(pdev);
	
	/* Setup DMA */
	err = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
	if (err) {
		pr_err("No suitable DMA available\n");
		goto err_disable_device;
	}
	
	/* Map BAR0 */
	err = pci_request_regions(pdev, DRIVER_NAME);
	if (err) {
		pr_err("Failed to request PCI regions\n");
		goto err_disable_device;
	}
	
	gda_dev->bar0_phys = pci_resource_start(pdev, 0);
	gda_dev->bar0_size = pci_resource_len(pdev, 0);
	gda_dev->bar0 = pci_iomap(pdev, 0, 0);
	
	if (!gda_dev->bar0) {
		pr_err("Failed to map BAR0\n");
		err = -ENOMEM;
		goto err_release_regions;
	}
	
	pr_info("BAR0: phys=0x%llx, size=0x%llx, virt=%p\n",
	        gda_dev->bar0_phys, gda_dev->bar0_size, gda_dev->bar0);
	
	/* Read NVMe capabilities */
	cap = readq(gda_dev->bar0 + 0x00);  /* CAP register (64-bit) */
	gda_dev->doorbell_stride = (cap >> 32) & 0xf;
	gda_dev->max_queue_entries = (cap & 0xffff) + 1;
	
	pr_info("NVMe capabilities: doorbell_stride=%u, max_queue_entries=%u\n",
	        gda_dev->doorbell_stride, gda_dev->max_queue_entries);
	
	return 0;

err_release_regions:
	pci_release_regions(pdev);
err_disable_device:
	pci_disable_device(pdev);
err_free_dev:
	kfree(gda_dev);
	gda_dev = NULL;
	return err;
}

static void nvme_gda_pci_remove(struct pci_dev *pdev)
{
	int i;
	
	if (!gda_dev)
		return;
	
	pr_info("Removing NVMe GDA device\n");
	
	/* Destroy all queues */
	for (i = 1; i < 256; i++) {
		if (gda_dev->queues[i])
			nvme_gda_destroy_queue_internal(gda_dev, i);
	}
	
	/* Unmap BAR0 */
	if (gda_dev->bar0)
		pci_iounmap(pdev, gda_dev->bar0);
	
	pci_release_regions(pdev);
	pci_disable_device(pdev);
	
	kfree(gda_dev);
	gda_dev = NULL;
}

static struct pci_device_id nvme_gda_pci_ids[] = {
	{ PCI_DEVICE_CLASS(PCI_CLASS_STORAGE_EXPRESS, 0xffffff) },
	{ 0, }
};
MODULE_DEVICE_TABLE(pci, nvme_gda_pci_ids);

static struct pci_driver nvme_gda_pci_driver = {
	.name = DRIVER_NAME,
	.id_table = nvme_gda_pci_ids,
	.probe = nvme_gda_pci_probe,
	.remove = nvme_gda_pci_remove,
};

/*
 * Module init/exit
 */
static int __init nvme_gda_init(void)
{
	int err;
	
	pr_info("NVMe GDA Driver v%s initializing\n", DRIVER_VERSION);
	
	/* Register character device */
	err = alloc_chrdev_region(&nvme_gda_devt, 0, 1, DRIVER_NAME);
	if (err) {
		pr_err("Failed to allocate char device region\n");
		return err;
	}
	
	cdev_init(&nvme_gda_cdev, &nvme_gda_fops);
	nvme_gda_cdev.owner = THIS_MODULE;
	
	err = cdev_add(&nvme_gda_cdev, nvme_gda_devt, 1);
	if (err) {
		pr_err("Failed to add cdev\n");
		goto err_unreg_chrdev;
	}
	
	/* Create device class */
	nvme_gda_class = class_create(DRIVER_NAME);
	if (IS_ERR(nvme_gda_class)) {
		pr_err("Failed to create device class\n");
		err = PTR_ERR(nvme_gda_class);
		goto err_del_cdev;
	}
	
	/* Create device */
	nvme_gda_device = device_create(nvme_gda_class, NULL, nvme_gda_devt,
	                                NULL, DRIVER_NAME "0");
	if (IS_ERR(nvme_gda_device)) {
		pr_err("Failed to create device\n");
		err = PTR_ERR(nvme_gda_device);
		goto err_destroy_class;
	}
	
	/* Register PCI driver */
	err = pci_register_driver(&nvme_gda_pci_driver);
	if (err) {
		pr_err("Failed to register PCI driver\n");
		goto err_destroy_device;
	}
	
	pr_info("NVMe GDA driver loaded successfully\n");
	return 0;

err_destroy_device:
	device_destroy(nvme_gda_class, nvme_gda_devt);
err_destroy_class:
	class_destroy(nvme_gda_class);
err_del_cdev:
	cdev_del(&nvme_gda_cdev);
err_unreg_chrdev:
	unregister_chrdev_region(nvme_gda_devt, 1);
	return err;
}

static void __exit nvme_gda_exit(void)
{
	pr_info("NVMe GDA driver unloading\n");
	
	pci_unregister_driver(&nvme_gda_pci_driver);
	device_destroy(nvme_gda_class, nvme_gda_devt);
	class_destroy(nvme_gda_class);
	cdev_del(&nvme_gda_cdev);
	unregister_chrdev_region(nvme_gda_devt, 1);
	
	pr_info("NVMe GDA driver unloaded\n");
}

module_init(nvme_gda_init);
module_exit(nvme_gda_exit);

