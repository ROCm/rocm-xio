/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for nvme-ep helper functions:
 * sqeSetup, calculatePrps, cqeOk, cqeStatusCode,
 * cqeStatusType, sqeRead/sqeWrite, cqeRead/cqeWrite,
 * NVME_CQE_STATUS_* macros, NVME_STATUS_MAKE
 * round-trip, and dataPattern.
 */

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <hip/hip_runtime.h>

#include "nvme-ep.h"
#include "xio-data-pattern.hpp"
#include "xio-test-assert.h"

using namespace xio::nvme_ep;

/* ---- sqeSetup tests ---- */

int test_sqeSetup_basic() {
  struct nvme_sqe sqe = {};
  sqe.opcode = nvme_cmd_read;
  sqe.command_id = 1;
  sqe.nsid = 1;
  sqe.dptr.prp.prp1 = 0x1000;

  sqeSetup(&sqe, 100, 8);

  ASSERT_EQ(sqe.cdw10, 100u);
  ASSERT_EQ(sqe.cdw11, 0u);
  ASSERT_EQ(sqe.cdw12, 7u);
  ASSERT_EQ(sqe.flags, 0);
  ASSERT_EQ(sqe.cdw2, 0u);
  ASSERT_EQ(sqe.cdw3, 0u);
  ASSERT_EQ(sqe.metadata, 0u);
  ASSERT_EQ(sqe.cdw13, 0u);
  ASSERT_EQ(sqe.cdw14, 0u);
  ASSERT_EQ(sqe.cdw15, 0u);
  ASSERT_EQ(sqe.dptr.prp.prp1, 0x1000u);
  return 0;
}

int test_sqeSetup_large_lba() {
  struct nvme_sqe sqe = {};
  sqe.opcode = nvme_cmd_write;
  sqe.command_id = 2;
  sqe.nsid = 1;

  uint64_t lba = 0x0000000100000042ULL;
  sqeSetup(&sqe, lba, 1);

  ASSERT_EQ(sqe.cdw10, 0x00000042u);
  ASSERT_EQ(sqe.cdw11, 0x00000001u);
  ASSERT_EQ(sqe.cdw12, 0u);
  return 0;
}

int test_sqeSetup_zero_preserves() {
  struct nvme_sqe sqe = {};
  sqe.cdw10 = 0xAAAAAAAA;
  sqe.cdw11 = 0xBBBBBBBB;
  sqe.cdw12 = 0xCCCCCCCC;

  sqeSetup(&sqe, 0, 0);

  ASSERT_EQ(sqe.cdw10, 0xAAAAAAAAu);
  ASSERT_EQ(sqe.cdw11, 0xBBBBBBBBu);
  ASSERT_EQ(sqe.cdw12, 0xCCCCCCCCu);
  ASSERT_EQ(sqe.flags, 0);
  ASSERT_EQ(sqe.cdw13, 0u);
  return 0;
}

int test_sqeSetup_nlb_one() {
  struct nvme_sqe sqe = {};
  sqeSetup(&sqe, 50, 1);
  ASSERT_EQ(sqe.cdw12, 0u);
  ASSERT_EQ(sqe.cdw10, 50u);
  return 0;
}

/* ---- calculatePrps tests ---- */

int test_prp_single_page_aligned() {
  struct nvme_sqe sqe = {};
  calculatePrps(0x10000, 512, &sqe);
  ASSERT_EQ(sqe.dptr.prp.prp1, 0x10000u);
  ASSERT_EQ(sqe.dptr.prp.prp2, 0u);
  return 0;
}

int test_prp_single_page_fits() {
  struct nvme_sqe sqe = {};
  calculatePrps(0x10000, NVME_PAGE_SIZE, &sqe);
  ASSERT_EQ(sqe.dptr.prp.prp1, 0x10000u);
  ASSERT_EQ(sqe.dptr.prp.prp2, 0u);
  return 0;
}

int test_prp_crosses_page_boundary() {
  struct nvme_sqe sqe = {};
  uint64_t addr = 0x10F00;
  uint32_t size = 4096;
  calculatePrps(addr, size, &sqe);
  ASSERT_EQ(sqe.dptr.prp.prp1, addr);
  ASSERT_EQ(sqe.dptr.prp.prp2, 0x11000u);
  return 0;
}

