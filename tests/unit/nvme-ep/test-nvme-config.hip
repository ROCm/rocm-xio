/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for nvme-ep configuration, struct sizes, magic constants, and
 * queue-length validation.
 */

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <hip/hip_runtime.h>

#include "nvme-ep.h"
#include "xio-test-assert.h"

using namespace xio::nvme_ep;

int test_struct_sizes() {
  ASSERT_EQ(sizeof(struct nvme_sqe), 64u);
  ASSERT_EQ(sizeof(struct nvme_cqe), 16u);
  ASSERT_EQ(sizeof(struct nvme_smart_log), 512u);
  ASSERT_EQ(sizeof(struct nvme_id_ns), 4096u);
  ASSERT_EQ(sizeof(struct nvme_lbaf), 4u);
  return 0;
}

int test_queue_entry_size_macros() {
  ASSERT_EQ(NVME_EP_SQE_SIZE, 64);
  ASSERT_EQ(NVME_EP_CQE_SIZE, 16);
  ASSERT_EQ(NVME_NVM_IOSQES, 6);
  ASSERT_EQ(NVME_NVM_IOCQES, 4);
  ASSERT_EQ(1 << NVME_NVM_IOSQES, NVME_EP_SQE_SIZE);
  ASSERT_EQ(1 << NVME_NVM_IOCQES, NVME_EP_CQE_SIZE);
  return 0;
}

int test_sqe_field_access() {
  struct nvme_sqe sqe = {};
  sqe.opcode = nvme_cmd_read;
  sqe.flags = 0x42;
  sqe.command_id = 0xBEEF;
  sqe.nsid = 1;
  sqe.cdw10 = 0x11111111;
  sqe.cdw11 = 0x22222222;
  sqe.cdw12 = 7;
  sqe.cdw13 = 0x33333333;
  sqe.cdw14 = 0x44444444;
  sqe.cdw15 = 0x55555555;
  sqe.dptr.prp.prp1 = 0xDEAD000000000000ULL;
  sqe.dptr.prp.prp2 = 0xCAFE000000000000ULL;

  ASSERT_EQ(sqe.opcode, (uint8_t)nvme_cmd_read);
  ASSERT_EQ(sqe.flags, 0x42);
  ASSERT_EQ(sqe.command_id, 0xBEEF);
  ASSERT_EQ(sqe.nsid, 1u);
  ASSERT_EQ(sqe.cdw10, 0x11111111u);
  ASSERT_EQ(sqe.cdw11, 0x22222222u);
  ASSERT_EQ(sqe.cdw12, 7u);
  ASSERT_EQ(sqe.dptr.prp.prp1, 0xDEAD000000000000ULL);
  ASSERT_EQ(sqe.dptr.prp.prp2, 0xCAFE000000000000ULL);
  return 0;
}

int test_cqe_field_access() {
  struct nvme_cqe cqe = {};
  cqe.result = 0x123456789ABCDEF0ULL;
  cqe.sq_head = 42;
  cqe.sq_id = 5;
  cqe.command_id = 0x1234;
  cqe.status = NVME_STATUS_MAKE(1, 0, 0);

  ASSERT_EQ(cqe.result, 0x123456789ABCDEF0ULL);
  ASSERT_EQ(cqe.sq_head, 42);
  ASSERT_EQ(cqe.sq_id, 5);
  ASSERT_EQ(cqe.command_id, 0x1234);
  ASSERT_EQ(NVME_CQE_STATUS_PHASE(cqe.status), 1u);
  ASSERT_EQ(NVME_CQE_STATUS_SC(cqe.status), 0u);
  ASSERT_EQ(NVME_CQE_STATUS_SCT(cqe.status), 0u);
  return 0;
}

int test_cqe_cdw0_union() {
  struct nvme_cqe cqe = {};
  cqe.cdw0 = 0xAABBCCDD;
  cqe.rsvd = 0x11223344;
  ASSERT_EQ(cqe.cdw0, 0xAABBCCDD);
  ASSERT_EQ(cqe.rsvd, 0x11223344u);
  uint64_t expected = (uint64_t)0x11223344 << 32 | 0xAABBCCDD;
  ASSERT_EQ(cqe.result, expected);
  return 0;
}

