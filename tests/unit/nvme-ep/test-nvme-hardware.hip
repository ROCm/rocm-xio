/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Hardware integration tests for nvme-ep.
 * Requires a real NVMe controller.
 * Skips with exit code 77 if no device is available.
 *
 * Usage:
 *   test-nvme-hardware --controller /dev/nvme2
 *   NVME_DEVICE=/dev/nvme2 test-nvme-hardware
 *   test-nvme-hardware  (auto-detects /dev/nvme0)
 */

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <hip/hip_runtime.h>

#include <fcntl.h>
#include <unistd.h>

#include "nvme-ep.h"

using namespace xio::nvme_ep;

#define ASSERT_EQ(a, b)                                                        \
  do {                                                                         \
    if ((a) != (b)) {                                                          \
      printf("ASSERT_EQ failed: %s:%d: "                                       \
             "%s != %s\n",                                                     \
             __FILE__, __LINE__, #a, #b);                                      \
      abort();                                                                 \
    }                                                                          \
  } while (0)

#define ASSERT_TRUE(x)                                                         \
  do {                                                                         \
    if (!(x)) {                                                                \
      printf("ASSERT_TRUE failed: %s:%d: %s\n", __FILE__, __LINE__, #x);       \
      abort();                                                                 \
    }                                                                          \
  } while (0)

#define ASSERT_GE(a, b)                                                        \
  do {                                                                         \
    if (!((a) >= (b))) {                                                       \
      printf("ASSERT_GE failed: %s:%d: "                                       \
             "%s < %s\n",                                                      \
             __FILE__, __LINE__, #a, #b);                                      \
      abort();                                                                 \
    }                                                                          \
  } while (0)

#define ASSERT_LE(a, b)                                                        \
  do {                                                                         \
    if (!((a) <= (b))) {                                                       \
      printf("ASSERT_LE failed: %s:%d: "                                       \
             "%s > %s\n",                                                      \
             __FILE__, __LINE__, #a, #b);                                      \
      abort();                                                                 \
    }                                                                          \
  } while (0)

#define ASSERT_GT(a, b)                                                        \
  do {                                                                         \
    if (!((a) > (b))) {                                                        \
      printf("ASSERT_GT failed: %s:%d: "                                       \
             "%s <= %s\n",                                                     \
             __FILE__, __LINE__, #a, #b);                                      \
      abort();                                                                 \
    }                                                                          \
  } while (0)

static std::string g_controller;

static bool is_power_of_2(unsigned v) {
  return v != 0 && (v & (v - 1)) == 0;
}

int test_queryLbaSize() {
  unsigned lba_size = 0;
  int ret = queryLbaSize(g_controller.c_str(), 1, &lba_size);
  ASSERT_EQ(ret, 0);
  ASSERT_TRUE(is_power_of_2(lba_size));
  ASSERT_GE(lba_size, 512u);
  ASSERT_LE(lba_size, 4096u);
  printf("  LBA size: %u bytes\n", lba_size);
  return 0;
}

int test_queryNamespaceCapacity() {
  uint64_t capacity = 0;
  int ret = queryNamespaceCapacity(g_controller.c_str(), 1, &capacity);
  ASSERT_EQ(ret, 0);
  ASSERT_GT(capacity, 0u);
  printf("  Namespace capacity: %llu LBAs\n", (unsigned long long)capacity);
  return 0;
}

int test_queryMaxQueueId() {
  uint16_t max_qid = 0;
  int ret = queryMaxQueueId(g_controller.c_str(), &max_qid);
  ASSERT_EQ(ret, 0);
  ASSERT_GE(max_qid, 1u);
  printf("  Max queue ID: %u\n", max_qid);
  return 0;
}

int test_checkRootfs() {
  int ret = checkRootfs(g_controller.c_str());
  ASSERT_EQ(ret, 0);
  printf("  Device is not rootfs (safe)\n");
  return 0;
}

static uint64_t read_le128_low64(const uint8_t* p) {
  uint64_t val = 0;
  for (int i = 7; i >= 0; i--) {
    val = (val << 8) | p[i];
  }
  return val;
}

int test_readSmartLog() {
  struct nvme_smart_log smart = {};
  int ret = readSmartLog(g_controller.c_str(), &smart);
  ASSERT_EQ(ret, 0);

  ASSERT_LE(smart.percent_used, 100u);

  uint64_t data_read = read_le128_low64(smart.data_units_read);
  uint64_t data_written = read_le128_low64(smart.data_units_written);

  printf("  SMART: critical_warning=%u, "
         "percent_used=%u%%, "
         "data_read=%llu, data_written=%llu\n",
         smart.critical_warning, smart.percent_used,
         (unsigned long long)data_read, (unsigned long long)data_written);
  return 0;
}

int test_validateConfig() {
  nvmeEpConfig cfg;
  cfg.controller = g_controller;
  cfg.ioParams.readIo = 10;
  cfg.ioParams.writeIo = 0;
  cfg.ioParams.batchSize = 1;

  std::string err = validateConfig(&cfg);
  if (!err.empty()) {
    printf("  validateConfig error: %s\n", err.c_str());
  }
  ASSERT_TRUE(err.empty());

  ASSERT_TRUE(cfg.ioParams.lbaSize >= 512);
  ASSERT_TRUE(is_power_of_2(cfg.ioParams.lbaSize));

  ASSERT_GT(cfg.queueId, 0u);

  printf("  validateConfig: OK (lbaSize=%u, "
         "queueId=%u)\n",
         cfg.ioParams.lbaSize, cfg.queueId);
  return 0;
}

static std::string find_controller(int argc, char** argv) {
  for (int i = 1; i < argc - 1; i++) {
    if (strcmp(argv[i], "--controller") == 0) {
      return argv[i + 1];
    }
  }

  const char* env = getenv("NVME_DEVICE");
  if (env && env[0] != '\0') {
    return env;
  }

  if (access("/dev/nvme0", F_OK) == 0) {
    return "/dev/nvme0";
  }

  return "";
}

int main(int argc, char** argv) {
  g_controller = find_controller(argc, argv);
  if (g_controller.empty()) {
    printf("SKIP: no NVMe device available "
           "(use --controller or NVME_DEVICE)\n");
    return 77;
  }

  if (access(g_controller.c_str(), F_OK) != 0) {
    printf("SKIP: NVMe device %s not found\n", g_controller.c_str());
    return 77;
  }

  printf("Testing NVMe device: %s\n", g_controller.c_str());

  int failures = 0;
  failures += test_queryLbaSize();
  failures += test_queryNamespaceCapacity();
  failures += test_queryMaxQueueId();
  failures += test_checkRootfs();
  failures += test_readSmartLog();
  failures += test_validateConfig();

  if (failures == 0) {
    printf("All nvme-ep hardware tests passed.\n");
    return 0;
  }
  printf("%d nvme-ep hardware test(s) failed.\n", failures);
  return 1;
}
