/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * vfu-doorbell: a small vfio-user server with two roles.
 *
 *   target  A PCI device whose BAR0 carries doorbell "overlays": byte ranges
 *           with a semantic model (index, keyed, event), a slot width and a
 *           stride. Every write is decoded and recorded per key so a guest
 *           can read back what arrived: counts, order, lost and reordered
 *           writes. It is the thing being rung.
 *   ringer  A PCI device the guest programs to write a pattern of values to
 *           any guest physical address, using the same libvfio-user calls an
 *           emulated GPU would use. It is the thing doing the ringing.
 *
 * Run one process per device, each on its own socket. See README.md.
 *
 * libvfio-user is not thread safe, so every library call is made under
 * lib_lock. The ringer's worker holds it across vfu_mmio_write(), which waits
 * for QEMU's reply; that is the same structure as a GPU emulator and is what
 * makes the single-socket deadlock reproducible.
 */
#define _GNU_SOURCE
#include "vfu-doorbell.h"

#include <errno.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <getopt.h>
#include <libvfio-user.h>
#include <poll.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>

#define LOG_LEVEL_DEFAULT LOG_WARNING

static volatile sig_atomic_t stop_requested;
static pthread_mutex_t lib_lock = PTHREAD_MUTEX_INITIALIZER;
static const char* role_name = "vfu-doorbell";

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static uint64_t load_le(const void* p, size_t n) {
  uint64_t v = 0;
  memcpy(&v, p, n > 8 ? 8 : n);
  return v;
}

static void store_le(void* p, size_t n, uint64_t v) {
  memcpy(p, &v, n > 8 ? 8 : n);
}

static void log_cb(vfu_ctx_t* ctx, int level, const char* msg) {
  (void)ctx;
  (void)level;
  fprintf(stderr, "%s: %s\n", role_name, msg);
}

/* ------------------------------------------------------------------------ */
/* Target                                                                    */
/* ------------------------------------------------------------------------ */

struct key_state {
  uint64_t last;
  uint64_t count;
  uint64_t head;
  uint64_t regress;
  uint64_t gaps;
  uint64_t ooo;
  uint16_t last_seq;
  bool seq_seen;
};

struct region {
  uint32_t model;
  uint32_t flags;
  uint64_t base;
  uint64_t size;
  uint32_t width;
  uint32_t stride;
  uint64_t writes;
  uint64_t bad;
  uint64_t gaps;
  uint64_t ooo;
  struct key_state* keys;
  size_t nkeys;
};

struct target {
  struct region regions[VFU_DB_T_MAX_REGIONS];
  uint64_t total_writes;
  uint64_t total_bad;
  uint64_t arrivals;
  uint32_t state_region;
  uint32_t state_key;
  struct vfu_db_log_entry log[VFU_DB_T_LOG_ENTRIES];
};

static struct target tgt;

/* --trace N: log the first N individual writes after each reset. */
static unsigned trace_writes_arg;
static unsigned trace_writes_left;

static const char* model_str(uint32_t m) {
  switch (m) {
    case VFU_DB_MODEL_INDEX:
      return "index";
    case VFU_DB_MODEL_KEYED:
      return "keyed";
    case VFU_DB_MODEL_EVENT:
      return "event";
    default:
      return "off";
  }
}

static void region_log(unsigned ri, const struct region* r) {
  fprintf(stderr,
          "%s: region %u: %s base=0x%llx size=0x%llx width=%u stride=%u%s\n",
          role_name, ri, model_str(r->model), (unsigned long long)r->base,
          (unsigned long long)r->size, r->width, r->stride,
          (r->flags & VFU_DB_FLAG_SEQ) ? " seq" : "");
}

static void region_free(struct region* r) {
  free(r->keys);
  r->keys = NULL;
  r->nkeys = 0;
}

/* Validate a region's parameters and (re)allocate its key state. A region
 * that does not validate is switched off. */
static void region_reconfigure(struct region* r) {
  size_t slots;
  size_t nkeys;

  region_free(r);
  r->writes = r->bad = r->gaps = r->ooo = 0;
  if (r->model == VFU_DB_MODEL_OFF)
    return;
  bool ok = r->model <= VFU_DB_MODEL_EVENT;
  ok = ok && (r->width == 1 || r->width == 2 || r->width == 4 || r->width == 8);
  ok = ok && r->stride >= r->width && (r->stride % r->width) == 0;
  ok = ok && r->base >= VFU_DB_T_WINDOW_BASE && (r->base % 4) == 0;
  ok = ok && r->size >= r->stride && r->base + r->size <= VFU_DB_T_BAR_SIZE;
  ok = ok && (r->model != VFU_DB_MODEL_KEYED || r->width == 8);
  if (!ok) {
    fprintf(stderr, "%s: rejecting invalid region configuration\n", role_name);
    r->model = VFU_DB_MODEL_OFF;
    return;
  }
  slots = r->size / r->stride;
  if (r->model == VFU_DB_MODEL_KEYED) {
    if (slots > 16)
      slots = 16;
    nkeys = slots * VFU_DB_KEYED_KEYS_PER_SLOT;
  } else {
    nkeys = slots;
  }
  r->keys = calloc(nkeys, sizeof(*r->keys));
  if (!r->keys) {
    r->model = VFU_DB_MODEL_OFF;
    return;
  }
  r->nkeys = nkeys;
}

