/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Scan /sys/class/infiniband for a device matching a PCI vendor ID.
 * Used by RDMA test binaries for auto-detecting the NIC provider.
 */

#ifndef RDMA_EP_TEST_DETECT_PCI_VENDOR_HPP
#define RDMA_EP_TEST_DETECT_PCI_VENDOR_HPP

#include <cstdint>
#include <cstdio>

#include <dirent.h>

inline bool detect_pci_vendor(uint16_t vendor_id) {
  DIR* d = opendir("/sys/class/infiniband");
  if (!d)
    return false;
  struct dirent* ent;
  while ((ent = readdir(d)) != nullptr) {
    if (ent->d_name[0] == '.')
      continue;
    char path[512];
    snprintf(path, sizeof(path), "/sys/class/infiniband/%s/device/vendor",
             ent->d_name);
    FILE* f = fopen(path, "r");
    if (!f)
      continue;
    unsigned int vid = 0;
    if (fscanf(f, "%x", &vid) == 1 && vid == vendor_id) {
      fclose(f);
      closedir(d);
      return true;
    }
    fclose(f);
  }
  closedir(d);
  return false;
}

#endif // RDMA_EP_TEST_DETECT_PCI_VENDOR_HPP
