/*
 * SPDX-License-Identifier: GPL-2.0
 *
 * rocm-xio fio engine — C-visible shim declarations
 */

#ifndef FIO_ROCM_XIO_HIP_H
#define FIO_ROCM_XIO_HIP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct rxio_queue_ctx;

struct rxio_queue_ctx* rxio_ctx_alloc(void);
void rxio_ctx_free(struct rxio_queue_ctx* ctx);

/*
 * rxio_setup — allocate queue, GPU buffer, BAR0 mapping.
 *
 * @buf_size     Total GPU data buffer (single_size * batch_capacity).
 * @single_size  Bytes per single I/O transfer.
 * @batch_cap    Max ops per stream batch (1 = sync mode, >1 = async batch).
 * @job_index    td->subjob_number; when queue_id=0 assigns max_qid-job_index.
 */
int rxio_setup(struct rxio_queue_ctx* ctx, const char* controller,
               uint16_t queue_id, uint16_t queue_size, size_t buf_size,
               size_t single_size, int batch_cap, unsigned memory_mode,
               int gpu_id, int job_index);

/*
 * Persistent kernel API — launch once, process many ops.
 *
 * rxio_start_persistent: launch gpuKernelPersistent on the stream.
 *   ring_depth: work-ring slots (= iodepth; must be power of 2 recommended).
 *
 * rxio_post_work: CPU writes one work item and signals the GPU (non-blocking).
 *   Returns 0 if the slot was free, -ENOSPC if the ring is full.
 *
 * rxio_reap: CPU polls for the oldest outstanding completion.
 *   Returns 1 if the next slot completed, 0 if still running, <0 on error.
 *
 * rxio_stop_persistent: set stop flag, wait for kernel to exit.
 */
int rxio_start_persistent(struct rxio_queue_ctx* ctx, int ring_depth);
int rxio_post_work(struct rxio_queue_ctx* ctx, uint64_t lba, uint32_t lbas,
                   int is_write, int slot);
int rxio_reap(struct rxio_queue_ctx* ctx);
void rxio_stop_persistent(struct rxio_queue_ctx* ctx);

/*
 * rxio_submit — launch one gpuKernelStateful asynchronously on the stream.
 *
 * @lba       Starting LBA for the first op in the batch.
 * @lbas      LBAs per op (all ops in the batch use the same transfer size).
 * @is_write  Non-zero for write.
 * @slot      Buffer slot index (0-based); op k uses GPU memory at slot+k.
 * @n_ops     Number of sequential ops to submit in this kernel call (≥1).
 *            ops use consecutive LBAs: lba, lba+lbas, lba+2*lbas, …
 */
int rxio_submit(struct rxio_queue_ctx* ctx, uint64_t lba, uint32_t lbas,
                int is_write, int slot, int n_ops);

/*
 * rxio_sync — wait for all in-flight kernels on the stream to complete.
 * Returns 0 on success, negative errno on failure.
 */
int rxio_sync(struct rxio_queue_ctx* ctx);

/*
 * rxio_poll — non-blocking check; returns 1 if stream idle, 0 if busy.
 */
int rxio_poll(struct rxio_queue_ctx* ctx);

/* D2H / H2D copies for verify (use slot 0 for iodepth=1) */
int rxio_copy_from_gpu(struct rxio_queue_ctx* ctx, void* dst, size_t len,
                       int slot);
int rxio_copy_to_gpu(struct rxio_queue_ctx* ctx, const void* src, size_t len,
                     int slot);

/* rxio_teardown — quiesce resume, delete queue, free GPU resources. */
void rxio_teardown(struct rxio_queue_ctx* ctx);

/* Metadata (valid after rxio_setup) */
unsigned rxio_lba_size(struct rxio_queue_ctx* ctx);
uint64_t rxio_ns_capacity_lbas(struct rxio_queue_ctx* ctx);

#ifdef __cplusplus
}
#endif

#endif /* FIO_ROCM_XIO_HIP_H */