static void target_reset_state(struct target* t) {
  fprintf(stderr, "%s: reset: %llu writes, %llu bad since the last reset\n",
          role_name, (unsigned long long)t->total_writes,
          (unsigned long long)t->total_bad);
  trace_writes_left = trace_writes_arg;
  for (unsigned i = 0; i < VFU_DB_T_MAX_REGIONS; i++)
    region_reconfigure(&t->regions[i]);
  t->total_writes = t->total_bad = t->arrivals = 0;
  memset(t->log, 0, sizeof(t->log));
}

static void log_write(struct target* t, unsigned region, uint64_t off,
                      uint64_t value, size_t size) {
  uint64_t arrival = ++t->arrivals;
  struct vfu_db_log_entry* e = &t->log[(arrival - 1) % VFU_DB_T_LOG_ENTRIES];
  e->arrival = arrival;
  e->value = value;
  e->offset = (uint32_t)off;
  e->size = (uint16_t)size;
  e->region = (uint16_t)region;
  e->time_ns = now_ns();
}

/* Account one sequence number against a key: in order, gap, or late. */
static void track_seq(struct region* r, struct key_state* k, uint16_t seq) {
  if (!k->seq_seen) {
    k->seq_seen = true;
    k->last_seq = seq;
    return;
  }
  int16_t d = (int16_t)(uint16_t)(seq - (uint16_t)(k->last_seq + 1));
  if (d == 0) {
    k->last_seq = seq;
  } else if (d > 0) {
    k->gaps += (uint64_t)d;
    r->gaps += (uint64_t)d;
    k->last_seq = seq;
  } else {
    k->ooo++;
    r->ooo++;
  }
}

/* Apply one write that landed in a region window. */
static void region_write(struct target* t, unsigned ri, uint64_t off,
                         size_t count, const char* buf) {
  struct region* r = &t->regions[ri];
  uint64_t rel = off - r->base;
  uint64_t value = load_le(buf, count);
  uint64_t slot = rel / r->stride;
  uint32_t idx;
  uint32_t ring = 0;
  uint32_t qid = 0;
  uint16_t seq = 0;
  bool has_seq = false;
  size_t key;

  if (trace_writes_left) {
    trace_writes_left--;
    fprintf(stderr, "%s: write region=%u off=0x%llx size=%zu value=0x%llx\n",
            role_name, ri, (unsigned long long)off, count,
            (unsigned long long)value);
  }
  if ((rel % r->stride) != 0 || count != r->width || slot >= r->nkeys) {
    r->bad++;
    t->total_bad++;
    log_write(t, ri, off, value, count);
    return;
  }
  idx = (uint32_t)(value & (count == 1 ? 0xffu : 0xffffu));
  if (r->model == VFU_DB_MODEL_KEYED) {
    ring = (uint32_t)((value >> 16) & 7u);
    qid = (uint32_t)((value >> 24) & 0xffffffu);
    if (r->flags & VFU_DB_FLAG_SEQ) {
      seq = (uint16_t)(value >> 48);
      has_seq = true;
    }
    if (slot >= 16) {
      r->bad++;
      t->total_bad++;
      log_write(t, ri, off, value, count);
      return;
    }
    key = (size_t)slot * VFU_DB_KEYED_KEYS_PER_SLOT + (qid & 0xffu) * 8u + ring;
  } else {
    if ((r->flags & VFU_DB_FLAG_SEQ) && count >= 4) {
      seq = (uint16_t)(value >> (count * 8 - 16));
      has_seq = true;
    }
    key = (size_t)slot;
  }
  struct key_state* k = &r->keys[key];
  if (r->model != VFU_DB_MODEL_EVENT && k->count > 0) {
    uint16_t d = (uint16_t)(idx - (uint16_t)k->head);
    if (d != 0 && d >= 0x8000)
      k->regress++;
  }
  if (has_seq)
    track_seq(r, k, seq);
  k->last = value;
  k->head = idx;
  k->count++;
  r->writes++;
  t->total_writes++;
  log_write(t, ri, off, value, count);
}

static const struct key_state zero_key;

static const struct key_state* state_lookup(const struct target* t) {
  if (t->state_region >= VFU_DB_T_MAX_REGIONS)
    return &zero_key;
  const struct region* r = &t->regions[t->state_region];
  if (!r->keys || t->state_key >= r->nkeys)
    return &zero_key;
  return &r->keys[t->state_key];
}

/* Build the control page as the guest sees it. Rebuilt on every read so that
 * any access width works. */
