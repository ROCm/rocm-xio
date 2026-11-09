/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * vfu-doorbell: register layout and value encoding shared by the vfio-user
 * "ringee" and "ringer" test devices and the guest-side xio-doorbell tool.
 *
 * Both devices are plain PCI devices with a single BAR0 of little-endian
 * registers; there is no guest driver. The guest tool maps BAR0 through
 * sysfs (resourceN) and reads physical addresses from the sysfs resource file.
 */
#pragma once

#include <stdint.h>

/* PCI identity. Not an allocated vendor ID: both devices exist only inside a
 * test VM, and the guest tool matches on vendor and device together. */
#define VFU_DB_PCI_VENDOR 0x1de0u
#define VFU_DB_PCI_DEV_RINGEE 0x0001u
#define VFU_DB_PCI_DEV_RINGER 0x0002u

#define VFU_DB_PAGE 0x1000u

/* ------------------------------------------------------------------------ */
/* Ringee device                                                             */
/* ------------------------------------------------------------------------ */

/*
 * BAR0 layout (64 KiB):
 *   0x0000  control page: identity, counters, region table, state window
 *   0x1000  write log, read-only ring of vfu_db_log_entry
 *   0x2000+ doorbell windows, placed by the region table
 *
 * A doorbell window is an overlay: a byte range of BAR0 given a semantic
 * model, a slot width and a stride. A write inside a window is decoded
 * according to the model and recorded in per-key state that the guest can read
 * back through the state window (VFU_DB_RE_STATE_*).
 */
#define VFU_DB_RE_BAR_SIZE 0x10000u
#define VFU_DB_RE_MAX_REGIONS 8u
#define VFU_DB_RE_WINDOW_BASE 0x2000u
#define VFU_DB_RE_LOG_ENTRIES 128u
#define VFU_DB_RE_MAGIC_VALUE 0x45524244u /* "DBRE" */
#define VFU_DB_RE_VERSION_VALUE 1u

/* Control page registers. u32 unless noted. */
#define VFU_DB_RE_MAGIC 0x000u
#define VFU_DB_RE_VERSION 0x004u
#define VFU_DB_RE_NREGIONS 0x008u
#define VFU_DB_RE_LOG_ENTRIES_REG 0x00cu
#define VFU_DB_RE_CTRL 0x010u /* write bit0: reset counters, state, log */
#define VFU_DB_RE_TOTAL_WRITES 0x018u /* u64: writes that matched a slot */
#define VFU_DB_RE_TOTAL_BAD 0x020u    /* u64: writes that matched no slot */
#define VFU_DB_RE_LOG_COUNT 0x028u    /* u64: entries ever logged */

/* State window: select a region and a key, then read the key's state. */
#define VFU_DB_RE_STATE_REGION 0x040u /* u32 */
#define VFU_DB_RE_STATE_KEY 0x044u    /* u32 */
#define VFU_DB_RE_ST_LAST 0x048u      /* u64: last value written */
#define VFU_DB_RE_ST_COUNT 0x050u     /* u64: writes seen for this key */
#define VFU_DB_RE_ST_HEAD 0x058u      /* u64: index after the last write */
#define VFU_DB_RE_ST_REGRESS 0x060u   /* u64: index went backwards */
#define VFU_DB_RE_ST_SEQ_GAPS 0x068u  /* u64: sequence numbers never seen */
#define VFU_DB_RE_ST_SEQ_OOO 0x070u   /* u64: late or duplicate sequence */
#define VFU_DB_RE_ST_LAST_SEQ 0x078u  /* u64: last in-order sequence */

