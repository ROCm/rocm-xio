/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * rocm-xio Kernel Module
 *
 * Provides a userspace interface for GPU-initiated I/O:
 * - VRAM physical address translation via dmabuf
 * - Explicit NVMe queue address registration via IOCTL
 * - Automatic PRP injection for NVMe commands via kprobe
 *   * CREATE_SQ/CREATE_CQ: Injects registered queue physical addresses
 *   * READ/WRITE: Injects buffer PRP1/PRP2 addresses from registered buffers
 * - Device information retrieval
 * - High-performance interfaces:
 *   * mmap: For fast address translation (future)
 *   * io_uring_cmd: For async high-performance operations (future)
 *
 * Usage:
 *   1. Userspace allocates GPU VRAM buffers (queues, data buffers etc)
 *   2. Get physical addresses via GET_VRAM_PHYS_ADDR ioctl
 *   3. Register queue addresses via REGISTER_QUEUE_ADDR ioctl
 *   4. Register data buffers via REGISTER_BUFFER ioctl (optional, for I/O)
 *   5. Use normal NVMe driver interface - kprobe automatically injects
 *      physical addresses into PRP1/PRP2 fields
 */

#include "rocm-xio.h"

#include <drm/drm_gem.h>
#include <drm/ttm/ttm_bo.h>
#include <drm/ttm/ttm_resource.h>
#include <linux/blk-mq.h>
#include <linux/blkdev.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/dma-buf.h>
#include <linux/dma-mapping.h>
#include <linux/file.h>
#include <linux/fs.h>
#include <linux/io_uring.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/kref.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/nvme.h>
#include <linux/pci.h>
#include <linux/scatterlist.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/version.h>
#include <linux/xarray.h>

#define DEVICE_NAME ROCM_XIO_DEVICE_NAME
#define CLASS_NAME "rocm_axiio"

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("ROCm AxIIO kernel module for GPU-initiated NVMe I/O");
MODULE_VERSION("1.0");
MODULE_INFO(import_ns, "DMA_BUF");

static int major_number;
static struct class* rocm_xio_class = NULL;
static struct device* rocm_xio_device = NULL;

/* Kprobe for NVMe command injection */
static struct kprobe nvme_kp = {
  .symbol_name = "nvme_submit_user_cmd",
};

/* Enable/disable injection (module parameter) */
static bool inject_enabled = true;

/* Forward declaration for kref_put release callback */
static void contig_alloc_release(struct kref* ref);
module_param(inject_enabled, bool, 0644);
MODULE_PARM_DESC(inject_enabled,
                 "Enable automatic PRP injection for NVMe commands");

/* Queue address registration for CREATE_SQ/CREATE_CQ injection */
struct queue_addr_entry {
  __u64 virt_addr;
  __u64 phys_addr;
  __u64 size;
  __u8 queue_type; /* 0=SQ, 1=CQ */
  __u16 nvme_bdf;  /* NVMe device BDF (0xBBDD format) */
  __u64 prp2;      /* PRP2 for PC=0 queues (0=none) */
  struct list_head list;
};

/* Buffer registration for I/O command injection */
struct vram_buffer_entry {
  __u64 virt_addr;
  __u64 phys_addr;
  __u64 size;
  struct list_head list;
  // For passthrough NVMe - keep attachment alive for P2PDMA
  struct dma_buf* dmabuf;
  struct dma_buf_attachment* attach;
  struct sg_table* sgt;
  struct pci_dev* nvme_pdev; // Keep reference to NVMe device
  bool is_passthrough;       // Track if this needs cleanup
};

static LIST_HEAD(queue_addrs);
static DEFINE_SPINLOCK(queue_addrs_lock);

static LIST_HEAD(vram_buffers);
static DEFINE_SPINLOCK(vram_buffers_lock);

/* Contiguous DMA allocations for CQR=1 multi-page queues */
struct contig_alloc_entry {
  void* cpu_addr;
  dma_addr_t dma_addr;
  size_t size;
  __u32 id;
  struct pci_dev* pdev;
  struct file* owner;
  struct kref ref;
  struct list_head list;
};

static LIST_HEAD(contig_allocs);
static DEFINE_SPINLOCK(contig_allocs_lock);
static __u32 contig_alloc_next_id = 1;

/*
 * Tracking for quiesced NVMe namespace request_queues.
 *
 * Each entry pins the userspace-provided block-device file so the
 * underlying struct block_device (and its request_queue) stays
 * valid for the duration of the quiesce window. Entries are owned
 * by the rocm-xio file that issued ROCM_XIO_QUIESCE_NS and are
 * released either by an explicit ROCM_XIO_UNQUIESCE_NS ioctl or
 * automatically when that fd is closed.
 *
 * Two flavours exist:
 *
 *   - mode == QUIESCED_NS_MODE_FULL: blk_mq_quiesce_queue() was
 *     called on the entire namespace request_queue. The block
 *     layer stops dispatching new I/O on every hardware queue
 *     backing this namespace.
 *
 *   - mode == QUIESCED_NS_MODE_HCTX: only the hardware context
 *     matching @hctx_idx (= qid - 1) is stopped via
 *     blk_mq_stop_hw_queue(). The kernel continues to dispatch
 *     I/O for the same namespace on the namespace's other
 *     hardware queues, which is the usual ask when rocm-xio only
 *     reclaims a single NVMe I/O queue ID.
 */
enum quiesced_ns_mode {
  QUIESCED_NS_MODE_FULL = 0,
  QUIESCED_NS_MODE_HCTX = 1,
};

struct quiesced_ns_entry {
  struct file* bdev_file;  /* pinned namespace bdev file */
  struct block_device* bd; /* convenience pointer (no extra ref) */
  struct file* owner;      /* rocm-xio fd that quiesced this ns */
  enum quiesced_ns_mode mode;
  unsigned int hctx_idx; /* only valid when mode == HCTX */
  struct list_head list;
};

static LIST_HEAD(quiesced_ns);
static DEFINE_MUTEX(quiesced_ns_lock);

static struct block_device* rocm_xio_file_to_bdev(struct file* bdev_file) {
  struct inode* inode;

  if (!bdev_file)
    return NULL;

  /*
   * On Linux 6.5+, opening /dev/<blkdev> from userspace stores
   * the devtmpfs inode in file->f_inode, while the real bdev
   * inode (which I_BDEV()'s container_of() arithmetic
   * expects) lives at file->f_mapping->host. Calling
   * file_inode() here yields a wild block_device pointer whose
   * deref produces faults like 'page fault for address
   * 0x100000010' inside the QUIESCE_NS ioctl. Use
   * f_mapping->host so I_BDEV() lands on the correct
   * bdev_inode container.
   */
  if (bdev_file->f_mapping)
    inode = bdev_file->f_mapping->host;
  else
    inode = file_inode(bdev_file);
  if (!inode || !S_ISBLK(inode->i_mode))
    return NULL;
  return I_BDEV(inode);
}

/*
 * Look up a hardware context by index on a request_queue. The
 * underlying storage changed during the 6.x kernel cycle: older
 * kernels embed an array (@queue_hw_ctx) while newer kernels use
 * an xarray (@hctx_table). The 6.5 merge window is the
 * transition point.
 */
static struct blk_mq_hw_ctx* rocm_xio_hctx_at(struct request_queue* q,
                                              unsigned int idx) {
  if (!q || idx >= q->nr_hw_queues)
    return NULL;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 5, 0)
  return xa_load(&q->hctx_table, idx);
#else
  return q->queue_hw_ctx[idx];
#endif
}

static void contig_alloc_release(struct kref* ref) {
  struct contig_alloc_entry* ca = container_of(ref, struct contig_alloc_entry,
                                               ref);
  dma_free_coherent(&ca->pdev->dev, ca->size, ca->cpu_addr, ca->dma_addr);
  pci_dev_put(ca->pdev);
  kfree(ca);
}

/*
 * --------------------------------------------------------------------
 * QID 8 wedge fix: snapshot kernel NVMe queue DMA addresses, and
 * re-create the queues on the device after xio-tester destroys them.
 * --------------------------------------------------------------------
 *
 * Why this exists:
 *
 *   xio-tester picks the highest available NVMe QID via sysfs
 *   queue_count, which collides with the QID the kernel already owns
 *   (e.g. QID 8 on an 8-vCPU guest). The kprobe on
 *   nvme_submit_user_cmd rewrites the PRP1 of the kernel's
 *   CREATE_SQ/CREATE_CQ to xio-tester's contig buffer, so the device
 *   side of the QID is silently re-pointed. On xio-tester exit, its
 *   DELETE_SQ/DELETE_CQ destroy the queue on the device but never
 *   recreate it -- yet the kernel's struct nvme_queue for that QID
 *   still believes it is live. The next kernel I/O scheduled to that
 *   hctx times out and forces a controller reset.
 *
 * Our fix:
 *
 *   - Snapshot each kernel queue's sq_dma_addr / cq_dma_addr / depth /
 *     cq_vector when nvme_alloc_queue() returns. The first batch of
 *     queues allocated at PCI probe (before this module loads) cannot
 *     be captured, so the very first xio-tester run after module load
 *     may still wedge once; the controller reset that follows hits
 *     nvme_alloc_queue() again and from then on we have snapshots.
 *
 *   - Track which (pdev, qid) pairs each rocm-xio fd hijacked by
 *     watching the kprobe inject into a CREATE_SQ/CREATE_CQ.
 *
 *   - In rocm_xio_release(), before freeing the contig pages, submit
 *     CREATE_CQ then CREATE_SQ for each poisoned (pdev, qid) using
 *     the snapshot's DMA addresses, so the device's per-QID context
 *     lines back up with the kernel's still-intact nvme_queue.
 *
 * Layout assumptions live in one struct redefinition below
 * (nvmeq_layout) gated on a kernel-version check, so an SRU that
 * reshuffles struct nvme_queue gets a hard compile-time hint.
 */

/* Forward declaration -- exported from nvme-core, declared here to
 * avoid pulling in drivers/nvme/host/nvme.h which is not in
 * /lib/modules/.../build/include.
 */
extern int nvme_submit_sync_cmd(struct request_queue* q,
                                struct nvme_command* cmd, void* buf,
                                unsigned bufflen);

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 8, 0) ||                            \
  LINUX_VERSION_CODE >= KERNEL_VERSION(6, 10, 0)
#warning "rocm-xio QID-restore code: struct nvme_queue layout copied from "    \
         "v6.8 drivers/nvme/host/pci.c. Re-verify on this kernel."
#endif

/*
 * Mirror of the private struct nvme_queue from
 * drivers/nvme/host/pci.c in Ubuntu 6.8.0-117. We only need the
 * leading fields up to and including @cq_vector. Do not reorder or
 * extend without verifying against the running kernel's pci.c.
 */
struct rocm_xio_nvmeq_layout {
  void* dev; /* struct nvme_dev * */
  spinlock_t sq_lock;
  void* sq_cmds;
  spinlock_t cq_poll_lock ____cacheline_aligned_in_smp;
  void* cqes; /* struct nvme_completion * */
  dma_addr_t sq_dma_addr;
  dma_addr_t cq_dma_addr;
  u32 __iomem* q_db;
  u32 q_depth;
  u16 cq_vector;
  u16 sq_tail;
  u16 last_sq_tail;
  u16 cq_head;
  u16 qid;
  u8 cq_phase;
  u8 sqes;
  unsigned long flags;
};

/* Bit positions within nvme_queue->flags. Copied from
 * drivers/nvme/host/pci.c. NVMEQ_POLLED is the only one we read.
 */
#define ROCM_XIO_NVMEQ_ENABLED 0
#define ROCM_XIO_NVMEQ_SQ_CMB 1
#define ROCM_XIO_NVMEQ_DELETE_ERROR 2
#define ROCM_XIO_NVMEQ_POLLED 3

/*
 * Mirror of the leading portion of struct nvme_dev. We only need the
 * @queues pointer and @dev (for to_pci_dev). queue_count lives inside
 * the embedded nvme_ctrl but we never read it from here; we always
 * cross-reference against our own snapshot list.
 */
struct rocm_xio_nvme_dev_layout {
  void* queues; /* struct nvme_queue * */
};

/*
 * Snapshot of one (pci_dev, qid) kernel-side NVMe queue. Keyed by
 * (pdev, qid). We hold a pci_dev ref so the bus address stays
 * meaningful even if the device unbinds.
 *
 * @admin_q is captured at snapshot time so we don't have to chase
 * private nvme_ctrl layout offsets at recreation time. It is the
 * request_queue we feed to nvme_submit_sync_cmd().
 */
struct nvme_queue_snapshot {
  struct pci_dev* pdev;
  u16 qid;
  dma_addr_t sq_dma_addr;
  dma_addr_t cq_dma_addr;
  u32 q_depth;
  u16 cq_vector;
  bool polled;
  struct request_queue* admin_q;
  /*
   * The struct nvme_dev* that owns this queue. Captured so the
   * resurrect path can reach the live struct nvme_queue via
   * dev->queues[qid] and reset its host-side ring pointers after
   * CREATE_CQ/CREATE_SQ (see rocm_xio_resurrect_work_fn). Stored as
   * void* because we never pull private nvme_dev fields through it
   * except @queues, which we reach via rocm_xio_nvme_dev_layout.
   */
  void* dev; /* struct nvme_dev * */
  struct list_head list;
};

static LIST_HEAD(nvme_queue_snapshots);
static DEFINE_SPINLOCK(nvme_queue_snapshots_lock);

/*
 * Per-(bdf, qid) record of queues that have been wedged by
 * xio-tester. Entries are added when the kprobe sees a hijacked
 * CREATE_SQ/CREATE_CQ. Entries are marked "needs_resurrect" when
 * the kprobe sees a DELETE_SQ/DELETE_CQ for the same (bdf, qid)
 * pair. A workqueue then runs in process context to issue
 * CREATE_CQ + CREATE_SQ via the snapshotted admin_q.
 *
 * Keyed globally by (bdf, qid), NOT by file owner. xio-tester
 * splits queue registration, contig allocation, and the actual
 * NVMe ops across multiple file descriptors, so a per-fd model
 * fires release-time resurrect against the wrong fd's lifetime.
 * Watching DELETE in the kprobe and scheduling work matches the
 * real "wedge event" (device-side queue destroyed by user
 * command).
 *
 * We deliberately store BDF rather than pci_dev* here because the
 * kprobe records entries from atomic context where
 * pci_get_domain_bus_and_slot() (which may sleep on the PCI bus
 * mutex) is not safe to call.
 */
struct poisoned_qid_entry {
  u16 bdf;
  u16 qid;
  bool created;         /* kprobe saw injected CREATE_* */
  bool needs_resurrect; /* kprobe saw DELETE_*, work not yet done */
  struct list_head list;
};

static LIST_HEAD(poisoned_qids);
static DEFINE_SPINLOCK(poisoned_qids_lock);

/* kretprobe storage: pass nvmeq + qid from entry to return handler.
 * Used by both nvme_alloc_queue (initial allocation) and
 * nvme_create_queue (per-create / per-reset).
 */
struct rocm_xio_alloc_queue_ctx {
  void* nvme_dev; /* struct nvme_dev *  (alloc_queue path) */
  void* nvmeq;    /* struct nvme_queue * (create_queue path) */
  int qid;
};

/*
 * Store or update a snapshot for (pdev, qid). Caller must hold a
 * reference on @pdev; on success the snapshot owns one additional
 * reference (we always pci_dev_get inside).
 */