static void render_ctrl(const struct target* t, uint8_t* page) {
  memset(page, 0, VFU_DB_PAGE);
  store_le(page + VFU_DB_T_MAGIC, 4, VFU_DB_T_MAGIC_VALUE);
  store_le(page + VFU_DB_T_VERSION, 4, VFU_DB_T_VERSION_VALUE);
  store_le(page + VFU_DB_T_NREGIONS, 4, VFU_DB_T_MAX_REGIONS);
  store_le(page + VFU_DB_T_LOG_ENTRIES_REG, 4, VFU_DB_T_LOG_ENTRIES);
  store_le(page + VFU_DB_T_TOTAL_WRITES, 8, t->total_writes);
  store_le(page + VFU_DB_T_TOTAL_BAD, 8, t->total_bad);
  store_le(page + VFU_DB_T_LOG_COUNT, 8, t->arrivals);
  store_le(page + VFU_DB_T_STATE_REGION, 4, t->state_region);
  store_le(page + VFU_DB_T_STATE_KEY, 4, t->state_key);
  const struct key_state* k = state_lookup(t);
  store_le(page + VFU_DB_T_ST_LAST, 8, k->last);
  store_le(page + VFU_DB_T_ST_COUNT, 8, k->count);
  store_le(page + VFU_DB_T_ST_HEAD, 8, k->head);
  store_le(page + VFU_DB_T_ST_REGRESS, 8, k->regress);
  store_le(page + VFU_DB_T_ST_SEQ_GAPS, 8, k->gaps);
  store_le(page + VFU_DB_T_ST_SEQ_OOO, 8, k->ooo);
  store_le(page + VFU_DB_T_ST_LAST_SEQ, 8, k->last_seq);
  for (unsigned i = 0; i < VFU_DB_T_MAX_REGIONS; i++) {
    const struct region* r = &t->regions[i];
    uint8_t* p = page + VFU_DB_T_REGION_TABLE + i * VFU_DB_T_REGION_STRIDE;
    store_le(p + VFU_DB_T_RG_MODEL, 4, r->model);
    store_le(p + VFU_DB_T_RG_FLAGS, 4, r->flags);
    store_le(p + VFU_DB_T_RG_BASE, 8, r->base);
    store_le(p + VFU_DB_T_RG_SIZE, 8, r->size);
    store_le(p + VFU_DB_T_RG_WIDTH, 4, r->width);
    store_le(p + VFU_DB_T_RG_STRIDE, 4, r->stride);
    store_le(p + VFU_DB_T_RG_WRITES, 8, r->writes);
    store_le(p + VFU_DB_T_RG_BAD, 8, r->bad);
    store_le(p + VFU_DB_T_RG_GAPS, 8, r->gaps);
    store_le(p + VFU_DB_T_RG_OOO, 8, r->ooo);
  }
}

static void ctrl_write(struct target* t, uint64_t off, size_t count,
                       const char* buf) {
  uint64_t v = load_le(buf, count);
  if (off == VFU_DB_T_CTRL) {
    if (v & 1u)
      target_reset_state(t);
    return;
  }
  if (off == VFU_DB_T_STATE_REGION) {
    t->state_region = (uint32_t)v;
    return;
  }
  if (off == VFU_DB_T_STATE_KEY) {
    t->state_key = (uint32_t)v;
    return;
  }
  if (off < VFU_DB_T_REGION_TABLE)
    return;
  uint64_t rel = off - VFU_DB_T_REGION_TABLE;
  unsigned ri = (unsigned)(rel / VFU_DB_T_REGION_STRIDE);
  unsigned field = (unsigned)(rel % VFU_DB_T_REGION_STRIDE);
  if (ri >= VFU_DB_T_MAX_REGIONS)
    return;
  struct region* r = &t->regions[ri];
  switch (field) {
    case VFU_DB_T_RG_MODEL:
      r->model = (uint32_t)v;
      region_reconfigure(r);
      region_log(ri, r);
      break;
    case VFU_DB_T_RG_FLAGS:
      r->flags = (uint32_t)v;
      break;
    case VFU_DB_T_RG_BASE:
      r->base = v;
      break;
    case VFU_DB_T_RG_SIZE:
      r->size = v;
      break;
    case VFU_DB_T_RG_WIDTH:
      r->width = (uint32_t)v;
      break;
    case VFU_DB_T_RG_STRIDE:
      r->stride = (uint32_t)v;
      break;
    default:
      break;
  }
}