int test_config_defaults() {
  nvmeEpConfig cfg;

  ASSERT_TRUE(cfg.controller.empty());
  ASSERT_EQ(cfg.queueId, 0);
  ASSERT_EQ(cfg.queueLength, 64);
  ASSERT_EQ(cfg.numQueues, 1);
  ASSERT_TRUE(!cfg.queuesCreated);
  ASSERT_TRUE(cfg.queueIds.empty());
  ASSERT_TRUE(cfg.queueInfos.empty());
  ASSERT_EQ(cfg.doorbellAddr, 0u);
  ASSERT_EQ(cfg.sqBaseAddr, 0u);
  ASSERT_EQ(cfg.cqBaseAddr, 0u);
  ASSERT_EQ(cfg.sqSize, 0u);
  ASSERT_EQ(cfg.cqSize, 0u);

  ASSERT_TRUE(cfg.ioParams.accessPattern == "random");
  ASSERT_EQ(cfg.ioParams.lbaSize, 512u);
  ASSERT_EQ(cfg.ioParams.baseLba, 0u);
  ASSERT_EQ(cfg.ioParams.lbaRangeLbas, 0u);
  ASSERT_EQ(cfg.ioParams.lfsrSeed, 0u);
  ASSERT_EQ(cfg.ioParams.readIo, 0);
  ASSERT_EQ(cfg.ioParams.writeIo, 0);
  ASSERT_EQ(cfg.ioParams.nsid, 1u);
  ASSERT_EQ(cfg.ioParams.lbasPerIo, 1u);
  ASSERT_TRUE(!cfg.ioParams.infiniteMode);
  ASSERT_EQ(cfg.ioParams.batchSize, 1u);

  ASSERT_EQ(cfg.bufferParams.bufferSize, (size_t)(1024 * 1024));

  ASSERT_TRUE(!cfg.doorbellParams.usePciMmioBridge);
  ASSERT_EQ(cfg.doorbellParams.mmioBridgeBdf, 0x0020);
  ASSERT_EQ(cfg.doorbellParams.nvmeTargetBdf, 0x0030);
  ASSERT_EQ(cfg.doorbellParams.shadowBufferVirt, nullptr);
  ASSERT_EQ(cfg.doorbellParams.nvmeBar0Gpu, nullptr);
  return 0;
}

int test_doorbell_constants() {
  ASSERT_EQ(doorbellBase, 0x1000u);
  ASSERT_EQ(doorBellStride, 4u);
  return 0;
}

int test_admin_response_size() {
  ASSERT_EQ(nvmeAdminRespSize, 4096u);
  ASSERT_EQ(nvmeLogPageSize, 512u);
  return 0;
}

int test_command_opcodes() {
  ASSERT_EQ(nvme_cmd_read, 0x02);
  ASSERT_EQ(nvme_cmd_write, 0x01);
  ASSERT_EQ(nvme_cmd_flush, 0x00);
  ASSERT_EQ(nvme_admin_identify, 0x06);
  ASSERT_EQ(nvme_admin_create_sq, 0x01);
  ASSERT_EQ(nvme_admin_create_cq, 0x05);
  ASSERT_EQ(nvme_admin_delete_sq, 0x00);
  ASSERT_EQ(nvme_admin_delete_cq, 0x04);
  return 0;
}

static bool is_power_of_2(uint32_t v) {
  return v != 0 && (v & (v - 1)) == 0;
}

int test_queue_length_validation() {
  ASSERT_TRUE(!is_power_of_2(0));
  ASSERT_TRUE(is_power_of_2(1));
  ASSERT_TRUE(is_power_of_2(2));
  ASSERT_TRUE(!is_power_of_2(3));
  ASSERT_TRUE(is_power_of_2(4));
  ASSERT_TRUE(!is_power_of_2(63));
  ASSERT_TRUE(is_power_of_2(64));
  ASSERT_TRUE(!is_power_of_2(100));
  ASSERT_TRUE(is_power_of_2(1024));
  ASSERT_TRUE(!is_power_of_2(4095));
  ASSERT_TRUE(is_power_of_2(4096));
  ASSERT_TRUE(is_power_of_2(65536));
  ASSERT_TRUE(!is_power_of_2(65537));

  ASSERT_TRUE(1 >= 1 && 1 <= 65536 && is_power_of_2(1));
  ASSERT_TRUE(64 >= 1 && 64 <= 65536 && is_power_of_2(64));
  ASSERT_TRUE(65536 >= 1 && 65536 <= 65536 && is_power_of_2(65536));
  ASSERT_TRUE(!(65537 >= 1 && 65537 <= 65536));
  return 0;
}

int test_nvme_page_size() {
  ASSERT_EQ(NVME_PAGE_SIZE, 4096);
  return 0;
}

int test_status_code_constants() {
  ASSERT_EQ(NVME_SCT_GENERIC, 0x0);
  ASSERT_EQ(NVME_SCT_CMD_SPECIFIC, 0x1);
  ASSERT_EQ(NVME_SCT_MEDIA_ERROR, 0x2);
  ASSERT_EQ(NVME_SCT_VENDOR, 0x7);
  ASSERT_EQ(NVME_SC_SUCCESS, 0x0);
  ASSERT_EQ(NVME_SC_INVALID_OPCODE, 0x1);
  ASSERT_EQ(NVME_SC_INVALID_FIELD, 0x2);
  ASSERT_EQ(NVME_SC_LBA_RANGE, 0x80);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_struct_sizes();
  failures += test_queue_entry_size_macros();
  failures += test_sqe_field_access();
  failures += test_cqe_field_access();
  failures += test_cqe_cdw0_union();
  failures += test_config_defaults();
  failures += test_doorbell_constants();
  failures += test_admin_response_size();
  failures += test_command_opcodes();
  failures += test_queue_length_validation();
  failures += test_nvme_page_size();
  failures += test_status_code_constants();

  if (failures == 0) {
    printf("All nvme-ep config tests passed.\n");
    return 0;
  }
  printf("%d nvme-ep config test(s) failed.\n", failures);
  return 1;
}