int test_prp_unaligned_within_page() {
  struct nvme_sqe sqe = {};
  uint64_t addr = 0x10200;
  uint32_t size = 256;
  calculatePrps(addr, size, &sqe);
  ASSERT_EQ(sqe.dptr.prp.prp1, addr);
  ASSERT_EQ(sqe.dptr.prp.prp2, 0u);
  return 0;
}

int test_prp_at_page_boundary() {
  struct nvme_sqe sqe = {};
  uint64_t addr = 0x11000;
  uint32_t size = NVME_PAGE_SIZE;
  calculatePrps(addr, size, &sqe);
  ASSERT_EQ(sqe.dptr.prp.prp1, addr);
  ASSERT_EQ(sqe.dptr.prp.prp2, 0u);
  return 0;
}

int test_prp_two_full_pages() {
  struct nvme_sqe sqe = {};
  uint64_t addr = 0x20000;
  uint32_t size = 2 * NVME_PAGE_SIZE;
  calculatePrps(addr, size, &sqe);
  ASSERT_EQ(sqe.dptr.prp.prp1, addr);
  ASSERT_EQ(sqe.dptr.prp.prp2, 0x21000u);
  return 0;
}

/* ---- cqeOk / cqeStatusCode / cqeStatusType ---- */

int test_cqeOk_success() {
  struct nvme_cqe cqe = {};
  cqe.status = NVME_STATUS_MAKE(0, NVME_SC_SUCCESS, NVME_SCT_GENERIC);
  ASSERT_TRUE(cqeOk(&cqe));
  return 0;
}

int test_cqeOk_success_with_phase() {
  struct nvme_cqe cqe = {};
  cqe.status = NVME_STATUS_MAKE(1, NVME_SC_SUCCESS, NVME_SCT_GENERIC);
  ASSERT_TRUE(cqeOk(&cqe));
  return 0;
}

int test_cqeOk_error_sc() {
  struct nvme_cqe cqe = {};
  cqe.status = NVME_STATUS_MAKE(0, NVME_SC_LBA_RANGE, NVME_SCT_GENERIC);
  ASSERT_TRUE(!cqeOk(&cqe));
  return 0;
}

int test_cqeOk_error_sct() {
  struct nvme_cqe cqe = {};
  cqe.status = NVME_STATUS_MAKE(0, NVME_SC_SUCCESS, NVME_SCT_CMD_SPECIFIC);
  ASSERT_TRUE(!cqeOk(&cqe));
  return 0;
}

int test_cqeOk_vendor_error() {
  struct nvme_cqe cqe = {};
  cqe.status = NVME_STATUS_MAKE(0, 0x42, NVME_SCT_VENDOR);
  ASSERT_TRUE(!cqeOk(&cqe));
  return 0;
}

int test_cqeStatusCode_extraction() {
  struct nvme_cqe cqe = {};
  cqe.status = NVME_STATUS_MAKE(0, 0x80, NVME_SCT_GENERIC);
  ASSERT_EQ(cqeStatusCode(&cqe), 0x80u);
  ASSERT_EQ(cqeStatusType(&cqe), (uint8_t)NVME_SCT_GENERIC);
  return 0;
}

int test_cqeStatusType_extraction() {
  struct nvme_cqe cqe = {};
  cqe.status = NVME_STATUS_MAKE(1, 0x02, NVME_SCT_MEDIA_ERROR);
  ASSERT_EQ(cqeStatusCode(&cqe), 0x02u);
  ASSERT_EQ(cqeStatusType(&cqe), (uint8_t)NVME_SCT_MEDIA_ERROR);
  return 0;
}

/* ---- NVME_CQE_STATUS_* macro tests ---- */

