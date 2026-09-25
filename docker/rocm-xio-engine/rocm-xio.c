/*
 * SPDX-License-Identifier: GPL-2.0
 *
 * rocm-xio fio engine v5 — persistent GPU kernel
 *
 * gpuKernelPersistent runs for the lifetime of each fio file (queue).
 * The CPU posts work items to a GPU-accessible ring; the GPU picks them
 * up, executes the NVMe I/O, and marks completions — all without any
 * per-op kernel re-launch.  This eliminates the ~16 µs HIP dispatch
 * overhead from every operation.
 *
 * Theoretical IOPS: 1/(NVMe RTT) ≈ 71K per thread vs 33K before.
 *
 * Usage:
 *   ioengine=external:/path/to/rocm-xio.so
 *   filename=/dev/nvme2  bs=4k  iodepth=4  numjobs=2  --thread
 *   [rocm-xio]
 *   gpu_id=0  queue_id=0  queue_depth=64  memory_mode=8
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fcntl.h>
#include <linux/fs.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include "../fio.h"
#include "../optgroup.h"
#include "../verify.h"
#include "rocm-xio-hip.h"

struct rocm_xio_options {
  struct thread_data* td;
  int gpu_id;
  unsigned int queue_id;
  unsigned int queue_depth;
  unsigned int memory_mode;
};

static struct fio_option options[] = {
  {
    .name = "gpu_id",
    .lname = "rocm-xio GPU device index",
    .type = FIO_OPT_INT,
    .off1 = offsetof(struct rocm_xio_options, gpu_id),
    .help = "HIP GPU device index (default 0)",
    .def = "0",
    .minval = 0,
    .category = FIO_OPT_C_ENGINE,
    .group = FIO_OPT_G_ROCM_XIO,
  },
  {
    .name = "queue_id",
    .lname = "rocm-xio NVMe queue ID",
    .type = FIO_OPT_INT,
    .off1 = offsetof(struct rocm_xio_options, queue_id),
    .help = "NVMe I/O queue ID (0 = auto, unique per numjob)",
    .def = "0",
    .minval = 0,
    .category = FIO_OPT_C_ENGINE,
    .group = FIO_OPT_G_ROCM_XIO,
  },
  {
    .name = "queue_depth",
    .lname = "rocm-xio NVMe queue depth",
    .type = FIO_OPT_INT,
    .off1 = offsetof(struct rocm_xio_options, queue_depth),
    .help = "NVMe SQ/CQ depth in entries (power of 2)",
    .def = "64",
    .minval = 2,
    .maxval = 4096,
    .category = FIO_OPT_C_ENGINE,
    .group = FIO_OPT_G_ROCM_XIO,
  },
  {
    .name = "memory_mode",
    .lname = "rocm-xio memory mode flags",
    .type = FIO_OPT_INT,
    .off1 = offsetof(struct rocm_xio_options, memory_mode),
    .help = "XIO_MEM_MODE_* (0=host coherent, 8=GPU VRAM)",
    .def = "8",
    .minval = 0,
    .category = FIO_OPT_C_ENGINE,
    .group = FIO_OPT_G_ROCM_XIO,
  },
  {.name = NULL},
};

/*
 * Per-file engine state.
 * ring[] tracks io_us posted to the GPU work ring, in submission order.
 */
#define RXIO_RING 63

struct rocm_xio_file_data {
  struct rxio_queue_ctx* ctx;
  unsigned lba_size;
  int iodepth; /* = fio iodepth, capped at RXIO_RING */

  struct io_u* ring[RXIO_RING]; /* io_u ring (submission order) */
  int ring_head;                /* next slot to fill */
  int ring_tail;                /* oldest outstanding slot */
  int ring_count;               /* slots in flight */
};

/* Completed io_u scratch array for event() */
struct rxio_events {
  struct io_u** arr;
  int cap;
  int count;
};

static int fio_rocm_xio_init(struct thread_data* td) {
  return 0;
}

