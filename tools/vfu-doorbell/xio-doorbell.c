/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * xio-doorbell: guest-side driver for the vfu-doorbell ringee and ringer.
 *
 * It maps each device's BAR0 through sysfs, so it needs root and no kernel
 * driver. It can configure the ringee's doorbell overlays, ring them from the
 * CPU (the trapped, known-good path), ask the ringer to ring them through the
 * vfio-user server, and read back what the ringee saw.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <dirent.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "vfu-doorbell.h"

struct dev {
  char bdf[288];
  volatile uint8_t* bar;
  size_t size;
  uint64_t gpa; /* BAR0 guest physical address (no IOMMU assumed) */
  bool present;
};

static struct dev ringee;
static struct dev ringer;

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* ---------------------------------------------------------------------- */
/* Device discovery and register access                                    */
/* ---------------------------------------------------------------------- */

static bool read_hex_file(const char* path, unsigned* out) {
  FILE* f = fopen(path, "r");
  if (!f)
    return false;
  bool ok = fscanf(f, "%x", out) == 1;
  fclose(f);
  return ok;
}

/* Map BAR0 of the PCI device `name` (a sysfs name, "0000:00:05.0"). */
static bool open_dev(const char* name, struct dev* d) {
  char path[512];
  snprintf(d->bdf, sizeof(d->bdf), "%s", name);
  snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource", name);
  FILE* f = fopen(path, "r");
  unsigned long long start = 0;
  if (f) {
    if (fscanf(f, "%llx", &start) != 1)
      start = 0;
    fclose(f);
  }
  d->gpa = start;
  snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource0", name);
  int fd = open(path, O_RDWR | O_SYNC);
  struct stat st;
  if (fd < 0 || fstat(fd, &st) != 0) {
    perror(path);
    if (fd >= 0)
      close(fd);
    return false;
  }
  d->size = (size_t)st.st_size;
  void* m = mmap(NULL, d->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);
  if (m == MAP_FAILED) {
    perror("mmap resource0");
    return false;
  }
  d->bar = m;
  d->present = true;
  return true;
}

static bool find_device(unsigned vendor, unsigned device, struct dev* d) {
  DIR* dir = opendir("/sys/bus/pci/devices");
  struct dirent* e;
  if (!dir)
    return false;
  while ((e = readdir(dir)) != NULL) {
    char path[512];
    unsigned v = 0;
    unsigned dv = 0;
    if (e->d_name[0] == '.')
      continue;
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/vendor", e->d_name);
    if (!read_hex_file(path, &v) || v != vendor)
      continue;
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/device", e->d_name);
    if (!read_hex_file(path, &dv) || dv != device)
      continue;
    if (!open_dev(e->d_name, d))
      continue;
    closedir(dir);
    return true;
  }
  closedir(dir);
  return false;
}

/*
 * MMIO accessors. In a VM every access to a vfio-user BAR traps, and KVM's
 * instruction emulator only handles plain moves through general-purpose
 * registers. A compiler is free to load two adjacent volatile 8-byte values
 * with an SSE movq, which the emulator rejects by injecting #UD. So on x86 the
 * accessors are inline assembly that names a general register.
 */
#if defined(__x86_64__)
#define MMIO_RD(name, type, insn)                                              \
  static inline type name(const volatile void* p) {                            \
    type v;                                                                    \
    __asm__ volatile(insn " %1, %0"                                            \
                     : "=r"(v)                                                 \
                     : "m"(*(const volatile type*)p)                           \
                     : "memory");                                              \
    return v;                                                                  \
  }
#define MMIO_WR(name, type, insn)                                              \
  static inline void name(volatile void* p, type v) {                          \
    __asm__ volatile(insn " %1, %0"                                            \
                     : "=m"(*(volatile type*)p)                                \
                     : "r"(v)                                                  \
                     : "memory");                                              \
  }
MMIO_RD(mmio_read8, uint8_t, "movb")
MMIO_RD(mmio_read16, uint16_t, "movw")
MMIO_RD(mmio_read32, uint32_t, "movl")
MMIO_RD(mmio_read64, uint64_t, "movq")
MMIO_WR(mmio_write8, uint8_t, "movb")
MMIO_WR(mmio_write16, uint16_t, "movw")
MMIO_WR(mmio_write32, uint32_t, "movl")
MMIO_WR(mmio_write64, uint64_t, "movq")
#else
#define MMIO_RD(name, type)                                                    \
  static inline type name(const volatile void* p) {                            \
    return *(const volatile type*)p;                                           \
  }
#define MMIO_WR(name, type)                                                    \
  static inline void name(volatile void* p, type v) {                          \
    *(volatile type*)p = v;                                                    \
  }
MMIO_RD(mmio_read8, uint8_t)
MMIO_RD(mmio_read16, uint16_t)
MMIO_RD(mmio_read32, uint32_t)
MMIO_RD(mmio_read64, uint64_t)
MMIO_WR(mmio_write8, uint8_t)
MMIO_WR(mmio_write16, uint16_t)
MMIO_WR(mmio_write32, uint32_t)
MMIO_WR(mmio_write64, uint64_t)
#endif

static uint32_t rd32(const struct dev* d, uint64_t off) {
  return mmio_read32(d->bar + off);
}

static uint64_t rd64(const struct dev* d, uint64_t off) {
  return mmio_read64(d->bar + off);
}

static void wr32(const struct dev* d, uint64_t off, uint32_t v) {
  mmio_write32(d->bar + off, v);
}

static void wr64(const struct dev* d, uint64_t off, uint64_t v) {
  mmio_write64(d->bar + off, v);
}

static void wrw(const struct dev* d, uint64_t off, unsigned width, uint64_t v) {
  switch (width) {
    case 1:
      mmio_write8(d->bar + off, (uint8_t)v);
      break;
    case 2:
      mmio_write16(d->bar + off, (uint16_t)v);
      break;
    case 4:
      mmio_write32(d->bar + off, (uint32_t)v);
      break;
    default:
      mmio_write64(d->bar + off, v);
      break;
  }
}

static bool need_ringee(void) {
  if (!ringee.present)
    fprintf(stderr, "xio-doorbell: no vfu-doorbell ringee device found\n");
  return ringee.present;
}

static bool need_ringer(void) {
  if (!ringer.present)
    fprintf(stderr, "xio-doorbell: no vfu-doorbell ringer device found\n");
  return ringer.present;
}

/* ---------------------------------------------------------------------- */
/* Ringee access                                                           */
/* ---------------------------------------------------------------------- */

struct region_cfg {
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
  uint64_t match;
  uint64_t nomatch;
};

struct key_state {
  uint64_t last;
  uint64_t count;
  uint64_t head;
  uint64_t regress;
  uint64_t gaps;
  uint64_t ooo;
  uint64_t last_seq;
};

static void t_region(unsigned r, struct region_cfg* c) {
  uint64_t p = VFU_DB_RE_REGION_TABLE + (uint64_t)r * VFU_DB_RE_REGION_STRIDE;
  c->model = rd32(&ringee, p + VFU_DB_RE_RG_MODEL);
  c->flags = rd32(&ringee, p + VFU_DB_RE_RG_FLAGS);
  c->base = rd64(&ringee, p + VFU_DB_RE_RG_BASE);
  c->size = rd64(&ringee, p + VFU_DB_RE_RG_SIZE);
  c->width = rd32(&ringee, p + VFU_DB_RE_RG_WIDTH);
  c->stride = rd32(&ringee, p + VFU_DB_RE_RG_STRIDE);
  c->writes = rd64(&ringee, p + VFU_DB_RE_RG_WRITES);
  c->bad = rd64(&ringee, p + VFU_DB_RE_RG_BAD);
  c->gaps = rd64(&ringee, p + VFU_DB_RE_RG_GAPS);
  c->ooo = rd64(&ringee, p + VFU_DB_RE_RG_OOO);
  c->match = rd64(&ringee, p + VFU_DB_RE_RG_MATCH);
  c->nomatch = rd64(&ringee, p + VFU_DB_RE_RG_NOMATCH);
}

static void t_config(unsigned r, unsigned model, unsigned flags, uint64_t base,
                     uint64_t size, unsigned width, unsigned stride,
                     uint64_t match) {
  uint64_t p = VFU_DB_RE_REGION_TABLE + (uint64_t)r * VFU_DB_RE_REGION_STRIDE;
  /* Off first, so the other fields are only stored while it is being set up. */
  wr32(&ringee, p + VFU_DB_RE_RG_MODEL, VFU_DB_MODEL_OFF);
  wr64(&ringee, p + VFU_DB_RE_RG_MATCH, match);
  wr32(&ringee, p + VFU_DB_RE_RG_FLAGS, flags);
  wr64(&ringee, p + VFU_DB_RE_RG_BASE, base);
  wr64(&ringee, p + VFU_DB_RE_RG_SIZE, size);
  wr32(&ringee, p + VFU_DB_RE_RG_WIDTH, width);
  wr32(&ringee, p + VFU_DB_RE_RG_STRIDE, stride);
  wr32(&ringee, p + VFU_DB_RE_RG_MODEL, model); /* last: validates */
}

