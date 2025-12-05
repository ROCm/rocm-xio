/*
 * NVMe SMART Log Checker
 * Read SMART log to verify if commands are being processed
 */

#ifndef NVME_SMART_CHECK_H
#define NVME_SMART_CHECK_H

#include <cstring>
#include <iostream>

#include <fcntl.h>
#include <linux/nvme_ioctl.h>
#include <sys/ioctl.h>
#include <unistd.h>

namespace nvme_smart {

struct smart_counters {
  uint64_t data_units_read[2];     // 128-bit value
  uint64_t data_units_written[2];  // 128-bit value
  uint64_t host_read_commands[2];  // 128-bit value
  uint64_t host_write_commands[2]; // 128-bit value
};

/*
 * Read NVMe SMART log
 * Returns 0 on success, -1 on error
 */
static inline int read_smart_log(const char* nvme_device,
                                 smart_counters* counters) {
  int fd = open(nvme_device, O_RDONLY);
  if (fd < 0) {
    std::cerr << "Failed to open " << nvme_device << ": " << strerror(errno)
              << std::endl;
    return -1;
  }

  // SMART log is 512 bytes at log page 0x02
  unsigned char smart_log[512];
  memset(smart_log, 0, sizeof(smart_log));

  struct nvme_admin_cmd cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = 0x02;     // Get Log Page
  cmd.nsid = 0xFFFFFFFF; // Global namespace
  cmd.addr = (uint64_t)smart_log;
  cmd.data_len = 512;
  cmd.cdw10 = 0x02 | ((511 / 4) << 16); // Log ID 0x02, NUMDL=(512/4 - 1)

  if (ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd) < 0) {
    std::cerr << "SMART log ioctl failed: " << strerror(errno) << std::endl;
    close(fd);
    return -1;
  }

  // Parse SMART log structure
  // Offsets from NVMe spec 1.4:
  // Bytes 32-47: Data Units Read (128-bit)
  // Bytes 48-63: Data Units Written (128-bit)
  // Bytes 64-79: Host Read Commands (128-bit)
  // Bytes 80-95: Host Write Commands (128-bit)

  memcpy(&counters->data_units_read, smart_log + 32, 16);
  memcpy(&counters->data_units_written, smart_log + 48, 16);
  memcpy(&counters->host_read_commands, smart_log + 64, 16);
  memcpy(&counters->host_write_commands, smart_log + 80, 16);

  close(fd);
  return 0;
}

/*
 * Print SMART counters
 */
static inline void print_smart_counters(const char* label,
                                        const smart_counters& counters) {
  std::cout << label << ":" << std::endl;
  std::cout << "  Host Read Commands:  " << counters.host_read_commands[0]
            << std::endl;
  std::cout << "  Host Write Commands: " << counters.host_write_commands[0]
            << std::endl;
  std::cout << "  Data Units Read:     " << counters.data_units_read[0]
            << std::endl;
  std::cout << "  Data Units Written:  " << counters.data_units_written[0]
            << std::endl;
}

/*
 * Compare two SMART counters and show difference
 */
static inline bool compare_smart_counters(const smart_counters& before,
                                          const smart_counters& after,
                                          uint64_t expected_reads) {
  uint64_t read_delta = after.host_read_commands[0] -
                        before.host_read_commands[0];
  uint64_t write_delta = after.host_write_commands[0] -
                         before.host_write_commands[0];

  std::cout << "\n=== SMART Counter Changes ===" << std::endl;
  std::cout << "  Host Read Commands:  +" << read_delta;
  if (expected_reads > 0) {
    std::cout << " (expected +" << expected_reads << ")";
  }
  std::cout << std::endl;
  std::cout << "  Host Write Commands: +" << write_delta << std::endl;

  if (read_delta >= expected_reads && expected_reads > 0) {
    std::cout << "  ✅ Commands were processed by NVMe controller!"
              << std::endl;
    return true;
  } else if (read_delta > 0) {
    std::cout << "  ⚠️  Some commands processed, but less than expected"
              << std::endl;
    return false;
  } else {
    std::cout
      << "  ❌ NO commands processed - doorbell writes not reaching controller!"
      << std::endl;
    return false;
  }
}

} // namespace nvme_smart

#endif // NVME_SMART_CHECK_H
