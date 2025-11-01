/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef NVME_EP_H
#define NVME_EP_H

#include <cstdint>

#include <hip/hip_runtime.h>

/*
 * NVMe Definitions for AxIIO nvme-ep Endpoint
 *
 * These definitions are based on the NVM Express specification and the
 * Linux kernel NVMe implementation. For reference, see:
 *   - Linux kernel: include/linux/nvme.h
 *   - NVMe spec: https://nvmexpress.org/specifications/
 *
 * To fetch the latest Linux kernel NVMe headers for reference:
 *   make fetch-nvme-headers
 *
 * The downloaded headers will be in include/external/ for reference.
 */

// Magic ID for nvme-ep queue entries
#define NVME_EP_MAGIC_ID 0xF1

// NVMe endpoint queue entry sizes
// These match the NVMe specification requirements
#define NVME_EP_SQE_SIZE 64 // NVMe Submission Queue Entry: 64 bytes
#define NVME_EP_CQE_SIZE 16 // NVMe Completion Queue Entry: 16 bytes

//
// NVMe Command Opcodes (NVM Command Set)
// Reference: Linux kernel enum nvme_opcode
//
#define NVME_CMD_FLUSH 0x00
#define NVME_CMD_WRITE 0x01
#define NVME_CMD_READ 0x02
#define NVME_CMD_WRITE_UNCOR 0x04
#define NVME_CMD_COMPARE 0x05
#define NVME_CMD_WRITE_ZEROS 0x08
#define NVME_CMD_DSM 0x09 // Dataset Management
#define NVME_CMD_VERIFY 0x0c
#define NVME_CMD_RESV_REGISTER 0x0d
#define NVME_CMD_RESV_REPORT 0x0e
#define NVME_CMD_RESV_ACQUIRE 0x11
#define NVME_CMD_RESV_RELEASE 0x15

// Admin Command Opcodes
#define NVME_ADMIN_DELETE_SQ 0x00
#define NVME_ADMIN_CREATE_SQ 0x01
#define NVME_ADMIN_GET_LOG_PAGE 0x02
#define NVME_ADMIN_DELETE_CQ 0x04
#define NVME_ADMIN_CREATE_CQ 0x05
#define NVME_ADMIN_IDENTIFY 0x06
#define NVME_ADMIN_ABORT_CMD 0x08
#define NVME_ADMIN_SET_FEATURES 0x09
#define NVME_ADMIN_GET_FEATURES 0x0a
#define NVME_ADMIN_ASYNC_EVENT 0x0c
#define NVME_ADMIN_NS_MGMT 0x0d
#define NVME_ADMIN_ACTIVATE_FW 0x10
#define NVME_ADMIN_DOWNLOAD_FW 0x11
#define NVME_ADMIN_NS_ATTACH 0x15
#define NVME_ADMIN_FORMAT_NVM 0x80
#define NVME_ADMIN_SECURITY_SEND 0x81
#define NVME_ADMIN_SECURITY_RECV 0x82

//
// NVMe Status Code Types
//
#define NVME_SCT_GENERIC 0x0
#define NVME_SCT_CMD_SPECIFIC 0x1
#define NVME_SCT_MEDIA_ERROR 0x2
#define NVME_SCT_VENDOR 0x7

//
// NVMe Generic Command Status Codes
//
#define NVME_SC_SUCCESS 0x00
#define NVME_SC_INVALID_OPCODE 0x01
#define NVME_SC_INVALID_FIELD 0x02
#define NVME_SC_CMDID_CONFLICT 0x03
#define NVME_SC_DATA_XFER_ERROR 0x04
#define NVME_SC_POWER_LOSS 0x05
#define NVME_SC_INTERNAL 0x06
#define NVME_SC_ABORT_REQ 0x07
#define NVME_SC_ABORT_QUEUE 0x08
#define NVME_SC_FUSED_FAIL 0x09
#define NVME_SC_FUSED_MISSING 0x0a
#define NVME_SC_INVALID_NS 0x0b
#define NVME_SC_CMD_SEQ_ERROR 0x0c
#define NVME_SC_LBA_RANGE 0x80
#define NVME_SC_CAP_EXCEEDED 0x81
#define NVME_SC_NS_NOT_READY 0x82
#define NVME_SC_RESERVATION_CONFLICT 0x83

//
// NVMe Submission Queue Entry (64 bytes)
// This structure represents a standard NVMe command
//
struct nvme_sqe {
  // DW0: Command Dword 0
  uint8_t opcode;      // Command opcode
  uint8_t flags;       // FUSE and PSDT fields
  uint16_t command_id; // Command identifier

  // DW1: Namespace Identifier
  uint32_t nsid; // Namespace ID

  // DW2-3: Reserved
  uint32_t cdw2;
  uint32_t cdw3;

  // DW4-5: Metadata Pointer
  uint64_t metadata;

  // DW6-9: Data Pointer (PRP Entry 1 and 2, or SGL)
  union {
    struct {
      uint64_t prp1; // PRP Entry 1
      uint64_t prp2; // PRP Entry 2
    } prp;
    struct {
      uint64_t addr;     // SGL Address
      uint32_t length;   // SGL Length
      uint32_t key_type; // SGL Key and Type
    } sgl;
  } dptr;

  // DW10-15: Command Specific
  uint32_t cdw10;
  uint32_t cdw11;
  uint32_t cdw12;
  uint32_t cdw13;
  uint32_t cdw14;
  uint32_t cdw15;
} __attribute__((packed));

