/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for the NVMe Key-Value helper functions defined in nvme-kv.h:
 * kvSqeSetup, kvExecSqeSetup, kvSqeSetupPacked, opcode constants, status
 * code constants, key-length limits, and the packed key layout stride.
 *
 * All functions under test are __host__ __device__ inline helpers and require
 * no hardware, no GPU, and no NVMe device.
 */

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <hip/hip_runtime.h>

#include "nvme-ep.h"
#include "nvme-kv.h"
#include "xio-test-assert.h"

using namespace xio::nvme_ep;

/* ------------------------------------------------------------------ */
/* Opcode and constant sanity checks                                   */
/* ------------------------------------------------------------------ */

int test_kv_opcodes() {
  /* NVMe KV spec: Store=0x01, Retrieve=0x02, Delete=0x10, Exist=0x14. */
  ASSERT_EQ((int)nvme_kv_cmd_store, 0x01);
  ASSERT_EQ((int)nvme_kv_cmd_retrieve, 0x02);
  ASSERT_EQ((int)nvme_kv_cmd_list, 0x06);
  ASSERT_EQ((int)nvme_kv_cmd_delete, 0x10);
  ASSERT_EQ((int)nvme_kv_cmd_exist, 0x14);
  ASSERT_EQ((int)nvme_kv_cmd_exec, 0x83);
  printf("PASS: test_kv_opcodes\n");
  return 0;
}

int test_kv_status_codes() {
  ASSERT_EQ(NVME_KV_SC_INVALID_VALUE_SIZE, 0x85);
  ASSERT_EQ(NVME_KV_SC_INVALID_KEY_SIZE, 0x86);
  ASSERT_EQ(NVME_KV_SC_KEY_DOES_NOT_EXIST, 0x87);
  ASSERT_EQ(NVME_KV_SC_KEY_EXISTS, 0x89);
  printf("PASS: test_kv_status_codes\n");
  return 0;
}

int test_kv_key_max_len() {
  ASSERT_EQ(NVME_KV_KEY_MAX_LEN, 16);
  ASSERT_EQ(NVME_KV_PACKED_WORDS_PER_KEY, 5);
  printf("PASS: test_kv_key_max_len\n");
  return 0;
}

/* ------------------------------------------------------------------ */
/* kvSqeSetup — key encoding                                           */
/* ------------------------------------------------------------------ */

int test_kvSqeSetup_short_key() {
  /* 3-byte key "abc" -> packed as { 'a','b','c',0, 0,0,0,0, ... } */
  uint8_t raw[16] = {'a', 'b', 'c', 0};
  uint32_t key[4] = {};
  memcpy(key, raw, 16);

  struct nvme_sqe sqe = {};
  sqe.opcode = (uint8_t)nvme_kv_cmd_store;
  sqe.nsid = 1;

  kvSqeSetup(&sqe, key, 3, 512);

  /* CDW2 holds bytes 0..3 little-endian: 'a'=0x61, 'b'=0x62, 'c'=0x63 */
  ASSERT_EQ(sqe.cdw2, (uint32_t)0x00636261u);
  ASSERT_EQ(sqe.cdw3, 0u);
  ASSERT_EQ(sqe.cdw14, 0u);
  ASSERT_EQ(sqe.cdw15, 0u);

  /* CDW11[7:0] = key length */
  ASSERT_EQ(sqe.cdw11 & 0xFFu, 3u);

  /* CDW10 = value size */
  ASSERT_EQ(sqe.cdw10, 512u);

  /* CDW12/13 must be zero for plain Store/Retrieve */
  ASSERT_EQ(sqe.cdw12, 0u);
  ASSERT_EQ(sqe.cdw13, 0u);

  ASSERT_EQ(sqe.flags, 0);
  ASSERT_EQ(sqe.metadata, 0u);

  printf("PASS: test_kvSqeSetup_short_key\n");
  return 0;
}

int test_kvSqeSetup_max_key() {
  /* 16-byte key: bytes 0-7 in CDW2/3, bytes 8-15 in CDW14/15. */
  uint8_t raw[16];
  for (int i = 0; i < 16; i++)
    raw[i] = (uint8_t)(i + 1);
  uint32_t key[4] = {};
  memcpy(key, raw, 16);

  struct nvme_sqe sqe = {};
  kvSqeSetup(&sqe, key, 16, 4096);

  /* CDW2 = bytes 0..3: 0x01020304 LE = 0x04030201 */
  ASSERT_EQ(sqe.cdw2, (uint32_t)0x04030201u);
  ASSERT_EQ(sqe.cdw3, (uint32_t)0x08070605u);
  ASSERT_EQ(sqe.cdw14, (uint32_t)0x0c0b0a09u);
  ASSERT_EQ(sqe.cdw15, (uint32_t)0x100f0e0du);

  ASSERT_EQ(sqe.cdw11 & 0xFFu, 16u);
  ASSERT_EQ(sqe.cdw10, 4096u);

  printf("PASS: test_kvSqeSetup_max_key\n");
  return 0;
}

