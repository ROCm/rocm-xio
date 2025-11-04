/* SPDX-License-Identifier: GPL-2.0 */
/*
 * NVMe Kernel API Integration
 *
 * Use the Linux kernel's internal NVMe APIs to create I/O queues
 * that coexist with the kernel driver.
 *
 * This approach:
 * 1. Uses kernel's nvme_alloc_queue() or similar APIs
 * 2. Registers queues with the kernel driver
 * 3. Exports queue memory and doorbells to userspace
 * 4. Allows GPU-direct I/O while maintaining kernel compatibility
 */

#ifndef NVME_KERNEL_API_H
#define NVME_KERNEL_API_H

#include <linux/blk-mq.h>
#include <linux/nvme.h>

/*
 * Strategy: Hook into the kernel's NVMe subsystem
 *
 * The kernel NVMe driver (drivers/nvme/host/pci.c) exposes some APIs
 * that we can use. However, most are not exported (EXPORT_SYMBOL).
 *
 * Options:
 * 1. Request additional EXPORT_SYMBOL in kernel driver (upstream patch)
 * 2. Use kprobes to hook into internal functions (fragile)
 * 3. Communicate with nvme driver via custom ioctl (requires driver patch)
 * 4. Reserve queue IDs via module parameter
 */

/*
 * Approach: Reserve Queue IDs
 *
 * Modify the NVMe driver to:
 * - Accept a module parameter: reserved_queues=N
 * - Skip queue IDs above (total_queues - N) for kernel use
 * - Allow userspace to use the reserved queue IDs
 *
 * This requires a small patch to the kernel's nvme driver.
 */

/*
 * Proposed kernel nvme driver patch (drivers/nvme/host/pci.c):
 *
 * static unsigned int reserved_userspace_queues = 0;
 * module_param(reserved_userspace_queues, uint, 0644);
 * MODULE_PARM_DESC(reserved_userspace_queues,
 *                  "Number of queue IDs to reserve for userspace (e.g.,
 * GPU-direct I/O)");
 *
 * In nvme_setup_io_queues():
 *   // Reduce nr_io_queues by reserved amount
 *   nr_io_queues -= reserved_userspace_queues;
 *
 * In nvme_create_io_queues():
 *   // Only create queues up to (nr_io_queues - reserved_userspace_queues)
 *
 * Export a new ioctl for userspace to query reserved range:
 *   NVME_IOCTL_GET_RESERVED_QUEUES
 */

/*
 * Our module can then:
 * 1. Query which queue IDs are reserved for userspace
 * 2. Use those IDs without conflict
 * 3. Kernel driver won't touch those queues
 * 4. We send admin commands via NVME_IOCTL_ADMIN_CMD (works!)
 */

struct nvme_reserved_queue_info {
  u16 first_reserved_qid; /* First queue ID available for userspace */
  u16 num_reserved;       /* Number of reserved queues */
  u16 total_queues;       /* Total queues (kernel + reserved) */
};

/*
 * Check if a queue ID is in the reserved range
 */
static inline bool is_queue_reserved_for_userspace(
  u16 qid, const struct nvme_reserved_queue_info* info) {
  return (qid >= info->first_reserved_qid) &&
         (qid < info->first_reserved_qid + info->num_reserved);
}

/*
 * Alternative: Use existing kernel queues in "peek" mode
 *
 * Instead of creating new queues, we can:
 * 1. Map existing kernel queue memory (read-only)
 * 2. Observe CQEs without interfering
 * 3. Used for tracing/profiling, not for submission
 *
 * This doesn't require any kernel changes!
 */

/*
 * Alternative: Use "queue sharing" mode
 *
 * Multiple entities can submit to the same SQ:
 * 1. Kernel submits via blk-mq
 * 2. Userspace submits via our module
 * 3. Both poll the same CQ
 *
 * Challenges:
 * - Need atomic doorbell updates
 * - Need CQE routing (kernel vs userspace)
 * - Complex synchronization
 */

#endif /* NVME_KERNEL_API_H */