static void nvme_queue_snapshot_store(struct pci_dev* pdev, u16 qid,
                                      dma_addr_t sq_dma, dma_addr_t cq_dma,
                                      u32 depth, u16 cq_vector, bool polled,
                                      struct request_queue* admin_q,
                                      void* nvme_dev) {
  struct nvme_queue_snapshot *snap, *existing;
  unsigned long flags_irq;
  bool replaced = false;

  snap = kmalloc(sizeof(*snap), GFP_ATOMIC);
  if (!snap) {
    pr_warn("rocm-axiio: snapshot kmalloc failed for %s qid=%u\n",
            pci_name(pdev), qid);
    return;
  }
  snap->pdev = pci_dev_get(pdev);
  snap->qid = qid;
  snap->sq_dma_addr = sq_dma;
  snap->cq_dma_addr = cq_dma;
  snap->q_depth = depth;
  snap->cq_vector = cq_vector;
  snap->polled = polled;
  snap->admin_q = admin_q;
  snap->dev = nvme_dev;
  INIT_LIST_HEAD(&snap->list);

  spin_lock_irqsave(&nvme_queue_snapshots_lock, flags_irq);
  list_for_each_entry(existing, &nvme_queue_snapshots, list) {
    if (existing->pdev == pdev && existing->qid == qid) {
      existing->sq_dma_addr = sq_dma;
      existing->cq_dma_addr = cq_dma;
      existing->q_depth = depth;
      existing->cq_vector = cq_vector;
      existing->polled = polled;
      existing->admin_q = admin_q;
      existing->dev = nvme_dev;
      replaced = true;
      break;
    }
  }
  if (!replaced)
    list_add(&snap->list, &nvme_queue_snapshots);
  spin_unlock_irqrestore(&nvme_queue_snapshots_lock, flags_irq);

  if (replaced) {
    pci_dev_put(snap->pdev);
    kfree(snap);
    pr_info("rocm-axiio: nvme queue snapshot UPDATED %s qid=%u "
            "sq=0x%llx cq=0x%llx depth=%u vec=%u polled=%d admin_q=%p\n",
            pci_name(pdev), qid, (unsigned long long)sq_dma,
            (unsigned long long)cq_dma, depth, cq_vector, (int)polled, admin_q);
  } else {
    pr_info("rocm-axiio: nvme queue snapshot CAPTURED %s qid=%u "
            "sq=0x%llx cq=0x%llx depth=%u vec=%u polled=%d admin_q=%p\n",
            pci_name(pdev), qid, (unsigned long long)sq_dma,
            (unsigned long long)cq_dma, depth, cq_vector, (int)polled, admin_q);
  }
}

/* Return a copy of the snapshot for (pdev, qid), or false if none. */
static bool nvme_queue_snapshot_lookup(struct pci_dev* pdev, u16 qid,
                                       struct nvme_queue_snapshot* out) {
  struct nvme_queue_snapshot* s;
  unsigned long flags_irq;
  bool found = false;

  spin_lock_irqsave(&nvme_queue_snapshots_lock, flags_irq);
  list_for_each_entry(s, &nvme_queue_snapshots, list) {
    if (s->pdev == pdev && s->qid == qid) {
      *out = *s;
      INIT_LIST_HEAD(&out->list);
      out->pdev = pdev; /* do not transfer ref */
      found = true;
      break;
    }
  }
  spin_unlock_irqrestore(&nvme_queue_snapshots_lock, flags_irq);
  return found;
}

static void nvme_queue_snapshots_free_all(void) {
  struct nvme_queue_snapshot *s, *tmp;
  unsigned long flags_irq;
  LIST_HEAD(to_free);

  spin_lock_irqsave(&nvme_queue_snapshots_lock, flags_irq);
  list_for_each_entry_safe(s, tmp, &nvme_queue_snapshots, list) {
    list_del(&s->list);
    list_add(&s->list, &to_free);
  }
  spin_unlock_irqrestore(&nvme_queue_snapshots_lock, flags_irq);

  list_for_each_entry_safe(s, tmp, &to_free, list) {
    list_del(&s->list);
    pci_dev_put(s->pdev);
    kfree(s);
  }
}

/* Forward decl: workqueue handler does the actual resurrect.
 *
 * Use delayed_work with a short delay so we run AFTER the user-issued
 * DELETE_SQ/DELETE_CQ pair has completed on the device. The kprobe
 * fires in pre-handler context (before the kernel submits the
 * DELETE command to the controller), so an immediate schedule_work
 * can race the controller-side teardown and we'd CREATE_CQ against
 * a still-live CQ (returns 0x4101 Invalid Queue Identifier).
 *
 * 250ms is well over a single admin-command latency in the worst
 * case while still being unnoticeable to the next kernel I/O on
 * that hctx.
 */
#define ROCM_XIO_RESURRECT_DELAY_MS 250
static void rocm_xio_resurrect_work_fn(struct work_struct* w);
static DECLARE_DELAYED_WORK(rocm_xio_resurrect_work,
                            rocm_xio_resurrect_work_fn);

/*
 * Mark (bdf, qid) as hijacked by a kprobe-injected CREATE_*.
 * Idempotent. Called from kprobe pre-handler (atomic).
 */
static void poisoned_qid_mark_created(u16 bdf, u16 qid) {
  struct poisoned_qid_entry *e, *existing = NULL;
  unsigned long flags_irq;

  spin_lock_irqsave(&poisoned_qids_lock, flags_irq);
  list_for_each_entry(e, &poisoned_qids, list) {
    if (e->bdf == bdf && e->qid == qid) {
      existing = e;
      break;
    }
  }
  if (existing) {
    existing->created = true;
    spin_unlock_irqrestore(&poisoned_qids_lock, flags_irq);
    return;
  }
  spin_unlock_irqrestore(&poisoned_qids_lock, flags_irq);

  e = kmalloc(sizeof(*e), GFP_ATOMIC);
  if (!e) {
    pr_warn("rocm-axiio: poisoned_qid kmalloc failed for bdf=0x%04x qid=%u\n",
            bdf, qid);
    return;
  }
  e->bdf = bdf;
  e->qid = qid;
  e->created = true;
  e->needs_resurrect = false;
  INIT_LIST_HEAD(&e->list);

  spin_lock_irqsave(&poisoned_qids_lock, flags_irq);
  /* Re-check under lock */
  list_for_each_entry(existing, &poisoned_qids, list) {
    if (existing->bdf == bdf && existing->qid == qid) {
      existing->created = true;
      spin_unlock_irqrestore(&poisoned_qids_lock, flags_irq);
      kfree(e);
      return;
    }
  }
  list_add(&e->list, &poisoned_qids);
  spin_unlock_irqrestore(&poisoned_qids_lock, flags_irq);

  pr_info("rocm-axiio: tracked hijacked CREATE_* on bdf 0x%04x qid %u\n", bdf,
          qid);
}

/*
 * Mark (bdf, qid) as deleted on the device by a user-issued
 * DELETE_*. If we previously saw a hijacked CREATE_* for the same
 * pair, schedule resurrection. Called from kprobe pre-handler
 * (atomic).
 *
 * Note: this must be called on DELETE_CQ (opcode 0x04), not
 * DELETE_SQ. DELETE_SQ is sent first, DELETE_CQ second, and the
 * device must have processed BOTH before we can issue CREATE_CQ
 * for the same QID -- otherwise the controller still sees a live
 * CQ and rejects our CREATE_CQ with Invalid Queue Identifier
 * (0x4101). Scheduling on DELETE_CQ guarantees the pair has at
 * least reached the controller.
 */
static void poisoned_qid_mark_deleted(u16 bdf, u16 qid) {
  struct poisoned_qid_entry* e;
  unsigned long flags_irq;
  bool schedule = false;

  spin_lock_irqsave(&poisoned_qids_lock, flags_irq);
  list_for_each_entry(e, &poisoned_qids, list) {
    if (e->bdf == bdf && e->qid == qid) {
      if (e->created) {
        e->needs_resurrect = true;
        schedule = true;
      }
      break;
    }
  }
  spin_unlock_irqrestore(&poisoned_qids_lock, flags_irq);

  if (schedule) {
    pr_info("rocm-axiio: user DELETE on bdf 0x%04x qid %u; scheduling "
            "queue resurrection in %u ms\n",
            bdf, qid, ROCM_XIO_RESURRECT_DELAY_MS);
    /* mod_delayed_work coalesces multiple DELETE events into a
     * single resurrect pass at the latest scheduled time. */
    mod_delayed_work(system_wq, &rocm_xio_resurrect_work,
                     msecs_to_jiffies(ROCM_XIO_RESURRECT_DELAY_MS));
  }
}

/* kretprobe entry for nvme_alloc_queue(dev, qid, depth):
 * stash (dev, qid) from RDI/RSI.
 */
static int nvme_alloc_queue_entry_handler(struct kretprobe_instance* ri,
                                          struct pt_regs* regs) {
  struct rocm_xio_alloc_queue_ctx* ctx = (struct rocm_xio_alloc_queue_ctx*)
                                           ri->data;
#ifdef CONFIG_X86_64
  ctx->nvme_dev = (void*)regs->di;
  ctx->nvmeq = NULL;
  ctx->qid = (int)regs->si;
#else
  ctx->nvme_dev = NULL;
  ctx->nvmeq = NULL;
  ctx->qid = -1;
#endif
  return 0;
}

/* kretprobe entry for nvme_create_queue(nvmeq, qid, polled):
 * stash (nvmeq, qid) from RDI/RSI.
 */
static int nvme_create_queue_entry_handler(struct kretprobe_instance* ri,
                                           struct pt_regs* regs) {
  struct rocm_xio_alloc_queue_ctx* ctx = (struct rocm_xio_alloc_queue_ctx*)
                                           ri->data;
#ifdef CONFIG_X86_64
  ctx->nvme_dev = NULL;
  ctx->nvmeq = (void*)regs->di;
  ctx->qid = (int)regs->si;
#else
  ctx->nvme_dev = NULL;
  ctx->nvmeq = NULL;
  ctx->qid = -1;
#endif
  return 0;
}

/* kretprobe return: if call succeeded, snapshot dev->queues[qid]. */
static int nvme_alloc_queue_ret_handler(struct kretprobe_instance* ri,
                                        struct pt_regs* regs) {
  struct rocm_xio_alloc_queue_ctx* ctx = (struct rocm_xio_alloc_queue_ctx*)
                                           ri->data;
  struct rocm_xio_nvme_dev_layout* dev_layout;
  struct rocm_xio_nvmeq_layout* nvmeq;
  struct pci_dev* pdev;
  long retval;

#ifdef CONFIG_X86_64
  retval = (long)regs->ax;
#else
  return 0;
#endif

  if (retval != 0)
    return 0; /* alloc failed, nothing to snapshot */
  if (!ctx->nvme_dev || ctx->qid < 0)
    return 0;

  dev_layout = (struct rocm_xio_nvme_dev_layout*)ctx->nvme_dev;
  if (!dev_layout->queues)
    return 0;

  /*
   * dev->queues is an array of struct nvme_queue. The stride is the
   * real sizeof(struct nvme_queue) the kernel built with, NOT the
   * size of our mirror. Verified via pahole on 6.8.0-117-generic
   * BTF: sizeof(struct nvme_queue) == 192 bytes.
   */
  {
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 8, 0) &&                           \
  LINUX_VERSION_CODE < KERNEL_VERSION(6, 10, 0)
    const size_t kernel_nvmeq_stride = 192;
#else
    const size_t kernel_nvmeq_stride = sizeof(struct rocm_xio_nvmeq_layout);
#endif
    nvmeq = (struct rocm_xio_nvmeq_layout*)((u8*)dev_layout->queues +
                                            (size_t)ctx->qid *
                                              kernel_nvmeq_stride);
  }

  /*
   * Resolve struct pci_dev from struct nvme_dev. struct nvme_dev's
   * @dev field is at a known offset just after @admin_tagset; rather
   * than encode that, we use ctx->nvme_dev only to access the @queues
   * array, and instead pull the pci_dev from a back-reference we
   * already have: every snapshot covers one NVMe controller, and the
   * kprobe also runs in the context of a specific @q -> request_queue
   * whose ->queuedata leads back to nvme_dev. That detour is hard
   * here. The simplest reliable path: read @nvmeq->dev (a struct
   * nvme_dev *), then walk the global pci bus to find the pci_dev
   * whose ->driver_data == that nvme_dev.
   */
  {
    void* nvme_dev_ptr = nvmeq->dev;
    struct pci_dev* iter = NULL;
    pdev = NULL;
    /* for_each_pci_dev() walks via pci_get_device() which takes a
     * ref on each visited dev; the macro auto-puts the previous
     * iterator when advancing, but a 'break' leaves a ref on the
     * matching dev. We intentionally keep that ref while
     * snapshotting -- it's transferred into the snapshot entry
     * via pci_dev_get inside nvme_queue_snapshot_store, which
     * means we must drop one extra ref here.
     */
    for_each_pci_dev(iter) {
      if (iter->driver && pci_get_drvdata(iter) == nvme_dev_ptr) {
        pdev = iter;
        break;
      }
    }
  }

  if (!pdev) {
    pr_warn("rocm-axiio: snapshot: could not resolve pci_dev for "
            "nvme_dev=%p qid=%d\n",
            ctx->nvme_dev, ctx->qid);
    return 0;
  }

  /*
   * Extract admin_q from struct nvme_dev. Layout (from pahole on
   * 6.8.0-117-generic): struct nvme_ctrl is embedded in nvme_dev
   * at offset 496; nvme_ctrl->admin_q is at offset 56 within
   * nvme_ctrl. Total = 552.
   */
  {
    const size_t NVME_DEV_CTRL_OFFSET = 496;
    const size_t NVME_CTRL_ADMIN_Q_OFFSET = 56;
    struct request_queue* admin_q = *(
      struct request_queue**)((u8*)ctx->nvme_dev + NVME_DEV_CTRL_OFFSET +
                              NVME_CTRL_ADMIN_Q_OFFSET);

    nvme_queue_snapshot_store(pdev, (u16)ctx->qid, nvmeq->sq_dma_addr,
                              nvmeq->cq_dma_addr, nvmeq->q_depth,
                              nvmeq->cq_vector,
                              test_bit(ROCM_XIO_NVMEQ_POLLED, &nvmeq->flags),
                              admin_q, ctx->nvme_dev);
  }
  /* Drop the ref left by the 'break' out of for_each_pci_dev. */
  pci_dev_put(pdev);
  return 0;
}

static struct kretprobe nvme_alloc_queue_krp = {
  .kp.symbol_name = "nvme_alloc_queue",
  .entry_handler = nvme_alloc_queue_entry_handler,
  .handler = nvme_alloc_queue_ret_handler,
  .data_size = sizeof(struct rocm_xio_alloc_queue_ctx),
  .maxactive = 32,
};

static bool nvme_alloc_queue_krp_registered = false;

/* kretprobe return for nvme_create_queue: read nvmeq fields directly.
 * Snapshot is captured for every (pdev, qid) on every reset, since
 * nvme_create_queue is invoked each time the controller comes back.
 */