static ssize_t target_bar0(vfu_ctx_t* ctx, char* buf, size_t count,
                           loff_t offset, bool is_write) {
  struct target* t = &tgt;
  uint64_t off = (uint64_t)offset;
  (void)ctx;

  if (offset < 0 || off + count > VFU_DB_T_BAR_SIZE) {
    errno = EINVAL;
    return -1;
  }
  if (off < VFU_DB_PAGE) {
    if (is_write) {
      ctrl_write(t, off, count, buf);
    } else {
      uint8_t page[VFU_DB_PAGE];
      render_ctrl(t, page);
      memcpy(buf, page + off, count);
    }
    return (ssize_t)count;
  }
  if (off < VFU_DB_T_WINDOW_BASE) {
    if (is_write) {
      errno = EPERM;
      return -1;
    }
    /* The log is an array of 32-byte entries starting at the page base. */
    memcpy(buf, (const uint8_t*)t->log + (off - VFU_DB_T_LOG_BASE), count);
    return (ssize_t)count;
  }
  for (unsigned i = 0; i < VFU_DB_T_MAX_REGIONS; i++) {
    struct region* r = &t->regions[i];
    if (r->model == VFU_DB_MODEL_OFF || off < r->base ||
        off >= r->base + r->size)
      continue;
    if (is_write) {
      region_write(t, i, off, count, buf);
    } else {
      /* Doorbells are write-only on real devices; return the last value. */
      uint64_t rel = off - r->base;
      uint64_t slot = rel / r->stride;
      uint64_t last = 0;
      if (r->model != VFU_DB_MODEL_KEYED && slot < r->nkeys)
        last = r->keys[slot].last;
      store_le(buf, count, last);
    }
    return (ssize_t)count;
  }
  /* Inside the BAR but outside every window. */
  if (is_write) {
    t->total_bad++;
    log_write(t, 0xffffu, off, load_le(buf, count), count);
  } else {
    memset(buf, 0, count);
  }
  return (ssize_t)count;
}

/* Parse "N:model:base:size:width:stride[:seq]". */
static int parse_region(const char* spec) {
  char* copy = strdup(spec);
  char* save = NULL;
  char* tok[8];
  int n = 0;
  if (!copy)
    return -1;
  for (char* p = strtok_r(copy, ":", &save); p && n < 8;
       p = strtok_r(NULL, ":", &save))
    tok[n++] = p;
  int rc = -1;
  if (n >= 6) {
    unsigned long ri = strtoul(tok[0], NULL, 0);
    struct region* r = ri < VFU_DB_T_MAX_REGIONS ? &tgt.regions[ri] : NULL;
    uint32_t model = VFU_DB_MODEL_OFF;
    if (!strcmp(tok[1], "index"))
      model = VFU_DB_MODEL_INDEX;
    else if (!strcmp(tok[1], "keyed"))
      model = VFU_DB_MODEL_KEYED;
    else if (!strcmp(tok[1], "event"))
      model = VFU_DB_MODEL_EVENT;
    if (r && model != VFU_DB_MODEL_OFF) {
      r->base = strtoull(tok[2], NULL, 0);
      r->size = strtoull(tok[3], NULL, 0);
      r->width = (uint32_t)strtoul(tok[4], NULL, 0);
      r->stride = (uint32_t)strtoul(tok[5], NULL, 0);
      r->flags = (n >= 7 && !strcmp(tok[6], "seq")) ? VFU_DB_FLAG_SEQ : 0;
      r->model = model;
      region_reconfigure(r);
      rc = r->model == VFU_DB_MODEL_OFF ? -1 : 0;
      if (rc == 0)
        region_log((unsigned)ri, r);
    }
  }
  free(copy);
  return rc;
}

/* Default overlays: an NVMe-like index region, an ionic-like keyed region and
 * an event region, each one page. */
static void target_defaults(void) {
  parse_region("0:index:0x2000:0x1000:4:4:seq");
  parse_region("1:keyed:0x3000:0x1000:8:8:seq");
  parse_region("2:event:0x4000:0x1000:4:4:seq");
}

/* ------------------------------------------------------------------------ */
/* Ringer                                                                    */
/* ------------------------------------------------------------------------ */

struct job {
  uint64_t gpa;
  uint64_t value;
  int64_t step;
  uint64_t stride;
  uint32_t count;
  uint32_t size;
  uint32_t nslots;
  uint32_t flags;
  uint32_t qids;
  uint32_t qid0;
  uint32_t ring;
  uint32_t pattern;
  uint32_t delay_ns;
  uint32_t mode;
  uint64_t done_gpa;
  uint64_t done_value;
};

struct ringer {
  vfu_ctx_t* ctx;
  struct job regs; /* what the guest has programmed so far */
  pthread_mutex_t job_lock;
  pthread_cond_t job_cv;
  bool job_pending;
  struct job job;
  _Atomic uint32_t status;
  _Atomic uint64_t sent;
  _Atomic uint64_t errors;
  _Atomic uint32_t last_errno;
  _Atomic uint64_t elapsed_ns;
  _Atomic uint64_t max_lat_ns;
};

static struct ringer rng;

static uint64_t xorshift64(uint64_t* s) {
  uint64_t x = *s;
  x ^= x << 13;
  x ^= x >> 7;
  x ^= x << 17;
  return *s = x;
}

