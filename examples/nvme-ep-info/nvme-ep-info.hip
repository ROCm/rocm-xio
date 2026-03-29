/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Example: query NVMe controller properties using the
 * rocm-xio nvme-ep host-side API.
 *
 * Prints LBA size, namespace capacity, maximum queue ID,
 * and SMART/Health log data for a given NVMe controller.
 *
 * Prerequisites:
 *   - An NVMe device (e.g. /dev/nvme0)
 *   - Root access (NVMe admin commands require CAP_SYS_ADMIN)
 *   - rocm-xio installed (find_package(rocm-xio))
 *
 * Usage:
 *   sudo ./nvme-ep-info [/dev/nvmeN]
 *
 * If no device is specified, /dev/nvme0 is used.
 * Returns exit code 0 on success, 77 when the device
 * cannot be opened (CTest SKIP convention).
 */

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <fcntl.h>
#include <unistd.h>

#include "endpoints/nvme-ep/nvme-ep.h"
#include "xio.h"

static constexpr int SKIP_EXIT_CODE = 77;

int main(int argc, char** argv) {
  const char* device = "/dev/nvme0";
  if (argc > 1)
    device = argv[1];

  printf("rocm-xio nvme-ep info example\n");
  printf("Device: %s\n\n", device);

  int fd = open(device, O_RDONLY);
  if (fd < 0) {
    fprintf(stderr, "Cannot open %s: %s\n", device, strerror(errno));
    fprintf(stderr, "SKIP: no NVMe device available.\n");
    return SKIP_EXIT_CODE;
  }
  close(fd);

  int rc = xio::nvme_ep::checkRootfs(device);
  if (rc != 0) {
    fprintf(stderr,
            "WARNING: %s appears to host the root "
            "filesystem.\n",
            device);
  }

  unsigned lbaSize = 0;
  rc = xio::nvme_ep::queryLbaSize(device, 1, &lbaSize);
  if (rc != 0) {
    fprintf(stderr, "ERROR: queryLbaSize failed (%d).\n", rc);
    return 1;
  }
  printf("Namespace 1 LBA size: %u bytes\n", lbaSize);

  uint64_t capacityLbas = 0;
  rc = xio::nvme_ep::queryNamespaceCapacity(device, 1, &capacityLbas);
  if (rc != 0) {
    fprintf(stderr, "ERROR: queryNamespaceCapacity failed (%d).\n", rc);
    return 1;
  }
  double capacityGiB = static_cast<double>(capacityLbas) * lbaSize /
                       (1024.0 * 1024 * 1024);
  printf("Namespace 1 capacity: %lu LBAs (%.2f GiB)\n",
         static_cast<unsigned long>(capacityLbas), capacityGiB);

  uint16_t maxQueueId = 0;
  rc = xio::nvme_ep::queryMaxQueueId(device, &maxQueueId);
  if (rc != 0) {
    fprintf(stderr, "ERROR: queryMaxQueueId failed (%d).\n", rc);
    return 1;
  }
  printf("Max IO queue ID:      %u\n", maxQueueId);

  struct nvme_smart_log smartLog;
  memset(&smartLog, 0, sizeof(smartLog));
  rc = xio::nvme_ep::readSmartLog(device, &smartLog);
  if (rc != 0) {
    fprintf(stderr,
            "WARNING: readSmartLog failed (%d), "
            "skipping SMART data.\n",
            rc);
  } else {
    printf("\nSMART / Health Information:\n");
    printf("  Critical warnings:     0x%02x\n", smartLog.critical_warning);
    printf("  Temperature:           %u K (%d C)\n", smartLog.temperature,
           static_cast<int>(smartLog.temperature) - 273);
    printf("  Available spare:       %u%%\n", smartLog.avail_spare);
    printf("  Available spare thr:   %u%%\n", smartLog.spare_thresh);
    printf("  Percent used:          %u%%\n", smartLog.percent_used);
    printf("  Power cycles:          %llu\n",
           static_cast<unsigned long long>(smartLog.power_cycles[0]));
    printf("  Power on hours:        %llu\n",
           static_cast<unsigned long long>(smartLog.power_on_hours[0]));
  }

  printf("\nAll NVMe info queries passed.\n");
  return 0;
}