static int nvme_create_queue_ret_handler(struct kretprobe_instance* ri,
                                         struct pt_regs* regs) {
  struct rocm_xio_alloc_queue_ctx* ctx = (struct rocm_xio_alloc_queue_ctx*)
                                           ri->data;
  struct rocm_xio_nvmeq_layout* nvmeq;
  struct pci_dev* pdev = NULL;
  void* nvme_dev_ptr;
  long retval;

#ifdef CONFIG_X86_64
  retval = (long)regs->ax;
#else
  return 0;
#endif

  if (retval != 0)
    return 0;
  if (!ctx->nvmeq || ctx->qid < 0)
    return 0;

  nvmeq = (struct rocm_xio_nvmeq_layout*)ctx->nvmeq;
  nvme_dev_ptr = nvmeq->dev;

  {
    struct pci_dev* iter = NULL;
    for_each_pci_dev(iter) {
      if (iter->driver && pci_get_drvdata(iter) == nvme_dev_ptr) {
        pdev = iter;
        break;
      }
    }
  }

  if (!pdev) {
    pr_warn("rocm-axiio: snapshot(create_queue): could not resolve pci_dev "
            "for nvme_dev=%p qid=%d\n",
            nvme_dev_ptr, ctx->qid);
    return 0;
  }

  {
    const size_t NVME_DEV_CTRL_OFFSET = 496;
    const size_t NVME_CTRL_ADMIN_Q_OFFSET = 56;
    struct request_queue* admin_q = *(
      struct request_queue**)((u8*)nvme_dev_ptr + NVME_DEV_CTRL_OFFSET +
                              NVME_CTRL_ADMIN_Q_OFFSET);
    nvme_queue_snapshot_store(pdev, (u16)ctx->qid, nvmeq->sq_dma_addr,
                              nvmeq->cq_dma_addr, nvmeq->q_depth,
                              nvmeq->cq_vector,
                              test_bit(ROCM_XIO_NVMEQ_POLLED, &nvmeq->flags),
                              admin_q, nvme_dev_ptr);
  }
  pci_dev_put(pdev);
  return 0;
}

static struct kretprobe nvme_create_queue_krp = {
  .kp.symbol_name = "nvme_create_queue",
  .entry_handler = nvme_create_queue_entry_handler,
  .handler = nvme_create_queue_ret_handler,
  .data_size = sizeof(struct rocm_xio_alloc_queue_ctx),
  .maxactive = 32,
};

static bool nvme_create_queue_krp_registered = false;

static void contig_vma_open(struct vm_area_struct* vma) {
  struct contig_alloc_entry* ca = vma->vm_private_data;
  kref_get(&ca->ref);
}

static void contig_vma_close(struct vm_area_struct* vma) {
  struct contig_alloc_entry* ca = vma->vm_private_data;
  kref_put(&ca->ref, contig_alloc_release);
}

static const struct vm_operations_struct contig_vm_ops = {
  .open = contig_vma_open,
  .close = contig_vma_close,
};

/* PCI MMIO bridge shadow buffer mapping */
static __u64 mmio_bridge_shadow_gpa = 0;
static __u64 mmio_bridge_shadow_size = 0;
static DEFINE_MUTEX(mmio_bridge_lock);

/*
 * DMA-BUF attach ops for P2P support.
 * We pin the buffer, so move_notify should never be called.
 */
static void rocm_xio_move_notify(struct dma_buf_attachment* attach) {
  pr_warn_ratelimited("rocm-axiio: move_notify called on pinned buffer "
                      "(should not happen)\n");
}

static const struct dma_buf_attach_ops rocm_xio_attach_ops = {
  .allow_peer2peer = true,
  .move_notify = rocm_xio_move_notify,
};

/*
 * Extract the actual VRAM offset from AMDGPU's internal buffer object.
 * The dmabuf->priv points to the amdgpu_bo, which contains the TTM resource
 * with the real VRAM page offset.
 */
static int extract_vram_offset_from_amdgpu_bo(struct dma_buf* dmabuf,
                                              resource_size_t bar_start,
                                              resource_size_t bar_size,
                                              __u64* offset) {
  struct drm_gem_object* gem_obj;
  struct ttm_buffer_object* tbo;
  struct ttm_resource* resource;
  unsigned long page_offset;

  if (!dmabuf || !dmabuf->priv) {
    pr_err("rocm-axiio: Invalid dmabuf or missing private data\n");
    return -EINVAL;
  }

  /*
   * For DRM/TTM dmabufs, priv points to drm_gem_object,
   * which is the 'base' field (first field) of ttm_buffer_object.
   * Use container_of to get the ttm_buffer_object.
   */
  gem_obj = (struct drm_gem_object*)dmabuf->priv;
  tbo = container_of(gem_obj, struct ttm_buffer_object, base);

  if (!tbo->resource) {
    pr_err("rocm-axiio: TTM resource not available\n");
    return -EINVAL;
  }

  resource = tbo->resource;

  /* resource->start is the VRAM offset in pages */
  page_offset = resource->start;

  /* Convert page offset to byte offset (assuming 4KB pages) */
  *offset = page_offset << PAGE_SHIFT;

  pr_info("rocm-axiio: Extracted from TTM resource:\n");
  pr_info("  page_offset=0x%lx, byte_offset=0x%llx\n", page_offset, *offset);
  pr_info("  resource.mem_type=%u, size=0x%zx\n", resource->mem_type,
          resource->size);

  /* Verify this is actually VRAM (mem_type should be TTM_PL_VRAM = 2) */
  if (resource->mem_type != 2) {
    pr_err("rocm-axiio: Buffer is not in VRAM (mem_type=%u, expected 2)\n",
           resource->mem_type);
    return -EINVAL;
  }

  /* Sanity check: offset should be within BAR size */
  if (*offset >= bar_size) {
    pr_warn("rocm-axiio: Calculated offset 0x%llx exceeds BAR size 0x%llx\n",
            *offset, (u64)bar_size);
    /* Continue anyway - might be correct for large VRAM BARs */
  }

  return 0;
}

/*
 * Extract VRAM physical offset from scatter-gather table
 */
static int extract_vram_offset_from_sg(struct sg_table* sgt,
                                       struct pci_dev* gpu_dev,
                                       resource_size_t bar_start,
                                       resource_size_t bar_size,
                                       struct dma_buf* dmabuf, __u64* offset) {
  struct scatterlist* sg;
  dma_addr_t dma_addr;
  phys_addr_t phys_addr;
  int i;

  if (!sgt || sgt->nents == 0) {
    return -EINVAL;
  }

  /* Log what we see in the scatter-gather table */
  for_each_sg(sgt->sgl, sg, sgt->nents, i) {
    phys_addr = sg_phys(sg);
    dma_addr = sg_dma_address(sg);

    pr_info("rocm-axiio: sg[%d]: phys=0x%llx dma=0x%llx len=%u\n", i,
            (u64)phys_addr, (u64)dma_addr, sg->length);

    /* Check if physical address is within the GPU BAR range */
    if (phys_addr >= bar_start && phys_addr < (bar_start + bar_size)) {
      *offset = phys_addr - bar_start;
      pr_info("rocm-axiio: Found VRAM offset from sg_phys: 0x%llx\n", *offset);
      return 0;
    }
  }

  /*
   * The sg_table doesn't have GPU BAR addresses (as expected for VRAM).
   * Try to extract the real VRAM offset from AMDGPU's TTM resource first.
   */
  pr_info("rocm-axiio: Trying TTM resource extraction...\n");
  if (extract_vram_offset_from_amdgpu_bo(dmabuf, bar_start, bar_size, offset) ==
      0) {
    /* Success! TTM gave us the real offset */
    return 0;
  }

  /*
   * TTM extraction failed. Fallback to DMA address heuristic.
   * For P2PDMA, the DMA address sometimes encodes the offset within the
   * resource.
   */
  sg = sgt->sgl;
  dma_addr = sg_dma_address(sg);

  pr_info("rocm-axiio: TTM failed, trying DMA address as direct offset: "
          "0x%llx\n",
          (u64)dma_addr);

  if (dma_addr > 0 && dma_addr < bar_size) {
    *offset = dma_addr;
    pr_warn("rocm-axiio: Using DMA address as VRAM offset (may be wrong!): "
            "0x%llx\n",
            *offset);
    return 0;
  }

  pr_err("rocm-axiio: Could not extract VRAM offset from sg_table or TTM\n");
  pr_err("rocm-axiio: dma_addr=0x%llx bar_size=0x%llx\n", (u64)dma_addr,
         (u64)bar_size);

  return -EINVAL;
}

/* Get GPU BAR GPA for emulated NVMe (returns guest-visible BAR address) */
static int get_dmabuf_bar_gpa(int dmabuf_fd, __u64* bar_gpa, __u64* size) {
  struct dma_buf* dmabuf;
  struct pci_dev* gpu_dev = NULL;
  struct sg_table* sgt = NULL;
  struct dma_buf_attachment* attach = NULL;
  resource_size_t bar_start, bar_size;
  int ret = 0;
  int i;

  /* Get dmabuf */
  dmabuf = dma_buf_get(dmabuf_fd);
  if (IS_ERR(dmabuf)) {
    pr_err("rocm-axiio: dma_buf_get failed: %ld\n", PTR_ERR(dmabuf));
    return PTR_ERR(dmabuf);
  }

  *size = dmabuf->size;

  /* Find AMD GPU by scanning PCI devices */
  gpu_dev = pci_get_device(PCI_VENDOR_ID_ATI, PCI_ANY_ID, NULL);
  if (!gpu_dev) {
    pr_err("rocm-axiio: AMD GPU not found\n");
    ret = -ENODEV;
    goto cleanup_no_attach;
  }

  /*
   * Use dynamic attach with P2P support.
   * This tells AMDGPU we support peer-to-peer DMA, so it will
   * keep the buffer in VRAM instead of forcing it to GTT.
   * We pin the buffer immediately after attach, so move_notify
   * should never be called (buffer is pinned and can't move).
   */
  attach = dma_buf_dynamic_attach(dmabuf, &gpu_dev->dev, &rocm_xio_attach_ops,
                                  NULL);
  if (IS_ERR(attach)) {
    pr_err("rocm-axiio: dma_buf_dynamic_attach failed: %ld\n", PTR_ERR(attach));
    ret = PTR_ERR(attach);
    goto cleanup_no_attach;
  }

  /* Pin the buffer so it doesn't move */
  ret = dma_buf_pin(attach);
  if (ret) {
    pr_err("rocm-axiio: dma_buf_pin failed: %d\n", ret);
    goto cleanup_detach;
  }

  sgt = dma_buf_map_attachment(attach, DMA_BIDIRECTIONAL);
  if (IS_ERR(sgt)) {
    pr_err("rocm-axiio: dma_buf_map_attachment failed: %ld\n", PTR_ERR(sgt));
    ret = PTR_ERR(sgt);
    goto cleanup;
  }

  pr_info("rocm-axiio: dmabuf mapped: nents=%u\n", sgt->nents);

  /* Find the GPU VRAM BAR */
  for (i = 0; i < PCI_STD_NUM_BARS; i++) {
    if (!(pci_resource_flags(gpu_dev, i) & IORESOURCE_MEM))
      continue;

    bar_start = pci_resource_start(gpu_dev, i);
    bar_size = pci_resource_len(gpu_dev, i);

    /* Use BAR 0 for VRAM (typical for AMD GPUs) */
    if (i == 0 && (pci_resource_flags(gpu_dev, i) & IORESOURCE_PREFETCH)) {
      pr_info("rocm-axiio: Found GPU VRAM BAR%d: GPA=0x%llx size=0x%llx\n", i,
              (u64)bar_start, (u64)bar_size);

      /*
       * Extract the actual VRAM offset from the scatter-gather table
       * This should give us the physical offset within the GPU's VRAM BAR
       */
      __u64 vram_offset = 0;
      if (extract_vram_offset_from_sg(sgt, gpu_dev, bar_start, bar_size, dmabuf,
                                      &vram_offset) == 0) {
        *bar_gpa = bar_start + vram_offset;
        pr_info("rocm-axiio: BAR GPA=0x%llx (base=0x%llx + offset=0x%llx)\n",
                *bar_gpa, (u64)bar_start, vram_offset);
      } else {
        /* Fallback: return BAR base (will be wrong but better than crashing) */
        *bar_gpa = bar_start;
        pr_warn("rocm-axiio: Failed to extract offset, using BAR base\n");
      }

      ret = 0;
      goto cleanup;
    }
  }

  pr_err("rocm-axiio: No suitable GPU VRAM BAR found\n");
  ret = -EINVAL;

cleanup:
  if (sgt && !IS_ERR(sgt))
    dma_buf_unmap_attachment(attach, sgt, DMA_BIDIRECTIONAL);
  if (attach && !IS_ERR(attach)) {
    dma_buf_unpin(attach);
  cleanup_detach:
    dma_buf_detach(dmabuf, attach);
  }
cleanup_no_attach:
  if (gpu_dev)
    pci_dev_put(gpu_dev);
  dma_buf_put(dmabuf);
  return ret;
}

/* Get physical address from dmabuf using DMA API (for passthrough NVMe)
 * Attaches dmabuf to NVMe device and returns P2PDMA IOVA
 * Returns attachment info via output parameters - caller must keep alive
 */
/* Extract BDF from pci_dev structure */
static __u16 pci_dev_to_bdf(struct pci_dev* pdev) {
  if (!pdev)
    return 0;
  /* Encode BDF: format is 0xBBDD (bus=B, dev=D, func=F) */
  return ((__u16)(pdev->bus->number) << 8) | (__u16)(pdev->devfn);
}

/* Format BDF as PCI address string (e.g., "0000:85:00.0") */
static void format_bdf_as_pci_addr(__u16 bdf, char* buf, size_t buf_size) {
  if (bdf == 0 || !buf || buf_size < 13) {
    if (buf && buf_size > 0)
      buf[0] = '\0';
    return;
  }

  /* Decode BDF: format is 0xBBDD (bus=B, dev=D, func=F) */
  unsigned int bus = (bdf >> 8) & 0xFF;
  unsigned int devfn = bdf & 0xFF;
  unsigned int device = (devfn >> 3) & 0x1F;
  unsigned int function = devfn & 0x7;

  /* Format as DDDD:BB:DD.F (domain is always 0000 for now) */
  snprintf(buf, buf_size, "0000:%02x:%02x.%x", bus, device, function);
}