int test_status_macros() {
  uint16_t status = 0xFFFF;
  ASSERT_EQ(NVME_CQE_STATUS_PHASE(status), 1u);
  ASSERT_EQ(NVME_CQE_STATUS_SC(status), 0xFFu);
  ASSERT_EQ(NVME_CQE_STATUS_SCT(status), 0x7u);
  ASSERT_EQ(NVME_CQE_STATUS_CRD(status), 0x3u);
  ASSERT_EQ(NVME_CQE_STATUS_MORE(status), 0x1u);
  ASSERT_EQ(NVME_CQE_STATUS_DNR(status), 0x1u);

  status = 0x0000;
  ASSERT_EQ(NVME_CQE_STATUS_PHASE(status), 0u);
  ASSERT_EQ(NVME_CQE_STATUS_SC(status), 0u);
  ASSERT_EQ(NVME_CQE_STATUS_SCT(status), 0u);
  ASSERT_EQ(NVME_CQE_STATUS_CRD(status), 0u);
  ASSERT_EQ(NVME_CQE_STATUS_MORE(status), 0u);
  ASSERT_EQ(NVME_CQE_STATUS_DNR(status), 0u);

  status = 0x0001;
  ASSERT_EQ(NVME_CQE_STATUS_PHASE(status), 1u);
  ASSERT_EQ(NVME_CQE_STATUS_SC(status), 0u);

  status = (uint16_t)(0x42 << 1);
  ASSERT_EQ(NVME_CQE_STATUS_SC(status), 0x42u);
  ASSERT_EQ(NVME_CQE_STATUS_SCT(status), 0u);
  return 0;
}

/* ---- NVME_STATUS_MAKE round-trip ---- */

int test_status_make_roundtrip() {
  uint8_t phases[] = {0, 1};
  uint8_t scs[] = {0x00, 0x01, 0x42, 0x7F, 0x80, 0xFF};
  uint8_t scts[] = {0, NVME_SCT_CMD_SPECIFIC, NVME_SCT_MEDIA_ERROR,
                    NVME_SCT_VENDOR};

  for (unsigned pi = 0; pi < sizeof(phases) / sizeof(phases[0]); pi++) {
    for (unsigned si = 0; si < sizeof(scs) / sizeof(scs[0]); si++) {
      for (unsigned ti = 0; ti < sizeof(scts) / sizeof(scts[0]); ti++) {
        uint8_t p = phases[pi];
        uint8_t sc = scs[si];
        uint8_t sct = scts[ti];
        uint16_t status = NVME_STATUS_MAKE(p, sc, sct);

        ASSERT_EQ(NVME_CQE_STATUS_PHASE(status), p);
        ASSERT_EQ(NVME_CQE_STATUS_SC(status), sc);
        ASSERT_EQ(NVME_CQE_STATUS_SCT(status), sct);
      }
    }
  }
  return 0;
}

/* ---- sqeRead / sqeWrite round-trip ---- */

int test_sqe_read_write_roundtrip() {
  struct nvme_sqe original = {};
  original.opcode = nvme_cmd_write;
  original.flags = 0x12;
  original.command_id = 0xABCD;
  original.nsid = 3;
  original.cdw2 = 0x11111111;
  original.cdw3 = 0x22222222;
  original.metadata = 0x3333333333333333ULL;
  original.dptr.prp.prp1 = 0x4444444444444444ULL;
  original.dptr.prp.prp2 = 0x5555555555555555ULL;
  original.cdw10 = 0x66666666;
  original.cdw11 = 0x77777777;
  original.cdw12 = 0x88888888;
  original.cdw13 = 0x99999999;
  original.cdw14 = 0xAAAAAAAA;
  original.cdw15 = 0xBBBBBBBB;

  volatile struct nvme_sqe slot = {};
  sqeWrite(original, &slot);

  struct nvme_sqe readback = sqeRead(&slot);

  ASSERT_EQ(readback.opcode, original.opcode);
  ASSERT_EQ(readback.flags, original.flags);
  ASSERT_EQ(readback.command_id, original.command_id);
  ASSERT_EQ(readback.nsid, original.nsid);
  ASSERT_EQ(readback.cdw2, original.cdw2);
  ASSERT_EQ(readback.cdw3, original.cdw3);
  ASSERT_EQ(readback.metadata, original.metadata);
  ASSERT_EQ(readback.dptr.prp.prp1, original.dptr.prp.prp1);
  ASSERT_EQ(readback.dptr.prp.prp2, original.dptr.prp.prp2);
  ASSERT_EQ(readback.cdw10, original.cdw10);
  ASSERT_EQ(readback.cdw11, original.cdw11);
  ASSERT_EQ(readback.cdw12, original.cdw12);
  ASSERT_EQ(readback.cdw13, original.cdw13);
  ASSERT_EQ(readback.cdw14, original.cdw14);
  ASSERT_EQ(readback.cdw15, original.cdw15);
  ASSERT_EQ(memcmp(&readback, &original, sizeof(struct nvme_sqe)), 0);
  return 0;
}