int test_kvSqeSetup_retrieve_value_len() {
  /* For Retrieve, CDW10 is the HOST BUFFER SIZE (cap), not the stored length.
   */
  uint32_t key[4] = {0x11223344u, 0, 0, 0};
  struct nvme_sqe sqe = {};
  sqe.opcode = (uint8_t)nvme_kv_cmd_retrieve;

  kvSqeSetup(&sqe, key, 4, 65536);

  ASSERT_EQ(sqe.cdw10, 65536u);
  ASSERT_EQ(sqe.cdw2, 0x11223344u);
  ASSERT_EQ(sqe.cdw11 & 0xFFu, 4u);

  printf("PASS: test_kvSqeSetup_retrieve_value_len\n");
  return 0;
}

int test_kvSqeSetup_zero_key_len() {
  /* key_len=0 is unusual but must not crash; CDW11[7:0] becomes 0. */
  uint32_t key[4] = {};
  struct nvme_sqe sqe = {};
  kvSqeSetup(&sqe, key, 0, 0);
  ASSERT_EQ(sqe.cdw11 & 0xFFu, 0u);
  ASSERT_EQ(sqe.cdw10, 0u);
  printf("PASS: test_kvSqeSetup_zero_key_len\n");
  return 0;
}

int test_kvSqeSetup_does_not_touch_dptr() {
  /* kvSqeSetup must leave PRP1/PRP2 alone — caller sets DPTR. */
  uint32_t key[4] = {1, 2, 3, 4};
  struct nvme_sqe sqe = {};
  sqe.dptr.prp.prp1 = 0xDEADBEEFCAFEBABEULL;
  sqe.dptr.prp.prp2 = 0x0102030405060708ULL;

  kvSqeSetup(&sqe, key, 4, 512);

  ASSERT_EQ(sqe.dptr.prp.prp1, (uint64_t)0xDEADBEEFCAFEBABEULL);
  ASSERT_EQ(sqe.dptr.prp.prp2, (uint64_t)0x0102030405060708ULL);
  printf("PASS: test_kvSqeSetup_does_not_touch_dptr\n");
  return 0;
}

int test_kvSqeSetup_does_not_touch_opcode_nsid() {
  /* kvSqeSetup must not overwrite opcode, command_id, nsid. */
  uint32_t key[4] = {};
  struct nvme_sqe sqe = {};
  sqe.opcode = (uint8_t)nvme_kv_cmd_store;
  sqe.command_id = 42;
  sqe.nsid = 7;

  kvSqeSetup(&sqe, key, 1, 1);

  ASSERT_EQ(sqe.opcode, (uint8_t)nvme_kv_cmd_store);
  ASSERT_EQ(sqe.command_id, (uint16_t)42u);
  ASSERT_EQ(sqe.nsid, (uint32_t)7u);
  printf("PASS: test_kvSqeSetup_does_not_touch_opcode_nsid\n");
  return 0;
}

/* ------------------------------------------------------------------ */
/* kvExecSqeSetup                                                      */
/* ------------------------------------------------------------------ */

int test_kvExecSqeSetup_basic() {
  struct nvme_sqe sqe = {};
  sqe.opcode = (uint8_t)nvme_kv_cmd_exec;
  sqe.dptr.prp.prp1 = 0xABCDEF00u;

  kvExecSqeSetup(&sqe, 128, 4096, 5);

  /* CDW10 = payload length, CDW12 = osize, CDW13 = op_id */
  ASSERT_EQ(sqe.cdw10, 128u);
  ASSERT_EQ(sqe.cdw12, 4096u);
  ASSERT_EQ(sqe.cdw13, 5u);

  /* Inline key dwords reserved (zero) for Exec */
  ASSERT_EQ(sqe.cdw2, 0u);
  ASSERT_EQ(sqe.cdw3, 0u);
  ASSERT_EQ(sqe.cdw11, 0u);
  ASSERT_EQ(sqe.cdw14, 0u);
  ASSERT_EQ(sqe.cdw15, 0u);

  /* DPTR untouched */
  ASSERT_EQ(sqe.dptr.prp.prp1, (uint64_t)0xABCDEF00u);

  ASSERT_EQ(sqe.flags, 0);
  ASSERT_EQ(sqe.metadata, 0u);
  printf("PASS: test_kvExecSqeSetup_basic\n");
  return 0;
}

