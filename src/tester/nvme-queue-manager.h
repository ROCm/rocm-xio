#ifndef NVME_QUEUE_MANAGER_H
#define NVME_QUEUE_MANAGER_H

#include <cstdint>
#include <cstring>
#include <iostream>

#include <fcntl.h>
#include <linux/nvme_ioctl.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "nvme-device-helper.h"

// NVMe Admin Command Opcodes
#define NVME_ADMIN_CREATE_SQ 0x01
#define NVME_ADMIN_CREATE_CQ 0x05
#define NVME_ADMIN_DELETE_SQ 0x00
#define NVME_ADMIN_DELETE_CQ 0x04
#define NVME_ADMIN_IDENTIFY 0x06
#ifndef NVME_ADMIN_GET_FEATURES
#define NVME_ADMIN_GET_FEATURES 0x0A
#endif

// Feature IDs
#define NVME_FEAT_NUM_QUEUES 0x07

// Get the number of I/O queues supported by the controller
static inline int nvme_get_queue_count(const char* device_path,
                                       uint16_t* num_sq, uint16_t* num_cq) {
  std::cout << "\nQuerying NVMe controller queue capabilities..." << std::endl;

  int fd = open(device_path, O_RDWR);
  if (fd < 0) {
    perror("Error opening NVMe device");
    return -1;
  }

  // Get Features command for Number of Queues (Feature ID 0x07)
  struct nvme_admin_cmd cmd;
  memset(&cmd, 0, sizeof(cmd));

  cmd.opcode = NVME_ADMIN_GET_FEATURES;
  cmd.cdw10 = NVME_FEAT_NUM_QUEUES;

  int ret = ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd);

  if (ret < 0) {
    perror("  Error: Get Features ioctl failed");
    close(fd);
    return -1;
  }

  // Result format:
  // Bits 15:0  = Number of I/O Submission Queues Allocated (0-based, so add 1)
  // Bits 31:16 = Number of I/O Completion Queues Allocated (0-based, so add 1)
  *num_sq = (cmd.result & 0xFFFF) + 1;
  *num_cq = ((cmd.result >> 16) & 0xFFFF) + 1;

  std::cout << "  Number of I/O Submission Queues: " << *num_sq << std::endl;
  std::cout << "  Number of I/O Completion Queues: " << *num_cq << std::endl;

  close(fd);
  return 0;
}

// Read admin queue attributes from BAR0 to find how many queues are allocated
static inline int nvme_get_allocated_queue_info(nvme_controller_t* ctrl,
                                                uint16_t* admin_sq_size,
                                                uint16_t* admin_cq_size) {
  // Read Admin Queue Attributes (AQA) register at offset 0x24
  volatile uint32_t* aqa_reg = (volatile uint32_t*)((char*)ctrl->bar0_mapped +
                                                    0x24);
  uint32_t aqa = *aqa_reg;

  // AQA format:
  // Bits 11:0  = Admin Submission Queue Size (0-based)
  // Bits 27:16 = Admin Completion Queue Size (0-based)
  *admin_sq_size = (aqa & 0xFFF) + 1;
  *admin_cq_size = ((aqa >> 16) & 0xFFF) + 1;

  std::cout << "\nAdmin Queue Attributes:" << std::endl;
  std::cout << "  Admin SQ Size: " << *admin_sq_size << " entries" << std::endl;
  std::cout << "  Admin CQ Size: " << *admin_cq_size << " entries" << std::endl;

  return 0;
}

// Select a dedicated queue ID for our use
// We'll use a high queue ID (63) to minimize conflicts with kernel queues
// Returns the queue ID to use
static inline int nvme_select_dedicated_queue(const char* device_path,
                                              uint16_t max_queues) {
  std::cout << "\nSelecting dedicated queue ID..." << std::endl;

  // Use queue ID 63 (highest standard queue ID)
  uint16_t qid = 63;

  // Make sure controller supports this many queues
  if (qid >= max_queues) {
    qid = max_queues - 1;
  }

  // Make sure we don't collide with admin queue or first kernel queue
  if (qid < 2) {
    std::cerr << "  Error: Not enough queues available (need at least 3)"
              << std::endl;
    return -1;
  }

  std::cout << "  Selected Queue ID: " << qid << " (will be created/recreated)"
            << std::endl;
  return qid;
}