static int fio_rocm_xio_open_file(struct thread_data* td, struct fio_file* f) {
  struct rocm_xio_options* o = td->eo;
  struct rocm_xio_file_data* fd;
  size_t single_size, buf_size;
  int iodepth, rc;

  fd = calloc(1, sizeof(*fd));
  if (!fd)
    return ENOMEM;
  fd->ctx = rxio_ctx_alloc();
  if (!fd->ctx) {
    free(fd);
    return ENOMEM;
  }

  iodepth = (int)td->o.iodepth;
  if (iodepth < 1)
    iodepth = 1;
  if (iodepth > RXIO_RING)
    iodepth = RXIO_RING;
  fd->iodepth = iodepth;

  single_size = td->o.max_bs[DDIR_READ];
  if (td->o.max_bs[DDIR_WRITE] > single_size)
    single_size = td->o.max_bs[DDIR_WRITE];
  single_size = (single_size + 4095) & ~(size_t)4095;
  if (!single_size)
    single_size = 4096;
  buf_size = single_size * (size_t)iodepth;

  rc = rxio_setup(fd->ctx, f->file_name, (uint16_t)o->queue_id,
                  (uint16_t)o->queue_depth, buf_size, single_size, iodepth,
                  o->memory_mode, o->gpu_id, td->subjob_number);
  if (rc < 0) {
    log_err("rocm-xio: rxio_setup(%s) failed: %d\n", f->file_name, rc);
    rxio_ctx_free(fd->ctx);
    free(fd);
    return -rc;
  }

  fd->lba_size = rxio_lba_size(fd->ctx);
  if (!f->real_file_size) {
    f->real_file_size = rxio_ns_capacity_lbas(fd->ctx) * fd->lba_size;
    fio_file_set_size_known(f);
  }

  /* Launch the persistent kernel — dispatch cost paid once */
  rc = rxio_start_persistent(fd->ctx, iodepth);
  if (rc < 0) {
    log_err("rocm-xio: rxio_start_persistent failed: %d\n", rc);
    rxio_teardown(fd->ctx);
    rxio_ctx_free(fd->ctx);
    free(fd);
    return -rc;
  }

  FILE_SET_ENG_DATA(f, fd);
  return 0;
}

static int fio_rocm_xio_close_file(struct thread_data* td, struct fio_file* f) {
  struct rocm_xio_file_data* fd = FILE_ENG_DATA(f);
  (void)td;
  if (fd) {
    rxio_teardown(fd->ctx); /* stops persistent kernel */
    rxio_ctx_free(fd->ctx);
    free(fd);
    FILE_SET_ENG_DATA(f, NULL);
  }
  return 0;
}

static void fio_rocm_xio_cleanup(struct thread_data* td) {
  struct rxio_events* ev = td->io_ops_data;
  if (ev) {
    free(ev->arr);
    free(ev);
    td->io_ops_data = NULL;
  }
}

/*
 * queue() — post one op to the GPU's work ring.
 * The persistent kernel picks it up and processes it independently.
 */
static enum fio_q_status fio_rocm_xio_queue(struct thread_data* td,
                                            struct io_u* io_u) {
  struct rocm_xio_file_data* fd = FILE_ENG_DATA(io_u->file);
  uint64_t lba;
  uint32_t lbas;
  int is_write, slot, rc;

  if (!fd || !fd->ctx) {
    io_u->error = EINVAL;
    td_verror(td, EINVAL, "xfer");
    return FIO_Q_COMPLETED;
  }

  fio_ro_check(td, io_u);

  switch (io_u->ddir) {
    case DDIR_SYNC:
    case DDIR_DATASYNC:
      return FIO_Q_COMPLETED;

    case DDIR_READ:
    case DDIR_WRITE:
      if (!fd->lba_size) {
        io_u->error = EIO;
        td_verror(td, EIO, "xfer");
        return FIO_Q_COMPLETED;
      }

      if (fd->ring_count >= fd->iodepth)
        return FIO_Q_BUSY;

      is_write = (io_u->ddir == DDIR_WRITE);
      lba = io_u->offset / fd->lba_size;
      lbas = (uint32_t)(io_u->xfer_buflen / fd->lba_size);
      if (!lbas)
        lbas = 1;

      slot = fd->ring_head;

      /* Record io_u in the ring */
      fd->ring[slot] = io_u;
      fd->ring_head = (fd->ring_head + 1) % RXIO_RING;
      fd->ring_count++;

      /* Post to persistent kernel's work ring */
      rc = rxio_post_work(fd->ctx, lba, lbas, is_write, slot);
      if (rc < 0) {
        /* Undo ring insert */
        fd->ring_head = slot;
        fd->ring_count--;
        fd->ring[slot] = NULL;
        if (rc == -ENOSPC)
          return FIO_Q_BUSY; /* don't set error */
        io_u->error = EIO;
        td_verror(td, EIO, "post_work");
        return FIO_Q_COMPLETED;
      }
      return FIO_Q_QUEUED;

    default:
      io_u->error = EINVAL;
      td_verror(td, EINVAL, "ddir");
      return FIO_Q_COMPLETED;
  }
}

/* commit() — no-op; persistent kernel processes ops as they are posted */
static int fio_rocm_xio_commit(struct thread_data* td) {
  (void)td;
  return 0;
}

/*
 * getevents() — reap completions from the GPU work ring.
 * rxio_reap() returns 1 when the oldest outstanding slot is done.
 * Spins until min completions are ready.
 */