int test_kvExecSqeSetup_large_op_id() {
  struct nvme_sqe sqe = {};
  kvExecSqeSetup(&sqe, 0, 0, 0xFFFFFFFFu);
  ASSERT_EQ(sqe.cdw13, 0xFFFFFFFFu);
  printf("PASS: test_kvExecSqeSetup_large_op_id\n");
  return 0;
}

/* ------------------------------------------------------------------ */
/* kvSqeSetupPacked — packed multi-key layout                          */
/* ------------------------------------------------------------------ */

int test_kvSqeSetupPacked_roundtrip() {
  /* Build one packed key: words 0-3 = 16-byte key image, word 4 = length. */
  uint32_t packed[NVME_KV_PACKED_WORDS_PER_KEY] = {};
  uint8_t raw[16] = {'x', 'y', 'z', 0};
  memcpy(packed, raw, 16);
  packed[4] = 3; /* key length */

  struct nvme_sqe sqe = {};
  kvSqeSetupPacked(&sqe, packed, 256);

  /* Must match the result of calling kvSqeSetup directly with the same args. */
  struct nvme_sqe ref = {};
  kvSqeSetup(&ref, packed, 3, 256);

  ASSERT_EQ(sqe.cdw2, ref.cdw2);
  ASSERT_EQ(sqe.cdw3, ref.cdw3);
  ASSERT_EQ(sqe.cdw10, ref.cdw10);
  ASSERT_EQ(sqe.cdw11, ref.cdw11);
  ASSERT_EQ(sqe.cdw14, ref.cdw14);
  ASSERT_EQ(sqe.cdw15, ref.cdw15);

  printf("PASS: test_kvSqeSetupPacked_roundtrip\n");
  return 0;
}

int test_kvSqeSetupPacked_stride() {
  /* The stride is NVME_KV_PACKED_WORDS_PER_KEY uint32 = 20 bytes per key.
   * Verify that pointer arithmetic into a packed array gives the right key. */
  uint32_t manifest[2 * NVME_KV_PACKED_WORDS_PER_KEY] = {};

  /* Key 0: "aa" (len 2) */
  manifest[0] = 0x61616161u; /* 'aaaa' */
  manifest[4] = 2;

  /* Key 1: "bb" (len 2) */
  manifest[NVME_KV_PACKED_WORDS_PER_KEY + 0] = 0x62626262u;
  manifest[NVME_KV_PACKED_WORDS_PER_KEY + 4] = 2;

  struct nvme_sqe sqe0 = {}, sqe1 = {};
  kvSqeSetupPacked(&sqe0, manifest, 100);
  kvSqeSetupPacked(&sqe1, manifest + NVME_KV_PACKED_WORDS_PER_KEY, 200);

  ASSERT_EQ(sqe0.cdw2, 0x61616161u);
  ASSERT_EQ(sqe0.cdw11 & 0xFFu, 2u);
  ASSERT_EQ(sqe0.cdw10, 100u);

  ASSERT_EQ(sqe1.cdw2, 0x62626262u);
  ASSERT_EQ(sqe1.cdw11 & 0xFFu, 2u);
  ASSERT_EQ(sqe1.cdw10, 200u);

  printf("PASS: test_kvSqeSetupPacked_stride\n");
  return 0;
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */

int main() {
  /* Opcode / constant checks */
  test_kv_opcodes();
  test_kv_status_codes();
  test_kv_key_max_len();

  /* kvSqeSetup */
  test_kvSqeSetup_short_key();
  test_kvSqeSetup_max_key();
  test_kvSqeSetup_retrieve_value_len();
  test_kvSqeSetup_zero_key_len();
  test_kvSqeSetup_does_not_touch_dptr();
  test_kvSqeSetup_does_not_touch_opcode_nsid();

  /* kvExecSqeSetup */
  test_kvExecSqeSetup_basic();
  test_kvExecSqeSetup_large_op_id();

  /* kvSqeSetupPacked */
  test_kvSqeSetupPacked_roundtrip();
  test_kvSqeSetupPacked_stride();

  printf("All NVMe KV helper tests passed.\n");
  return 0;
}