/* Region table: VFU_DB_RE_REGION_TABLE + region * VFU_DB_RE_REGION_STRIDE. */
#define VFU_DB_RE_REGION_TABLE 0x100u
#define VFU_DB_RE_REGION_STRIDE 0x40u
#define VFU_DB_RE_RG_MODEL 0x00u  /* u32: VFU_DB_MODEL_*; write last */
#define VFU_DB_RE_RG_FLAGS 0x04u  /* u32: VFU_DB_FLAG_* */
#define VFU_DB_RE_RG_BASE 0x08u   /* u64: BAR0 offset of the window */
#define VFU_DB_RE_RG_SIZE 0x10u   /* u64: window size in bytes */
#define VFU_DB_RE_RG_WIDTH 0x18u  /* u32: slot width: 1, 2, 4 or 8 */
#define VFU_DB_RE_RG_STRIDE 0x1cu /* u32: bytes between slot starts */
#define VFU_DB_RE_RG_WRITES 0x20u /* u64, read-only */
#define VFU_DB_RE_RG_BAD 0x28u    /* u64, read-only */
#define VFU_DB_RE_RG_GAPS 0x30u   /* u64, read-only: sum over keys */
#define VFU_DB_RE_RG_OOO 0x38u    /* u64, read-only: sum over keys */

#define VFU_DB_RE_LOG_BASE 0x1000u

/*
 * Doorbell semantic models.
 *
 * INDEX  one register per queue. The value is a queue position in bits
 *        [15:0]. The key is the slot. NVMe doorbells: slot 2q is queue q's
 *        SQ tail and slot 2q+1 its CQ head with width 4, stride 4.
 * KEYED  one 8-byte register per queue type with the queue carried in the
 *        value: index [15:0], ring [18:16], queue id [47:24]. The key is
 *        (slot, queue id & 0xff, ring). ionic doorbells.
 * EVENT  every write counts; the key is the slot. For writes where the
 *        number of writes, not the value, is what matters.
 */
#define VFU_DB_MODEL_OFF 0u
#define VFU_DB_MODEL_INDEX 1u
#define VFU_DB_MODEL_KEYED 2u
#define VFU_DB_MODEL_EVENT 3u

/* Region flag: the writer puts a per-key sequence number in the bits above the
 * index so the ringee can count lost and reordered writes. Width 4: bits
 * [31:16]. Width 8: bits [63:48]. Not available for widths 1 and 2. */
#define VFU_DB_FLAG_SEQ (1u << 0)

#define VFU_DB_KEYED_KEYS_PER_SLOT 2048u /* 256 queue ids * 8 rings */

struct vfu_db_log_entry {
  uint64_t arrival; /* 1-based arrival number; 0 means empty */
  uint64_t value;
  uint32_t offset; /* BAR0 offset of the write */
  uint16_t size;
  uint16_t region; /* 0xffff if the write matched no region */
  uint64_t time_ns;
};

/* ------------------------------------------------------------------------ */
/* Ringer device                                                             */
/* ------------------------------------------------------------------------ */

/* BAR0 is one page. Program the job registers, then write 1 to GO. */
#define VFU_DB_R_BAR_SIZE VFU_DB_PAGE
#define VFU_DB_R_MAGIC_VALUE 0x47524244u /* "DBRG" */
#define VFU_DB_R_VERSION_VALUE 1u

#define VFU_DB_R_MAGIC 0x000u
#define VFU_DB_R_VERSION 0x004u
#define VFU_DB_R_GPA 0x010u      /* u64: guest physical address of slot 0 */
#define VFU_DB_R_VALUE 0x018u    /* u64: starting index (low 16 bits) */
#define VFU_DB_R_STEP 0x020u     /* u64: signed index step per write to a key */
#define VFU_DB_R_COUNT 0x028u    /* u32: number of writes */
#define VFU_DB_R_SIZE 0x02cu     /* u32: write size: 1, 2, 4 or 8 */
#define VFU_DB_R_STRIDE 0x030u   /* u64: GPA bytes between slots */
#define VFU_DB_R_NSLOTS 0x038u   /* u32: slots cycled through */
#define VFU_DB_R_FLAGS 0x03cu    /* u32: VFU_DB_RF_* */
#define VFU_DB_R_QIDS 0x040u     /* u32: queue ids cycled through (keyed) */
#define VFU_DB_R_QID0 0x044u     /* u32: first queue id (keyed) */
#define VFU_DB_R_RING 0x048u     /* u32: ring field (keyed) */
#define VFU_DB_R_PATTERN 0x04cu  /* u32: VFU_DB_PAT_* */
#define VFU_DB_R_DELAY_NS 0x050u /* u32: sleep between writes */
#define VFU_DB_R_MODE 0x054u     /* u32: VFU_DB_MODE_* */
#define VFU_DB_R_GO 0x060u       /* u32, write-only: 1 starts the job */
#define VFU_DB_R_STATUS 0x064u   /* u32: VFU_DB_ST_* */
#define VFU_DB_R_SENT 0x068u     /* u64: writes that succeeded */
#define VFU_DB_R_ERRORS 0x070u   /* u64: writes that failed */
#define VFU_DB_R_ERRNO 0x078u    /* u32: errno of the last failure */
#define VFU_DB_R_ELAPSED 0x080u  /* u64: job time, nanoseconds */
#define VFU_DB_R_MAX_LAT 0x088u  /* u64: slowest single write, nanoseconds */
/*
 * Completion without MMIO: when DONE_GPA is non-zero the ringer stores the
 * 8-byte DONE_VALUE there (guest RAM, a plain DMA-mapped store, no protocol
 * message) after the job finishes. A guest that polls that word never touches
 * the ringer's BAR while a job runs. Polling STATUS over MMIO instead can
 * deadlock against the ringer's synchronous DMA_WRITE; see README.md.
 */
