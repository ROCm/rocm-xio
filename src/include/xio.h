/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef XIO_H
#define XIO_H

#include <cstdint>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include <hip/hip_runtime.h>

#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>

// Forward declaration for CLI11
namespace CLI {
class App;
}

#include "xio-endpoint-registry.h"
// AUTO-GENERATED - DO NOT EDIT MANUALLY
#include "xio-endpoint-includes-gen.h"

// ROCm-XIO kernel module device path
#define ROCM_XIO_DEVICE_PATH "/dev/rocm-xio"

#define HIP_CHECK(expression)                                                  \
  {                                                                            \
    const hipError_t status = expression;                                      \
    if (status != hipSuccess) {                                                \
      std::cerr << "HIP error " << status << ": " << hipGetErrorString(status) \
                << " at " << __FILE__ << ":" << __LINE__ << std::endl;         \
    }                                                                          \
  }

/**
 * Base configuration structure for all endpoints
 *
 * Contains common testing parameters that apply to all endpoints.
 * Endpoints can extend this with their own configuration structures
 * via the endpointConfig pointer.
 */
struct XioEndpointConfig {
  // Common testing parameters
  unsigned iterations = 128; // Number of iterations
  unsigned numThreads = 1;   // Number of GPU threads (1-32)
  long long delayNs = 0;     // Delay in nanoseconds
                             // Negative: fixed delay of |delayNs|
                             // Positive: random delay 0 to delayNs
                             // Zero: no delay
  unsigned memoryMode = 0;   // Memory mode bits:
                             // Bit 0 (LSB): GPU write location (SQE)
                             //   (0=host, 1=device)
                             // Bit 1: CPU write location (CQE)
                             //   (0=host, 1=device)
                             // Bit 2: Doorbell location (doorbell mode only)
                             //   (0=host, 1=device)
  int verbose = 0;           // Verbose output level:
                             // 0 = no verbose output
                             // 1 = normal verbose (-v)
                             // 2 = very verbose (-vv) - enables SQE/CQE dumping
  bool pciMmioBridge = false; // Use PCI MMIO bridge for doorbell routing

  // Timing arrays (optional, can be nullptr)
  unsigned long long int* startTimes = nullptr;
  unsigned long long int* endTimes = nullptr;

  // Queue pointers (host-accessible buffers)
  void* submissionQueue = nullptr; // Host-accessible SQE buffer
  void* completionQueue = nullptr; // Host-accessible CQE buffer

  // Endpoint-specific configuration (opaque pointer)
  // Endpoints cast this to their specific config type
  void* endpointConfig = nullptr;

  // Default constructor
  XioEndpointConfig() = default;

  // Convenience constructor for simple cases
  XioEndpointConfig(unsigned iter, unsigned threads = 1)
    : iterations(iter), numThreads(threads) {
  }
};

/*
 * XioEndpoint Base Class
 *
 * Base class for all endpoint implementations. Uses polymorphism to
 * eliminate switch statements and function pointers.
 */
class XioEndpoint {
public:
  virtual ~XioEndpoint() = default;

  // Accessors (host-only)
  __host__ virtual EndpointType getType() const = 0;
  __host__ virtual const char* getName() const = 0;
  __host__ virtual const char* getDescription() const = 0;

  // Get queue entry sizes (host-only) - each derived class knows its sizes
  __host__ virtual size_t getSubmissionQueueEntrySize() const = 0;
  __host__ virtual size_t getCompletionQueueEntrySize() const = 0;

  // Get queue lengths (host-only) - number of entries needed
  // Default implementation returns numThreads for multi-threaded, 1 for
  // single-threaded Derived classes can override for custom queue sizing (e.g.,
  // doorbell mode)
  __host__ virtual size_t getSubmissionQueueLength(
    const XioEndpointConfig* config) const;
  __host__ virtual size_t getCompletionQueueLength(
    const XioEndpointConfig* config) const;