/* ---- sqeWrite/sqeRead stress ---- */

int test_sqe_roundtrip_stress() {
  volatile struct nvme_sqe slot = {};

  /* All zeros */
  struct nvme_sqe zero = {};
  memset(&zero, 0, sizeof(zero));
  sqeWrite(zero, &slot);
  struct nvme_sqe rb = sqeRead(&slot);
  ASSERT_EQ(memcmp(&rb, &zero, sizeof(zero)), 0);

  /* All 0xFF */
  struct nvme_sqe ones = {};
  memset(&ones, 0xFF, sizeof(ones));
  sqeWrite(ones, &slot);
  rb = sqeRead(&slot);
  ASSERT_EQ(memcmp(&rb, &ones, sizeof(ones)), 0);

  /* Alternating 0xAA */
  struct nvme_sqe alt_aa = {};
  memset(&alt_aa, 0xAA, sizeof(alt_aa));
  sqeWrite(alt_aa, &slot);
  rb = sqeRead(&slot);
  ASSERT_EQ(memcmp(&rb, &alt_aa, sizeof(alt_aa)), 0);

  /* Alternating 0x55 */
  struct nvme_sqe alt_55 = {};
  memset(&alt_55, 0x55, sizeof(alt_55));
  sqeWrite(alt_55, &slot);
  rb = sqeRead(&slot);
  ASSERT_EQ(memcmp(&rb, &alt_55, sizeof(alt_55)), 0);

  /* Distinct non-trivial fields */
  struct nvme_sqe distinct = {};
  distinct.opcode = 0xDE;
  distinct.flags = 0xAD;
  distinct.command_id = 0xBEEF;
  distinct.nsid = 0xCAFEBABE;
  distinct.cdw2 = 0x01020304;
  distinct.cdw3 = 0x05060708;
  distinct.metadata = 0x090A0B0C0D0E0F10ULL;
  distinct.dptr.prp.prp1 = 0x1112131415161718ULL;
  distinct.dptr.prp.prp2 = 0x191A1B1C1D1E1F20ULL;
  distinct.cdw10 = 0x21222324;
  distinct.cdw11 = 0x25262728;
  distinct.cdw12 = 0x292A2B2C;
  distinct.cdw13 = 0x2D2E2F30;
  distinct.cdw14 = 0x31323334;
  distinct.cdw15 = 0x35363738;
  sqeWrite(distinct, &slot);
  rb = sqeRead(&slot);
  ASSERT_EQ(memcmp(&rb, &distinct, sizeof(distinct)), 0);
  return 0;
}

/* ---- cqeRead / cqeWrite round-trip ---- */

int test_cqe_read_write_roundtrip() {
  struct nvme_cqe original = {};
  original.result = 0xFEDCBA9876543210ULL;
  original.sq_head = 0x1234;
  original.sq_id = 0x5678;
  original.command_id = 0x9ABC;
  original.status = 0xDEF0;

  volatile struct nvme_cqe slot = {};
  cqeWrite(original, &slot);

  struct nvme_cqe readback = cqeRead(&slot);

  ASSERT_EQ(readback.result, original.result);
  ASSERT_EQ(readback.sq_head, original.sq_head);
  ASSERT_EQ(readback.sq_id, original.sq_id);
  ASSERT_EQ(readback.command_id, original.command_id);
  ASSERT_EQ(readback.status, original.status);
  ASSERT_EQ(memcmp(&readback, &original, sizeof(struct nvme_cqe)), 0);
  return 0;
}

/* ---- cqeWrite/cqeRead stress ---- */