#define VFU_DB_R_DONE_GPA 0x090u   /* u64 */
#define VFU_DB_R_DONE_VALUE 0x098u /* u64 */

/* Ringer flags. */
#define VFU_DB_RF_SEQ (1u << 0)   /* insert per-key sequence numbers */
#define VFU_DB_RF_KEYED (1u << 1) /* encode ring and queue id (size 8) */
#define VFU_DB_RF_INLINE                                                       \
  (1u << 2)                        /* write from inside the BAR callback:      \
                                      reproduces the single-socket deadlock */
#define VFU_DB_RF_POSTED (1u << 3) /* reserved: no posted API yet */

#define VFU_DB_PAT_MONOTONIC 0u /* index += step per write to a key */
#define VFU_DB_PAT_REPEAT 1u    /* same index every time */
#define VFU_DB_PAT_RANDOM 2u    /* pseudo-random index */

/* How the ringer delivers a write. */
#define VFU_DB_MODE_MMIO                                                       \
  0u /* vfu_mmio_write: DMA_WRITE to any GPA; reaches                          \
        device registers (the trap-style writer) */
#define VFU_DB_MODE_SHM                                                        \
  1u /* store into DMA-mapped guest memory: reaches                            \
        RAM only (the memory-style writer) */

#define VFU_DB_ST_IDLE 0u
#define VFU_DB_ST_RUNNING 1u
#define VFU_DB_ST_DONE 2u
#define VFU_DB_ST_ERROR 3u

/* ------------------------------------------------------------------------ */
/* Value encoding                                                            */
/* ------------------------------------------------------------------------ */

/**
 * @brief Build the value a writer stores for one doorbell write.
 * @param width Write width in bytes: 1, 2, 4 or 8.
 * @param keyed Encode ring and queue id (needs width 8).
 * @param idx Queue position; only the low 16 bits are used.
 * @param ring Ring field, 3 bits (keyed only).
 * @param qid Queue id, 24 bits (keyed only).
 * @param seq Sequence number, 16 bits (used when seq_en is set).
 * @param seq_en Place seq above the index; ignored for widths 1 and 2.
 * @return The value, truncated to the width.
 */
static inline uint64_t vfu_db_pack(unsigned width, int keyed, uint32_t idx,
                                   uint32_t ring, uint32_t qid, uint32_t seq,
                                   int seq_en) {
  uint64_t v = idx & 0xffffu;
  if (width == 1)
    return idx & 0xffu;
  if (keyed) {
    v |= (uint64_t)(ring & 7u) << 16;
    v |= (uint64_t)(qid & 0xffffffu) << 24;
    if (seq_en)
      v |= (uint64_t)(seq & 0xffffu) << 48;
    return v;
  }
  if (seq_en && width >= 4)
    v |= (uint64_t)(seq & 0xffffu) << (width * 8u - 16u);
  return v;
}
