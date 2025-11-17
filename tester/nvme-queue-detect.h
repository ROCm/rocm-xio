/*
 * NVMe Queue Detection Helper
 * Detects how many queues the kernel driver is using
 */

#ifndef NVME_QUEUE_DETECT_H
#define NVME_QUEUE_DETECT_H

#include <cstring>
#include <fstream>
#include <iostream>
#include <string>

#include <dirent.h>
#include <sys/stat.h>

namespace nvme_axiio {

/*
 * Get the number of I/O queues currently in use by the kernel driver
 * Returns number of queues, or -1 on error
 */
static inline int get_kernel_queue_count(const char* nvme_device) {
  // Extract controller number from device path (e.g., /dev/nvme0 -> nvme0)
  const char* dev_name = strrchr(nvme_device, '/');
  if (dev_name) {
    dev_name++; // Skip the '/'
  } else {
    dev_name = nvme_device;
  }

  // Remove namespace suffix if present (nvme0n1 -> nvme0)
  std::string ctrl_name(dev_name);
  size_t n_pos = ctrl_name.find('n');
  if (n_pos != std::string::npos) {
    ctrl_name = ctrl_name.substr(0, n_pos);
  }

  std::cout << "Detecting kernel queue usage for " << ctrl_name << "..."
            << std::endl;

  // Method 1: Check /sys/class/nvme/nvmeX/queue_count
  std::string queue_count_path = "/sys/class/nvme/" + ctrl_name +
                                 "/queue_count";
  std::ifstream qc_file(queue_count_path);
  if (qc_file.is_open()) {
    int count;
    qc_file >> count;
    qc_file.close();
    std::cout << "  Found queue_count file: " << count << " queues"
              << std::endl;
    return count;
  }

  // Method 2: Count mq directories in /sys/class/nvme/nvmeX/device/mq/
  std::string mq_path = "/sys/class/nvme/" + ctrl_name + "/device/mq";
  DIR* dir = opendir(mq_path.c_str());
  if (dir) {
    int count = 0;
    struct dirent* entry;
    while ((entry = readdir(dir)) != nullptr) {
      if (entry->d_name[0] != '.') {
        count++;
      }
    }
    closedir(dir);
    std::cout << "  Counted mq directories: " << count << " queues"
              << std::endl;
    return count;
  }

  // Method 3: Check /sys/block/nvmeXnY/queue/
  // This gives us at least a lower bound
  std::string block_path = "/sys/block/" + ctrl_name + "n1/queue";
  struct stat st;
  if (stat(block_path.c_str(), &st) == 0) {
    // At minimum, there's 1 admin queue + some I/O queues
    // Default to assuming at least 4 queues are in use
    std::cout << "  Using conservative estimate: 4 queues" << std::endl;
    return 4;
  }

  // Couldn't determine - return error
  std::cerr << "  Warning: Could not determine kernel queue count" << std::endl;
  return -1;
}

/*
 * Select a free queue ID that won't conflict with kernel driver
 *
 * Strategy:
 * - Detect how many queues kernel is using (K)
 * - Use queue ID = K + margin (e.g., K + 16)
 * - Cap at reasonable maximum (e.g., 128)
 */
static inline uint16_t select_free_queue_id(const char* nvme_device,
                                            uint16_t min_margin = 16) {
  int kernel_queues = get_kernel_queue_count(nvme_device);

  uint16_t selected_qid;

  if (kernel_queues > 0) {
    // Use kernel queue count + margin
    selected_qid = kernel_queues + min_margin;
    std::cout << "  Kernel using " << kernel_queues << " queues" << std::endl;
    std::cout << "  Selected QID " << selected_qid << " (kernel + "
              << min_margin << " margin)" << std::endl;
  } else {
    // Couldn't detect - use safe default high in the range
    selected_qid = 63;
    std::cout << "  Could not detect kernel queues, using safe default: QID "
              << selected_qid << std::endl;
  }

  // Sanity check: cap at 255 (NVMe spec limit for most controllers)
  if (selected_qid > 255) {
    std::cout << "  Warning: QID " << selected_qid
              << " too high, capping at 255" << std::endl;
    selected_qid = 255;
  }

  return selected_qid;
}

/*
 * Check if a specific queue ID is likely free
 */
static inline bool is_queue_id_free(const char* nvme_device, uint16_t qid) {
  int kernel_queues = get_kernel_queue_count(nvme_device);

  if (kernel_queues < 0) {
    // Couldn't determine - assume it's risky if QID < 32
    return qid >= 32;
  }

  // Queue is free if it's beyond what kernel is using
  return qid > kernel_queues;
}

} // namespace nvme_axiio

#endif // NVME_QUEUE_DETECT_H