static int get_dmabuf_phys_addr(int dmabuf_fd, __u16 nvme_bdf, __u64* phys_addr,
                                __u64* size, struct dma_buf** dmabuf_out,
                                struct dma_buf_attachment** attach_out,
                                struct sg_table** sgt_out,
                                struct pci_dev** pdev_out) {
  struct dma_buf* dmabuf;
  struct dma_buf_attachment* attach;
  struct sg_table* sgt;
  struct pci_dev* pdev = NULL;
  struct device* dev;
  dma_addr_t dma_addr;
  int ret = 0;
  unsigned int domain, bus, devfn;

  /* Decode BDF: format is 0x0BDF (bus=B, dev=D, func=F) */
  bus = (nvme_bdf >> 8) & 0xFF;
  devfn = nvme_bdf & 0xFF;
  domain = 0; /* Assume domain 0 for now */

  /* Find the NVMe PCI device */
  pdev = pci_get_domain_bus_and_slot(domain, bus, devfn);
  if (!pdev) {
    char pci_addr[16];
    format_bdf_as_pci_addr(nvme_bdf, pci_addr, sizeof(pci_addr));
    if (pci_addr[0] != '\0') {
      pr_err("rocm-axiio: NVMe device not found (%s)\n", pci_addr);
    } else {
      pr_err("rocm-axiio: NVMe device not found (BDF: 0x%04x)\n", nvme_bdf);
    }
    return -ENODEV;
  }
  dev = &pdev->dev;

  {
    char pci_addr[16];
    format_bdf_as_pci_addr(nvme_bdf, pci_addr, sizeof(pci_addr));
    if (pci_addr[0] != '\0') {
      pr_info("rocm-axiio: Using NVMe device %s (%s) for P2PDMA\n",
              pci_name(pdev), pci_addr);
    } else {
      pr_info("rocm-axiio: Using NVMe device %s for P2PDMA\n", pci_name(pdev));
    }
  }

  /* Get dmabuf from fd */
  dmabuf = dma_buf_get(dmabuf_fd);
  if (IS_ERR(dmabuf)) {
    pr_err("rocm-axiio: dma_buf_get failed: %ld\n", PTR_ERR(dmabuf));
    ret = PTR_ERR(dmabuf);
    goto err_put_pci;
  }

  *size = dmabuf->size;

  /* Attach to NVMe device */
  attach = dma_buf_attach(dmabuf, dev);
  if (IS_ERR(attach)) {
    pr_err("rocm-axiio: dma_buf_attach failed: %ld\n", PTR_ERR(attach));
    ret = PTR_ERR(attach);
    goto err_put_dmabuf;
  }

  /* Map for DMA - this is where P2PDMA magic happens */
  sgt = dma_buf_map_attachment(attach, DMA_BIDIRECTIONAL);
  if (IS_ERR(sgt)) {
    pr_err("rocm-axiio: dma_buf_map_attachment failed: %ld\n", PTR_ERR(sgt));
    ret = PTR_ERR(sgt);
    goto err_detach;
  }

  /* Get DMA address from scatter-gather list */
  if (sgt->nents > 0) {
    dma_addr = sg_dma_address(sgt->sgl);
    *phys_addr = (__u64)dma_addr;
    pr_info("rocm-axiio: ✅ P2PDMA address: 0x%llx (size: %llu)\n", *phys_addr,
            *size);
  } else {
    pr_err("rocm-axiio: No DMA segments\n");
    ret = -EINVAL;
    goto err_unmap;
  }

  /* Return attachment info - caller must keep alive */
  *dmabuf_out = dmabuf;
  *attach_out = attach;
  *sgt_out = sgt;
  *pdev_out = pdev; // Caller gets reference

  return 0;

err_unmap:
  dma_buf_unmap_attachment(attach, sgt, DMA_BIDIRECTIONAL);
err_detach:
  dma_buf_detach(dmabuf, attach);
err_put_dmabuf:
  dma_buf_put(dmabuf);
err_put_pci:
  pci_dev_put(pdev);

  return ret;
}

/* Get NVMe device info */
static int get_nvme_device_info(__u16 bdf, struct rocm_xio_device_info* info) {
  struct pci_dev* nvme_dev = NULL;
  unsigned int domain, bus, devfn;
  resource_size_t bar0_start, bar0_size;

  /* Decode BDF: format is 0x0BDF (bus=B, dev=D, func=F) */
  bus = (bdf >> 8) & 0xFF;
  devfn = bdf & 0xFF;
  domain = 0; /* Assume domain 0 for now */

  /* Find the NVMe PCI device */
  nvme_dev = pci_get_domain_bus_and_slot(domain, bus, devfn);
  if (!nvme_dev) {
    char pci_addr[16];
    format_bdf_as_pci_addr(bdf, pci_addr, sizeof(pci_addr));
    if (pci_addr[0] != '\0') {
      pr_err("rocm-axiio: NVMe device not found (%s)\n", pci_addr);
    } else {
      pr_err("rocm-axiio: NVMe device not found (BDF: 0x%04x)\n", bdf);
    }
    return -ENODEV;
  }

  info->bdf = bdf;

  /* Get BAR0 information */
  bar0_start = pci_resource_start(nvme_dev, 0);
  bar0_size = pci_resource_len(nvme_dev, 0);
  info->bar0_addr = bar0_start;
  info->bar0_size = bar0_size;

  /* Doorbell stride is typically 4 bytes (32-bit registers) */
  info->doorbell_stride = 4;

  /* Maximum queues: typically 65535 for NVMe 1.4+ */
  info->max_queues = 65535;

  {
    char pci_addr[16];
    format_bdf_as_pci_addr(bdf, pci_addr, sizeof(pci_addr));
    if (pci_addr[0] != '\0') {
      pr_info("rocm-axiio: Device info for %s:\n", pci_addr);
    } else {
      pr_info("rocm-axiio: Device info for BDF 0x%04x:\n", bdf);
    }
  }
  pr_info("  BAR0: 0x%llx (size: 0x%llx)\n", (u64)info->bar0_addr,
          (u64)info->bar0_size);
  pr_info("  Doorbell stride: %u bytes\n", info->doorbell_stride);
  pr_info("  Max queues: %u\n", info->max_queues);

  pci_dev_put(nvme_dev);
  return 0;
}

/* Get PCI MMIO bridge shadow buffer GPA from PCI config space */
static int get_mmio_bridge_shadow_buffer(
  __u16 bridge_bdf, struct rocm_xio_mmio_bridge_shadow_req* req) {
  struct pci_dev* bridge_dev = NULL;
  unsigned int domain, bus, devfn;
  __u32 gpa_low = 0, gpa_high = 0;
  __u64 shadow_gpa = 0;

  /* Decode BDF: format is 0xBBDD (bus=B, dev=D, func=F) */
  bus = (bridge_bdf >> 8) & 0xFF;
  devfn = bridge_bdf & 0xFF;
  domain = 0; /* Assume domain 0 for now */

  /* Find the PCI MMIO bridge device */
  bridge_dev = pci_get_domain_bus_and_slot(domain, bus, devfn);
  if (!bridge_dev) {
    char pci_addr[16];
    format_bdf_as_pci_addr(bridge_bdf, pci_addr, sizeof(pci_addr));
    if (pci_addr[0] != '\0') {
      pr_err("rocm-axiio: PCI MMIO bridge device not found (%s)\n", pci_addr);
    } else {
      pr_err("rocm-axiio: PCI MMIO bridge device not found (BDF: 0x%04x)\n",
             bridge_bdf);
    }
    return -ENODEV;
  }

  /* Read shadow buffer GPA from PCI config space (offsets 0x40 and 0x44) */
  pci_read_config_dword(bridge_dev, 0x40, &gpa_low);
  pci_read_config_dword(bridge_dev, 0x44, &gpa_high);

  shadow_gpa = ((__u64)gpa_high << 32) | gpa_low;

  if (shadow_gpa == 0) {
    pr_err("rocm-axiio: PCI MMIO bridge shadow GPA is 0 (not configured)\n");
    pci_dev_put(bridge_dev);
    return -EINVAL;
  }

  req->bridge_bdf = bridge_bdf;
  req->shadow_gpa = shadow_gpa;
  req->shadow_size = 8192; /* 8KB shadow buffer (typical size) */

  pr_info("rocm-axiio: PCI MMIO bridge shadow buffer: GPA=0x%llx, size=%llu\n",
          (unsigned long long)shadow_gpa, (unsigned long long)req->shadow_size);

  pci_dev_put(bridge_dev);
  return 0;
}

/*
 * Look up physical address for queue (CREATE_SQ/CREATE_CQ).
 * Returns physical address if found, 0 otherwise.
 */
static __u64 lookup_queue_phys_addr(__u64 virt_addr) {
  struct queue_addr_entry* entry;
  __u64 phys_addr = 0;

  spin_lock(&queue_addrs_lock);
  list_for_each_entry(entry, &queue_addrs, list) {
    if (virt_addr >= entry->virt_addr &&
        virt_addr < (entry->virt_addr + entry->size)) {
      phys_addr = entry->phys_addr + (virt_addr - entry->virt_addr);
      break;
    }
  }
  spin_unlock(&queue_addrs_lock);

  return phys_addr;
}

/*
 * Look up BDF for queue address.
 * Returns BDF if found, 0 otherwise.
 */
static __u16 lookup_queue_bdf(__u64 virt_addr) {
  struct queue_addr_entry* entry;
  __u16 bdf = 0;

  spin_lock(&queue_addrs_lock);
  list_for_each_entry(entry, &queue_addrs, list) {
    if (virt_addr >= entry->virt_addr &&
        virt_addr < (entry->virt_addr + entry->size)) {
      bdf = entry->nvme_bdf;
      break;
    }
  }
  spin_unlock(&queue_addrs_lock);

  return bdf;
}

/*
 * Look up PRP2 value for queue (CREATE_SQ/CREATE_CQ with PC=0).
 * Returns PRP2 if found, 0 otherwise.
 */
static __u64 lookup_queue_prp2(__u64 virt_addr) {
  struct queue_addr_entry* entry;
  __u64 prp2 = 0;

  spin_lock(&queue_addrs_lock);
  list_for_each_entry(entry, &queue_addrs, list) {
    if (virt_addr >= entry->virt_addr &&
        virt_addr < (entry->virt_addr + entry->size)) {
      prp2 = entry->prp2;
      break;
    }
  }
  spin_unlock(&queue_addrs_lock);

  return prp2;
}

/*
 * Look up physical address for data buffer (I/O commands).
 * First checks registered VRAM buffers, then falls back to virt_to_phys.
 */
static __u64 lookup_buffer_phys_addr(__u64 virt_addr) {
  struct vram_buffer_entry* entry;
  __u64 phys_addr = 0;

  /* First check registered VRAM buffers */
  spin_lock(&vram_buffers_lock);
  list_for_each_entry(entry, &vram_buffers, list) {
    if (virt_addr >= entry->virt_addr &&
        virt_addr < (entry->virt_addr + entry->size)) {
      phys_addr = entry->phys_addr + (virt_addr - entry->virt_addr);
      break;
    }
  }
  spin_unlock(&vram_buffers_lock);

  if (phys_addr)
    return phys_addr;

  /* Fallback: try virt_to_phys (works for kernel memory) */
  if (virt_addr_valid((void*)virt_addr)) {
    return virt_to_phys((void*)virt_addr);
  }

  return 0;
}

/*
 * Kprobe pre-handler for nvme_submit_user_cmd.
 * Injects physical addresses into PRP1/PRP2 for NVMe commands.
 */
static int nvme_submit_user_cmd_pre(struct kprobe* p, struct pt_regs* regs) {
  struct nvme_command* cmd;
  u64 ubuffer;
  unsigned int bufflen;
  u8 opcode;
  __u64 phys_addr;

  if (!inject_enabled)
    return 0;

    /*
     * Function signature:
     * nvme_submit_user_cmd(struct request_queue *q,
     *                      struct nvme_command *cmd,
     *                      u64 ubuffer,
     *                      unsigned bufflen, ...)
     *
     * x86_64 calling convention:
     * RDI = arg0 (q)
     * RSI = arg1 (cmd)
     * RDX = arg2 (ubuffer)
     * RCX = arg3 (bufflen)
     */
#ifdef CONFIG_X86_64
  cmd = (struct nvme_command*)regs->si;
  ubuffer = regs->dx;
  bufflen = (unsigned int)regs->cx;
#else
  /* For non-x86_64, we'd need architecture-specific register access */
  return 0;
#endif

  if (!cmd)
    return 0;

  opcode = cmd->common.opcode;

  /* Handle DELETE_SQ (0x00) and DELETE_CQ (0x04) */
  if (opcode == 0x00 || opcode == 0x04) {
    /* Queue ID is in cdw10 (lower 16 bits) */
    __u16 queue_id = le32_to_cpu(cmd->common.cdw10) & 0xFFFF;
    __u16 bdf = lookup_queue_bdf(ubuffer);
    char pci_addr[16];
    format_bdf_as_pci_addr(bdf, pci_addr, sizeof(pci_addr));
    if (pci_addr[0] != '\0') {
      pr_info("rocm-axiio: Intercepted %s command (%s)\n",
              opcode == 0x00 ? "DELETE_SQ" : "DELETE_CQ", pci_addr);
    } else {
      pr_info("rocm-axiio: Intercepted %s command\n",
              opcode == 0x00 ? "DELETE_SQ" : "DELETE_CQ");
    }
    pr_info("  Queue ID: %u\n", queue_id);

    /*
     * If we've previously seen the kernel's CREATE_* for this
     * (bdf, qid) get hijacked, the device is about to lose the
     * queue. Trigger resurrection on DELETE_CQ (opcode 0x04), which
     * is the second of the DELETE_SQ/DELETE_CQ pair. By the time
     * the device acks DELETE_CQ, the CQ no longer exists and our
     * CREATE_CQ won't collide.
     *
     * For DELETE we don't have a registered queue_addr lookup that
     * reliably gives BDF (the ubuffer at DELETE time might not be
     * the queue's PRP). So if lookup_queue_bdf returned 0 we fall
     * back to "any bdf with a matching qid in the poisoned list".
     */
    if (opcode == 0x04) {
      if (bdf) {
        poisoned_qid_mark_deleted(bdf, queue_id);
      } else {
        struct poisoned_qid_entry* pe;
        unsigned long flags_irq;
        u16 found_bdf = 0;
        spin_lock_irqsave(&poisoned_qids_lock, flags_irq);
        list_for_each_entry(pe, &poisoned_qids, list) {
          if (pe->qid == queue_id && pe->created) {
            found_bdf = pe->bdf;
            break;
          }
        }
        spin_unlock_irqrestore(&poisoned_qids_lock, flags_irq);
        if (found_bdf)
          poisoned_qid_mark_deleted(found_bdf, queue_id);
      }
    }
  }

  /* Handle CREATE_CQ (0x05) and CREATE_SQ (0x01) */
  if ((opcode == 0x05 || opcode == 0x01) && bufflen == 0 && ubuffer != 0) {
    /* Queue ID is in cdw10 (lower 16 bits) */
    __u16 queue_id = le32_to_cpu(cmd->common.cdw10) & 0xFFFF;
    __u16 bdf = lookup_queue_bdf(ubuffer);
    char pci_addr[16];
    format_bdf_as_pci_addr(bdf, pci_addr, sizeof(pci_addr));
    if (pci_addr[0] != '\0') {
      pr_info("rocm-axiio: Intercepted %s command (%s)\n",
              opcode == 0x05 ? "CREATE_CQ" : "CREATE_SQ", pci_addr);
    } else {
      pr_info("rocm-axiio: Intercepted %s command\n",
              opcode == 0x05 ? "CREATE_CQ" : "CREATE_SQ");
    }
    pr_info("  Queue ID: %u\n", queue_id);
    pr_info("  Original PRP1: 0x%016llx\n",
            (unsigned long long)le64_to_cpu(cmd->common.dptr.prp1));
    pr_info("  ubuffer: 0x%016llx\n", (unsigned long long)ubuffer);

    /* Look up physical address from registered queue addresses */
    phys_addr = lookup_queue_phys_addr(ubuffer);
    if (phys_addr) {
      __u64 prp2_val;
      u16 hijack_bdf;

      cmd->common.dptr.prp1 = cpu_to_le64(phys_addr);
      pr_info("  Injected PRP1: 0x%016llx\n", (unsigned long long)phys_addr);

      prp2_val = lookup_queue_prp2(ubuffer);
      if (prp2_val) {
        cmd->common.dptr.prp2 = cpu_to_le64(prp2_val);
        pr_info("  Injected PRP2: 0x%016llx\n", (unsigned long long)prp2_val);
      }

      /*
       * Track that (bdf, qid) had its kernel CREATE_* hijacked.
       * The actual resurrect is triggered later when xio-tester
       * issues DELETE_SQ for the same (bdf, qid).
       */
      hijack_bdf = lookup_queue_bdf(ubuffer);
      if (hijack_bdf)
        poisoned_qid_mark_created(hijack_bdf, queue_id);
    } else {
      pr_info("rocm-axiio: Queue not registered, "
              "using ubuffer directly\n");
      cmd->common.dptr.prp1 = cpu_to_le64(ubuffer);
    }
  }

  /* Handle I/O commands (READ=0x02, WRITE=0x01) - inject buffer addresses */
  if (opcode == 0x01 || opcode == 0x02) {
    __u64 prp1_val = le64_to_cpu(cmd->common.dptr.prp1);
    __u64 prp2_val = le64_to_cpu(cmd->common.dptr.prp2);

    /* If PRP1 looks like a virtual address (not a high physical address),
     * try to convert it */
    if (prp1_val && prp1_val < 0x100000000ULL) {
      phys_addr = lookup_buffer_phys_addr(prp1_val);
      if (phys_addr) {
        pr_debug("rocm-axiio: Injecting PRP1 for I/O: 0x%016llx\n",
                 (unsigned long long)phys_addr);
        cmd->common.dptr.prp1 = cpu_to_le64(phys_addr);
      }
    }

    /* Same for PRP2 if present */
    if (prp2_val && prp2_val < 0x100000000ULL) {
      phys_addr = lookup_buffer_phys_addr(prp2_val);
      if (phys_addr) {
        pr_debug("rocm-axiio: Injecting PRP2 for I/O: 0x%016llx\n",
                 (unsigned long long)phys_addr);
        cmd->common.dptr.prp2 = cpu_to_le64(phys_addr);
      }
    }
  }

  return 0; /* Continue with original function */
}