  // Run endpoint test - launches GPU kernel and waits for completion
  // Each derived class implements this to call its specific run function
  __host__ virtual hipError_t run(XioEndpointConfig* config) = 0;

  // Configure endpoint-specific CLI options
  // Derived classes can override this to add their own CLI flags/options
  // Default implementation does nothing (no endpoint-specific options)
  __host__ virtual void configureCliOptions(CLI::App& app);

  // Initialize endpoint-specific configuration
  // Called after CLI parsing to set up endpointConfig pointer
  // Returns pointer to endpoint-specific config object (or nullptr if none)
  // Caller is responsible for managing the lifetime of the returned object
  __host__ virtual void* initializeEndpointConfig();

  // Apply common configuration to endpoint-specific config
  // Called after initializeEndpointConfig to copy common flags/options
  // Default implementation does nothing
  __host__ virtual void applyCommonConfig(void* endpointConfig,
                                          const XioEndpointConfig* baseConfig);

  // Validate endpoint-specific configuration
  // Called after applyCommonConfig to validate and auto-detect settings
  // Returns empty string if valid, error message otherwise
  // Default implementation returns empty string (no validation)
  __host__ virtual std::string validateConfig(void* endpointConfig);

  // Get iterations count for this endpoint
  // Called after validateConfig to determine how many iterations to run
  // Default implementation returns 128
  // Endpoints can override to return endpoint-specific value
  __host__ virtual unsigned getIterations(void* endpointConfig) const;

  // Check if endpoint is in emulate mode (runs on CPU instead of GPU)
  // Returns true if emulate mode is enabled, false otherwise
  // Default implementation returns false
  __host__ virtual bool isEmulateMode() const;

  // Get doorbell queue length (if doorbell mode is enabled)
  // Returns doorbell queue length if doorbell mode is enabled, 0 otherwise
  // Default implementation returns 0
  __host__ virtual unsigned getDoorbellQueueLength() const;
};

// Factory function to create endpoint instances
// Returns unique_ptr for proper ownership management
__host__ std::unique_ptr<XioEndpoint> createEndpoint(EndpointType type);
__host__ std::unique_ptr<XioEndpoint> createEndpoint(
  const std::string& endpointName);

// Helper functions
void xioPrintDeviceInfo();
std::string xioGetModelName(int deviceId);
void xioPrintGpuDeviceDetails(int deviceId);
void xioPrintStatistics(const std::vector<double>& durations,
                        unsigned totalIterations = 0, unsigned numThreads = 0,
                        unsigned readIterations = 0,
                        unsigned writeIterations = 0,
                        unsigned verifiedReadsCount = 0);
void xioPrintHistogram(const std::vector<double>& durations,
                       unsigned nIterations, unsigned numThreads = 0,
                       unsigned readIterations = 0,
                       unsigned writeIterations = 0,
                       unsigned verifiedReadsCount = 0);

// Queue memory allocation functions
// memoryMode bits: Bit 0 (LSB) = GPU write location (0=host, 1=device)
//                  Bit 1 = CPU write location (0=host, 1=device)
//                  Bit 2 = Doorbell location (0=host, 1=device)
//                  Bit 3 = Data buffer location (0=host, 1=device)
hipError_t xioAllocateSubmissionQueue(size_t size, unsigned memoryMode,
                                      void** ptr);
hipError_t xioAllocateCompletionQueue(size_t size, unsigned memoryMode,
                                      void** ptr);
hipError_t xioAllocateDataBuffer(size_t size, unsigned memoryMode, void** ptr);
void xioFreeSubmissionQueue(void* ptr, unsigned memoryMode);
void xioFreeCompletionQueue(void* ptr, unsigned memoryMode);
void xioFreeDataBuffer(void* ptr, unsigned memoryMode);

// HSA device memory allocation (for doorbell and other device memory needs)
hsa_status_t xioAllocDeviceMemory(size_t size, void** ptr,
                                  const char* direction);

