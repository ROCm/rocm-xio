/* Copyright (c) 2026 IBM Corporation
 *
 * SPDX-License-Identifier: MIT
 *
 * @file nvme-kv.h
 * @brief NVMe Key-Value Command Set support for the nvme-ep endpoint.
 *
 * GPU-initiated NVMe KV Store/Retrieve. The on-the-wire SQE layout below follows
 * the NVMe Key-Value Command Set specification, so it interoperates with any
 * conformant KV controller (validated against the SPDK kvdev target):
 *
 *   - Opcode:        Store = 0x01, Retrieve = 0x02. These are numerically equal
 *                    to block Write/Read; the controller routes them as KV
 *                    because the target namespace's Command Set Identifier
 *                    (CSI) is Key Value (0x1).
 *   - Key length:    CDW11 bits 7:0; request options in bits 15:8.
 *   - Key bytes:     CDW2/CDW3 hold key bytes 0..7, CDW14/CDW15 hold bytes
 *                    8..15 (a flat little-endian 16-byte image; max key 16 B).
 *   - Value size:    CDW10 (value length for Store, host-buffer size for
 *                    Retrieve). Must be <= the buffer described by the DPTR.
 *   - Value data:    DPTR / PRP1 / PRP2, exactly like a block transfer.
 *   - Retrieve done: the CQE's DW0 carries the TRUE stored value length (which
 *                    may exceed CDW10 -> the value was truncated to the buffer;
 *                    the command still completes SUCCESS).
 */

#ifndef NVME_KV_H
#define NVME_KV_H

#include <stdint.h>

#include <hip/hip_runtime.h> /* __host__ / __device__ */

#include "nvme-ep-generated.h" /* struct nvme_sqe, NVME_SC_* */

/** @brief NVMe Key-Value I/O opcodes (KV Command Set). */
enum {
  nvme_kv_cmd_store = 0x01,    /**< KV Store. */
  nvme_kv_cmd_retrieve = 0x02, /**< KV Retrieve. */
  nvme_kv_cmd_list = 0x06,     /**< KV List. */
  nvme_kv_cmd_delete = 0x10,   /**< KV Delete. */
  nvme_kv_cmd_exist = 0x14,    /**< KV Exist. */
};

/** @brief Maximum KV key length in bytes (inline in CDW2/3/14/15). */
#define NVME_KV_KEY_MAX_LEN 16

/* KV status codes (SCT = Generic). */
#define NVME_KV_SC_INVALID_VALUE_SIZE 0x85
#define NVME_KV_SC_INVALID_KEY_SIZE 0x86
#define NVME_KV_SC_KEY_DOES_NOT_EXIST 0x87
#define NVME_KV_SC_KEY_EXISTS 0x89

/**
 * @brief Encode the KV-specific SQE fields (key, key length, value size).
 *
 * The caller must already have set opcode, command_id, nsid, and the DPTR
 * (PRP1/PRP2) pointing at the value buffer. This fills only the KV metadata
 * dwords, leaving DPTR untouched.
 *
 * @param sqe       SQE to fill (writes cdw2/cdw3/cdw10/cdw11/cdw12/cdw13/
 *                  cdw14/cdw15, flags, metadata).
 * @param key       Up to 16 key bytes packed little-endian as 4 x uint32.
 * @param key_len   Key length in bytes (1..16).
 * @param value_len Value size (Store) or host-buffer size (Retrieve) -> CDW10.
 *
 * @note Callable from host and device code.
 */
__host__ __device__ static inline void kvSqeSetup(struct nvme_sqe* sqe,
                                                  const uint32_t key[4],
                                                  uint32_t key_len,
                                                  uint32_t value_len) {
  /* Key: low 8 bytes -> CDW2/CDW3, high 8 bytes -> CDW14/CDW15. */
  sqe->cdw2 = key[0];
  sqe->cdw3 = key[1];
  sqe->cdw14 = key[2];
  sqe->cdw15 = key[3];

  /* CDW11: key length [7:0], request options [15:8] (0 = unconditional). */
  sqe->cdw11 = (key_len & 0xFFu);

  /* CDW10: value size / host buffer size. */
  sqe->cdw10 = value_len;

  /* CDW12/CDW13 unused for plain Store/Retrieve. */
  sqe->cdw12 = 0;
  sqe->cdw13 = 0;

  sqe->flags = 0;
  sqe->metadata = 0;
}

#endif /* NVME_KV_H */