static void t_key(unsigned r, unsigned key, struct key_state* k) {
  wr32(&ringee, VFU_DB_RE_STATE_REGION, r);
  wr32(&ringee, VFU_DB_RE_STATE_KEY, key);
  k->last = rd64(&ringee, VFU_DB_RE_ST_LAST);
  k->count = rd64(&ringee, VFU_DB_RE_ST_COUNT);
  k->head = rd64(&ringee, VFU_DB_RE_ST_HEAD);
  k->regress = rd64(&ringee, VFU_DB_RE_ST_REGRESS);
  k->gaps = rd64(&ringee, VFU_DB_RE_ST_SEQ_GAPS);
  k->ooo = rd64(&ringee, VFU_DB_RE_ST_SEQ_OOO);
  k->last_seq = rd64(&ringee, VFU_DB_RE_ST_LAST_SEQ);
}

static const char* model_name(uint32_t m) {
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

/* ---------------------------------------------------------------------- */
/* Write generation shared by the CPU and ringer paths                     */
/* ---------------------------------------------------------------------- */

struct opts {
  unsigned size;
  uint32_t nslots;
  uint32_t qids;
  uint32_t qid0;
  uint32_t ring;
  int64_t step;
  uint64_t value;
  uint32_t pattern;
  bool seq;
  bool keyed;
  uint32_t delay_ns;
  uint32_t mode;
  bool inline_mode;
  uint64_t stride;
  unsigned timeout_ms;
  bool poll_mmio; /* poll STATUS over MMIO: can deadlock, see README.md */
  /* ring --raw/--preset: another device. gpa_base replaces the ringee's BAR0
   * address, and dst is the device the CPU path stores into. */
  uint64_t gpa_base;
  const struct dev* dst;
};

static void opts_for_region(const struct region_cfg* c, struct opts* o) {
  memset(o, 0, sizeof(*o));
  o->size = c->width;
  o->nslots = 1;
  o->qids = 1;
  o->step = 1;
  o->stride = c->stride;
  o->seq = (c->flags & VFU_DB_FLAG_SEQ) != 0;
  o->keyed = c->model == VFU_DB_MODEL_KEYED;
  o->timeout_ms = 10000;
  if (c->flags & VFU_DB_FLAG_MATCH) {
    /* Send the value the region rings on; --value overrides it. */
    o->value = c->match;
    o->pattern = VFU_DB_PAT_REPEAT;
  }
}

/* The CPU path: the same sequence of values the ringer would write, stored by
 * the CPU. A CPU store to a vfio-user BAR is trapped and sent to the server,
 * the known-good baseline the other paths are compared with. */
static void cpu_ring(const struct region_cfg* c, uint32_t count,
                     const struct opts* o) {
  const uint32_t nslots = o->nslots ? o->nslots : 1;
  const uint32_t qids = (o->keyed && o->qids) ? o->qids : 1;
  const size_t nkeys = (size_t)nslots * qids;
  uint64_t* per_key = calloc(nkeys, sizeof(*per_key));
  uint16_t* seqs = calloc(nkeys, sizeof(*seqs));
  uint64_t rnd = 0x9e3779b97f4a7c15ull ^ o->value;

  if (!per_key || !seqs) {
    free(per_key);
    free(seqs);
    return;
  }
  for (uint32_t i = 0; i < count; i++) {
    uint32_t slot = i % nslots;
    uint32_t qi = i % qids;
    size_t key = (size_t)slot * qids + qi;
    uint32_t idx;
    if (o->pattern == VFU_DB_PAT_REPEAT) {
      idx = (uint32_t)o->value;
    } else if (o->pattern == VFU_DB_PAT_RANDOM) {
      rnd ^= rnd << 13;
      rnd ^= rnd >> 7;
      rnd ^= rnd << 17;
      idx = (uint32_t)rnd;
    } else {
      idx = (uint32_t)((int64_t)o->value + o->step * (int64_t)per_key[key]);
    }
    per_key[key]++;
    uint32_t seq = o->seq ? seqs[key]++ : 0;
    uint64_t v = vfu_db_pack(o->size, o->keyed, idx, o->ring, o->qid0 + qi, seq,
                             o->seq);
    wrw(o->dst ? o->dst : &ringee, c->base + (uint64_t)slot * o->stride,
        o->size, v);
    if (o->delay_ns) {
      struct timespec ts = {.tv_sec = o->delay_ns / 1000000000u,
                            .tv_nsec = o->delay_ns % 1000000000u};
      nanosleep(&ts, NULL);
    }
  }
  free(per_key);
  free(seqs);
}

/* A pinned page the ringer stores its completion cookie into. Polling guest
 * RAM generates no MMIO, so the guest never touches the ringer's BAR while a
 * job runs. */
static volatile uint64_t* done_word;
static uint64_t done_gpa;

static bool ensure_done_page(void) {
  if (done_word)
    return true;
  void* m = mmap(NULL, VFU_DB_PAGE, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE | MAP_LOCKED, -1,
                 0);
  if (m == MAP_FAILED) {
    perror("mmap done page");
    return false;
  }
  *(volatile uint64_t*)m = 0;
  int fd = open("/proc/self/pagemap", O_RDONLY);
  uint64_t entry = 0;
  if (fd < 0 ||
      pread(fd, &entry, sizeof(entry),
            (off_t)(((uintptr_t)m / VFU_DB_PAGE) * sizeof(entry))) !=
        (ssize_t)sizeof(entry) ||
      !(entry >> 63) || (entry & ((1ull << 55) - 1)) == 0) {
    fprintf(stderr, "cannot resolve the completion page's physical address "
                    "(need root)\n");
    if (fd >= 0)
      close(fd);
    return false;
  }
  close(fd);
  done_word = m;
  done_gpa = (entry & ((1ull << 55) - 1)) * VFU_DB_PAGE;
  return true;
}

struct ring_result {
  bool ok;
  bool timed_out;
  uint32_t status;
  uint64_t sent;
  uint64_t errors;
  uint32_t err_no;
  uint64_t elapsed_ns;
  uint64_t max_lat_ns;
};

static struct ring_result ringer_run(const struct region_cfg* c, uint32_t count,
                                     const struct opts* o) {
  struct ring_result res = {0};
  uint32_t flags = 0;
  if (o->seq)
    flags |= VFU_DB_RF_SEQ;
  if (o->keyed)
    flags |= VFU_DB_RF_KEYED;
  if (o->inline_mode)
    flags |= VFU_DB_RF_INLINE;
  wr64(&ringer, VFU_DB_R_GPA,
       (o->gpa_base ? o->gpa_base : ringee.gpa) + c->base);
  wr64(&ringer, VFU_DB_R_VALUE, o->value);
  wr64(&ringer, VFU_DB_R_STEP, (uint64_t)o->step);
  wr64(&ringer, VFU_DB_R_STRIDE, o->stride);
  wr32(&ringer, VFU_DB_R_COUNT, count);
  wr32(&ringer, VFU_DB_R_SIZE, o->size);
  wr32(&ringer, VFU_DB_R_NSLOTS, o->nslots ? o->nslots : 1);
  wr32(&ringer, VFU_DB_R_FLAGS, flags);
  wr32(&ringer, VFU_DB_R_QIDS, o->qids ? o->qids : 1);
  wr32(&ringer, VFU_DB_R_QID0, o->qid0);
  wr32(&ringer, VFU_DB_R_RING, o->ring);
  wr32(&ringer, VFU_DB_R_PATTERN, o->pattern);
  wr32(&ringer, VFU_DB_R_DELAY_NS, o->delay_ns);
  wr32(&ringer, VFU_DB_R_MODE, o->mode);
  uint64_t cookie = 0;
  if (!o->poll_mmio) {
    if (!ensure_done_page()) {
      res.status = VFU_DB_ST_ERROR;
      return res;
    }
    cookie = (now_ns() << 1) | 1;
    *done_word = 0;
    wr64(&ringer, VFU_DB_R_DONE_GPA, done_gpa);
    wr64(&ringer, VFU_DB_R_DONE_VALUE, cookie);
  } else {
    wr64(&ringer, VFU_DB_R_DONE_GPA, 0);
  }
  wr32(&ringer, VFU_DB_R_GO, 1);

  const uint64_t deadline = now_ns() + (uint64_t)o->timeout_ms * 1000000ull;
  for (;;) {
    if (o->poll_mmio) {
      res.status = rd32(&ringer, VFU_DB_R_STATUS);
      if (res.status == VFU_DB_ST_DONE || res.status == VFU_DB_ST_ERROR)
        break;
    } else if (__atomic_load_n(done_word, __ATOMIC_ACQUIRE) == cookie) {
      break;
    }
    if (now_ns() > deadline) {
      res.timed_out = true;
      break;
    }
    struct timespec ts = {.tv_sec = 0, .tv_nsec = 1000 * 1000};
    nanosleep(&ts, NULL);
  }
  if (!o->poll_mmio && !res.timed_out)
    res.status = rd32(&ringer, VFU_DB_R_STATUS);
  res.sent = rd64(&ringer, VFU_DB_R_SENT);
  res.errors = rd64(&ringer, VFU_DB_R_ERRORS);
  res.err_no = rd32(&ringer, VFU_DB_R_ERRNO);
  res.elapsed_ns = rd64(&ringer, VFU_DB_R_ELAPSED);
  res.max_lat_ns = rd64(&ringer, VFU_DB_R_MAX_LAT);
  res.ok = !res.timed_out && res.status == VFU_DB_ST_DONE;
  return res;
}

/* Sum the per-key counters over the keys a run touches. */
static void sum_keys(unsigned r, const struct region_cfg* c,
                     const struct opts* o, uint64_t* regress, uint64_t* count) {
  const uint32_t nslots = o->nslots ? o->nslots : 1;
  const uint32_t qids = (o->keyed && o->qids) ? o->qids : 1;
  *regress = 0;
  *count = 0;
  for (uint32_t s = 0; s < nslots; s++) {
    for (uint32_t q = 0; q < qids; q++) {
      unsigned key = s;
      struct key_state k;
      if (c->model == VFU_DB_MODEL_KEYED)
        key = s * VFU_DB_KEYED_KEYS_PER_SLOT + ((o->qid0 + q) & 0xffu) * 8u +
              (o->ring & 7u);
      t_key(r, key, &k);
      *regress += k.regress;
      *count += k.count;
    }
  }
}

/* ---------------------------------------------------------------------- */
/* Commands                                                                */
/* ---------------------------------------------------------------------- */

static void print_region(unsigned r, const struct region_cfg* c) {
  printf("region %u: %-5s base=0x%llx size=0x%llx width=%u stride=%u%s  "
         "writes=%llu bad=%llu seq_gaps=%llu seq_ooo=%llu\n",
         r, model_name(c->model), (unsigned long long)c->base,
         (unsigned long long)c->size, c->width, c->stride,
         (c->flags & VFU_DB_FLAG_SEQ) ? " seq" : "",
         (unsigned long long)c->writes, (unsigned long long)c->bad,
         (unsigned long long)c->gaps, (unsigned long long)c->ooo);
  if (c->flags & VFU_DB_FLAG_MATCH)
    printf("          match=0x%llx nomatch=%llu\n",
           (unsigned long long)c->match, (unsigned long long)c->nomatch);
}

static int cmd_info(void) {
  if (ringee.present) {
    printf("ringee: %s BAR0 gpa=0x%llx size=0x%zx magic=0x%08x\n", ringee.bdf,
           (unsigned long long)ringee.gpa, ringee.size,
           rd32(&ringee, VFU_DB_RE_MAGIC));
    printf("  total writes=%llu bad=%llu logged=%llu\n",
           (unsigned long long)rd64(&ringee, VFU_DB_RE_TOTAL_WRITES),
           (unsigned long long)rd64(&ringee, VFU_DB_RE_TOTAL_BAD),
           (unsigned long long)rd64(&ringee, VFU_DB_RE_LOG_COUNT));
    for (unsigned r = 0; r < VFU_DB_RE_MAX_REGIONS; r++) {
      struct region_cfg c;
      t_region(r, &c);
      if (c.model != VFU_DB_MODEL_OFF)
        print_region(r, &c);
    }
  } else {
    printf("ringee: not found\n");
  }
  if (ringer.present)
    printf("ringer: %s BAR0 gpa=0x%llx size=0x%zx magic=0x%08x\n", ringer.bdf,
           (unsigned long long)ringer.gpa, ringer.size,
           rd32(&ringer, VFU_DB_R_MAGIC));
  else
    printf("ringer: not found\n");
  return (ringee.present ? 0 : 1);
}

static int cmd_log(int argc, char** argv) {
  unsigned n = argc > 0 ? (unsigned)strtoul(argv[0], NULL, 0) : 16;
  uint64_t total;
  if (!need_ringee())
    return 1;
  total = rd64(&ringee, VFU_DB_RE_LOG_COUNT);
  if (n > VFU_DB_RE_LOG_ENTRIES)
    n = VFU_DB_RE_LOG_ENTRIES;
  if (n > total)
    n = (unsigned)total;
  for (uint64_t a = total - n + 1; a <= total && n; a++) {
    uint64_t base = VFU_DB_RE_LOG_BASE + ((a - 1) % VFU_DB_RE_LOG_ENTRIES) *
                                           sizeof(struct vfu_db_log_entry);
    struct vfu_db_log_entry e;
    e.arrival = rd64(&ringee, base);
    e.value = rd64(&ringee, base + 8);
    uint64_t w = rd64(&ringee, base + 16);
    e.offset = (uint32_t)w;
    e.size = (uint16_t)(w >> 32);
    e.region = (uint16_t)(w >> 48);
    e.time_ns = rd64(&ringee, base + 24);
    printf("#%llu region=%u off=0x%x size=%u value=0x%llx t=%llu\n",
           (unsigned long long)e.arrival, e.region, e.offset, e.size,
           (unsigned long long)e.value, (unsigned long long)e.time_ns);
  }
  return 0;
}

static int cmd_dump(int argc, char** argv) {
  if (!need_ringee())
    return 1;
  if (argc > 0) {
    unsigned r = (unsigned)strtoul(argv[0], NULL, 0);
    struct region_cfg c;
    t_region(r, &c);
    print_region(r, &c);
    return 0;
  }
  for (unsigned r = 0; r < VFU_DB_RE_MAX_REGIONS; r++) {
    struct region_cfg c;
    t_region(r, &c);
    if (c.model != VFU_DB_MODEL_OFF)
      print_region(r, &c);
  }
  return 0;
}

static int cmd_config(int argc, char** argv) {
  if (!need_ringee())
    return 1;
  if (argc == 2 && !strncmp(argv[1], "match=", 6)) {
    /* Only the match value of a live match region; no reset. */
    unsigned r = (unsigned)strtoul(argv[0], NULL, 0);
    uint64_t v = strtoull(argv[1] + 6, NULL, 0);
    struct region_cfg c;
    t_region(r, &c);
    if (c.model == VFU_DB_MODEL_OFF || !(c.flags & VFU_DB_FLAG_MATCH)) {
      fprintf(stderr, "region %u is not a match region\n", r);
      return 1;
    }
    wr64(&ringee,
         VFU_DB_RE_REGION_TABLE + (uint64_t)r * VFU_DB_RE_REGION_STRIDE +
           VFU_DB_RE_RG_MATCH,
         v);
    t_region(r, &c);
    print_region(r, &c);
    if (c.match != v) {
      fprintf(stderr, "the ringee rejected match 0x%llx\n",
              (unsigned long long)v);
      return 1;
    }
    return 0;
  }
  if (argc < 6) {
    fprintf(stderr, "config <r> <index|keyed|event> <base> <size> <width> "
                    "<stride> [seq] [match=V]\n"
                    "config <r> match=V      change only a match region's "
                    "match value\n");
    return 2;
  }
  unsigned r = (unsigned)strtoul(argv[0], NULL, 0);
  unsigned model = !strcmp(argv[1], "index")   ? VFU_DB_MODEL_INDEX
                   : !strcmp(argv[1], "keyed") ? VFU_DB_MODEL_KEYED
                   : !strcmp(argv[1], "event") ? VFU_DB_MODEL_EVENT
                                               : VFU_DB_MODEL_OFF;
  unsigned flags = 0;
  uint64_t match = 0;
  for (int i = 6; i < argc; i++) {
    if (!strcmp(argv[i], "seq")) {
      flags |= VFU_DB_FLAG_SEQ;
    } else if (!strncmp(argv[i], "match=", 6)) {
      flags |= VFU_DB_FLAG_MATCH;
      match = strtoull(argv[i] + 6, NULL, 0);
    } else {
      fprintf(stderr, "unknown config option %s\n", argv[i]);
      return 2;
    }
  }
  t_config(r, model, flags, strtoull(argv[2], NULL, 0),
           strtoull(argv[3], NULL, 0), (unsigned)strtoul(argv[4], NULL, 0),
           (unsigned)strtoul(argv[5], NULL, 0), match);
  struct region_cfg c;
  t_region(r, &c);
  print_region(r, &c);
  return c.model == VFU_DB_MODEL_OFF ? 1 : 0;
}

/* ---------------------------------------------------------------------- */
/* Self-test                                                               */
/* ---------------------------------------------------------------------- */

static int failures;

static void check(const char* name, bool ok) {
  printf("%s  %s\n", ok ? "PASS" : "FAIL", name);
  if (!ok)
    failures++;
}

struct delta {
  uint64_t arrived;
  uint64_t bad;
  uint64_t gaps;
  uint64_t ooo;
  uint64_t regress;
  uint64_t nomatch;
  bool ran;
};

static struct delta scenario(bool via_ringer, unsigned r, uint32_t count,
                             const char* extra, bool keyed_two) {
  struct delta d = {0};
  struct region_cfg before;
  struct region_cfg after;
  struct opts o;
  /* Clear per-key state so each run's sequence numbers start from zero. */
  wr32(&ringee, VFU_DB_RE_CTRL, 1);
  t_region(r, &before);
  opts_for_region(&before, &o);
  o.nslots = 4;
  if (keyed_two) {
    o.nslots = 1;
    o.qids = 2;
  }
  if (extra && !strcmp(extra, "nomatch")) {
    o.value = 0xfb; /* not the region's match value */
  }
  if (extra && !strcmp(extra, "regress")) {
    o.step = -1;
    o.value = 50;
    o.nslots = 1;
  }
  if (via_ringer) {
    struct ring_result res = ringer_run(&before, count, &o);
    d.ran = res.ok;
  } else {
    cpu_ring(&before, count, &o);
    d.ran = true;
  }
  t_region(r, &after);
  uint64_t keycount;
  sum_keys(r, &after, &o, &d.regress, &keycount);
  d.arrived = after.writes - before.writes;
  d.bad = after.bad - before.bad;
  d.gaps = after.gaps - before.gaps;
  d.ooo = after.ooo - before.ooo;
  d.nomatch = after.nomatch - before.nomatch;
  return d;
}

static void expect_clean(const char* name, const struct delta* d,
                         uint32_t count) {
  bool ok = d->ran && d->arrived == count && d->bad == 0 && d->gaps == 0 &&
            d->ooo == 0 && d->regress == 0;
  check(name, ok);
  if (!ok)
    printf("      ran=%d arrived=%llu/%u bad=%llu gaps=%llu ooo=%llu "
           "regress=%llu\n",
           d->ran, (unsigned long long)d->arrived, count,
           (unsigned long long)d->bad, (unsigned long long)d->gaps,
           (unsigned long long)d->ooo, (unsigned long long)d->regress);
}

static int cmd_selftest(void) {
  if (!need_ringee())
    return 1;
  const uint32_t n = 1000;
  wr32(&ringee, VFU_DB_RE_CTRL, 1);
  /* The default overlays are re-applied by resetting regions to the table the
   * server started with; reconfigure explicitly so the test is self-contained
   * even against a --no-defaults ringee. */
  t_config(0, VFU_DB_MODEL_INDEX, VFU_DB_FLAG_SEQ, 0x2000, 0x1000, 4, 4, 0);
  t_config(1, VFU_DB_MODEL_KEYED, VFU_DB_FLAG_SEQ, 0x3000, 0x1000, 8, 8, 0);
  t_config(2, VFU_DB_MODEL_EVENT, VFU_DB_FLAG_SEQ, 0x4000, 0x1000, 4, 4, 0);
  /* A testdev-like doorbell: one byte, rings only on 0xfa. */
  t_config(3, VFU_DB_MODEL_EVENT, VFU_DB_FLAG_MATCH, 0x5000, 0x100, 1, 1, 0xfa);

  struct delta d = scenario(false, 0, n, NULL, false);
  expect_clean("cpu    index  1000 writes over 4 slots", &d, n);
  d = scenario(false, 1, n, NULL, true);
  expect_clean("cpu    keyed  1000 writes, 2 queue ids on one slot", &d, n);
  d = scenario(false, 2, n, NULL, false);
  expect_clean("cpu    event  1000 writes", &d, n);
  d = scenario(false, 0, 100, "regress", false);
  check("cpu    index  a backwards index is detected",
        d.ran && d.arrived == 100 && d.regress > 0);
  d = scenario(false, 3, 100, NULL, false);
  check("cpu    match  writes of the match value all ring",
        d.ran && d.arrived == 100 && d.nomatch == 0 && d.bad == 0);
  d = scenario(false, 3, 100, "nomatch", false);
  check("cpu    match  other values ring nothing and are counted",
        d.ran && d.arrived == 0 && d.nomatch == 100 && d.bad == 0);

  if (ringer.present) {
    d = scenario(true, 0, n, NULL, false);
    expect_clean("ringer index  1000 writes over 4 slots", &d, n);
    d = scenario(true, 1, n, NULL, true);
    expect_clean("ringer keyed  1000 writes, 2 queue ids on one slot", &d, n);
    d = scenario(true, 2, n, NULL, false);
    expect_clean("ringer event  1000 writes", &d, n);
    d = scenario(true, 0, 100, "regress", false);
    check("ringer index  a backwards index is detected",
          d.ran && d.arrived == 100 && d.regress > 0);
    d = scenario(true, 3, 100, NULL, false);
    check("ringer match  writes of the match value all ring",
          d.ran && d.arrived == 100 && d.nomatch == 0 && d.bad == 0);
    d = scenario(true, 3, 100, "nomatch", false);
    check("ringer match  other values ring nothing and are counted",
          d.ran && d.arrived == 0 && d.nomatch == 100 && d.bad == 0);
  } else {
    printf("SKIP  ringer tests: no ringer device\n");
  }
  printf("%s: %d failure(s)\n", failures ? "FAILED" : "OK", failures);
  return failures ? 1 : 0;
}

/*
 * --ringer, --ringee and --write values are comma-separated options. The first
 * two start with a name, `name,k1=v1,k2`; --write is only options. The options
 * belong to what they follow: only the named ringer or ringee (or --write)
 * accepts them, and any other is an error that lists what it does take.
 */
#define SPEC_MAX_OPTS 16

struct spec_opt {
  char* key;
  char* val; /* NULL for a bare key */
};

struct spec {
  char buf[256];
  const char* name;
  struct spec_opt opt[SPEC_MAX_OPTS];
  int n;
};

static bool parse_spec(const char* arg, const char* label, bool named,
                       struct spec* sp) {
  char* save = NULL;
  char* t;
  snprintf(sp->buf, sizeof(sp->buf), "%s", arg);
  sp->n = 0;
  if (named) {
    sp->name = strtok_r(sp->buf, ",", &save);
    if (!sp->name) {
      fprintf(stderr, "empty %s\n", label);
      return false;
    }
    t = strtok_r(NULL, ",", &save);
  } else {
    sp->name = label;
    t = strtok_r(sp->buf, ",", &save);
  }
  for (; t; t = strtok_r(NULL, ",", &save)) {
    if (sp->n >= SPEC_MAX_OPTS) {
      fprintf(stderr, "%s: too many options\n", sp->name);
      return false;
    }
    char* eq = strchr(t, '=');
    if (eq)
      *eq++ = '\0';
    sp->opt[sp->n].key = t;
    sp->opt[sp->n].val = eq;
    sp->n++;
  }
  return true;
}

/* `allowed` lists the keys the spec takes, "" for none. `role` is "ringer" or
 * "ringee", or "" when the spec's name is itself the label (--write). */
static bool spec_allow(const struct spec* sp, const char* role,
                       const char* allowed) {
  for (int i = 0; i < sp->n; i++) {
    const char* k = sp->opt[i].key;
    size_t kl = strlen(k);
    bool ok = false;
    for (const char* p = allowed; *p;) {
      size_t len = strcspn(p, ",");
      if (len == kl && !strncmp(p, k, kl))
        ok = true;
      p += len + (p[len] == ',');
    }
    if (!ok) {
      if (*allowed)
        fprintf(stderr, "%s%s%s has no option '%s' (it takes %s)\n", role,
                *role ? " " : "", sp->name, k, allowed);
      else
        fprintf(stderr, "%s%s%s takes no options, not '%s'\n", role,
                *role ? " " : "", sp->name, k);
      return false;
    }
  }
  return true;
}

static const struct spec_opt* spec_find(const struct spec* sp,
                                        const char* key) {
  for (int i = 0; i < sp->n; i++)
    if (!strcmp(sp->opt[i].key, key))
      return &sp->opt[i];
  return NULL;
}

/* A key that takes a value: NULL when absent. False if it has no value. */
static bool spec_value(const struct spec* sp, const char* key,
                       const char** val) {
  const struct spec_opt* o = spec_find(sp, key);
  *val = o ? o->val : NULL;
  if (o && !o->val) {
    fprintf(stderr, "%s: option %s needs a value (%s=...)\n", sp->name, key,
            key);
    return false;
  }
  return true;
}

/* A key that is a flag. False if it was given a value. */
static bool spec_flag(const struct spec* sp, const char* key, bool* on) {
  const struct spec_opt* o = spec_find(sp, key);
  *on = o != NULL;
  if (o && o->val) {
    fprintf(stderr, "%s: option %s takes no value\n", sp->name, key);
    return false;
  }
  return true;
}

static bool num_u64(const char* what, const char* v, uint64_t* out) {
  char* end = NULL;
  *out = strtoull(v, &end, 0);
  if (!*v || *end) {
    fprintf(stderr, "%s: '%s' is not a number\n", what, v);
    return false;
  }
  return true;
}

/* An optional numeric key: *have says whether it was given. */
static bool spec_u64(const struct spec* sp, const char* key, uint64_t* out,
                     bool* have) {
  const char* v;
  *have = false;
  if (!spec_value(sp, key, &v))
    return false;
  if (!v)
    return true;
  *have = true;
  return num_u64(key, v, out);
}

/* The --write options: what each write looks like and how they are spread. The
 * defaults, already in `o`, come from the region or the named device. */
static bool apply_write(const struct spec* sp, bool keyed, struct opts* o) {
  bool have;
  uint64_t u;
  const char* v;

  if (!spec_allow(sp, "",
                  "size,value,step,pattern,nslots,stride,seq,delay-ns,"
                  "qids,qid0,ring"))
    return false;
  if (!keyed && (spec_find(sp, "qids") || spec_find(sp, "qid0") ||
                 spec_find(sp, "ring"))) {
    fprintf(stderr, "--write: qids, qid0 and ring apply only to a keyed "
                    "region\n");
    return false;
  }
  if (!spec_u64(sp, "size", &u, &have))
    return false;
  if (have) {
    if (u != 1 && u != 2 && u != 4 && u != 8) {
      fprintf(stderr, "--write: size must be 1, 2, 4 or 8\n");
      return false;
    }
    o->size = (unsigned)u;
  }
  if (!spec_u64(sp, "value", &u, &have))
    return false;
  if (have)
    o->value = u;
  if (!spec_value(sp, "step", &v))
    return false;
  if (v) {
    char* end = NULL;
    o->step = strtoll(v, &end, 0);
    if (!*v || *end) {
      fprintf(stderr, "step: '%s' is not a number\n", v);
      return false;
    }
  }
  if (!spec_value(sp, "pattern", &v))
    return false;
  if (v) {
    if (!strcmp(v, "monotonic")) {
      o->pattern = VFU_DB_PAT_MONOTONIC;
    } else if (!strcmp(v, "repeat")) {
      o->pattern = VFU_DB_PAT_REPEAT;
    } else if (!strcmp(v, "random")) {
      o->pattern = VFU_DB_PAT_RANDOM;
    } else {
      fprintf(stderr,
              "--write: pattern is monotonic, repeat or random, not "
              "'%s'\n",
              v);
      return false;
    }
  }
  if (!spec_u64(sp, "nslots", &u, &have))
    return false;
  if (have)
    o->nslots = (uint32_t)u;
  if (!spec_u64(sp, "stride", &u, &have))
    return false;
  if (have)
    o->stride = u;
  if (!spec_u64(sp, "delay-ns", &u, &have))
    return false;
  if (have)
    o->delay_ns = (uint32_t)u;
  if (!spec_u64(sp, "qids", &u, &have))
    return false;
  if (have)
    o->qids = (uint32_t)u;
  if (!spec_u64(sp, "qid0", &u, &have))
    return false;
  if (have)
    o->qid0 = (uint32_t)u;
  if (!spec_u64(sp, "ring", &u, &have))
    return false;
  if (have)
    o->ring = (uint32_t)u;
  /* seq is a flag, or seq=0 / seq=1 */
  const struct spec_opt* so = spec_find(sp, "seq");
  if (so) {
    if (!so->val) {
      o->seq = true;
    } else {
      if (!num_u64("seq", so->val, &u))
        return false;
      o->seq = u != 0;
    }
  }
  return true;
}

/* ---------------------------------------------------------------------- */
/* ring: who writes (--ringer), what is rung (--ringee), and presets       */
/* ---------------------------------------------------------------------- */

/* clang-format off */
/*
 * A ringee is the thing being rung:
 *
 *   vfu-doorbell        our ringee device (the default)
 *   qemu-pci-testdev    QEMU's pci-testdev. Doorbell at BAR0 offset 0, 1 byte,
 *                       rings only on 0xFA (an ioeventfd datamatch).
 *   qemu-nvme           QEMU's NVMe. It has a doorbell per queue, chosen with
 *                       the options sq=N|free or cq=N|free (or with --raw): SQ
 *                       tail or CQ head at BAR0+0x1000 with stride 8 per queue
 *                       (CAP.DSTRD 0). `free` is the lowest queue id the guest's
 *                       driver does not own. force allows one it owns.
 *   <bdf>               any other PCI device; needs --raw
 *
 * A device with one doorbell (qemu-pci-testdev) is rung with `ring --ringee X
 * <count>`. Everything a named device fills in can also be typed: --raw
 * <offset> is an offset into the device's BAR0, with --size, --value and
 * --pattern.
 */
/* clang-format on */
struct target {
  struct dev store;
  struct dev* dev;
  bool ours; /* the vfu-doorbell ringee */
  bool nvme;
  bool has_base; /* the device's own doorbell offset */
  uint64_t base;
  unsigned size; /* 0: no default */
  bool has_value;
  uint64_t value;
  bool has_pattern;
  uint32_t pattern;
};

/* The number of queues the guest's NVMe driver has for this controller: the
 * admin queue and the I/O queues, so it owns ids 0 to count - 1. */
static bool nvme_queue_count(const char* bdf, unsigned* count) {
  DIR* dir = opendir("/sys/class/nvme");
  struct dirent* e;
  bool found = false;
  if (!dir)
    return false;
  while ((e = readdir(dir)) != NULL) {
    char path[512];
    char addr[64] = "";
    if (e->d_name[0] == '.')
      continue;
    snprintf(path, sizeof(path), "/sys/class/nvme/%s/address", e->d_name);
    FILE* f = fopen(path, "r");
    if (!f)
      continue;
    if (fscanf(f, "%63s", addr) != 1)
      addr[0] = '\0';
    fclose(f);
    if (strcmp(addr, bdf))
      continue;
    snprintf(path, sizeof(path), "/sys/class/nvme/%s/queue_count", e->d_name);
    f = fopen(path, "r");
    if (f) {
      if (fscanf(f, "%u", count) == 1)
        found = true;
      fclose(f);
    }
  }
  closedir(dir);
  return found;
}

static bool queue_in_use(const char* bdf, unsigned qid) {
  unsigned count;
  return nvme_queue_count(bdf, &count) && qid < count;
}

/* With no driver bound there are no live queues, so the lowest is 1. */
static unsigned nvme_free_queue(const char* bdf) {
  unsigned count;
  return nvme_queue_count(bdf, &count) ? count : 1;
}

/* BAR0 offset of a queue's doorbell: sq and cq take a number or `free`. */
static bool nvme_doorbell(const struct target* t, bool cq, const char* val,
                          uint64_t* off) {
  unsigned qid;
  if (!strcmp(val, "free")) {
    qid = nvme_free_queue(t->dev->bdf);
    printf("nvme: the first queue the driver does not own is %u\n", qid);
  } else if (val[0] >= '0' && val[0] <= '9') {
    qid = (unsigned)strtoul(val, NULL, 0);
  } else {
    fprintf(stderr,
            "ringee qemu-nvme: %s takes a queue number or free, not "
            "'%s'\n",
            cq ? "cq" : "sq", val);
    return false;
  }
  *off = 0x1000u + 8u * qid + (cq ? 4u : 0u);
  return true;
}

static bool resolve_ringee(const char* spec, struct target* t) {
  memset(t, 0, sizeof(*t));
  if (!strcmp(spec, "vfu-doorbell")) {
    if (!need_ringee())
      return false;
    t->dev = &ringee;
    t->ours = true;
    return true;
  }
  if (!strcmp(spec, "qemu-pci-testdev")) {
    if (!find_device(0x1b36, 0x0005, &t->store)) {
      fprintf(stderr, "no QEMU pci-testdev (1b36:0005) in this guest\n");
      return false;
    }
    t->dev = &t->store;
    t->has_base = true;
    t->base = 0;
    t->size = 1;
    t->has_value = true;
    t->value = 0xfa;
    t->has_pattern = true;
    t->pattern = VFU_DB_PAT_REPEAT;
    return true;
  }
  if (!strcmp(spec, "qemu-nvme")) {
    if (!find_device(0x1b36, 0x0010, &t->store)) {
      fprintf(stderr, "no QEMU NVMe controller (1b36:0010) in this guest\n");
      return false;
    }
    t->dev = &t->store;
    t->nvme = true;
    t->size = 4;
    return true;
  }
  if (!strncmp(spec, "qemu-", 5)) {
    fprintf(stderr, "unknown ringee '%s' (qemu-pci-testdev, qemu-nvme)\n",
            spec);
    return false;
  }
  if (!open_dev(spec, &t->store))
    return false;
  t->dev = &t->store;
  return true;
}

/* The write pattern a preset fixes. Zero or unset fields keep the defaults. */
struct pattern {
  uint32_t size;
  uint32_t nslots;
  uint32_t qids;
  int64_t step;
  bool has_value;
  uint64_t value;
  bool has_pattern;
  uint32_t pattern;
};

static void apply_pattern(const struct pattern* p, struct opts* o) {
  if (p->size)
    o->size = p->size;
  if (p->nslots)
    o->nslots = p->nslots;
  if (p->qids)
    o->qids = p->qids;
  if (p->step)
    o->step = p->step;
  if (p->has_value)
    o->value = p->value;
  if (p->has_pattern)
    o->pattern = p->pattern;
}

/* The options only the vfu-doorbell ringer takes: how it writes, not what. */
struct ringer_opts {
  bool inline_mode;
  bool poll_mmio;
  bool shm;
  unsigned timeout_ms; /* 0: the default */
};

static void apply_ringer_opts(const struct ringer_opts* rp, struct opts* o) {
  o->inline_mode = rp->inline_mode;
  o->poll_mmio = rp->poll_mmio;
  if (rp->shm)
    o->mode = VFU_DB_MODE_SHM;
  if (rp->timeout_ms)
    o->timeout_ms = rp->timeout_ms;
}

enum { EXP_NONE = 0, EXP_ARRIVE_ALL, EXP_ALL_IGNORED };

/* Run against one of the ringee's own regions and judge it by the counters. */
static int run_region(bool cpu, unsigned r, uint32_t count, struct opts* o,
                      const struct region_cfg* before, unsigned expect,
                      const char* name) {
  struct region_cfg after;
  uint64_t t0 = now_ns();
  struct ring_result res = {.ok = true};
  if (cpu)
    cpu_ring(before, count, o);
  else
    res = ringer_run(before, count, o);
  uint64_t dt = now_ns() - t0;
  t_region(r, &after);
  uint64_t regress;
  uint64_t keycount;
  sum_keys(r, &after, o, &regress, &keycount);
  uint64_t arrived = after.writes - before->writes;
  uint64_t bad = after.bad - before->bad;
  uint64_t gaps = after.gaps - before->gaps;
  uint64_t ooo = after.ooo - before->ooo;
  uint64_t ignored = after.nomatch - before->nomatch;
  printf("path=%s count=%u elapsed=%.3f ms\n", cpu ? "cpu" : "ringer", count,
         (double)dt / 1e6);
  if (!cpu)
    printf(
      "ringer: status=%u sent=%llu errors=%llu errno=%u max_lat=%.1f us%s\n",
      res.status, (unsigned long long)res.sent, (unsigned long long)res.errors,
      res.err_no, (double)res.max_lat_ns / 1e3,
      res.timed_out ? "  TIMEOUT (possible deadlock)" : "");
  printf("ringee: arrived=%llu bad=%llu seq_gaps=%llu seq_ooo=%llu "
         "regress=%llu\n",
         (unsigned long long)arrived, (unsigned long long)bad,
         (unsigned long long)gaps, (unsigned long long)ooo,
         (unsigned long long)regress);
  if (before->flags & VFU_DB_FLAG_MATCH)
    printf("ringee: ignored=%llu (value != match 0x%llx)\n",
           (unsigned long long)ignored, (unsigned long long)before->match);
  (void)keycount;
  if (expect == EXP_NONE)
    return res.ok ? 0 : 1;
  bool ok = res.ok && bad == 0;
  if (expect == EXP_ARRIVE_ALL)
    ok = ok && arrived == count && gaps == 0 && ooo == 0 && regress == 0 &&
         ignored == 0;
  else
    ok = ok && arrived == 0 && ignored == count;
  printf("%s  %s\n", ok ? "PASS" : "FAIL", name);
  return ok ? 0 : 1;
}

/* ring <region> ... */
static int ring_region(bool cpu, const struct ringer_opts* rp, unsigned r,
                       uint32_t count, const struct spec* wr) {
  struct region_cfg before;
  struct opts o;

  if (!need_ringee() || (!cpu && !need_ringer()))
    return 1;
  t_region(r, &before);
  if (before.model == VFU_DB_MODEL_OFF) {
    fprintf(stderr, "region %u is not configured\n", r);
    return 1;
  }
  opts_for_region(&before, &o);
  if (!apply_write(wr, before.model == VFU_DB_MODEL_KEYED, &o))
    return 2;
  apply_ringer_opts(rp, &o);
  return run_region(cpu, r, count, &o, &before, EXP_NONE, NULL);
}

/* A write to some device's BAR0. There are no per-region counters for it, so
 * what arrived is judged from the device's own side. */
static int ring_external(bool cpu, bool force, struct target* t, bool have_raw,
                         uint64_t raw, uint32_t count, struct opts* o) {
  struct region_cfg c = {.model = VFU_DB_MODEL_INDEX, .width = 4};

  if (have_raw) {
    c.base = raw;
  } else if (t->has_base) {
    c.base = t->base;
  } else {
    fprintf(stderr, "this ringee has no known doorbell: give offset=X\n");
    return 2;
  }
  if (c.base + o->size > t->dev->size) {
    fprintf(stderr, "offset 0x%llx is outside the ringee's BAR0 (0x%zx)\n",
            (unsigned long long)c.base, t->dev->size);
    return 2;
  }
  if (t->nvme && !force && c.base >= 0x1000 &&
      queue_in_use(t->dev->bdf, (unsigned)((c.base - 0x1000) / 8))) {
    fprintf(stderr,
            "NVMe queue %u exists in the guest's driver; ringing it can "
            "corrupt a live queue. Pick another or add ,force to the ringee.\n",
            (unsigned)((c.base - 0x1000) / 8));
    return 1;
  }
  if (!cpu && !need_ringer())
    return 1;
  o->gpa_base = t->dev->gpa;
  o->dst = t->dev;
  o->stride = o->stride ? o->stride : o->size;
  printf("ringee: %s BAR0+0x%llx gpa=0x%llx size=%u x%u\n", t->dev->bdf,
         (unsigned long long)c.base, (unsigned long long)(o->gpa_base + c.base),
         o->size, count);

  uint64_t t0 = now_ns();
  struct ring_result res = {.ok = true};
  if (cpu)
    cpu_ring(&c, count, o);
  else
    res = ringer_run(&c, count, o);
  printf("path=%s count=%u elapsed=%.3f ms\n", cpu ? "cpu" : "ringer", count,
         (double)(now_ns() - t0) / 1e6);
  if (!cpu)
    printf("ringer: status=%u sent=%llu errors=%llu errno=%u%s\n", res.status,
           (unsigned long long)res.sent, (unsigned long long)res.errors,
           res.err_no, res.timed_out ? "  TIMEOUT" : "");
  if (t->ours)
    printf("no region is judged for an offset write: read the ringee with dump "
           "and log\n");
  else
    printf("no ringee counters for this device: check its own trace\n");
  return res.ok ? 0 : 1;
}

/* ---------------------------------------------------------------------- */
/* Presets                                                                 */
/* ---------------------------------------------------------------------- */

/*
 * A preset is a whole run: the ringer, the ringee, the ringee's region (when it
 * is the vfu-doorbell ringee) and the write pattern. It writes nothing to the
 * ringee's configuration. Its region is one of the ringee's static ones, and
 * the preset checks that the region is what it expects and refuses to run
 * otherwise. `ring --preset <name>` takes no other argument; `presets` lists
 * each preset with the explicit command that does the same.
 */
struct preset {
  const char* name;
  const char* desc;
  bool cpu;              /* the ringer: the CPU, else the vfu-doorbell ringer */
  const char* ringee;    /* as for --ringee */
  int region;            /* the ringee's region, or -1 */
  struct region_cfg cfg; /* what the region must be */
  uint32_t count;
  struct pattern pat;
  unsigned expect;
  const char* qsel; /* an NVMe doorbell: "sq=free", "cq=3" */
};

#define RG(m, f, b, sz, w, st, mt)                                             \
  {.model = (m),                                                               \
   .flags = (f),                                                               \
   .base = (b),                                                                \
   .size = (sz),                                                               \
   .width = (w),                                                               \
   .stride = (st),                                                             \
   .match = (mt)}

static const struct preset presets[] = {
  {"index-ringer",
   "index region 0, 1000 writes over 4 slots, ringer",
   false,
   "vfu-doorbell",
   0,
   RG(VFU_DB_MODEL_INDEX, VFU_DB_FLAG_SEQ, 0x2000, 0x1000, 4, 4, 0),
   1000,
   {.nslots = 4},
   EXP_ARRIVE_ALL,
   NULL},
  {"index-cpu",
   "index region 0, 1000 writes over 4 slots, CPU",
   true,
   "vfu-doorbell",
   0,
   RG(VFU_DB_MODEL_INDEX, VFU_DB_FLAG_SEQ, 0x2000, 0x1000, 4, 4, 0),
   1000,
   {.nslots = 4},
   EXP_ARRIVE_ALL,
   NULL},
  {"keyed-ringer",
   "keyed region 1, two queue ids on one register, ringer",
   false,
   "vfu-doorbell",
   1,
   RG(VFU_DB_MODEL_KEYED, VFU_DB_FLAG_SEQ, 0x3000, 0x1000, 8, 8, 0),
   1000,
   {.nslots = 1, .qids = 2},
   EXP_ARRIVE_ALL,
   NULL},
  {"event-ringer",
   "event region 2, 1000 writes over 4 slots, ringer",
   false,
   "vfu-doorbell",
   2,
   RG(VFU_DB_MODEL_EVENT, VFU_DB_FLAG_SEQ, 0x4000, 0x1000, 4, 4, 0),
   1000,
   {.nslots = 4},
   EXP_ARRIVE_ALL,
   NULL},
  {"testdev-ringer",
   "testdev-like region 3, the match value, ringer",
   false,
   "vfu-doorbell",
   3,
   RG(VFU_DB_MODEL_EVENT, VFU_DB_FLAG_MATCH, 0x5000, 0x100, 1, 1, 0xfa),
   100,
   {0},
   EXP_ARRIVE_ALL,
   NULL},
  {"testdev-miss-ringer",
   "testdev-like region 3, a value that is not the match, ringer",
   false,
   "vfu-doorbell",
   3,
   RG(VFU_DB_MODEL_EVENT, VFU_DB_FLAG_MATCH, 0x5000, 0x100, 1, 1, 0xfa),
   100,
   {.has_value = true, .value = 0xfb},
   EXP_ALL_IGNORED,
   NULL},
  {"testdev-qemu-ringer",
   "QEMU pci-testdev doorbell, ringer",
   false,
   "qemu-pci-testdev",
   -1,
   {0},
   10,
   {.size = 1,
    .has_value = true,
    .value = 0xfa,
    .has_pattern = true,
    .pattern = VFU_DB_PAT_REPEAT},
   EXP_NONE,
   NULL},
  {"testdev-qemu-cpu",
   "QEMU pci-testdev doorbell, CPU",
   true,
   "qemu-pci-testdev",
   -1,
   {0},
   10,
   {.size = 1,
    .has_value = true,
    .value = 0xfa,
    .has_pattern = true,
    .pattern = VFU_DB_PAT_REPEAT},
   EXP_NONE,
   NULL},
  {"nvme-qemu-ringer",
   "QEMU NVMe tail doorbell of a queue the driver does not own, ringer",
   false,
   "qemu-nvme",
   -1,
   {0},
   3,
   {.size = 4},
   EXP_NONE,
   "sq=free"},
};

static const char* pattern_name(uint32_t p) {
  return p == VFU_DB_PAT_REPEAT   ? "repeat"
         : p == VFU_DB_PAT_RANDOM ? "random"
                                  : "monotonic";
}

static size_t wadd(char* w, size_t m, size_t n, const char* fmt, ...) {
  va_list ap;
  int k;
  va_start(ap, fmt);
  k = vsnprintf(w + m, n - m, fmt, ap);
  va_end(ap);
  return m + (size_t)k;
}

/* The explicit command line that does what a preset does. */
static void preset_cmdline(const struct preset* p, char* out, size_t n) {
  char w[160];
  size_t m = 0;
  size_t k = (size_t)snprintf(out, n, "ring --ringer %s --ringee %s",
                              p->cpu ? "cpu" : "vfu-doorbell", p->ringee);
  if (p->region >= 0)
    k += (size_t)snprintf(out + k, n - k, ",region=%d", p->region);
  else if (p->qsel)
    k += (size_t)snprintf(out + k, n - k, ",%s", p->qsel);
  k += (size_t)snprintf(out + k, n - k, " --count %u", p->count);
  w[0] = '\0';
  if (p->region < 0 && p->pat.size)
    m = wadd(w, m, sizeof(w), "%ssize=%u", m ? "," : "", p->pat.size);
  if (p->pat.nslots)
    m = wadd(w, m, sizeof(w), "%snslots=%u", m ? "," : "", p->pat.nslots);
  if (p->pat.qids)
    m = wadd(w, m, sizeof(w), "%sqids=%u", m ? "," : "", p->pat.qids);
  if (p->pat.step)
    m = wadd(w, m, sizeof(w), "%sstep=%lld", m ? "," : "",
             (long long)p->pat.step);
  if (p->pat.has_value)
    m = wadd(w, m, sizeof(w), "%svalue=0x%llx", m ? "," : "",
             (unsigned long long)p->pat.value);
  if (p->pat.has_pattern)
    m = wadd(w, m, sizeof(w), "%spattern=%s", m ? "," : "",
             pattern_name(p->pat.pattern));
  if (m)
    snprintf(out + k, n - k, " --write %s", w);
}

static int cmd_presets(void) {
  for (size_t i = 0; i < sizeof(presets) / sizeof(presets[0]); i++) {
    char cmd[256];
    preset_cmdline(&presets[i], cmd, sizeof(cmd));
    printf("%-20s %s\n    %s\n", presets[i].name, presets[i].desc, cmd);
  }
  return 0;
}

static void describe_region(char* out, size_t n, const struct region_cfg* c) {
  size_t k = (size_t)snprintf(out, n,
                              "%s base=0x%llx size=0x%llx width=%u "
                              "stride=%u%s",
                              model_name(c->model), (unsigned long long)c->base,
                              (unsigned long long)c->size, c->width, c->stride,
                              (c->flags & VFU_DB_FLAG_SEQ) ? " seq" : "");
  if (c->flags & VFU_DB_FLAG_MATCH)
    snprintf(out + k, n - k, " match=0x%llx", (unsigned long long)c->match);
}

static int run_preset(const struct preset* p) {
  char cmd[256];
  struct opts o;

  preset_cmdline(p, cmd, sizeof(cmd));
  printf("preset %s: %s\nequivalent: %s\n", p->name, p->desc, cmd);

  if (p->region >= 0) {
    struct region_cfg got;
    char want[160];
    char have[160];
    const uint32_t mask = VFU_DB_FLAG_SEQ | VFU_DB_FLAG_MATCH;
    if (!need_ringee() || (!p->cpu && !need_ringer()))
      return 1;
    t_region((unsigned)p->region, &got);
    bool same = got.model == p->cfg.model &&
                (got.flags & mask) == p->cfg.flags && got.base == p->cfg.base &&
                got.size == p->cfg.size && got.width == p->cfg.width &&
                got.stride == p->cfg.stride &&
                (!(p->cfg.flags & VFU_DB_FLAG_MATCH) ||
                 got.match == p->cfg.match);
    if (!same) {
      describe_region(want, sizeof(want), &p->cfg);
      describe_region(have, sizeof(have), &got);
      fprintf(stderr,
              "region %d is not what this preset needs\n  needs: %s\n  is:    "
              "%s\n",
              p->region, want, have);
      return 1;
    }
    wr32(&ringee, VFU_DB_RE_CTRL, 1); /* counters and per-key state to zero */
    t_region((unsigned)p->region, &got);
    opts_for_region(&got, &o);
    apply_pattern(&p->pat, &o);
    return run_region(p->cpu, (unsigned)p->region, p->count, &o, &got,
                      p->expect, p->name);
  }

  struct target t;
  if (!resolve_ringee(p->ringee, &t))
    return 1;
  struct region_cfg c0 = {.model = VFU_DB_MODEL_INDEX, .width = 4};
  opts_for_region(&c0, &o);
  apply_pattern(&p->pat, &o);
  uint64_t where = 0;
  if (p->qsel && !nvme_doorbell(&t, p->qsel[0] == 'c', p->qsel + 3, &where))
    return 1;
  return ring_external(p->cpu, false, &t, p->qsel != NULL, where, p->count, &o);
}

static bool ringer_spec(const char* arg, bool* cpu, struct ringer_opts* rp) {
  struct spec sp;
  const char* v;
  if (!parse_spec(arg, "ringer", true, &sp))
    return false;
  if (!strcmp(sp.name, "cpu")) {
    *cpu = true;
    return spec_allow(&sp, "ringer", "");
  }
  if (strcmp(sp.name, "vfu-doorbell")) {
    fprintf(stderr, "unknown ringer '%s' (vfu-doorbell, cpu)\n", sp.name);
    return false;
  }
  if (!spec_allow(&sp, "ringer", "inline,poll-mmio,shm,timeout-ms") ||
      !spec_flag(&sp, "inline", &rp->inline_mode) ||
      !spec_flag(&sp, "poll-mmio", &rp->poll_mmio) ||
      !spec_flag(&sp, "shm", &rp->shm) || !spec_value(&sp, "timeout-ms", &v))
    return false;
  if (v) {
    uint64_t ms;
    if (!num_u64("timeout-ms", v, &ms))
      return false;
    rp->timeout_ms = (unsigned)ms;
  }
  return true;
}

static int ring_usage(void) {
  fprintf(stderr,
          "ring [--ringee D[,opts]] [--ringer R[,opts]] [--count N] [--write "
          "k=v,...]\n"
          "ring --preset <name>\n"
          "(xio-doorbell help lists the options)\n");
  return 2;
}

/* clang-format off */
/*
 * ring: ring a doorbell and say what arrived.
 *
 *   ring --ringee vfu-doorbell,region=0 --count 1000 --write nslots=4
 *   ring --ringee qemu-nvme,sq=free --count 3
 *   ring --ringee <bdf>,offset=0x10f0 --count 1 --write size=4,value=9
 *   ring --preset <name>                          a whole run, nothing else
 *
 * --ringee picks what is rung and where in it (default vfu-doorbell,region=0);
 * --ringer picks who writes (vfu-doorbell, the default, or cpu); --write shapes the
 * writes. Each takes comma-separated options that only it understands.
 */
/* clang-format on */
static int cmd_ring(int argc, char** argv) {
  const char* ringer_arg = NULL;
  const char* ringee_arg = NULL;
  const char* write_arg = NULL;
  const char* count_arg = NULL;
  const char* preset = NULL;

  for (int i = 0; i < argc; i++) {
    const char* a = argv[i];
    const char** dst = !strcmp(a, "--ringer")   ? &ringer_arg
                       : !strcmp(a, "--ringee") ? &ringee_arg
                       : !strcmp(a, "--write")  ? &write_arg
                       : !strcmp(a, "--count")  ? &count_arg
                       : !strcmp(a, "--preset") ? &preset
                                                : NULL;
    if (!dst) {
      fprintf(stderr, "unexpected argument '%s'\n", a);
      return ring_usage();
    }
    if (i + 1 >= argc) {
      fprintf(stderr, "%s needs a value\n", a);
      return 2;
    }
    *dst = argv[++i];
  }

  if (preset) {
    if (ringer_arg || ringee_arg || write_arg || count_arg) {
      fprintf(stderr, "--preset takes no other argument; use `presets` to "
                      "see what each one does\n");
      return 2;
    }
    for (size_t i = 0; i < sizeof(presets) / sizeof(presets[0]); i++)
      if (!strcmp(presets[i].name, preset))
        return run_preset(&presets[i]);
    fprintf(stderr, "unknown preset '%s' (see `presets`)\n", preset);
    return 2;
  }

  uint64_t count = 1;
  if (count_arg && !num_u64("--count", count_arg, &count))
    return 2;

  bool cpu = false;
  struct ringer_opts rp = {0};
  if (ringer_arg && !ringer_spec(ringer_arg, &cpu, &rp))
    return 2;

  struct spec rs;
  if (!parse_spec(ringee_arg ? ringee_arg : "vfu-doorbell,region=0", "ringee",
                  true, &rs))
    return 2;
  const char* name = rs.name;
  const bool ours = !strcmp(name, "vfu-doorbell");
  const bool is_testdev = !strcmp(name, "qemu-pci-testdev");
  const bool is_nvme = !strcmp(name, "qemu-nvme");
  if (!strncmp(name, "qemu-", 5) && !is_testdev && !is_nvme) {
    fprintf(stderr, "unknown ringee '%s' (qemu-pci-testdev, qemu-nvme)\n",
            name);
    return 2;
  }
  if (!spec_allow(&rs, "ringee",
                  ours      ? "region,offset"
                  : is_nvme ? "sq,cq,force,offset"
                            : "offset"))
    return 2;
  const char *region_s, *sq, *cq, *offset_s;
  bool force;
  if (!spec_value(&rs, "region", &region_s) || !spec_value(&rs, "sq", &sq) ||
      !spec_value(&rs, "cq", &cq) || !spec_value(&rs, "offset", &offset_s) ||
      !spec_flag(&rs, "force", &force))
    return 2;
  const int chosen = !!region_s + !!sq + !!cq + !!offset_s;
  if (chosen > 1) {
    fprintf(stderr, "ringee %s: give only one of %s\n", name,
            ours      ? "region and offset"
            : is_nvme ? "sq, cq and offset"
                      : "offset");
    return 2;
  }
  if (!chosen && !is_testdev) {
    if (ours)
      fprintf(stderr, "ringee vfu-doorbell needs region=N or offset=X\n");
    else if (is_nvme)
      fprintf(stderr, "which doorbell? give the ringee sq=N|free, cq=N|free "
                      "or offset=X\n");
    else
      fprintf(stderr, "ringee %s needs offset=X\n", name);
    return 2;
  }

  struct spec ws;
  if (!parse_spec(write_arg ? write_arg : "", "--write", false, &ws))
    return 2;

  if (region_s) {
    uint64_t r;
    if (!num_u64("region", region_s, &r))
      return 2;
    if (r >= VFU_DB_RE_MAX_REGIONS) {
      fprintf(stderr, "region must be below %u\n", VFU_DB_RE_MAX_REGIONS);
      return 2;
    }
    return ring_region(cpu, &rp, (unsigned)r, (uint32_t)count, &ws);
  }

  struct target t;
  struct opts o;
  struct region_cfg c0 = {.model = VFU_DB_MODEL_INDEX, .width = 4};
  if (!resolve_ringee(name, &t))
    return 1;
  opts_for_region(&c0, &o);
  if (t.size)
    o.size = t.size;
  if (t.has_value)
    o.value = t.value;
  if (t.has_pattern)
    o.pattern = t.pattern;
  if (!apply_write(&ws, false, &o))
    return 2;
  apply_ringer_opts(&rp, &o);
  bool have_raw = false;
  uint64_t where = 0;
  if (offset_s) {
    if (!num_u64("offset", offset_s, &where))
      return 2;
    have_raw = true;
  } else if (sq || cq) {
    if (!nvme_doorbell(&t, cq != NULL, sq ? sq : cq, &where))
      return 2;
    have_raw = true;
  }
  return ring_external(cpu, force, &t, have_raw, where, (uint32_t)count, &o);
}

/* clang-format off */
static void usage(FILE* out) {
  fputs(
    "usage: xio-doorbell <command> [args]\n"
    "\n"
    "  info                      show the devices and the configured regions\n"
    "  reset                     reset the ringee's counters, per-key state and write log\n"
    "  dump [region]             show region counters\n"
    "  log [n]                   show the last n logged writes, in arrival order\n"
    "  config <region> <model> <base> <size> <width> <stride> [seq] [match=V]\n"
    "                            set a region; model is index, keyed or event\n"
    "  config <region> match=V   change only a match region's match value, with no reset\n"
    "  presets                   list the presets, each with the explicit ring command that does the same\n"
    "  selftest                  run the built-in scenarios\n"
    "  ring                      ring a doorbell and report what arrived (two forms, below)\n"
    "  help                      this text\n"
    "\n"
    "ring [--ringee D[,opts]] [--ringer R[,opts]] [--count N] [--write k=v,...]\n"
    "\n"
    "  Every flag is optional. With none, this is what runs:\n"
    "      ring --ringee vfu-doorbell,region=0 --ringer vfu-doorbell --count 1\n"
    "\n"
    "  Options after a comma belong to the thing they follow; one it does not take is an error.\n"
    "\n"
    "  --ringee D[,opts]         [default: --ringee vfu-doorbell,region=0]  What is rung, and where in it. One of:\n"
    "      vfu-doorbell,(region=N | offset=X)\n"
    "      qemu-pci-testdev[,offset=X]\n"
    "      qemu-nvme,(sq=Q | cq=Q | offset=X)[,force]\n"
    "      BDF,offset=X                            any other PCI device, for example 0000:00:03.0\n"
    "    In these forms [ ] is optional and ( | ) is exactly one of the choices. What each option means:\n"
    "      region=N              one of our ringee's regions; its counters judge the writes (only this form is judged)\n"
    "      offset=X              an offset into the device's BAR0  [qemu-pci-testdev default: offset=0, its one doorbell]\n"
    "      sq=Q                  a queue's SQ tail doorbell; Q is a queue number, or free for the lowest queue the driver does not own\n"
    "      cq=Q                  a queue's CQ head doorbell; Q is as for sq\n"
    "      force                 also allow a queue the guest driver owns\n"
    "\n"
    "  --ringer R[,opts]         [default: --ringer vfu-doorbell]  Who writes. One of:\n"
    "      vfu-doorbell[,inline][,poll-mmio][,shm][,timeout-ms=N]     the ringer device, writing with vfu_mmio_write\n"
    "      cpu                                                        the guest CPU stores through the mapped BAR\n"
    "    What each option means:\n"
    "      inline                write from the ringer's BAR callback (can deadlock)\n"
    "      poll-mmio             poll the ringer's STATUS register over MMIO (can deadlock)\n"
    "      shm                   write through DMA-mapped guest memory\n"
    "      timeout-ms=N          how long to wait for the ringer to finish  [default: timeout-ms=10000]\n"
    "\n"
    "  --count N                 [default: --count 1]  How many writes\n"
    "\n"
    "  --write k=v,...           [default: none]  Shape the writes. Every key is optional. Defaults come from the region or the\n"
    "                            named device; for a region these override what its config implies, so a wrong size\n"
    "                            sends malformed writes on purpose.\n"
    "      size=W                bytes per write: 1, 2, 4 or 8\n"
    "      value=V               the first value\n"
    "      step=S                added to the value on each write to a slot\n"
    "      pattern=P             monotonic (adds step), repeat or random\n"
    "      nslots=N              slots cycled through\n"
    "      stride=B              bytes between slots\n"
    "      seq[=0|1]             put a per-slot sequence number above the index\n"
    "      delay-ns=N            pause after each write\n"
    "      qids=Q                queue ids cycled through; only for a keyed region, an error otherwise\n"
    "      qid0=Q                the first queue id; keyed region only\n"
    "      ring=R                the ring; keyed region only\n"
    "\n"
    "ring --preset <name>\n"
    "\n"
    "  Run a whole named run: its ringer, ringee, region, writes and expected result. <name> is required and\n"
    "  nothing else may be given with it.\n"
    "  `presets` lists them, each with the explicit ring command that does the same.\n",
    out);
}
/* clang-format on */

int main(int argc, char** argv) {
  if (argc < 2) {
    usage(stderr);
    return 2;
  }
  if (!strcmp(argv[1], "help") || !strcmp(argv[1], "--help") ||
      !strcmp(argv[1], "-h")) {
    usage(stdout);
    return 0;
  }
  const char* cmd = argv[1];
  if (!strcmp(cmd, "presets"))
    return cmd_presets(); /* needs no device, so no root */
  find_device(VFU_DB_PCI_VENDOR, VFU_DB_PCI_DEV_RINGEE, &ringee);
  find_device(VFU_DB_PCI_VENDOR, VFU_DB_PCI_DEV_RINGER, &ringer);
  if (!strcmp(cmd, "info"))
    return cmd_info();
  if (!strcmp(cmd, "reset")) {
    if (!need_ringee())
      return 1;
    wr32(&ringee, VFU_DB_RE_CTRL, 1);
    return 0;
  }
  if (!strcmp(cmd, "config"))
    return cmd_config(argc - 2, argv + 2);
  if (!strcmp(cmd, "dump"))
    return cmd_dump(argc - 2, argv + 2);
  if (!strcmp(cmd, "log"))
    return cmd_log(argc - 2, argv + 2);
  if (!strcmp(cmd, "ring"))
    return cmd_ring(argc - 2, argv + 2);
  if (!strcmp(cmd, "selftest"))
    return cmd_selftest();
  usage(stderr);
  return 2;
}