// Extract endpoint name from command line arguments
// This allows endpoints to add their CLI options before full parsing
// Returns empty string if endpoint name not found in arguments
std::string xioExtractEndpointName(int argc, char** argv);

// Detect PCI MMIO bridge BDF by scanning PCI devices
// Looks for Vendor ID 0x1b36 (Red Hat, Inc.) and Device ID 0x0015
// Returns 0 on success with BDF in *bdf_out, negative error code on failure
// Errors out if 0 or >1 PCI MMIO bridges are found
int xioDetectPciMmioBridgeBdf(uint16_t* bdf_out);

// Detect PCI BDF from device file path
// Takes a device path like /dev/nvme0 or /dev/nvme1
// Returns 0 on success with BDF in *bdf_out, negative error code on failure
// Returns -ENODEV if device not found or not a PCI device
__host__ int xioDetectBdfFromDevice(const char* device_path, uint16_t* bdf_out);

// Detect if NVMe controller is emulated based on Vendor ID and Device ID
// Takes a device path like /dev/nvme0 or /dev/nvme1
// Returns 0 on success with is_emulated in *is_emulated_out, negative error
// code on failure Returns -ENODEV if device not found or not a PCI device
// Emulated NVMe controllers typically have Vendor ID 0x1b36 (Red Hat/QEMU)
__host__ int xioDetectEmulatedNvme(const char* device_path,
                                   bool* is_emulated_out);

// Kernel module management functions
// Check if rocm-xio kernel module is loaded
// Returns true if module is loaded, false otherwise
__host__ bool xioCheckKernelModuleLoaded();

// Attempt to load rocm-xio kernel module
// Returns 0 on success, negative error code on failure
__host__ int xioLoadKernelModule();

// Ensure rocm-xio device node exists, create if missing
// Returns 0 on success, negative error code on failure
// Note: Creating device node requires root permissions
__host__ int xioEnsureDeviceNode();

// Physical address translation
// Get physical address from virtual address using /proc/self/pagemap
//
// This function reads the kernel's pagemap to translate a virtual address
// to its corresponding physical address. This is useful for obtaining DMA
// addresses for host-allocated memory buffers.
//
// Note: This method may not work reliably in all environments:
// - Requires CAP_SYS_ADMIN or root privileges
// - May not work correctly with IOMMU enabled
// - For device memory (VRAM), use DMA-BUF export instead
//
// @param virt_addr Virtual address to translate
// @return Physical address on success, 0 on failure
__host__ uint64_t xioGetPhysAddr(void* virt_addr);

//
// Common endpoint utilities namespace
//
namespace xio_ep {

/**
 * Generic doorbell ringing function for direct memory-mapped I/O
 *
 * This is the base implementation for simple doorbell patterns where
 * we write a value directly to a memory-mapped register.
 *
 * @param doorbell_addr GPU-accessible pointer to doorbell register
 * @param value Value to write to doorbell (typically queue tail)
 */
__host__ __device__ static inline void ringDoorbell(
  volatile uint32_t* doorbell_addr, uint32_t value) {
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif
  *doorbell_addr = value;
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif
}

/**
 * Generic doorbell ringing with offset calculation
 *
 * Convenience wrapper for doorbells that are offset from a base address.
 *
 * @param base_addr Base address (e.g., BAR0)
 * @param offset Offset from base address to doorbell register
 * @param value Value to write to doorbell
 */
__host__ __device__ static inline void ringDoorbell(void* base_addr,
                                                    uint32_t offset,
                                                    uint32_t value) {
  if (base_addr != nullptr) {
    volatile uint32_t* doorbell_reg = reinterpret_cast<volatile uint32_t*>(
      static_cast<volatile char*>(base_addr) + offset);
    ringDoorbell(doorbell_reg, value);
  }
}

} // namespace xio_ep

#endif // XIO_H