int test_cqe_roundtrip_stress() {
  volatile struct nvme_cqe slot = {};

  struct nvme_cqe zero = {};
  memset(&zero, 0, sizeof(zero));
  cqeWrite(zero, &slot);
  struct nvme_cqe rb = cqeRead(&slot);
  ASSERT_EQ(memcmp(&rb, &zero, sizeof(zero)), 0);

  struct nvme_cqe ones = {};
  memset(&ones, 0xFF, sizeof(ones));
  cqeWrite(ones, &slot);
  rb = cqeRead(&slot);
  ASSERT_EQ(memcmp(&rb, &ones, sizeof(ones)), 0);

  struct nvme_cqe alt_aa = {};
  memset(&alt_aa, 0xAA, sizeof(alt_aa));
  cqeWrite(alt_aa, &slot);
  rb = cqeRead(&slot);
  ASSERT_EQ(memcmp(&rb, &alt_aa, sizeof(alt_aa)), 0);

  struct nvme_cqe alt_55 = {};
  memset(&alt_55, 0x55, sizeof(alt_55));
  cqeWrite(alt_55, &slot);
  rb = cqeRead(&slot);
  ASSERT_EQ(memcmp(&rb, &alt_55, sizeof(alt_55)), 0);

  struct nvme_cqe distinct = {};
  distinct.result = 0x0102030405060708ULL;
  distinct.sq_head = 0x090A;
  distinct.sq_id = 0x0B0C;
  distinct.command_id = 0x0D0E;
  distinct.status = 0x0F10;
  cqeWrite(distinct, &slot);
  rb = cqeRead(&slot);
  ASSERT_EQ(memcmp(&rb, &distinct, sizeof(distinct)), 0);
  return 0;
}

/* ---- dataPattern generate & verify ---- */

int test_dataPattern_generate_verify() {
  const size_t sz = 512;
  uint8_t buf[sz];
  memset(buf, 0, sz);

  xio::DataPatternParams params = {};
  params.buffer = buf;
  params.size = sz;
  params.offset = 0;
  params.blockSize = 512;
  params.seed = 0x1234;
  params.errorOffset = nullptr;

  bool ok = xio::dataPattern(false, params);
  ASSERT_TRUE(ok);

  bool all_zero = true;
  for (size_t i = 0; i < sz; i++) {
    if (buf[i] != 0) {
      all_zero = false;
      break;
    }
  }
  ASSERT_TRUE(!all_zero);

  ok = xio::dataPattern(true, params);
  ASSERT_TRUE(ok);
  return 0;
}

int test_dataPattern_corruption_detected() {
  const size_t sz = 512;
  uint8_t buf[sz];

  xio::DataPatternParams params = {};
  params.buffer = buf;
  params.size = sz;
  params.offset = 0;
  params.blockSize = 512;
  params.seed = 0x5678;
  params.errorOffset = nullptr;

  xio::dataPattern(false, params);

  buf[100] ^= 0xFF;

  size_t err_off = 0;
  params.errorOffset = &err_off;
  bool ok = xio::dataPattern(true, params);
  ASSERT_TRUE(!ok);
  ASSERT_EQ(err_off, 100u);
  return 0;
}

int test_dataPattern_determinism() {
  const size_t sz = 1024;
  uint8_t buf1[sz], buf2[sz];

  xio::DataPatternParams p1 = {};
  p1.buffer = buf1;
  p1.size = sz;
  p1.offset = 0;
  p1.blockSize = 512;
  p1.seed = 0xABCD;
  p1.errorOffset = nullptr;
  xio::dataPattern(false, p1);

  xio::DataPatternParams p2 = {};
  p2.buffer = buf2;
  p2.size = sz;
  p2.offset = 0;
  p2.blockSize = 512;
  p2.seed = 0xABCD;
  p2.errorOffset = nullptr;
  xio::dataPattern(false, p2);

  ASSERT_EQ(memcmp(buf1, buf2, sz), 0);
  return 0;
}

int test_dataPattern_different_seeds() {
  const size_t sz = 512;
  uint8_t buf1[sz], buf2[sz];

  xio::DataPatternParams p = {};
  p.size = sz;
  p.offset = 0;
  p.blockSize = 512;
  p.errorOffset = nullptr;

  p.buffer = buf1;
  p.seed = 0x1111;
  xio::dataPattern(false, p);

  p.buffer = buf2;
  p.seed = 0x2222;
  xio::dataPattern(false, p);

  ASSERT_NE(memcmp(buf1, buf2, sz), 0);
  return 0;
}