/* One write. When the caller already holds lib_lock (the INLINE path) pass
 * locked = true. */
static int do_write(struct ringer* g, const struct job* j, uint64_t gpa,
                    uint64_t value, bool locked) {
  uint8_t bytes[8];
  int rc;

  store_le(bytes, j->size, value);
  if (!locked)
    pthread_mutex_lock(&lib_lock);
  if (j->mode == VFU_DB_MODE_SHM) {
    dma_sg_t* sg = alloca(dma_sg_size());
    struct iovec iov;
    rc = vfu_addr_to_sgl(g->ctx, (vfu_dma_addr_t)gpa, j->size, sg, 1,
                         PROT_WRITE) == 1
           ? 0
           : -1;
    if (rc == 0 && vfu_sgl_get(g->ctx, sg, &iov, 1, 0) == 0) {
      memcpy(iov.iov_base, bytes, j->size);
      __atomic_thread_fence(__ATOMIC_RELEASE);
      vfu_sgl_put(g->ctx, sg, &iov, 1);
    } else {
      rc = -1;
      if (errno == 0)
        errno = ENOENT;
    }
  } else {
    rc = vfu_mmio_write(g->ctx, gpa, bytes, j->size);
  }
  int saved = errno;
  if (!locked)
    pthread_mutex_unlock(&lib_lock);
  errno = saved;
  return rc;
}

/* Tell the guest the job is over by storing a cookie into guest RAM. */
static void signal_done(struct ringer* g, const struct job* j, bool locked) {
  if (!j->done_gpa)
    return;
  struct job dj = *j;
  dj.mode = VFU_DB_MODE_SHM;
  dj.size = 8;
  if (do_write(g, &dj, j->done_gpa, j->done_value, locked) != 0)
    fprintf(stderr, "%s: could not signal completion at gpa 0x%llx\n",
            role_name, (unsigned long long)j->done_gpa);
}

static void run_job(struct ringer* g, const struct job* j) {
  const bool keyed = (j->flags & VFU_DB_RF_KEYED) != 0;
  const bool seq_en = (j->flags & VFU_DB_RF_SEQ) != 0;
  const uint32_t nslots = j->nslots ? j->nslots : 1;
  const uint32_t qids = (keyed && j->qids) ? j->qids : 1;
  const size_t nkeys = (size_t)nslots * qids;
  uint64_t* per_key = calloc(nkeys, sizeof(*per_key));
  uint16_t* seqs = calloc(nkeys, sizeof(*seqs));
  uint64_t rnd = 0x9e3779b97f4a7c15ull ^ j->value;
  uint64_t max_lat = 0;
  uint64_t sent = 0;
  uint64_t errors = 0;

  atomic_store(&g->sent, 0);
  atomic_store(&g->errors, 0);
  atomic_store(&g->last_errno, 0);
  atomic_store(&g->max_lat_ns, 0);
  atomic_store(&g->elapsed_ns, 0);
  atomic_store(&g->status, VFU_DB_ST_RUNNING);
  if (!per_key || !seqs ||
      !(j->size == 1 || j->size == 2 || j->size == 4 || j->size == 8) ||
      (keyed && j->size != 8) || (j->flags & VFU_DB_RF_POSTED)) {
    atomic_store(&g->last_errno,
                 (j->flags & VFU_DB_RF_POSTED) ? EOPNOTSUPP : EINVAL);
    atomic_store(&g->status, VFU_DB_ST_ERROR);
    signal_done(g, j, (j->flags & VFU_DB_RF_INLINE) != 0);
    free(per_key);
    free(seqs);
    return;
  }
  const bool locked = (j->flags & VFU_DB_RF_INLINE) != 0;
  fprintf(stderr,
          "%s: job: gpa=0x%llx count=%u size=%u nslots=%u%s mode=%s%s%s\n",
          role_name, (unsigned long long)j->gpa, j->count, j->size, nslots,
          keyed ? " keyed" : "", j->mode == VFU_DB_MODE_SHM ? "shm" : "mmio",
          seq_en ? " seq" : "", locked ? " inline" : "");
  const uint64_t start = now_ns();
  for (uint32_t i = 0; i < j->count && !stop_requested; i++) {
    uint32_t slot = i % nslots;
    uint32_t qi = i % qids;
    size_t key = (size_t)slot * qids + qi;
    uint32_t idx;
    if (j->pattern == VFU_DB_PAT_REPEAT)
      idx = (uint32_t)j->value;
    else if (j->pattern == VFU_DB_PAT_RANDOM)
      idx = (uint32_t)xorshift64(&rnd);
    else
      idx = (uint32_t)((int64_t)j->value + j->step * (int64_t)per_key[key]);
    per_key[key]++;
    uint32_t seq = seq_en ? seqs[key]++ : 0;
    uint64_t v = vfu_db_pack(j->size, keyed, idx, j->ring, j->qid0 + qi, seq,
                             seq_en);
    uint64_t t0 = now_ns();
    int rc = do_write(g, j, j->gpa + (uint64_t)slot * j->stride, v, locked);
    uint64_t lat = now_ns() - t0;
    if (lat > max_lat)
      max_lat = lat;
    if (rc == 0) {
      sent++;
    } else {
      errors++;
      atomic_store(&g->last_errno, (uint32_t)errno);
    }
    atomic_store(&g->sent, sent);
    atomic_store(&g->errors, errors);
    atomic_store(&g->max_lat_ns, max_lat);
    if (j->delay_ns) {
      struct timespec ts = {.tv_sec = j->delay_ns / 1000000000u,
                            .tv_nsec = j->delay_ns % 1000000000u};
      nanosleep(&ts, NULL);
    }
  }
  atomic_store(&g->elapsed_ns, now_ns() - start);
  atomic_store(&g->status, errors ? VFU_DB_ST_ERROR : VFU_DB_ST_DONE);
  fprintf(stderr,
          "%s: job done: sent=%llu errors=%llu errno=%u elapsed=%.3f ms "
          "max_lat=%.1f us\n",
          role_name, (unsigned long long)sent, (unsigned long long)errors,
          atomic_load(&g->last_errno), (double)(now_ns() - start) / 1e6,
          (double)max_lat / 1e3);
  signal_done(g, j, locked);
  free(per_key);
  free(seqs);
}