// Helper to check if controller is ready
static inline bool nvme_check_ready(nvme_controller_t* ctrl) {
  // Check Controller Configuration (CC) register at offset 0x14
  volatile uint32_t* cc_reg = (volatile uint32_t*)((char*)ctrl->bar0_mapped +
                                                   0x14);
  uint32_t cc = *cc_reg;

  // Check if controller is enabled (EN bit = bit 0)
  bool enabled = (cc & 0x1) != 0;

  // Check Controller Status (CSTS) register at offset 0x1C
  volatile uint32_t* csts_reg = (volatile uint32_t*)((char*)ctrl->bar0_mapped +
                                                     0x1C);
  uint32_t csts = *csts_reg;

  // Check if controller is ready (RDY bit = bit 0)
  bool ready = (csts & 0x1) != 0;

  std::cout << "NVMe Controller Status:" << std::endl;
  std::cout << "  CC (Config): 0x" << std::hex << cc << std::dec
            << " (EN=" << enabled << ")" << std::endl;
  std::cout << "  CSTS (Status): 0x" << std::hex << csts << std::dec
            << " (RDY=" << ready << ")" << std::endl;

  return enabled && ready;
}

// Create I/O Completion Queue via ioctl (like nvme-cli)
static inline int nvme_create_io_cq(const char* device_path, uint16_t qid,
                                    uint16_t qsize, uint64_t cq_phys_addr) {
  std::cout << "\nCreating I/O Completion Queue via ioctl:" << std::endl;
  std::cout << "  Queue ID: " << qid << std::endl;
  std::cout << "  Queue Size: " << qsize << " entries" << std::endl;
  std::cout << "  Physical Address: 0x" << std::hex << cq_phys_addr << std::dec
            << std::endl;

  int fd = open(device_path, O_RDWR);
  if (fd < 0) {
    perror("Error opening NVMe device");
    return -1;
  }

  // Build Create I/O Completion Queue admin command using Linux kernel
  // structure
  struct nvme_admin_cmd cmd;
  memset(&cmd, 0, sizeof(cmd));

  cmd.opcode = NVME_ADMIN_CREATE_CQ;
  cmd.addr = cq_phys_addr;

  // CDW10: Queue ID (bits 15:0) and Queue Size (bits 31:16)
  // Per NVMe spec 1.4, Figure 145
  cmd.cdw10 = ((uint32_t)(qsize - 1) << 16) | qid; // qsize-1 is 0-based

  // CDW11: Queue flags
  // Bit 0: Physically Contiguous (PC) = 1
  // Bit 1: Interrupt Enable (IEN) = 1 (enable interrupts!)
  // Bits 31:16: Interrupt Vector (IV) = 0 (use vector 0)
  cmd.cdw11 = 0x3; // Physically contiguous, interrupts enabled, vector 0

  // Submit admin command via ioctl
  int ret = ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd);

  if (ret < 0) {
    perror("  Error: Create CQ ioctl failed");
    std::cerr << "    errno=" << errno << " (" << strerror(errno) << ")"
              << std::endl;
    close(fd);
    return -1;
  }

  // Check command result - NVMe completion status
  if (cmd.result != 0) {
    uint16_t status = (cmd.result >> 1) &
                      0x7FF;           // Status Code Type + Status Code
    uint8_t sct = (status >> 8) & 0x7; // Status Code Type
    uint8_t sc = status & 0xFF;        // Status Code
    std::cerr << "  Error: Create CQ command failed" << std::endl;
    std::cerr << "    NVMe Status: SCT=" << (int)sct << " SC=" << (int)sc
              << std::endl;
    std::cerr << "    Raw result: 0x" << std::hex << cmd.result << std::dec
              << std::endl;
    close(fd);
    return -1;
  }

  std::cout << "  ✅ I/O Completion Queue created successfully (result=0x"
            << std::hex << cmd.result << std::dec << ")" << std::endl;
  close(fd);
  return 0;
}