//
// NVMe Completion Queue Entry (16 bytes)
// This structure represents the completion status of a command
//
struct nvme_cqe {
  // DW0: Command Specific
  union {
    uint32_t result; // Command-specific result
    struct {
      uint32_t cdw0; // Generic DW0
    };
  };

  // DW1: Reserved
  uint32_t rsvd;

  // DW2: SQ Head Pointer and SQ Identifier
  uint16_t sq_head; // SQ Head Pointer
  uint16_t sq_id;   // SQ Identifier

  // DW3: Command ID, Phase, and Status
  uint16_t command_id; // Command Identifier
  uint16_t status; // Status Field (Phase Tag + Status Code + Status Code Type +
                   // More + DNR)
} __attribute__((packed));

//
// Helper macros for NVMe CQE status field
//
#define NVME_CQE_STATUS_PHASE(status) (((status) >> 0) & 0x1)
#define NVME_CQE_STATUS_SC(status) (((status) >> 1) & 0xFF)
#define NVME_CQE_STATUS_SCT(status) (((status) >> 9) & 0x7)
#define NVME_CQE_STATUS_CRD(status) (((status) >> 12) & 0x3)
#define NVME_CQE_STATUS_MORE(status) (((status) >> 14) & 0x1)
#define NVME_CQE_STATUS_DNR(status) (((status) >> 15) & 0x1)

#define NVME_STATUS_MAKE(phase, sc, sct)                                       \
  ((((phase) & 0x1) << 0) | (((sc) & 0xFF) << 1) | (((sct) & 0x7) << 9))

//
// Helper functions to create NVMe commands
//

// Create an NVMe Read command
__host__ __device__ static inline void nvme_sqe_setup_read(
  struct nvme_sqe* sqe, uint16_t cid, uint32_t nsid, uint64_t slba,
  uint32_t nlb, uint64_t prp1, uint64_t prp2) {
  sqe->opcode = NVME_CMD_READ;
  sqe->flags = 0;
  sqe->command_id = cid;
  sqe->nsid = nsid;
  sqe->cdw2 = 0;
  sqe->cdw3 = 0;
  sqe->metadata = 0;
  sqe->dptr.prp.prp1 = prp1;
  sqe->dptr.prp.prp2 = prp2;
  sqe->cdw10 = (uint32_t)(slba & 0xFFFFFFFF);         // SLBA lower 32 bits
  sqe->cdw11 = (uint32_t)((slba >> 32) & 0xFFFFFFFF); // SLBA upper 32 bits
  sqe->cdw12 = nlb - 1; // Number of logical blocks (0's based)
  sqe->cdw13 = 0;
  sqe->cdw14 = 0;
  sqe->cdw15 = 0;
}

// Create an NVMe Write command
__host__ __device__ static inline void nvme_sqe_setup_write(
  struct nvme_sqe* sqe, uint16_t cid, uint32_t nsid, uint64_t slba,
  uint32_t nlb, uint64_t prp1, uint64_t prp2) {
  sqe->opcode = NVME_CMD_WRITE;
  sqe->flags = 0;
  sqe->command_id = cid;
  sqe->nsid = nsid;
  sqe->cdw2 = 0;
  sqe->cdw3 = 0;
  sqe->metadata = 0;
  sqe->dptr.prp.prp1 = prp1;
  sqe->dptr.prp.prp2 = prp2;
  sqe->cdw10 = (uint32_t)(slba & 0xFFFFFFFF);
  sqe->cdw11 = (uint32_t)((slba >> 32) & 0xFFFFFFFF);
  sqe->cdw12 = nlb - 1; // Number of logical blocks (0's based)
  sqe->cdw13 = 0;
  sqe->cdw14 = 0;
  sqe->cdw15 = 0;
}

// Create an NVMe Flush command
__host__ __device__ static inline void nvme_sqe_setup_flush(
  struct nvme_sqe* sqe, uint16_t cid, uint32_t nsid) {
  sqe->opcode = NVME_CMD_FLUSH;
  sqe->flags = 0;
  sqe->command_id = cid;
  sqe->nsid = nsid;
  sqe->cdw2 = 0;
  sqe->cdw3 = 0;
  sqe->metadata = 0;
  sqe->dptr.prp.prp1 = 0;
  sqe->dptr.prp.prp2 = 0;
  sqe->cdw10 = 0;
  sqe->cdw11 = 0;
  sqe->cdw12 = 0;
  sqe->cdw13 = 0;
  sqe->cdw14 = 0;
  sqe->cdw15 = 0;
}

// Check if CQE indicates success
__host__ __device__ static inline bool nvme_cqe_ok(const struct nvme_cqe* cqe) {
  uint16_t status = cqe->status;
  uint8_t sc = NVME_CQE_STATUS_SC(status);
  uint8_t sct = NVME_CQE_STATUS_SCT(status);
  return (sct == NVME_SCT_GENERIC && sc == NVME_SC_SUCCESS);
}

// Get status code from CQE
__host__ __device__ static inline uint8_t nvme_cqe_status_code(
  const struct nvme_cqe* cqe) {
  return NVME_CQE_STATUS_SC(cqe->status);
}

// Get status code type from CQE
__host__ __device__ static inline uint8_t nvme_cqe_status_type(
  const struct nvme_cqe* cqe) {
  return NVME_CQE_STATUS_SCT(cqe->status);
}

#endif // NVME_EP_H
