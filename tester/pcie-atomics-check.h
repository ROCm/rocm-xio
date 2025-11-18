#pragma once

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <unistd.h>

namespace nvme_axiio {

// Check if PCIe atomics are enabled by examining dmesg and lspci
// Can be disabled via environment variable AXIIO_IGNORE_ATOMICS=1
inline bool check_pcie_atomics_support(bool verbose = true,
                                       bool* force_mode = nullptr) {
  // Check if user wants to ignore atomics check
  const char* ignore_env = getenv("AXIIO_IGNORE_ATOMICS");
  const char* force_env = getenv("AXIIO_FORCE_GPU");
  const char* fast_env = getenv("AXIIO_FAST_ATOMICS_CHECK");
  bool ignore_atomics = (ignore_env && atoi(ignore_env) == 1) ||
                        (force_env && atoi(force_env) == 1);
  bool fast_check = (fast_env && atoi(fast_env) == 1);

  if (ignore_atomics) {
    if (verbose) {
      printf("\n=== PCIe Atomics Check DISABLED ===\n");
      printf("Environment variable detected: AXIIO_IGNORE_ATOMICS=1 or "
             "AXIIO_FORCE_GPU=1\n");
      printf("⚠️  Proceeding with GPU operations despite atomics status.\n");
      printf("⚠️  GPU kernels may fail, but we'll try anyway.\n");
      printf("========================================\n\n");
    }
    if (force_mode)
      *force_mode = true;
    return true; // Pretend atomics are OK
  }

  if (force_mode)
    *force_mode = false;

  bool atomics_ok = true;

  if (verbose) {
    printf("\n=== Checking PCIe Atomics Support ===\n");
  }

  // Method 1: Check dmesg for the specific error message
  // Skip dmesg in fast mode (it can be slow with large buffers)
  FILE* dmesg_pipe = nullptr;
  if (!fast_check) {
    dmesg_pipe = popen("dmesg 2>/dev/null | grep -i 'pcie atomics' | tail -5", "r");
  }
  if (dmesg_pipe) {
    char line[512];
    bool found_atomics_msg = false;
    while (fgets(line, sizeof(line), dmesg_pipe)) {
      found_atomics_msg = true;
      if (strstr(line, "not enabled") ||
          strstr(line, "hostcall not supported")) {
        atomics_ok = false;
        if (verbose) {
          printf("⚠️  WARNING: %s", line);
        }
      } else if (verbose) {
        printf("   %s", line);
      }
    }
    pclose(dmesg_pipe);

    if (!found_atomics_msg && verbose) {
      printf("   No PCIe atomics messages in dmesg\n");
    }
  }

  // Method 2: Check GPU device PCIe capabilities
  // Skip lspci check in fast mode (it's slow, especially -vvv)
  if (!fast_check) {
    // Find AMD GPU device (use faster method: lspci without verbose first)
    FILE* lspci_find = popen("lspci 2>/dev/null | grep -i "
                             "'amd.*radeon\\|amd.*vga' | head -1 | cut -d' ' -f1",
                             "r");
    if (lspci_find) {
      char gpu_addr[32];
      if (fgets(gpu_addr, sizeof(gpu_addr), lspci_find)) {
        // Remove newline
        gpu_addr[strcspn(gpu_addr, "\n")] = 0;

        if (verbose) {
          printf("   Found AMD GPU at PCIe address: %s\n", gpu_addr);
        }

        // Check PCIe capabilities - use faster method: only read atomic ops section
        // Use -v instead of -vvv to avoid reading all config space (much faster)
        // Then grep for atomic section only
        char cmd[256];
        snprintf(cmd, sizeof(cmd),
                 "lspci -v -s %s 2>/dev/null | grep -A2 -i 'atomic'", gpu_addr);
        FILE* lspci_cap = popen(cmd, "r");
        if (lspci_cap) {
          char line[512];
          bool atomics_supported = false;
          bool atomics_enabled = false;

          while (fgets(line, sizeof(line), lspci_cap)) {
            // Check for capabilities: "AtomicOpsCap: 32bit+ 64bit+"
            if (strstr(line, "AtomicOpsCap:")) {
              if (strstr(line, "32bit+") || strstr(line, "64bit+")) {
                atomics_supported = true;
              }
            }
            // Check for control enabled: "AtomicOpsCtl: ReqEn+"
            if (strstr(line, "AtomicOpsCtl:")) {
              if (strstr(line, "ReqEn+")) {
                atomics_enabled = true;
              }
            }
          }
          pclose(lspci_cap);

          if (verbose) {
            printf("   PCIe Atomics Capability: %s\n",
                   atomics_supported ? "✅ Supported" : "❌ Not Supported");
            printf("   PCIe Atomics Control: %s\n",
                   atomics_enabled ? "✅ Enabled" : "❌ Not Enabled");
          }

          if (!atomics_supported || !atomics_enabled) {
            atomics_ok = false;
          } else if (verbose && !atomics_supported && !atomics_enabled) {
            printf(
              "   Could not determine PCIe atomic capabilities from lspci\n");
          }
        }
      }
      pclose(lspci_find);
    }
  } else if (verbose) {
    printf("   Skipping lspci check (fast mode)\n");
  }

  // Method 3: Try a simple HIP operation to verify
  if (verbose) {
    printf("\n   Testing HIP functionality...\n");
  }

  int deviceCount = 0;
  hipError_t err = hipGetDeviceCount(&deviceCount);
  if (err == hipSuccess && deviceCount > 0) {
    if (verbose) {
      printf("   ✅ hipGetDeviceCount: %d device(s)\n", deviceCount);
    }

    // Try a simple malloc/free
    void* test_ptr = nullptr;
    err = hipMalloc(&test_ptr, 1024);
    if (err == hipSuccess) {
      hipFree(test_ptr);
      if (verbose) {
        printf("   ✅ hipMalloc/hipFree: OK\n");
      }
    } else {
      if (verbose) {
        printf("   ❌ hipMalloc failed: %s\n", hipGetErrorString(err));
      }
      atomics_ok = false;
    }

    // Try hipHostMalloc
    void* host_ptr = nullptr;
    err = hipHostMalloc(&host_ptr, 1024);
    if (err == hipSuccess) {
      hipHostFree(host_ptr);
      if (verbose) {
        printf("   ✅ hipHostMalloc/hipHostFree: OK\n");
      }
    } else {
      if (verbose) {
        printf("   ❌ hipHostMalloc failed: %s\n", hipGetErrorString(err));
      }
      atomics_ok = false;
    }
  } else {
    if (verbose) {
      printf("   ❌ hipGetDeviceCount failed: %s\n", hipGetErrorString(err));
    }
    atomics_ok = false;
  }

  if (verbose) {
    printf("========================================\n");
    if (atomics_ok) {
      printf("✅ PCIe Atomics: ENABLED - GPU compute should work\n\n");
    } else {
      printf("\n");
      printf("❌❌❌ PCIe ATOMICS NOT ENABLED ❌❌❌\n");
      printf("\n");
      printf(
        "AMD GPUs require PCIe Atomic Operations for compute workloads.\n");
      printf(
        "This is especially common in virtualized environments (QEMU/KVM).\n");
      printf("\n");
      printf("To fix this issue:\n");
      printf("\n");
      printf("1. If running in a VM, shut down the VM\n");
      printf("2. Add atomics=on to the VFIO GPU passthrough configuration:\n");
      printf("\n");
      printf("   For QEMU command line:\n");
      printf("     -device vfio-pci,host=XX:XX.X,atomics=on\n");
      printf("\n");
      printf("   For libvirt XML:\n");
      printf("     <hostdev mode='subsystem' type='pci' managed='yes'>\n");
      printf("       <driver>\n");
      printf("         <atomics mode='on'/>\n");
      printf("       </driver>\n");
      printf("     </hostdev>\n");
      printf("\n");
      printf("3. Restart the VM\n");
      printf("\n");
      printf("Without PCIe atomics, GPU kernels will fail with:\n");
      printf("  'the operation cannot be performed in the present state'\n");
      printf("\n");
      printf("Workarounds:\n");
      printf("  - Run with --cpu-only flag for CPU-based command generation\n");
      printf(
        "  - Set AXIIO_FORCE_GPU=1 to attempt GPU mode anyway (may fail)\n");
      printf("  - Set AXIIO_IGNORE_ATOMICS=1 to skip this check entirely\n");
      printf("\n");
      printf("========================================\n\n");
    }
  }

  return atomics_ok;
}

} // namespace nvme_axiio