/* IOCTL handler */
static long rocm_xio_ioctl(struct file* file, unsigned int cmd,
                           unsigned long arg) {
  int ret = 0;

  switch (cmd) {
    case ROCM_XIO_GET_VRAM_PHYS_ADDR: {
      struct rocm_xio_vram_req req;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      {
        char pci_addr[16];
        format_bdf_as_pci_addr(req.nvme_bdf, pci_addr, sizeof(pci_addr));
        if (pci_addr[0] != '\0') {
          pr_info("rocm-axiio: Getting VRAM physical address for NVMe %s\n",
                  pci_addr);
        } else {
          pr_info("rocm-axiio: Getting VRAM physical address for NVMe BDF "
                  "0x%04x\n",
                  req.nvme_bdf);
        }
      }

      /*
       * Always return GPU BAR GPA (works for both emulated and passthrough
       * NVMe in VM environments)
       */
      ret = get_dmabuf_bar_gpa(req.dmabuf_fd, &req.phys_addr, &req.size);

      if (ret < 0)
        return ret;

      if (copy_to_user((void __user*)arg, &req, sizeof(req)))
        return -EFAULT;

      return 0;
    }

    case ROCM_XIO_GET_DEVICE_INFO: {
      struct rocm_xio_device_info info;

      if (copy_from_user(&info, (void __user*)arg, sizeof(info)))
        return -EFAULT;

      ret = get_nvme_device_info(info.bdf, &info);
      if (ret < 0)
        return ret;

      if (copy_to_user((void __user*)arg, &info, sizeof(info)))
        return -EFAULT;

      return 0;
    }

    case ROCM_XIO_CREATE_QUEUE:
    case ROCM_XIO_DELETE_QUEUE:
      /*
       * Queue creation/deletion is handled via kprobe injection.
       * Userspace allocates queues in VRAM, gets physical addresses via
       * GET_VRAM_PHYS_ADDR, then uses normal NVMe driver interface.
       * The kprobe automatically injects physical addresses.
       */
      pr_info("rocm-axiio: Queue management handled via kprobe injection\n");
      return -EOPNOTSUPP;

    case ROCM_XIO_BIND_DEVICE: {
      struct rocm_xio_bind_device_req req;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      /* Device binding is optional - just log it for now */
      {
        char pci_addr[16];
        format_bdf_as_pci_addr(req.bdf, pci_addr, sizeof(pci_addr));
        if (pci_addr[0] != '\0') {
          pr_info("rocm-axiio: Device binding requested for %s\n", pci_addr);
        } else {
          pr_info("rocm-axiio: Device binding requested for BDF 0x%04x\n",
                  req.bdf);
        }
      }
      return 0;
    }

    case ROCM_XIO_REGISTER_QUEUE_ADDR: {
      struct rocm_xio_register_queue_addr_req req;
      struct queue_addr_entry* entry;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      /* Allocate and register queue address entry */
      entry = kmalloc(sizeof(*entry), GFP_KERNEL);
      if (!entry)
        return -ENOMEM;

      entry->virt_addr = req.virt_addr;
      entry->phys_addr = req.phys_addr;
      entry->size = req.size;
      entry->queue_type = req.queue_type;
      entry->nvme_bdf = req.nvme_bdf;
      entry->prp2 = req.prp2;

      spin_lock(&queue_addrs_lock);
      list_add(&entry->list, &queue_addrs);
      spin_unlock(&queue_addrs_lock);

      {
        char pci_addr[16];
        format_bdf_as_pci_addr(req.nvme_bdf, pci_addr, sizeof(pci_addr));
        if (pci_addr[0] != '\0') {
          pr_info("rocm-axiio: Registered queue address: virt=0x%016llx "
                  "phys=0x%016llx size=0x%llx type=%u (%s)\n",
                  (unsigned long long)req.virt_addr,
                  (unsigned long long)req.phys_addr,
                  (unsigned long long)req.size, req.queue_type, pci_addr);
        } else {
          pr_info("rocm-axiio: Registered queue address: virt=0x%016llx "
                  "phys=0x%016llx size=0x%llx type=%u\n",
                  (unsigned long long)req.virt_addr,
                  (unsigned long long)req.phys_addr,
                  (unsigned long long)req.size, req.queue_type);
        }
      }

      return 0;
    }

    case ROCM_XIO_UNREGISTER_QUEUE_ADDR: {
      struct rocm_xio_unregister_queue_addr_req req;
      struct queue_addr_entry *entry, *tmp;
      bool found = false;
      __u16 found_nvme_bdf = 0;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      spin_lock(&queue_addrs_lock);
      list_for_each_entry_safe(entry, tmp, &queue_addrs, list) {
        if (entry->virt_addr == req.virt_addr) {
          list_del(&entry->list);
          found_nvme_bdf = entry->nvme_bdf;
          kfree(entry);
          found = true;
          break;
        }
      }
      spin_unlock(&queue_addrs_lock);

      if (!found) {
        pr_warn("rocm-axiio: Queue address 0x%016llx not found\n",
                (unsigned long long)req.virt_addr);
        return -ENOENT;
      }

      {
        char pci_addr[16];
        format_bdf_as_pci_addr(found_nvme_bdf, pci_addr, sizeof(pci_addr));
        if (pci_addr[0] != '\0') {
          pr_info("rocm-axiio: Unregistered queue address: virt=0x%016llx "
                  "(%s)\n",
                  (unsigned long long)req.virt_addr, pci_addr);
        } else {
          pr_info("rocm-axiio: Unregistered queue address: virt=0x%016llx\n",
                  (unsigned long long)req.virt_addr);
        }
      }
      return 0;
    }

    case ROCM_XIO_REGISTER_BUFFER: {
      struct rocm_xio_register_buffer_req req;
      struct vram_buffer_entry* entry;
      __u64 phys_addr;
      bool is_emulated = false;
      struct dma_buf* dmabuf = NULL;
      struct dma_buf_attachment* attach = NULL;
      struct sg_table* sgt = NULL;
      struct pci_dev* nvme_pdev = NULL;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      /* Determine if this is emulated NVMe based on flags field */
      if (req.flags & ROCM_XIO_FLAG_EMULATED) {
        is_emulated = true;
      } else if (req.flags & ROCM_XIO_FLAG_PASSTHROUGH) {
        is_emulated = false;
      }
      /* Default to passthrough if no flags set */

      /* Get physical address from dmabuf - choose method based on NVMe type */
      if (is_emulated) {
        /* Emulated NVMe: Return GPU BAR GPA */
        {
          char pci_addr[16];
          format_bdf_as_pci_addr(req.nvme_bdf, pci_addr, sizeof(pci_addr));
          if (pci_addr[0] != '\0') {
            pr_info("rocm-axiio: Emulated NVMe (%s) - using GPU BAR GPA\n",
                    pci_addr);
          } else {
            pr_info("rocm-axiio: Emulated NVMe - using GPU BAR GPA\n");
          }
        }
        ret = get_dmabuf_bar_gpa(req.dmabuf_fd, &phys_addr, &req.size);
        if (ret < 0)
          return ret;
      } else {
        /* Passthrough NVMe: Return P2PDMA IOVA - keep attachment alive */
        {
          char pci_addr[16];
          format_bdf_as_pci_addr(req.nvme_bdf, pci_addr, sizeof(pci_addr));
          if (pci_addr[0] != '\0') {
            pr_info("rocm-axiio: Passthrough NVMe (%s) - using P2PDMA IOVA\n",
                    pci_addr);
          } else {
            pr_info("rocm-axiio: Passthrough NVMe - using P2PDMA IOVA\n");
          }
        }
        ret = get_dmabuf_phys_addr(req.dmabuf_fd, req.nvme_bdf, &phys_addr,
                                   &req.size, &dmabuf, &attach, &sgt,
                                   &nvme_pdev);
        if (ret < 0)
          return ret;
      }

      /* Allocate and register buffer entry */
      entry = kmalloc(sizeof(*entry), GFP_KERNEL);
      if (!entry) {
        /* Cleanup passthrough attachment if allocated */
        if (!is_emulated && sgt && attach && dmabuf) {
          dma_buf_unmap_attachment(attach, sgt, DMA_BIDIRECTIONAL);
          dma_buf_detach(dmabuf, attach);
          dma_buf_put(dmabuf);
          if (nvme_pdev)
            pci_dev_put(nvme_pdev);
        }
        return -ENOMEM;
      }

      /* Store userspace virtual address */
      entry->virt_addr = (__u64)req.virt_addr;
      entry->phys_addr = phys_addr;
      entry->size = req.size;
      entry->is_passthrough = !is_emulated;

      /* Store attachment info for passthrough (keep alive) */
      if (!is_emulated) {
        entry->dmabuf = dmabuf;
        entry->attach = attach;
        entry->sgt = sgt;
        entry->nvme_pdev = nvme_pdev;
      } else {
        entry->dmabuf = NULL;
        entry->attach = NULL;
        entry->sgt = NULL;
        entry->nvme_pdev = NULL;
      }

      spin_lock(&vram_buffers_lock);
      list_add(&entry->list, &vram_buffers);
      spin_unlock(&vram_buffers_lock);

      req.phys_addr = phys_addr;

      /* Extract BDF for logging */
      __u16 bdf = req.nvme_bdf;
      if (bdf == 0 && entry->nvme_pdev) {
        bdf = pci_dev_to_bdf(entry->nvme_pdev);
      }

      {
        char pci_addr[16];
        format_bdf_as_pci_addr(bdf, pci_addr, sizeof(pci_addr));
        if (pci_addr[0] != '\0') {
          pr_info("rocm-axiio: Registered buffer: virt=0x%016llx "
                  "phys=0x%016llx size=0x%llx (%s)%s\n",
                  (unsigned long long)entry->virt_addr,
                  (unsigned long long)phys_addr, (unsigned long long)req.size,
                  pci_addr,
                  entry->is_passthrough ? " (P2PDMA attachment kept alive)"
                                        : "");
        } else {
          pr_info("rocm-axiio: Registered buffer: virt=0x%016llx "
                  "phys=0x%016llx size=0x%llx%s\n",
                  (unsigned long long)entry->virt_addr,
                  (unsigned long long)phys_addr, (unsigned long long)req.size,
                  entry->is_passthrough ? " (P2PDMA attachment kept alive)"
                                        : "");
        }
      }

      if (copy_to_user((void __user*)arg, &req, sizeof(req))) {
        /* Unregister on copy failure */
        spin_lock(&vram_buffers_lock);
        list_del(&entry->list);
        spin_unlock(&vram_buffers_lock);
        /* Cleanup passthrough attachment */
        if (entry->is_passthrough && entry->sgt && entry->attach &&
            entry->dmabuf) {
          dma_buf_unmap_attachment(entry->attach, entry->sgt,
                                   DMA_BIDIRECTIONAL);
          dma_buf_detach(entry->dmabuf, entry->attach);
          dma_buf_put(entry->dmabuf);
          if (entry->nvme_pdev)
            pci_dev_put(entry->nvme_pdev);
        }
        kfree(entry);
        return -EFAULT;
      }

      return 0;
    }

    case ROCM_XIO_UNREGISTER_BUFFER: {
      struct rocm_xio_unregister_buffer_req req;
      struct vram_buffer_entry *entry, *tmp;
      bool found = false;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      spin_lock(&vram_buffers_lock);
      list_for_each_entry_safe(entry, tmp, &vram_buffers, list) {
        if (entry->virt_addr == req.virt_addr) {
          list_del(&entry->list);
          found = true;
          break;
        }
      }
      spin_unlock(&vram_buffers_lock);

      if (!found) {
        pr_warn("rocm-axiio: Buffer 0x%016llx not found\n",
                (unsigned long long)req.virt_addr);
        return -ENOENT;
      }

      /* Extract BDF for logging */
      __u16 bdf = 0;
      if (entry->nvme_pdev) {
        bdf = pci_dev_to_bdf(entry->nvme_pdev);
      }

      {
        char pci_addr[16];
        format_bdf_as_pci_addr(bdf, pci_addr, sizeof(pci_addr));

        /* Cleanup passthrough attachment if needed */
        if (entry->is_passthrough && entry->sgt && entry->attach &&
            entry->dmabuf) {
          if (pci_addr[0] != '\0') {
            pr_info(
              "rocm-axiio: Cleaning up P2PDMA attachment for buffer 0x%016llx "
              "(%s)\n",
              (unsigned long long)entry->virt_addr, pci_addr);
          } else {
            pr_info("rocm-axiio: Cleaning up P2PDMA attachment for buffer "
                    "0x%016llx\n",
                    (unsigned long long)entry->virt_addr);
          }
          dma_buf_unmap_attachment(entry->attach, entry->sgt,
                                   DMA_BIDIRECTIONAL);
          dma_buf_detach(entry->dmabuf, entry->attach);
          dma_buf_put(entry->dmabuf);
          if (entry->nvme_pdev)
            pci_dev_put(entry->nvme_pdev);
        }

        if (pci_addr[0] != '\0') {
          pr_info("rocm-axiio: Unregistered buffer: virt=0x%016llx (%s)\n",
                  (unsigned long long)req.virt_addr, pci_addr);
        } else {
          pr_info("rocm-axiio: Unregistered buffer: virt=0x%016llx\n",
                  (unsigned long long)req.virt_addr);
        }
      }
      kfree(entry);
      return 0;
    }

    case ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER: {
      struct rocm_xio_mmio_bridge_shadow_req req;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      ret = get_mmio_bridge_shadow_buffer(req.bridge_bdf, &req);
      if (ret < 0)
        return ret;

      /* Store shadow buffer info for mmap */
      mutex_lock(&mmio_bridge_lock);
      mmio_bridge_shadow_gpa = req.shadow_gpa;
      mmio_bridge_shadow_size = req.shadow_size;
      mutex_unlock(&mmio_bridge_lock);

      if (copy_to_user((void __user*)arg, &req, sizeof(req)))
        return -EFAULT;

      return 0;
    }

    case ROCM_XIO_ALLOC_CONTIG_QUEUE: {
      struct rocm_xio_alloc_contig_req req;
      struct contig_alloc_entry* ca;
      struct pci_dev* pdev;
      unsigned int bus, devfn;
      void* cpu_addr;
      dma_addr_t dma_addr;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      if (req.size == 0 || req.size > (16 * 1024 * 1024)) {
        pr_err("rocm-axiio: contig alloc: invalid "
               "size %llu\n",
               (unsigned long long)req.size);
        return -EINVAL;
      }

      bus = (req.nvme_bdf >> 8) & 0xFF;
      devfn = req.nvme_bdf & 0xFF;
      pdev = pci_get_domain_bus_and_slot(0, bus, devfn);
      if (!pdev) {
        char pci_addr[16];
        format_bdf_as_pci_addr(req.nvme_bdf, pci_addr, sizeof(pci_addr));
        pr_err("rocm-axiio: contig alloc: NVMe "
               "device not found (%s)\n",
               pci_addr);
        return -ENODEV;
      }

      cpu_addr = dma_alloc_coherent(&pdev->dev, req.size, &dma_addr,
                                    GFP_KERNEL);
      if (!cpu_addr) {
        pr_err("rocm-axiio: contig alloc: "
               "dma_alloc_coherent failed for "
               "%llu bytes\n",
               (unsigned long long)req.size);
        pci_dev_put(pdev);
        return -ENOMEM;
      }

      memset(cpu_addr, 0, req.size);

      ca = kmalloc(sizeof(*ca), GFP_KERNEL);
      if (!ca) {
        dma_free_coherent(&pdev->dev, req.size, cpu_addr, dma_addr);
        pci_dev_put(pdev);
        return -ENOMEM;
      }

      ca->cpu_addr = cpu_addr;
      ca->dma_addr = dma_addr;
      ca->size = req.size;
      ca->pdev = pdev;
      ca->owner = file;
      kref_init(&ca->ref);

      spin_lock(&contig_allocs_lock);
      ca->id = contig_alloc_next_id++;
      list_add(&ca->list, &contig_allocs);
      spin_unlock(&contig_allocs_lock);

      req.phys_addr = (__u64)dma_addr;
      req.mmap_offset = ca->id;

      {
        char pci_addr[16];
        format_bdf_as_pci_addr(req.nvme_bdf, pci_addr, sizeof(pci_addr));
        pr_info("rocm-axiio: contig alloc: "
                "size=%llu dma=0x%llx id=%u "
                "(%s)\n",
                (unsigned long long)req.size, (unsigned long long)dma_addr,
                ca->id, pci_addr);
      }

      if (copy_to_user((void __user*)arg, &req, sizeof(req))) {
        spin_lock(&contig_allocs_lock);
        list_del(&ca->list);
        spin_unlock(&contig_allocs_lock);
        dma_free_coherent(&pdev->dev, req.size, cpu_addr, dma_addr);
        pci_dev_put(pdev);
        kfree(ca);
        return -EFAULT;
      }

      return 0;
    }

    case ROCM_XIO_QUIESCE_NS: {
      struct rocm_xio_quiesce_ns_req req;
      struct file* bdev_file;
      struct block_device* bd;
      struct request_queue* q;
      struct blk_mq_hw_ctx* hctx = NULL;
      struct quiesced_ns_entry* entry;
      struct quiesced_ns_entry* existing;
      enum quiesced_ns_mode mode;
      unsigned int hctx_idx = 0;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      if (req.bdev_fd < 0)
        return -EINVAL;

      bdev_file = fget(req.bdev_fd);
      if (!bdev_file) {
        pr_err("rocm-axiio: QUIESCE_NS: invalid bdev fd %d\n", req.bdev_fd);
        return -EBADF;
      }

      bd = rocm_xio_file_to_bdev(bdev_file);
      if (!bd) {
        pr_err("rocm-axiio: QUIESCE_NS: fd %d is not a block device\n",
               req.bdev_fd);
        fput(bdev_file);
        return -ENOTBLK;
      }

      q = bdev_get_queue(bd);
      if (!q) {
        pr_err("rocm-axiio: QUIESCE_NS: no request_queue for bdev\n");
        fput(bdev_file);
        return -ENODEV;
      }

      if (req.qid == 0) {
        mode = QUIESCED_NS_MODE_FULL;
      } else {
        /*
         * NVMe IO queue ID @qid maps to blk-mq hctx index
         * @qid - 1 in the default I/O queue map used by the
         * upstream NVMe PCI driver. Validate against the live
         * queue topology so a stale qid does not index past
         * the array.
         */
        if (!queue_is_mq(q)) {
          pr_err("rocm-axiio: QUIESCE_NS: %pg is not a blk-mq queue\n", bd);
          fput(bdev_file);
          return -EOPNOTSUPP;
        }
        hctx_idx = req.qid - 1;
        if (hctx_idx >= q->nr_hw_queues) {
          pr_err("rocm-axiio: QUIESCE_NS: qid %u out of range "
                 "(%pg has %u hw queues)\n",
                 req.qid, bd, q->nr_hw_queues);
          fput(bdev_file);
          return -ERANGE;
        }
        hctx = rocm_xio_hctx_at(q, hctx_idx);
        if (!hctx) {
          pr_err("rocm-axiio: QUIESCE_NS: no hctx for qid %u on %pg\n", req.qid,
                 bd);
          fput(bdev_file);
          return -ENODEV;
        }
        mode = QUIESCED_NS_MODE_HCTX;
      }

      mutex_lock(&quiesced_ns_lock);
      list_for_each_entry(existing, &quiesced_ns, list) {
        if (existing->owner != file || existing->bd != bd)
          continue;
        if (existing->mode == QUIESCED_NS_MODE_FULL &&
            mode == QUIESCED_NS_MODE_FULL) {
          mutex_unlock(&quiesced_ns_lock);
          pr_info("rocm-axiio: QUIESCE_NS: %pg already fully quiesced by "
                  "this fd\n",
                  bd);
          fput(bdev_file);
          return 0;
        }
        if (existing->mode == QUIESCED_NS_MODE_HCTX &&
            mode == QUIESCED_NS_MODE_HCTX && existing->hctx_idx == hctx_idx) {
          mutex_unlock(&quiesced_ns_lock);
          pr_info("rocm-axiio: QUIESCE_NS: %pg qid %u already stopped by "
                  "this fd\n",
                  bd, req.qid);
          fput(bdev_file);
          return 0;
        }
      }
      mutex_unlock(&quiesced_ns_lock);

      entry = kmalloc(sizeof(*entry), GFP_KERNEL);
      if (!entry) {
        fput(bdev_file);
        return -ENOMEM;
      }

      entry->bdev_file = bdev_file;
      entry->bd = bd;
      entry->owner = file;
      entry->mode = mode;
      entry->hctx_idx = hctx_idx;

      if (mode == QUIESCED_NS_MODE_FULL) {
        blk_mq_quiesce_queue(q);
        pr_info("rocm-axiio: QUIESCE_NS: quiesced entire request_queue "
                "for %pg\n",
                bd);
      } else {
        /*
         * Hold a brief whole-queue quiesce while we mark the
         * target hctx stopped. blk_mq_quiesce_queue() waits for
         * any in-flight dispatch (including one that may already
         * be touching the SQ we are about to reclaim) to
         * complete; the unquiesce immediately afterwards lets
         * the namespace's other hardware queues resume normal
         * I/O while our target hctx stays stopped.
         */
        blk_mq_quiesce_queue(q);
        blk_mq_stop_hw_queue(hctx);
        blk_mq_unquiesce_queue(q);
        pr_info("rocm-axiio: QUIESCE_NS: stopped hctx %u (qid %u) on %pg; "
                "other queues continue to dispatch\n",
                hctx_idx, req.qid, bd);
      }

      mutex_lock(&quiesced_ns_lock);
      list_add(&entry->list, &quiesced_ns);
      mutex_unlock(&quiesced_ns_lock);

      return 0;
    }

    case ROCM_XIO_UNQUIESCE_NS: {
      struct rocm_xio_quiesce_ns_req req;
      struct file* bdev_file;
      struct block_device* bd;
      struct request_queue* q;
      struct quiesced_ns_entry *entry, *tmp;
      struct quiesced_ns_entry* found = NULL;
      unsigned int hctx_idx = 0;
      enum quiesced_ns_mode want_mode;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      if (req.bdev_fd < 0)
        return -EINVAL;

      bdev_file = fget(req.bdev_fd);
      if (!bdev_file) {
        pr_err("rocm-axiio: UNQUIESCE_NS: invalid bdev fd %d\n", req.bdev_fd);
        return -EBADF;
      }

      bd = rocm_xio_file_to_bdev(bdev_file);
      if (!bd) {
        pr_err("rocm-axiio: UNQUIESCE_NS: fd %d is not a block device\n",
               req.bdev_fd);
        fput(bdev_file);
        return -ENOTBLK;
      }

      if (req.qid == 0) {
        want_mode = QUIESCED_NS_MODE_FULL;
      } else {
        want_mode = QUIESCED_NS_MODE_HCTX;
        hctx_idx = req.qid - 1;
      }

      mutex_lock(&quiesced_ns_lock);
      list_for_each_entry_safe(entry, tmp, &quiesced_ns, list) {
        if (entry->owner != file || entry->bd != bd)
          continue;
        if (entry->mode != want_mode)
          continue;
        if (want_mode == QUIESCED_NS_MODE_HCTX && entry->hctx_idx != hctx_idx)
          continue;
        list_del(&entry->list);
        found = entry;
        break;
      }
      mutex_unlock(&quiesced_ns_lock);

      if (!found) {
        pr_warn("rocm-axiio: UNQUIESCE_NS: no quiesce entry for %pg (qid %u)\n",
                bd, req.qid);
        fput(bdev_file);
        return -ENOENT;
      }

      q = bdev_get_queue(found->bd);
      if (q) {
        if (found->mode == QUIESCED_NS_MODE_FULL) {
          blk_mq_unquiesce_queue(q);
          pr_info("rocm-axiio: UNQUIESCE_NS: resumed entire request_queue "
                  "for %pg\n",
                  found->bd);
        } else {
          struct blk_mq_hw_ctx* hctx = rocm_xio_hctx_at(q, found->hctx_idx);
          if (hctx) {
            blk_mq_start_hw_queue(hctx);
            pr_info("rocm-axiio: UNQUIESCE_NS: started hctx %u (qid %u) "
                    "on %pg\n",
                    found->hctx_idx, req.qid, found->bd);
          } else {
            pr_warn("rocm-axiio: UNQUIESCE_NS: lost hctx %u for %pg\n",
                    found->hctx_idx, found->bd);
          }
        }
      } else {
        pr_warn("rocm-axiio: UNQUIESCE_NS: lost request_queue for %pg\n",
                found->bd);
      }

      fput(found->bdev_file);
      kfree(found);
      fput(bdev_file);
      return 0;
    }

    case ROCM_XIO_DEBUG_RESURRECT_QID: {
      /*
       * TEST-ONLY: drive the production resurrect path for (bdf, qid)
       * without the GPU/xio-tester hijack. This exists so the
       * ring-wrap stress test can exercise rocm_xio_resurrect_work_fn
       * (including the Task-A host ring-pointer reset) on hosts where
       * the Navi 21 GPU is wedged by the AMD reset bug and xio-tester
       * cannot run. It reuses the exact same code path as a real
       * DELETE_CQ-triggered resurrect: mark created + needs_resurrect,
       * then schedule rocm_xio_resurrect_work. No production caller
       * uses this; it is a faithful trigger, not a reimplementation.
       *
       * Requires a previously captured snapshot for (bdf, qid) (the
       * resurrect work fn bails with "NO snapshot" otherwise), and the
       * caller is responsible for having already issued DELETE_SQ +
       * DELETE_CQ for the qid so the controller side is actually gone.
       */
      struct rocm_xio_debug_resurrect_req req;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      pr_info("rocm-axiio: DEBUG_RESURRECT_QID: forcing resurrect of "
              "bdf=0x%04x qid=%u (test-only path)\n",
              req.bdf, req.qid);

      /* poisoned_qid_mark_created is idempotent; it creates the entry
       * if absent and sets created=true. Then mark_deleted flips
       * needs_resurrect and schedules the delayed work -- identical to
       * the kprobe-driven sequence. */
      poisoned_qid_mark_created(req.bdf, req.qid);
      poisoned_qid_mark_deleted(req.bdf, req.qid);
      return 0;
    }

    case ROCM_XIO_FREE_CONTIG_QUEUE: {
      struct rocm_xio_free_contig_req req;
      struct contig_alloc_entry *ca, *tmp;
      bool found = false;

      if (copy_from_user(&req, (void __user*)arg, sizeof(req)))
        return -EFAULT;

      spin_lock(&contig_allocs_lock);
      list_for_each_entry_safe(ca, tmp, &contig_allocs, list) {
        if (ca->id == req.mmap_offset && ca->owner == file) {
          list_del(&ca->list);
          found = true;
          break;
        }
      }
      spin_unlock(&contig_allocs_lock);

      if (!found) {
        pr_warn("rocm-axiio: contig free: id=%u "
                "not found or not owned by caller\n",
                req.mmap_offset);
        return -ENOENT;
      }

      pr_info("rocm-axiio: contig free: id=%u "
              "dma=0x%llx size=%zu\n",
              ca->id, (unsigned long long)ca->dma_addr, ca->size);

      kref_put(&ca->ref, contig_alloc_release);

      return 0;
    }

    default:
      return -ENOTTY;
  }
}