// Create I/O Submission Queue via ioctl (like nvme-cli)
static inline int nvme_create_io_sq(const char* device_path, uint16_t qid,
                                    uint16_t cqid, uint16_t qsize,
                                    uint64_t sq_phys_addr) {
  std::cout << "\nCreating I/O Submission Queue via ioctl:" << std::endl;
  std::cout << "  Queue ID: " << qid << std::endl;
  std::cout << "  Associated CQ ID: " << cqid << std::endl;
  std::cout << "  Queue Size: " << qsize << " entries" << std::endl;
  std::cout << "  Physical Address: 0x" << std::hex << sq_phys_addr << std::dec
            << std::endl;

  int fd = open(device_path, O_RDWR);
  if (fd < 0) {
    perror("Error opening NVMe device");
    return -1;
  }

  // Build Create I/O Submission Queue admin command
  struct nvme_admin_cmd cmd;
  memset(&cmd, 0, sizeof(cmd));

  cmd.opcode = NVME_ADMIN_CREATE_SQ;
  cmd.addr = sq_phys_addr;

  // CDW10: Queue ID (bits 15:0) and Queue Size (bits 31:16)
  // Per NVMe spec 1.4, Figure 147
  cmd.cdw10 = ((uint32_t)(qsize - 1) << 16) | qid;

  // CDW11: Queue flags and associated CQ ID
  // Bit 0: Physically Contiguous (PC) = 1
  // Bits 2:1: Queue Priority (01 = medium)
  // Bits 31:16: Completion Queue Identifier (CQID)
  cmd.cdw11 = 0x1 |
              ((uint32_t)cqid << 16); // PC=1, medium priority, associated CQ

  // Submit admin command via ioctl
  int ret = ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd);

  if (ret < 0) {
    perror("  Error: Create SQ ioctl failed");
    std::cerr << "    errno=" << errno << " (" << strerror(errno) << ")"
              << std::endl;
    close(fd);
    return -1;
  }

  // Check command result - NVMe completion status
  if (cmd.result != 0) {
    uint16_t status = (cmd.result >> 1) & 0x7FF;
    uint8_t sct = (status >> 8) & 0x7;
    uint8_t sc = status & 0xFF;
    std::cerr << "  Error: Create SQ command failed" << std::endl;
    std::cerr << "    NVMe Status: SCT=" << (int)sct << " SC=" << (int)sc
              << std::endl;
    std::cerr << "    Raw result: 0x" << std::hex << cmd.result << std::dec
              << std::endl;
    close(fd);
    return -1;
  }

  std::cout << "  ✅ I/O Submission Queue created successfully (result=0x"
            << std::hex << cmd.result << std::dec << ")" << std::endl;
  close(fd);
  return 0;
}

// Delete I/O Submission Queue via ioctl (cleanup)
static inline int nvme_delete_io_sq(const char* device_path, uint16_t qid) {
  std::cout << "\nDeleting I/O Submission Queue " << qid << " via ioctl..."
            << std::endl;

  int fd = open(device_path, O_RDWR);
  if (fd < 0) {
    perror("Error opening NVMe device");
    return -1;
  }

  struct nvme_admin_cmd cmd;
  memset(&cmd, 0, sizeof(cmd));

  cmd.opcode = NVME_ADMIN_DELETE_SQ;
  cmd.cdw10 = qid; // Queue ID to delete

  int ret = ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd);

  if (ret < 0) {
    perror("  Error: Delete SQ ioctl failed");
    close(fd);
    return -1;
  }

  std::cout << "  ✅ I/O Submission Queue deleted" << std::endl;
  close(fd);
  return 0;
}

// Delete I/O Completion Queue via ioctl (cleanup)
static inline int nvme_delete_io_cq(const char* device_path, uint16_t qid) {
  std::cout << "\nDeleting I/O Completion Queue " << qid << " via ioctl..."
            << std::endl;

  int fd = open(device_path, O_RDWR);
  if (fd < 0) {
    perror("Error opening NVMe device");
    return -1;
  }

  struct nvme_admin_cmd cmd;
  memset(&cmd, 0, sizeof(cmd));

  cmd.opcode = NVME_ADMIN_DELETE_CQ;
  cmd.cdw10 = qid; // Queue ID to delete

  int ret = ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd);

  if (ret < 0) {
    perror("  Error: Delete CQ ioctl failed");
    close(fd);
    return -1;
  }

  std::cout << "  ✅ I/O Completion Queue deleted" << std::endl;
  close(fd);
  return 0;
}

#endif // NVME_QUEUE_MANAGER_H