static void* ringer_worker(void* arg) {
  struct ringer* g = arg;
  while (!stop_requested) {
    struct job j;
    pthread_mutex_lock(&g->job_lock);
    while (!g->job_pending && !stop_requested) {
      struct timespec ts;
      clock_gettime(CLOCK_REALTIME, &ts);
      ts.tv_nsec += 100 * 1000 * 1000;
      if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec++;
        ts.tv_nsec -= 1000000000L;
      }
      pthread_cond_timedwait(&g->job_cv, &g->job_lock, &ts);
    }
    bool have = g->job_pending;
    j = g->job;
    g->job_pending = false;
    pthread_mutex_unlock(&g->job_lock);
    if (have)
      run_job(g, &j);
  }
  return NULL;
}

static uint64_t ringer_read(const struct ringer* g, uint64_t off) {
  switch (off & ~7ull) {
    case VFU_DB_R_MAGIC:
      return VFU_DB_R_MAGIC_VALUE | ((uint64_t)VFU_DB_R_VERSION_VALUE << 32);
    case VFU_DB_R_GPA:
      return g->regs.gpa;
    case VFU_DB_R_VALUE:
      return g->regs.value;
    case VFU_DB_R_STEP:
      return (uint64_t)g->regs.step;
    case VFU_DB_R_COUNT:
      return g->regs.count | ((uint64_t)g->regs.size << 32);
    case VFU_DB_R_STRIDE:
      return g->regs.stride;
    case VFU_DB_R_NSLOTS:
      return g->regs.nslots | ((uint64_t)g->regs.flags << 32);
    case VFU_DB_R_QIDS:
      return g->regs.qids | ((uint64_t)g->regs.qid0 << 32);
    case VFU_DB_R_RING:
      return g->regs.ring | ((uint64_t)g->regs.pattern << 32);
    case VFU_DB_R_DELAY_NS:
      return g->regs.delay_ns | ((uint64_t)g->regs.mode << 32);
    case VFU_DB_R_GO:
      return (uint64_t)atomic_load(&g->status) << 32;
    case VFU_DB_R_SENT:
      return atomic_load(&g->sent);
    case VFU_DB_R_ERRORS:
      return atomic_load(&g->errors);
    case VFU_DB_R_ERRNO:
      return atomic_load(&g->last_errno);
    case VFU_DB_R_ELAPSED:
      return atomic_load(&g->elapsed_ns);
    case VFU_DB_R_MAX_LAT:
      return atomic_load(&g->max_lat_ns);
    case VFU_DB_R_DONE_GPA:
      return g->regs.done_gpa;
    case VFU_DB_R_DONE_VALUE:
      return g->regs.done_value;
    default:
      return 0;
  }
}

static void ringer_write32(struct ringer* g, uint64_t off, uint32_t v) {
  switch (off) {
    case VFU_DB_R_COUNT:
      g->regs.count = v;
      break;
    case VFU_DB_R_SIZE:
      g->regs.size = v;
      break;
    case VFU_DB_R_NSLOTS:
      g->regs.nslots = v;
      break;
    case VFU_DB_R_FLAGS:
      g->regs.flags = v;
      break;
    case VFU_DB_R_QIDS:
      g->regs.qids = v;
      break;
    case VFU_DB_R_QID0:
      g->regs.qid0 = v;
      break;
    case VFU_DB_R_RING:
      g->regs.ring = v;
      break;
    case VFU_DB_R_PATTERN:
      g->regs.pattern = v;
      break;
    case VFU_DB_R_DELAY_NS:
      g->regs.delay_ns = v;
      break;
    case VFU_DB_R_MODE:
      g->regs.mode = v;
      break;
    case VFU_DB_R_GO:
      if (v == 1 && atomic_load(&g->status) != VFU_DB_ST_RUNNING) {
        if (g->regs.flags & VFU_DB_RF_INLINE) {
          /* Inside the BAR callback, with lib_lock held by the caller. */
          run_job(g, &g->regs);
        } else {
          atomic_store(&g->status, VFU_DB_ST_RUNNING);
          pthread_mutex_lock(&g->job_lock);
          g->job = g->regs;
          g->job_pending = true;
          pthread_cond_signal(&g->job_cv);
          pthread_mutex_unlock(&g->job_lock);
        }
      }
      break;
    default:
      break;
  }
}