/* MMAP implementation: pgoff=0 -> MMIO bridge, pgoff>=1 -> contig queue */
static int rocm_xio_mmap(struct file* file, struct vm_area_struct* vma) {
  unsigned long pfn;
  unsigned long size;
  int ret;

  if (vma->vm_pgoff == 0) {
    /* Existing MMIO bridge shadow buffer path */
    mutex_lock(&mmio_bridge_lock);

    if (mmio_bridge_shadow_gpa == 0) {
      mutex_unlock(&mmio_bridge_lock);
      pr_err("rocm-axiio: PCI MMIO bridge shadow "
             "buffer not configured\n");
      return -EINVAL;
    }

    pfn = mmio_bridge_shadow_gpa >> PAGE_SHIFT;

    ret = remap_pfn_range(vma, vma->vm_start, pfn, mmio_bridge_shadow_size,
                          vma->vm_page_prot);
    if (ret < 0) {
      mutex_unlock(&mmio_bridge_lock);
      pr_err("rocm-axiio: Failed to remap shadow "
             "buffer: %d\n",
             ret);
      return ret;
    }

    pr_info("rocm-axiio: Mapped MMIO bridge shadow: "
            "GPA=0x%llx size=%llu vaddr=0x%lx\n",
            (unsigned long long)mmio_bridge_shadow_gpa,
            (unsigned long long)mmio_bridge_shadow_size, vma->vm_start);

    mutex_unlock(&mmio_bridge_lock);
    return 0;
  }

  /* pgoff >= 1: contiguous queue allocation mapping */
  {
    struct contig_alloc_entry* ca = NULL;
    __u32 target_id = (__u32)vma->vm_pgoff;
    bool found = false;

    spin_lock(&contig_allocs_lock);
    list_for_each_entry(ca, &contig_allocs, list) {
      if (ca->id == target_id && ca->owner == vma->vm_file) {
        /*
         * Take a reference while still under the lock to
         * protect against concurrent FREE_CONTIG_QUEUE
         * dropping the last reference and freeing @ca.
         */
        kref_get(&ca->ref);
        found = true;
        break;
      }
    }
    spin_unlock(&contig_allocs_lock);

    if (!found) {
      pr_err("rocm-axiio: contig mmap: id=%u "
             "not found or not owned by mapping file\n",
             target_id);
      return -ENOENT;
    }

    size = vma->vm_end - vma->vm_start;
    if (size > ca->size) {
      pr_err("rocm-axiio: contig mmap: requested "
             "size %lu > alloc size %zu\n",
             size, ca->size);
      kref_put(&ca->ref, contig_alloc_release);
      return -EINVAL;
    }

    vma->vm_pgoff = 0;

    ret = dma_mmap_coherent(&ca->pdev->dev, vma, ca->cpu_addr, ca->dma_addr,
                            size);
    if (ret < 0) {
      pr_err("rocm-axiio: contig mmap: "
             "dma_mmap_coherent failed: "
             "%d\n",
             ret);
      kref_put(&ca->ref, contig_alloc_release);
      return ret;
    }

    vma->vm_private_data = ca;
    vma->vm_ops = &contig_vm_ops;

    pr_info("rocm-axiio: contig mmap: id=%u "
            "dma=0x%llx size=%lu vaddr=0x%lx\n",
            target_id, (unsigned long long)ca->dma_addr, size, vma->vm_start);

    return 0;
  }
}