static int fio_rocm_xio_getevents(struct thread_data* td, unsigned int min,
                                  unsigned int max, const struct timespec* t) {
  struct rxio_events* ev = td->io_ops_data;
  int found = 0;
  struct timespec deadline = {0, 0};
  if (t) {
    clock_gettime(CLOCK_MONOTONIC, &deadline);
    deadline.tv_sec  += t->tv_sec;
    deadline.tv_nsec += t->tv_nsec;
    if (deadline.tv_nsec >= 1000000000L) {
      deadline.tv_sec++;
      deadline.tv_nsec -= 1000000000L;
    }
  }

  if (!ev) {
    ev = calloc(1, sizeof(*ev));
    if (!ev)
      return -ENOMEM;
    ev->cap = td->o.iodepth + 16;
    ev->arr = calloc((size_t)ev->cap, sizeof(*ev->arr));
    if (!ev->arr) {
      free(ev);
      return -ENOMEM;
    }
    td->io_ops_data = ev;
  }
  ev->count = 0;

  do {
    struct fio_file* f;
    unsigned int fi;

    for_each_file(td, f, fi) {
      struct rocm_xio_file_data* fd = FILE_ENG_DATA(f);
      if (!fd || !fd->ring_count)
        continue;

      while (fd->ring_count > 0 && found < (int)max) {
        int r = rxio_reap(fd->ctx);
        if (r == 0)
          break; /* GPU not done yet */
        if (r < 0) {
          /* Error — retire head with EIO */
          struct io_u* u = fd->ring[fd->ring_tail];
          fd->ring_tail = (fd->ring_tail + 1) % RXIO_RING;
          fd->ring_count--;
          if (u) {
            u->error = EIO;
            ev->arr[found++] = u;
          }
          break;
        }
        /* Completion: retire oldest ring entry */
        struct io_u* u = fd->ring[fd->ring_tail];
        fd->ring_tail = (fd->ring_tail + 1) % RXIO_RING;
        fd->ring_count--;
        if (!u)
          continue;
        if (found < ev->cap)
          ev->arr[found++] = u;
      }
    }

    if (found < (int)min) {
      if (t) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec > deadline.tv_sec ||
            (now.tv_sec == deadline.tv_sec &&
             now.tv_nsec >= deadline.tv_nsec))
          break; /* deadline expired — return what we have */
      }
      usleep(1);
    }

  } while (found < (int)min);

  ev->count = found;
  return found;
}

static struct io_u* fio_rocm_xio_event(struct thread_data* td, int event) {
  struct rxio_events* ev = td->io_ops_data;
  if (!ev || event < 0 || event >= ev->count)
    return NULL;
  return ev->arr[event];
}

static int fio_rocm_xio_get_file_size(struct thread_data* td,
                                      struct fio_file* f) {
  struct rocm_xio_file_data* fd = FILE_ENG_DATA(f);
  if (fd && fd->ctx && fd->lba_size) {
    f->real_file_size = rxio_ns_capacity_lbas(fd->ctx) * fd->lba_size;
    fio_file_set_size_known(f);
    return 0;
  }
  /* Engine not yet open — query size via a temporary fd to avoid EBADF
   * from blockdev_size when f->fd is 0 (not yet opened by fio). */
  if (f->file_name) {
    int tmpfd = open(f->file_name, O_RDONLY);
    if (tmpfd >= 0) {
      unsigned long long bytes = 0;
      if (ioctl(tmpfd, BLKGETSIZE64, &bytes) == 0 && bytes) {
        f->real_file_size = bytes;
        fio_file_set_size_known(f);
        close(tmpfd);
        return 0;
      }
      close(tmpfd);
    }
  }
  return generic_get_file_size(td, f);
}

FIO_STATIC struct ioengine_ops ioengine = {
  .name = "rocm-xio",
  .version = FIO_IOOPS_VERSION,
  .init = fio_rocm_xio_init,
  .queue = fio_rocm_xio_queue,
  .commit = fio_rocm_xio_commit,
  .getevents = fio_rocm_xio_getevents,
  .event = fio_rocm_xio_event,
  .cleanup = fio_rocm_xio_cleanup,
  .open_file = fio_rocm_xio_open_file,
  .close_file = fio_rocm_xio_close_file,
  .get_file_size = fio_rocm_xio_get_file_size,
  .flags = FIO_NOEXTEND,
  .options = options,
  .option_struct_size = sizeof(struct rocm_xio_options),
};

void fio_init fio_rocm_xio_register(void) {
  register_ioengine(&ioengine);
}
void fio_exit fio_rocm_xio_unregister(void) {
  unregister_ioengine(&ioengine);
}
void get_ioengine(struct ioengine_ops** ops) {
  *ops = &ioengine;
}