static void ringer_write64(struct ringer* g, uint64_t off, uint64_t v) {
  switch (off) {
    case VFU_DB_R_GPA:
      g->regs.gpa = v;
      break;
    case VFU_DB_R_VALUE:
      g->regs.value = v;
      break;
    case VFU_DB_R_STEP:
      g->regs.step = (int64_t)v;
      break;
    case VFU_DB_R_STRIDE:
      g->regs.stride = v;
      break;
    case VFU_DB_R_DONE_GPA:
      g->regs.done_gpa = v;
      break;
    case VFU_DB_R_DONE_VALUE:
      g->regs.done_value = v;
      break;
    default:
      break;
  }
}

static ssize_t ringer_bar0(vfu_ctx_t* ctx, char* buf, size_t count,
                           loff_t offset, bool is_write) {
  struct ringer* g = &rng;
  uint64_t off = (uint64_t)offset;
  (void)ctx;

  if (offset < 0 || off + count > VFU_DB_R_BAR_SIZE) {
    errno = EINVAL;
    return -1;
  }
  if (is_write) {
    if (count == 8)
      ringer_write64(g, off, load_le(buf, 8));
    else if (count == 4)
      ringer_write32(g, off, (uint32_t)load_le(buf, 4));
    return (ssize_t)count;
  }
  uint64_t v = ringer_read(g, off);
  unsigned shift = (unsigned)(off & 7u) * 8u;
  store_le(buf, count, v >> shift);
  return (ssize_t)count;
}

/* ------------------------------------------------------------------------ */
/* Server                                                                    */
/* ------------------------------------------------------------------------ */

static void dma_register_cb(vfu_ctx_t* ctx, vfu_dma_info_t* info) {
  (void)ctx;
  fprintf(stderr, "%s: DMA map iova=%p len=%zu mapped=%d\n", role_name,
          info->iova.iov_base, info->iova.iov_len, info->vaddr != NULL);
}

static void dma_unregister_cb(vfu_ctx_t* ctx, vfu_dma_info_t* info) {
  (void)ctx;
  fprintf(stderr, "%s: DMA unmap iova=%p\n", role_name, info->iova.iov_base);
}

static int device_reset_cb(vfu_ctx_t* ctx, vfu_reset_type_t type) {
  (void)ctx;
  fprintf(stderr, "%s: device reset requested (type %d)\n", role_name,
          (int)type);
  return 0;
}

static void on_signal(int sig) {
  (void)sig;
  stop_requested = 1;
}

static void usage(const char* argv0) {
  fprintf(stderr,
          "usage: %s --role target|ringer --socket PATH [options]\n"
          "  --region N:model:base:size:width:stride[:seq]\n"
          "          configure a target overlay (model: index|keyed|event);\n"
          "          without any --region the target gets three defaults\n"
          "  --no-defaults   target starts with no regions configured\n"
          "  --trace N       target logs the first N writes after each reset\n"
          "  -v              debug logging from libvfio-user\n",
          argv0);
}