/* io_uring_cmd handler for high-performance async operations */
static int rocm_xio_uring_cmd(struct io_uring_cmd* ioucmd,
                              unsigned int issue_flags) {
  /* io_uring_cmd support for async high-performance buffer address
   * translation. This allows userspace to submit async requests for
   * address translation without blocking.
   *
   * For now, return -ENOSYS to indicate not yet implemented.
   * Future implementation could:
   *   - Accept virt_addr in ioucmd->cmd
   *   - Look up phys_addr from registered buffers
   *   - Return result via io_uring_cmd_done()
   */
  pr_debug("rocm-axiio: io_uring_cmd not yet implemented\n");
  return -ENOSYS;
}

/*
 * Resurrect every NVMe queue currently flagged as needing it.
 *
 * For each entry in poisoned_qids with needs_resurrect=true:
 *   1. Resolve the pci_dev and look up our cached snapshot.
 *   2. Submit CREATE_CQ then CREATE_SQ to the controller's admin
 *      queue with the kernel's original DMA addresses. This makes
 *      the device side of the QID line back up with the kernel's
 *      still-intact struct nvme_queue, so the next kernel I/O on
 *      that hctx no longer times out.
 *
 * Runs as workqueue work_struct -- process context, may sleep.
 *
 * Logging is verbose by design -- a malformed CREATE_SQ from kernel
 * context can panic the controller, so we want a clear breadcrumb
 * trail in dmesg if something misbehaves.
 */
static void rocm_xio_resurrect_work_fn(struct work_struct* w) {
  struct poisoned_qid_entry *pe, *pe_tmp;
  unsigned long flags_irq;
  bool clone_oom = false;
  LIST_HEAD(to_resurrect);

  (void)w;

  /*
   * Snapshot the set of entries that need resurrection AND
   * atomically clear the flag, so we don't double-fire if another
   * DELETE schedules us again while we're running.
   */
  spin_lock_irqsave(&poisoned_qids_lock, flags_irq);
  list_for_each_entry_safe(pe, pe_tmp, &poisoned_qids, list) {
    if (pe->needs_resurrect) {
      /* Detach a clone-ish view: build a parallel list of small
       * structs for the worker to iterate without holding the
       * spinlock.
       *
       * Allocate the clone BEFORE clearing the flags. If the
       * GFP_ATOMIC allocation fails we must NOT consume the
       * needs_resurrect flag: doing so would permanently strand the
       * QID (the device deleted it, but the kernel still believes it
       * exists, and no future event would re-trigger us because
       * @created would also be cleared). Instead leave the entry
       * untouched and reschedule a retry below.
       */
      struct poisoned_qid_entry* clone = kmalloc(sizeof(*clone), GFP_ATOMIC);
      if (!clone) {
        clone_oom = true;
        continue;
      }
      pe->needs_resurrect = false;
      pe->created = false; /* fresh slate: we're handing the QID back */
      clone->bdf = pe->bdf;
      clone->qid = pe->qid;
      clone->created = false;
      clone->needs_resurrect = false;
      INIT_LIST_HEAD(&clone->list);
      list_add_tail(&clone->list, &to_resurrect);
    }
  }
  spin_unlock_irqrestore(&poisoned_qids_lock, flags_irq);

  if (clone_oom) {
    pr_warn("rocm-axiio: resurrect: clone alloc failed under memory "
            "pressure; retrying in %u ms\n",
            ROCM_XIO_RESURRECT_DELAY_MS);
    mod_delayed_work(system_wq, &rocm_xio_resurrect_work,
                     msecs_to_jiffies(ROCM_XIO_RESURRECT_DELAY_MS));
  }

  list_for_each_entry_safe(pe, pe_tmp, &to_resurrect, list) {
    struct pci_dev* pdev;
    struct nvme_queue_snapshot snap;
    struct nvme_command c;
    int rc;
    unsigned int bus, devfn;
    int cq_flags;

    list_del(&pe->list);

    bus = (pe->bdf >> 8) & 0xFF;
    devfn = pe->bdf & 0xFF;
    pdev = pci_get_domain_bus_and_slot(0, bus, devfn);
    if (!pdev) {
      pr_warn("rocm-axiio: resurrect: pci_dev for bdf 0x%04x not found, "
              "skipping qid=%u\n",
              pe->bdf, pe->qid);
      kfree(pe);
      continue;
    }

    if (!nvme_queue_snapshot_lookup(pdev, pe->qid, &snap)) {
      pr_warn("rocm-axiio: resurrect: NO snapshot for %s qid=%u; "
              "kernel will hit a one-time timeout on this QID. "
              "(Snapshot will be captured on the controller reset that "
              "follows.)\n",
              pci_name(pdev), pe->qid);
      pci_dev_put(pdev);
      kfree(pe);
      continue;
    }

    if (!snap.admin_q) {
      pr_warn("rocm-axiio: resurrect: %s qid=%u has snapshot but no admin_q, "
              "skipping\n",
              pci_name(pdev), pe->qid);
      pci_dev_put(pdev);
      kfree(pe);
      continue;
    }

    if (snap.q_depth == 0 || snap.sq_dma_addr == 0 || snap.cq_dma_addr == 0) {
      pr_warn("rocm-axiio: resurrect: %s qid=%u snapshot looks bogus "
              "(depth=%u sq=0x%llx cq=0x%llx), skipping\n",
              pci_name(pdev), pe->qid, snap.q_depth,
              (unsigned long long)snap.sq_dma_addr,
              (unsigned long long)snap.cq_dma_addr);
      pci_dev_put(pdev);
      kfree(pe);
      continue;
    }

    /* ---- CREATE_CQ ---- (must come first; SQ references the CQ) */
    memset(&c, 0, sizeof(c));
    cq_flags = NVME_QUEUE_PHYS_CONTIG;
    if (!snap.polled)
      cq_flags |= NVME_CQ_IRQ_ENABLED;

    c.create_cq.opcode = nvme_admin_create_cq;
    c.create_cq.prp1 = cpu_to_le64(snap.cq_dma_addr);
    c.create_cq.cqid = cpu_to_le16(pe->qid);
    c.create_cq.qsize = cpu_to_le16(snap.q_depth - 1);
    c.create_cq.cq_flags = cpu_to_le16(cq_flags);
    c.create_cq.irq_vector = cpu_to_le16(snap.cq_vector);

    pr_info("rocm-axiio: resurrect: %s qid=%u CREATE_CQ "
            "prp1=0x%llx qsize=%u cq_flags=0x%x vec=%u\n",
            pci_name(pdev), pe->qid, (unsigned long long)snap.cq_dma_addr,
            snap.q_depth - 1, cq_flags, snap.cq_vector);

    rc = nvme_submit_sync_cmd(snap.admin_q, &c, NULL, 0);
    if (rc) {
      pr_warn("rocm-axiio: resurrect: %s qid=%u CREATE_CQ failed: %d\n",
              pci_name(pdev), pe->qid, rc);
      pci_dev_put(pdev);
      kfree(pe);
      continue;
    }

    /* ---- CREATE_SQ ---- */
    memset(&c, 0, sizeof(c));
    c.create_sq.opcode = nvme_admin_create_sq;
    c.create_sq.prp1 = cpu_to_le64(snap.sq_dma_addr);
    c.create_sq.sqid = cpu_to_le16(pe->qid);
    c.create_sq.qsize = cpu_to_le16(snap.q_depth - 1);
    c.create_sq.sq_flags = cpu_to_le16(NVME_QUEUE_PHYS_CONTIG);
    c.create_sq.cqid = cpu_to_le16(pe->qid);

    pr_info("rocm-axiio: resurrect: %s qid=%u CREATE_SQ "
            "prp1=0x%llx qsize=%u\n",
            pci_name(pdev), pe->qid, (unsigned long long)snap.sq_dma_addr,
            snap.q_depth - 1);

    rc = nvme_submit_sync_cmd(snap.admin_q, &c, NULL, 0);
    if (rc) {
      pr_warn("rocm-axiio: resurrect: %s qid=%u CREATE_SQ failed: %d "
              "(controller now has CQ but no SQ for this qid; a kernel "
              "I/O on this hctx will still time out and trigger a reset)\n",
              pci_name(pdev), pe->qid, rc);
      pci_dev_put(pdev);
      kfree(pe);
      continue;
    }

    /*
     * ---- Host-side ring-pointer write-back ----
     *
     * The controller, having just processed CREATE_CQ + CREATE_SQ,
     * has reset QID @pe->qid's internal SQ-head / CQ-tail to the top
     * (entry 0, phase 1) -- mandatory NVMe behaviour for a freshly
     * created queue. But the kernel's HOST-side copy of those
     * pointers in struct nvme_queue was NOT touched: the normal
     * reset lives in nvme_init_queue() (drivers/nvme/host/pci.c),
     * which is on the kernel queue-creation path and is never called
     * during our passthrough-based resurrect. Without this fix the
     * host keeps its stale sq_tail/cq_head/cq_phase: the next kernel
     * SQE is written to the wrong SQ slot and/or the completion path
     * checks the wrong phase bit, so the first post-resurrect I/O on
     * this queue hangs and times out.
     *
     * We mirror exactly the four ring pointers nvme_init_queue sets:
     *   sq_tail = 0; last_sq_tail = 0; cq_head = 0; cq_phase = 1;
     *
     * Side effects of nvme_init_queue() we deliberately do NOT
     * replicate, and why each is not load-bearing here:
     *   - nvmeq->q_db = &dev->dbs[...]: the doorbell BAR pointer is
     *     unchanged across resurrect (the queue struct, its index,
     *     and the BAR mapping are all the same object the kernel set
     *     up at probe time). Re-deriving it is a no-op.
     *   - memset(cqes, 0, CQ_SIZE): zeroing the CQE ring is only a
     *     belt-and-suspenders for the phase-tag scan. We restore
     *     cq_phase=1 and cq_head=0 so the host expects phase-1 CQEs,
     *     which is exactly what the controller will write into a
     *     freshly created CQ. The stale CQEs left from before the
     *     hijack already carry phase 1 (the queue had wrapped an even
     *     number of times or not at all is NOT guaranteed) -- so to
     *     be safe we DO clear the CQ ring below, matching
     *     nvme_init_queue, because a stale phase-1 CQE at cq_head
     *     could otherwise be mistaken for a fresh completion.
     *   - nvme_dbbuf_init(): shadow doorbell. QEMU's emulated NVMe
     *     does not advertise the dbbuf (CMB shadow doorbell) feature,
     *     so dbbuf_sq_db/dbbuf_cq_db are NULL on this controller and
     *     nvme_dbbuf_init is a no-op for it. We skip it; if a future
     *     controller advertised dbbuf this would need revisiting (we
     *     would have to re-init the shadow doorbell so the device and
     *     host agree on the doorbell values after the queue's
     *     internal pointers were reset). Noted, not implemented,
     *     because it is provably inert here.
     *   - dev->online_queues++: NOT a per-queue ring pointer and is
     *     explicitly out of scope for this change (a separate
     *     investigation owns online_queues). The queue was already
     *     counted online at probe time and was never torn down on the
     *     host side, so we must NOT bump it here -- doing so would
     *     double-count.
     *
     * SAFETY / LOCKING:
     *   sq_tail and last_sq_tail are written by the submit path
     *   (nvme_queue_rq -> nvme_sq_copy_cmd / nvme_write_sq_db) under
     *   nvmeq->sq_lock. We take that same lock so our reset is
     *   atomic w.r.t. any concurrent dispatch on another CPU. We
     *   reach the lock through the offset-verified mirror (sq_lock at
     *   offset 8, confirmed via pahole against this kernel's BTF), so
     *   it is the *same* spinlock object nvme_queue_rq uses -- not a
     *   copy. The lock is never taken from hard-IRQ context in the
     *   nvme driver, so plain spin_lock (matching upstream) is
     *   correct; we do not need irqsave.
     *
     *   cq_head and cq_phase are written by the completion path
     *   (nvme_process_cq -> nvme_update_cq_head) which, for an
     *   IRQ-driven (non-poll) queue, runs only on the single CPU the
     *   managed MSI-X vector is pinned to (CPU 7 for QID 8 here) and
     *   takes NO lock. We CANNOT serialise against it with a lock.
     *   We rely instead on the fact that at resurrect time the queue
     *   is wedged: xio-tester just issued DELETE_SQ/DELETE_CQ, the
     *   device has no QID @pe->qid, and PR-174's QUIESCE_NS stopped
     *   this hctx for the whole xio-tester run, so NO kernel command
     *   was outstanding on this queue and NO completion can be in
     *   flight -- the completion handler cannot be running. We
     *   publish the reset with wmb() (as nvme_init_queue does) before
     *   returning, so the first post-UNQUIESCE I/O and its completion
     *   observe the fresh pointers. If the completion path could race
     *   us we would be unable to make this safe with a lock; we have
     *   established it cannot, hence this is safe.
     */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 8, 0) &&                           \
  LINUX_VERSION_CODE < KERNEL_VERSION(6, 10, 0)
    /*
     * Liveness/identity re-validation before trusting snap.dev.
     *
     * snap.dev is a raw struct nvme_dev* captured >=250ms ago with NO
     * refcount; snap.pdev/pci_dev_get keeps the pci_dev alive but NOT
     * the nvme_dev, which the NVMe driver kfree()s on unbind/remove/
     * error-recovery. If the driver detached in that window, reading
     * dev_layout->queues and taking live_nvmeq->sq_lock below would be
     * a use-after-free. The upstream nvme_pci driver stores the
     * nvme_dev as pdev drvdata, so pci_get_drvdata(pdev) == snap.dev
     * confirms the same nvme_dev is still attached to this pdev. This
     * is best-effort (a TOCTOU detach in the tiny window after the
     * check is theoretically possible) but it closes the real-world
     * window -- a driver that detached long ago.
     */
    if (snap.dev && pci_get_drvdata(pdev) == snap.dev) {
      struct rocm_xio_nvme_dev_layout* dev_layout =
        (struct rocm_xio_nvme_dev_layout*)snap.dev;
      if (dev_layout->queues) {
        /*
         * dev->queues is an array of struct nvme_queue (NOT an array
         * of pointers); element stride is the real kernel
         * sizeof(struct nvme_queue) == 192 on 6.8.0-117-generic,
         * pahole-verified. Index by qid and cast to the mirror.
         */
        const size_t kernel_nvmeq_stride = 192;
        struct rocm_xio_nvmeq_layout* live_nvmeq =
          (struct rocm_xio_nvmeq_layout*)((u8*)dev_layout->queues +
                                          (size_t)pe->qid *
                                            kernel_nvmeq_stride);

        /*
         * Clear the CQE ring (matches nvme_init_queue's memset) so a
         * stale phase-1 CQE left at the old cq_head cannot be
         * mistaken for a fresh completion once we reset cq_head=0,
         * cq_phase=1. live_nvmeq->cqes is the same DMA-coherent CQ
         * buffer the controller now writes into; q_depth * sizeof(
         * struct nvme_completion) is its size.
         */
        if (live_nvmeq->cqes && snap.q_depth)
          memset(live_nvmeq->cqes, 0,
                 (size_t)snap.q_depth * sizeof(struct nvme_completion));

        /* sq_tail / last_sq_tail under sq_lock (submit-path lock). */
        spin_lock(&live_nvmeq->sq_lock);
        live_nvmeq->sq_tail = 0;
        live_nvmeq->last_sq_tail = 0;
        spin_unlock(&live_nvmeq->sq_lock);

        /* cq_head / cq_phase: no concurrent writer at resurrect time
         * (see SAFETY note above). */
        live_nvmeq->cq_head = 0;
        live_nvmeq->cq_phase = 1;

        wmb(); /* publish before the first post-resurrect I/O */

        pr_info("rocm-axiio: resurrect: %s qid=%u host ring pointers "
                "reset (sq_tail=last_sq_tail=cq_head=0, cq_phase=1)\n",
                pci_name(pdev), pe->qid);
      } else {
        pr_warn("rocm-axiio: resurrect: %s qid=%u dev->queues NULL, "
                "skipping host ring-pointer reset (queue may still "
                "desync)\n",
                pci_name(pdev), pe->qid);
      }
    } else if (snap.dev) {
      pr_warn("rocm-axiio: resurrect: %s qid=%u nvme driver detached "
              "(pci_get_drvdata != snapshot nvme_dev); skipping host "
              "ring-pointer reset to avoid use-after-free on the freed "
              "nvme_dev (queue may still desync)\n",
              pci_name(pdev), pe->qid);
    } else {
      pr_warn("rocm-axiio: resurrect: %s qid=%u snapshot has no nvme_dev, "
              "skipping host ring-pointer reset\n",
              pci_name(pdev), pe->qid);
    }
#else
    pr_warn("rocm-axiio: resurrect: host ring-pointer reset compiled out "
            "(kernel not in [6.8, 6.10)); mirror layout unverified for "
            "this kernel -- qid=%u may desync\n",
            pe->qid);
#endif

    pr_info("rocm-axiio: resurrect: %s qid=%u DONE\n", pci_name(pdev), pe->qid);

    pci_dev_put(pdev);
    kfree(pe);
  }
}