/* ---- dataPattern cross-LBA boundary ---- */

int test_dataPattern_cross_lba() {
  const uint32_t lba_size = 512;
  const size_t sz = 3 * lba_size;
  uint8_t buf[sz];

  xio::DataPatternParams p = {};
  p.buffer = buf;
  p.size = sz;
  p.offset = 0;
  p.blockSize = lba_size;
  p.seed = 0xBEEF;
  p.errorOffset = nullptr;
  xio::dataPattern(false, p);

  bool ok = xio::dataPattern(true, p);
  ASSERT_TRUE(ok);

  uint8_t buf_copy[sz];
  memcpy(buf_copy, buf, sz);
  p.buffer = buf_copy;
  p.size = sz;
  p.offset = 0;
  xio::dataPattern(false, p);
  ASSERT_EQ(memcmp(buf, buf_copy, sz), 0);
  return 0;
}

int test_dataPattern_different_offsets() {
  const uint32_t lba_size = 512;
  const size_t sz = lba_size;
  uint8_t buf_off0[sz], buf_off1[sz];

  xio::DataPatternParams p = {};
  p.size = sz;
  p.blockSize = lba_size;
  p.seed = 0xCAFE;
  p.errorOffset = nullptr;

  p.buffer = buf_off0;
  p.offset = 0;
  xio::dataPattern(false, p);

  p.buffer = buf_off1;
  p.offset = lba_size;
  xio::dataPattern(false, p);

  ASSERT_NE(memcmp(buf_off0, buf_off1, sz), 0);
  return 0;
}

int test_dataPattern_corruption_at_lba_boundary() {
  const uint32_t lba_size = 512;
  const size_t sz = 2 * lba_size;
  uint8_t buf[sz];

  xio::DataPatternParams p = {};
  p.buffer = buf;
  p.size = sz;
  p.offset = 0;
  p.blockSize = lba_size;
  p.seed = 0xFACE;
  p.errorOffset = nullptr;
  xio::dataPattern(false, p);

  buf[lba_size] ^= 0xFF;

  size_t err_off = 0;
  p.errorOffset = &err_off;
  bool ok = xio::dataPattern(true, p);
  ASSERT_TRUE(!ok);
  ASSERT_EQ(err_off, (size_t)lba_size);
  return 0;
}

int main() {
  int failures = 0;

  failures += test_sqeSetup_basic();
  failures += test_sqeSetup_large_lba();
  failures += test_sqeSetup_zero_preserves();
  failures += test_sqeSetup_nlb_one();

  failures += test_prp_single_page_aligned();
  failures += test_prp_single_page_fits();
  failures += test_prp_crosses_page_boundary();
  failures += test_prp_unaligned_within_page();
  failures += test_prp_at_page_boundary();
  failures += test_prp_two_full_pages();

  failures += test_cqeOk_success();
  failures += test_cqeOk_success_with_phase();
  failures += test_cqeOk_error_sc();
  failures += test_cqeOk_error_sct();
  failures += test_cqeOk_vendor_error();
  failures += test_cqeStatusCode_extraction();
  failures += test_cqeStatusType_extraction();

  failures += test_status_macros();
  failures += test_status_make_roundtrip();

  failures += test_sqe_read_write_roundtrip();
  failures += test_sqe_roundtrip_stress();
  failures += test_cqe_read_write_roundtrip();
  failures += test_cqe_roundtrip_stress();

  failures += test_dataPattern_generate_verify();
  failures += test_dataPattern_corruption_detected();
  failures += test_dataPattern_determinism();
  failures += test_dataPattern_different_seeds();
  failures += test_dataPattern_cross_lba();
  failures += test_dataPattern_different_offsets();
  failures += test_dataPattern_corruption_at_lba_boundary();

  if (failures == 0) {
    printf("All nvme-ep helper tests passed.\n");
    return 0;
  }
  printf("%d nvme-ep helper test(s) failed.\n", failures);
  return 1;
}