int main(int argc, char** argv) {
  const char* role = NULL;
  const char* socket_path = NULL;
  bool verbose = false;
  bool no_defaults = false;
  bool have_region = false;
  static const struct option opts[] = {
    {"role", required_argument, NULL, 'r'},
    {"socket", required_argument, NULL, 's'},
    {"region", required_argument, NULL, 'g'},
    {"no-defaults", no_argument, NULL, 'n'},
    {"trace", required_argument, NULL, 't'},
    {"help", no_argument, NULL, 'h'},
    {NULL, 0, NULL, 0},
  };
  int c;

  while ((c = getopt_long(argc, argv, "r:s:g:nt:vh", opts, NULL)) != -1) {
    switch (c) {
      case 'r':
        role = optarg;
        break;
      case 's':
        socket_path = optarg;
        break;
      case 'g':
        if (parse_region(optarg) != 0) {
          fprintf(stderr, "bad --region %s\n", optarg);
          return 2;
        }
        have_region = true;
        break;
      case 'n':
        no_defaults = true;
        break;
      case 't':
        trace_writes_arg = (unsigned)strtoul(optarg, NULL, 0);
        trace_writes_left = trace_writes_arg;
        break;
      case 'v':
        verbose = true;
        break;
      default:
        usage(argv[0]);
        return c == 'h' ? 0 : 2;
    }
  }
  if (!role || !socket_path ||
      (strcmp(role, "target") != 0 && strcmp(role, "ringer") != 0)) {
    usage(argv[0]);
    return 2;
  }
  const bool is_target = strcmp(role, "target") == 0;
  role_name = is_target ? "vfu-doorbell-target" : "vfu-doorbell-ringer";
  if (is_target && !have_region && !no_defaults)
    target_defaults();

  signal(SIGINT, on_signal);
  signal(SIGTERM, on_signal);

  vfu_ctx_t* ctx = vfu_create_ctx(VFU_TRANS_SOCK, socket_path,
                                  LIBVFIO_USER_FLAG_ATTACH_NB, NULL,
                                  VFU_DEV_TYPE_PCI);
  if (!ctx) {
    perror("vfu_create_ctx");
    return 1;
  }
  vfu_setup_log(ctx, log_cb, verbose ? LOG_DEBUG : LOG_LEVEL_DEFAULT);
  if (vfu_pci_init(ctx, VFU_PCI_TYPE_EXPRESS, PCI_HEADER_TYPE_NORMAL, 0) < 0) {
    perror("vfu_pci_init");
    return 1;
  }
  vfu_pci_set_id(ctx, VFU_DB_PCI_VENDOR,
                 is_target ? VFU_DB_PCI_DEV_TARGET : VFU_DB_PCI_DEV_RINGER,
                 VFU_DB_PCI_VENDOR, 0);
  /* Base class 0xff: a device that fits no defined class. */
  vfu_pci_set_class(ctx, 0xff, 0, 0);
  if (vfu_setup_region(ctx, VFU_PCI_DEV_BAR0_REGION_IDX,
                       is_target ? VFU_DB_T_BAR_SIZE : VFU_DB_R_BAR_SIZE,
                       is_target ? target_bar0 : ringer_bar0,
                       VFU_REGION_FLAG_RW | VFU_REGION_FLAG_MEM, NULL, 0, -1,
                       0) < 0) {
    perror("vfu_setup_region");
    return 1;
  }
  if (vfu_setup_device_dma(ctx, 256, dma_register_cb, dma_unregister_cb) < 0 ||
      vfu_setup_device_reset_cb(ctx, device_reset_cb) < 0) {
    perror("vfu_setup_device_*");
    return 1;
  }
  if (vfu_realize_ctx(ctx) < 0) {
    perror("vfu_realize_ctx");
    return 1;
  }

  pthread_t worker;
  bool have_worker = false;
  if (!is_target) {
    rng.ctx = ctx;
    pthread_mutex_init(&rng.job_lock, NULL);
    pthread_cond_init(&rng.job_cv, NULL);
    if (pthread_create(&worker, NULL, ringer_worker, &rng) != 0) {
      perror("pthread_create");
      return 1;
    }
    have_worker = true;
  }

  fprintf(stderr, "%s: serving on %s\n", role_name, socket_path);
  bool attached = false;
  while (!stop_requested) {
    if (!attached) {
      pthread_mutex_lock(&lib_lock);
      int rc = vfu_attach_ctx(ctx);
      int fd = vfu_get_poll_fd(ctx);
      pthread_mutex_unlock(&lib_lock);
      if (rc == 0) {
        attached = true;
        fprintf(stderr, "%s: client attached\n", role_name);
        continue;
      }
      if (errno != EAGAIN && errno != EWOULDBLOCK) {
        perror("vfu_attach_ctx");
        break;
      }
      struct pollfd pfd = {.fd = fd, .events = POLLIN};
      poll(&pfd, 1, 100);
      continue;
    }
    pthread_mutex_lock(&lib_lock);
    int fd = vfu_get_poll_fd(ctx);
    pthread_mutex_unlock(&lib_lock);
    struct pollfd pfd = {.fd = fd, .events = POLLIN};
    poll(&pfd, 1, 20);
    pthread_mutex_lock(&lib_lock);
    int rc = vfu_run_ctx(ctx);
    int err = errno;
    pthread_mutex_unlock(&lib_lock);
    if (rc < 0) {
      if (err == ENOTCONN) {
        fprintf(stderr, "%s: client disconnected\n", role_name);
        attached = false;
        if (is_target)
          target_reset_state(&tgt);
      } else if (err != EAGAIN && err != EWOULDBLOCK && err != EBUSY &&
                 err != EINTR) {
        errno = err;
        perror("vfu_run_ctx");
        break;
      }
    }
  }
  stop_requested = 1;
  if (have_worker)
    pthread_join(worker, NULL);
  pthread_mutex_lock(&lib_lock);
  vfu_destroy_ctx(ctx);
  pthread_mutex_unlock(&lib_lock);
  return 0;
}