static int rocm_xio_release(struct inode* inode, struct file* file) {
  struct contig_alloc_entry *ca, *tmp;
  struct quiesced_ns_entry *qn, *qn_tmp;
  LIST_HEAD(to_release);
  LIST_HEAD(quiesce_release);

  /*
   * Note: queue resurrection no longer runs here. It is triggered
   * from the kprobe pre-handler when it sees a user-issued
   * DELETE_SQ for a (bdf, qid) we previously saw a hijacked
   * CREATE_* for, via schedule_work(&rocm_xio_resurrect_work). That
   * timing is the actual "device-side queue is gone" event, which
   * may pre-date file-close by many milliseconds, and may involve
   * different fds for queue-addr registration vs. contig
   * allocation. Per-fd release was unreliable here.
   */

  spin_lock(&contig_allocs_lock);
  list_for_each_entry_safe(ca, tmp, &contig_allocs, list) {
    if (ca->owner == file) {
      list_del(&ca->list);
      list_add(&ca->list, &to_release);
    }
  }
  spin_unlock(&contig_allocs_lock);

  list_for_each_entry_safe(ca, tmp, &to_release, list) {
    list_del(&ca->list);
    pr_info("rocm-axiio: release: freeing "
            "contig id=%u dma=0x%llx "
            "size=%zu\n",
            ca->id, (unsigned long long)ca->dma_addr, ca->size);
    kref_put(&ca->ref, contig_alloc_release);
  }

  /*
   * Auto-unquiesce any namespaces this fd left quiesced. The
   * block layer would otherwise stay quiesced forever if a
   * caller crashed between QUIESCE_NS and UNQUIESCE_NS.
   */
  mutex_lock(&quiesced_ns_lock);
  list_for_each_entry_safe(qn, qn_tmp, &quiesced_ns, list) {
    if (qn->owner == file) {
      list_del(&qn->list);
      list_add(&qn->list, &quiesce_release);
    }
  }
  mutex_unlock(&quiesced_ns_lock);

  list_for_each_entry_safe(qn, qn_tmp, &quiesce_release, list) {
    struct request_queue* q = qn->bd ? bdev_get_queue(qn->bd) : NULL;
    list_del(&qn->list);
    if (q) {
      if (qn->mode == QUIESCED_NS_MODE_FULL) {
        blk_mq_unquiesce_queue(q);
        pr_info("rocm-axiio: release: auto-unquiesced request_queue for %pg\n",
                qn->bd);
      } else {
        struct blk_mq_hw_ctx* hctx = rocm_xio_hctx_at(q, qn->hctx_idx);
        if (hctx) {
          blk_mq_start_hw_queue(hctx);
          pr_info("rocm-axiio: release: auto-restarted hctx %u for %pg\n",
                  qn->hctx_idx, qn->bd);
        }
      }
    }
    fput(qn->bdev_file);
    kfree(qn);
  }

  return 0;
}

/* File operations */
static struct file_operations fops = {
  .owner = THIS_MODULE,
  .unlocked_ioctl = rocm_xio_ioctl,
  .mmap = rocm_xio_mmap,
  .release = rocm_xio_release,
  .uring_cmd = rocm_xio_uring_cmd,
};

static int __init rocm_xio_init(void) {
  int ret;

  /* Register character device */
  major_number = register_chrdev(0, DEVICE_NAME, &fops);
  if (major_number < 0) {
    pr_err("rocm-axiio: Failed to register device: %d\n", major_number);
    return major_number;
  }

  /* Create device class */
  rocm_xio_class = class_create(CLASS_NAME);
  if (IS_ERR(rocm_xio_class)) {
    unregister_chrdev(major_number, DEVICE_NAME);
    return PTR_ERR(rocm_xio_class);
  }

  /* Create device */
  rocm_xio_device = device_create(rocm_xio_class, NULL, MKDEV(major_number, 0),
                                  NULL, DEVICE_NAME);
  if (IS_ERR(rocm_xio_device)) {
    class_destroy(rocm_xio_class);
    unregister_chrdev(major_number, DEVICE_NAME);
    return PTR_ERR(rocm_xio_device);
  }

  /* Register kprobe for NVMe command injection */
  if (inject_enabled) {
    nvme_kp.pre_handler = nvme_submit_user_cmd_pre;
    ret = register_kprobe(&nvme_kp);
    if (ret < 0) {
      pr_warn("rocm-axiio: Failed to register kprobe: %d\n", ret);
      pr_warn("  Injection disabled - module will work in ioctl-only mode\n");
      inject_enabled = false;
    } else {
      pr_info("rocm-axiio: Kprobe registered successfully\n");
      pr_info("  Hooked: %s at %p\n", nvme_kp.symbol_name, nvme_kp.addr);
      pr_info("  Monitoring for CREATE_CQ/CREATE_SQ and I/O commands\n");
    }
  }

  /*
   * Register kretprobe on nvme_alloc_queue so we snapshot the kernel's
   * sq_dma_addr / cq_dma_addr / depth / cq_vector for every I/O queue
   * the nvme PCI driver allocates. These snapshots feed
   * rocm_xio_release()'s queue resurrection path.
   *
   * Note: queues created BEFORE this module loads (i.e. the first
   * probe of the nvme PCI driver) are NOT captured. The first
   * controller reset after module load -- including the one xio-tester
   * itself may trigger by wedging QID 8 -- re-invokes nvme_alloc_queue
   * and from that point we have a snapshot.
   */
  ret = register_kretprobe(&nvme_alloc_queue_krp);
  if (ret < 0) {
    pr_warn("rocm-axiio: Failed to register nvme_alloc_queue kretprobe: %d\n",
            ret);
    pr_warn("  Initial queue snapshot disabled (only matters at probe).\n");
  } else {
    nvme_alloc_queue_krp_registered = true;
    pr_info("rocm-axiio: nvme_alloc_queue kretprobe registered at %p\n",
            nvme_alloc_queue_krp.kp.addr);
  }

  ret = register_kretprobe(&nvme_create_queue_krp);
  if (ret < 0) {
    pr_warn("rocm-axiio: Failed to register nvme_create_queue kretprobe: %d\n",
            ret);
    pr_warn("  QID resurrection on release will be disabled.\n");
  } else {
    nvme_create_queue_krp_registered = true;
    pr_info("rocm-axiio: nvme_create_queue kretprobe registered at %p\n",
            nvme_create_queue_krp.kp.addr);
  }

  pr_info("rocm-axiio: Module loaded\n");
  pr_info("  Device: /dev/%s\n", DEVICE_NAME);
  pr_info("  Major number: %d\n", major_number);
  pr_info("  Injection: %s\n", inject_enabled ? "enabled" : "disabled");

  return 0;
}

static void __exit rocm_xio_exit(void) {
  struct queue_addr_entry *qentry, *qtmp;
  struct vram_buffer_entry *entry, *tmp;

  /* Unregister kprobe */
  if (inject_enabled) {
    unregister_kprobe(&nvme_kp);
  }

  if (nvme_alloc_queue_krp_registered) {
    unregister_kretprobe(&nvme_alloc_queue_krp);
    nvme_alloc_queue_krp_registered = false;
    pr_info("rocm-axiio: nvme_alloc_queue kretprobe unregistered "
            "(missed=%d)\n",
            nvme_alloc_queue_krp.nmissed);
  }
  if (nvme_create_queue_krp_registered) {
    unregister_kretprobe(&nvme_create_queue_krp);
    nvme_create_queue_krp_registered = false;
    pr_info("rocm-axiio: nvme_create_queue kretprobe unregistered "
            "(missed=%d)\n",
            nvme_create_queue_krp.nmissed);
  }

  /* Wait for any pending resurrect work to finish before tearing
   * down the snapshot/poisoned lists. */
  cancel_delayed_work_sync(&rocm_xio_resurrect_work);

  /* Free any remaining queue snapshots and poisoned-qid entries */
  nvme_queue_snapshots_free_all();
  {
    struct poisoned_qid_entry *pe, *pe_tmp;
    unsigned long flags_irq;
    LIST_HEAD(to_free);
    spin_lock_irqsave(&poisoned_qids_lock, flags_irq);
    list_for_each_entry_safe(pe, pe_tmp, &poisoned_qids, list) {
      list_del(&pe->list);
      list_add(&pe->list, &to_free);
    }
    spin_unlock_irqrestore(&poisoned_qids_lock, flags_irq);
    list_for_each_entry_safe(pe, pe_tmp, &to_free, list) {
      list_del(&pe->list);
      kfree(pe);
    }
  }

  /* Clean up registered queue addresses */
  spin_lock(&queue_addrs_lock);
  list_for_each_entry_safe(qentry, qtmp, &queue_addrs, list) {
    list_del(&qentry->list);
    kfree(qentry);
  }
  spin_unlock(&queue_addrs_lock);

  /* Clean up registered buffers */
  {
    LIST_HEAD(to_free);

    spin_lock(&vram_buffers_lock);
    list_splice_init(&vram_buffers, &to_free);
    spin_unlock(&vram_buffers_lock);

    list_for_each_entry_safe(entry, tmp, &to_free, list) {
      list_del(&entry->list);
      /* Cleanup passthrough attachment if needed */
      if (entry->is_passthrough && entry->sgt && entry->attach &&
          entry->dmabuf) {
        dma_buf_unmap_attachment(entry->attach, entry->sgt, DMA_BIDIRECTIONAL);
        dma_buf_detach(entry->dmabuf, entry->attach);
        dma_buf_put(entry->dmabuf);
        if (entry->nvme_pdev)
          pci_dev_put(entry->nvme_pdev);
      }
      kfree(entry);
    }
  }

  /* Clean up contiguous DMA allocations */
  {
    struct contig_alloc_entry *ca, *ca_tmp;
    LIST_HEAD(to_free);

    spin_lock(&contig_allocs_lock);
    list_for_each_entry_safe(ca, ca_tmp, &contig_allocs, list) {
      list_del(&ca->list);
      list_add(&ca->list, &to_free);
    }
    spin_unlock(&contig_allocs_lock);

    list_for_each_entry_safe(ca, ca_tmp, &to_free, list) {
      list_del(&ca->list);
      pr_info("rocm-axiio: exit: freeing contig "
              "id=%u dma=0x%llx size=%zu\n",
              ca->id, (unsigned long long)ca->dma_addr, ca->size);
      kref_put(&ca->ref, contig_alloc_release);
    }
  }

  /* Unquiesce any namespaces still held by the module */
  {
    struct quiesced_ns_entry *qn, *qn_tmp;
    LIST_HEAD(qn_free);

    mutex_lock(&quiesced_ns_lock);
    list_for_each_entry_safe(qn, qn_tmp, &quiesced_ns, list) {
      list_del(&qn->list);
      list_add(&qn->list, &qn_free);
    }
    mutex_unlock(&quiesced_ns_lock);

    list_for_each_entry_safe(qn, qn_tmp, &qn_free, list) {
      struct request_queue* q = qn->bd ? bdev_get_queue(qn->bd) : NULL;
      list_del(&qn->list);
      if (q) {
        if (qn->mode == QUIESCED_NS_MODE_FULL) {
          blk_mq_unquiesce_queue(q);
          pr_info("rocm-axiio: exit: unquiesced request_queue for %pg\n",
                  qn->bd);
        } else {
          struct blk_mq_hw_ctx* hctx = rocm_xio_hctx_at(q, qn->hctx_idx);
          if (hctx) {
            blk_mq_start_hw_queue(hctx);
            pr_info("rocm-axiio: exit: restarted hctx %u for %pg\n",
                    qn->hctx_idx, qn->bd);
          }
        }
      }
      fput(qn->bdev_file);
      kfree(qn);
    }
  }

  device_destroy(rocm_xio_class, MKDEV(major_number, 0));
  class_destroy(rocm_xio_class);
  unregister_chrdev(major_number, DEVICE_NAME);

  pr_info("rocm-axiio: Module unloaded\n");
}

module_init(rocm_xio_init);
module_exit(rocm_xio_exit);
