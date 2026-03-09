/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef XIO_H
#define XIO_H

#include <climits>
#include <cstdint>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include <hip/hip_runtime.h>

#include <drm/amdgpu_drm.h>
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
 * Timing statistics structure for less-timing mode
 * Tracks min, max, sum, and count of IO completion times
 */
struct XioTimingStats {
  unsigned long long int minDuration = ULLONG_MAX; // Minimum duration in GPU
                                                   // ticks
  unsigned long long int maxDuration = 0; // Maximum duration in GPU ticks
  unsigned long long int sumDuration = 0; // Sum of durations in GPU ticks
  unsigned long long int count = 0;       // Number of IO operations
};

/**
 * Base configuration structure for all endpoints
 *
 * Contains common testing parameters that apply to all endpoints.
 * Endpoints can extend this with their own configuration structures
 * via the endpointConfig pointer.
 */
struct XioEndpointConfig {
  // Common testing parameters
  unsigned iterations = 128;  // Number of iterations
  unsigned numThreads = 1;    // Number of GPU threads (1-32)
  long long delayNs = 0;      // Delay in nanoseconds
                              // Negative: fixed delay of |delayNs|
                              // Positive: random delay 0 to delayNs
                              // Zero: no delay
  unsigned memoryMode = 0;    // Memory mode bits:
                              // Bit 0 (LSB): GPU write location (SQE)
                              //   (0=host, 1=device)
                              // Bit 1: CPU write location (CQE)
                              //   (0=host, 1=device)
                              // Bit 2: Doorbell location (doorbell mode only)
                              //   (0=host, 1=device)
  bool verbose = false;       // Verbose output flag
  bool pciMmioBridge = false; // Use PCI MMIO bridge for doorbell routing

  // Timing arrays (optional, can be nullptr)
  // Used when full timing is enabled (default mode)
  unsigned long long int* startTimes = nullptr;
  unsigned long long int* endTimes = nullptr;

  // Timing statistics (optional, can be nullptr)
  // Used when less-timing mode is enabled
  XioTimingStats* timingStats = nullptr;

  // Queue pointers (host-accessible buffers)
  void* submissionQueue = nullptr; // Host-accessible SQE buffer
  void* completionQueue = nullptr; // Host-accessible CQE buffer

  // Stop flag for graceful shutdown (SIGINT handling)
  // Allocated with hipHostMalloc to be GPU-accessible
  // Set to true by signal handler to request kernel stop
  volatile bool* stopRequested = nullptr;

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
hipError_t xioAllocateQueue(size_t size, bool isDeviceMemory,
                            const char* queueName, void** ptr);
bool xioReallocateQueue(void** ptr, size_t size, const char* queueName);
struct drm_amdgpu_gem_userptr* xioRegQueueGpu(
  void* queue_virt, size_t queue_size_aligned, bool is_device,
  const char* queue_name, struct drm_amdgpu_gem_userptr* userptr);
void* xioGetGpuPointer(void* host_ptr, bool is_device, const char* queue_name);
hipError_t xioAllocateDataBuffer(size_t size, unsigned memoryMode, void** ptr);
void xioFreeQueue(void* ptr, bool isDeviceMemory, const char* queueName);
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

// Open a device file with retry logic for temporary busy conditions
// Handles EAGAIN/EWOULDBLOCK errors by retrying with exponential backoff
//
// @param device_path Path to the device file to open
// @param flags Open flags (e.g., O_RDONLY, O_RDWR)
// @param device_name Human-readable device name for error messages (can be
// NULL)
// @param max_retries Maximum number of retry attempts (default: 5)
// @param initial_delay_ms Initial delay in milliseconds before first retry
//                         (default: 100ms, doubles with each retry)
//
// @return File descriptor on success, -1 on failure (errno is set)
//
// @note Only retries on EAGAIN/EWOULDBLOCK errors. Other errors fail
//       immediately. Uses exponential backoff: delay = initial_delay_ms *
//       (2^retry)
__host__ int xioOpenDeviceWithRetry(const char* device_path, int flags,
                                    const char* device_name, int max_retries,
                                    int initial_delay_ms);

// Export HSA-allocated VRAM as DMA-BUF and register with kernel module
// Returns 0 on success, negative error code on failure
// is_emulated: true for emulated NVMe (returns GPU BAR GPA), false for
// passthrough (returns P2PDMA IOVA)
__host__ int export_and_register_vram_buffer(void* vram_ptr, size_t size,
                                             uint16_t nvme_bdf,
                                             const char* kernel_module_device,
                                             uint64_t* phys_addr_out,
                                             bool is_emulated);

// Buffer allocation result structure
struct xioBufferInfo {
  void* hostPtr;    // Host-accessible pointer (from hipMalloc or hipHostMalloc)
  void* gpuPtr;     // GPU-accessible pointer (may be same as hostPtr for device
                    // memory)
  uint64_t dmaAddr; // DMA/physical address for device access
  bool isDeviceMemory; // true if allocated with hipMalloc, false if
                       // hipHostMalloc
};

// Allocate GPU-accessible buffer for DMA operations
// This function allocates a buffer (device or host memory based on memoryMode)
// and sets it up for GPU access and DMA operations.
//
// For device memory (memoryMode bit 3 set):
//   - Allocates with hipMalloc
//   - Exports as DMA-BUF and registers with kernel module
//   - Returns DMA address from DMA-BUF export
//
// For host memory:
//   - Allocates with hipHostMalloc (mapped for GPU access)
//   - Gets physical address via xioGetPhysAddr
//   - Gets GPU pointer via hipHostGetDevicePointer
//
// @param size Buffer size in bytes
// @param memoryMode Memory mode flags (bit 3 = device memory)
// @param targetBdf Target device BDF for DMA-BUF registration (0 if not needed)
// @param devicePath Device path for emulation detection (nullptr if not needed)
// @param bufferInfo Output structure for buffer information
//
// @return hipSuccess on success, error code on failure
// @note On failure, bufferInfo->hostPtr will be nullptr
__host__ hipError_t xioAllocateGpuAccessibleBuffer(
  size_t size, unsigned memoryMode, uint16_t targetBdf, const char* devicePath,
  struct xioBufferInfo* bufferInfo);

// Free GPU-accessible buffer allocated with xioAllocateGpuAccessibleBuffer
// Uses the isDeviceMemory flag to determine correct free function
//
// @param bufferInfo Buffer info structure from xioAllocateGpuAccessibleBuffer
__host__ void xioFreeGpuAccessibleBuffer(struct xioBufferInfo* bufferInfo);

// Validate that a pointer is GPU-accessible
// This function checks if a pointer can be accessed by GPU code using
// hipPointerGetAttributes.
//
// @param ptr Pointer to validate (can be nullptr, in which case returns true)
// @param name Descriptive name for the pointer (used in error messages)
// @param disableOnFailure If true, prints error and returns false on failure.
//                         If false, prints warning but still returns false.
//
// @return true if pointer is GPU-accessible (or nullptr), false otherwise
__host__ bool xioValidateGpuPointer(void* ptr, const char* name,
                                    bool disableOnFailure);

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
// - For device memory (VRAM), use the overloaded version with device memory
//   parameters instead
//
// @param virt_addr Virtual address to translate
// @return Physical address on success, 0 on failure
__host__ uint64_t xioGetPhysAddr(void* virt_addr);

// Get physical address for a buffer (unified interface for device and host
// memory) For device memory: exports as DMA-BUF and registers with kernel
// module For host memory: uses /proc/self/pagemap to get physical address
//
// @param buffer_ptr Buffer virtual address
// @param size Buffer size in bytes
// @param is_device True if buffer is device memory (VRAM), false for host
// memory
// @param nvme_bdf NVMe controller BDF (required for device memory)
// @param kernel_module_device Path to kernel module device (required for device
// memory)
// @param is_emulated True if NVMe controller is emulated (required for device
// memory)
// @param buffer_name Name of buffer for logging (e.g., "submission queue")
//
// @return Physical address on success, 0 on failure
//
// @note For device memory, this exports the buffer as DMA-BUF and registers it
//       with the kernel module. For host memory, this uses pagemap lookup.
//       On failure, returns 0. Caller should handle fallback to virtual address
//       if needed.
__host__ uint64_t xioGetPhysAddr(void* buffer_ptr, size_t size, bool is_device,
                                 uint16_t nvme_bdf,
                                 const char* kernel_module_device,
                                 bool is_emulated, const char* buffer_name);
int xioKmodRegQueue(int kmod_fd, void* virt_addr, uint64_t phys_addr,
                    size_t size, uint8_t queue_type, const char* queue_name);

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

//
// PCI MMIO Bridge structures and definitions
//
// These structures are used for PCI MMIO bridge doorbell routing, which
// allows GPU-initiated MMIO writes to be routed through QEMU's PCI MMIO
// bridge device. This is endpoint-agnostic and can be used by any endpoint
// that needs to perform MMIO operations from GPU code.

// PCI MMIO Bridge ring metadata structure (matching QEMU implementation)
struct pci_mmio_bridge_ring_meta {
  uint32_t producer_idx; // Guest/device write index (tail)
  uint32_t consumer_idx; // QEMU read index (head)
  uint32_t queue_depth;  // Total number of command slots
  uint32_t reserved;
} __attribute__((packed));

// PCI MMIO Bridge command structure (matching QEMU implementation)
struct pci_mmio_bridge_command {
  uint16_t target_bdf; // Bus:Device:Function (bus|devfn)
  uint8_t target_bar;  // Which BAR on target device (0-5)
  uint8_t reserved1;
  uint32_t offset; // Offset within BAR
  uint64_t value;  // Value to write, or returned value for read
  uint8_t command; // Command type (WRITE=1, READ=2)
  uint8_t size;    // Transfer size: 1, 2, 4, or 8 bytes
  uint8_t status;  // Status (PENDING=0, COMPLETE=1, ERROR=2)
  uint8_t reserved2;
  uint32_t sequence; // Sequence number for ordering
} __attribute__((packed));

// PCI MMIO Bridge command types
#define PCI_MMIO_BRIDGE_CMD_NOP 0
#define PCI_MMIO_BRIDGE_CMD_WRITE 1
#define PCI_MMIO_BRIDGE_CMD_READ 2

// PCI MMIO Bridge status codes
#define PCI_MMIO_BRIDGE_STATUS_PENDING 0
#define PCI_MMIO_BRIDGE_STATUS_COMPLETE 1
#define PCI_MMIO_BRIDGE_STATUS_ERROR 2

// Map PCI MMIO bridge shadow buffer via kernel module
// Returns 0 on success, negative error code on failure
// The shadow buffer is mapped into the process address space and remains
// valid until the process exits (kernel module keeps the file descriptor
// open for the mapping)
__host__ int xioMapMmioBridgeShadowBuffer(uint16_t bridge_bdf,
                                          void** virt_addr);

// Register PCI MMIO bridge shadow buffer for GPU access
// This function registers a shadow buffer (already mapped via
// xioMapMmioBridgeShadowBuffer) with DRM GEM_USERPTR and HIP to make it
// GPU-accessible.
//
// @param shadow_virt Host virtual address of shadow buffer (from mmap)
// @param shadow_size Size of shadow buffer in bytes (typically 8192)
// @param gpu_ptr_out Output parameter for GPU-accessible pointer
//
// @return 0 on success, negative error code on failure
// @note On failure, the shadow buffer is unmapped and cleaned up
// @note The DRM file descriptor is closed after registration (mapping persists)
__host__ int xioRegisterMmioBridgeShadowBufferForGpu(void* shadow_virt,
                                                     size_t shadow_size,
                                                     void** gpu_ptr_out);

// Map PCI BAR for GPU access
// This function maps a PCI device's BAR (Base Address Register) to userspace
// and registers it with DRM GEM_USERPTR and HIP for GPU access.
//
// @param pci_bdf PCI device BDF in 0xBBDD format
// @param bar BAR number to map (0-5, typically 0 for BAR0)
// @param bar_cpu Output parameter for CPU-accessible BAR pointer
// @param bar_gpu Output parameter for GPU-accessible BAR pointer
// @param bar_size Size to map in bytes (defaults to 8192 if 0)
//
// @return 0 on success, negative error code on failure
// @note The file descriptors are kept open for the mapping to remain valid
// @note The kernel will clean up mappings when the process exits
__host__ int xioMapPciBar(uint16_t pci_bdf, uint8_t bar, void** bar_cpu,
                          void** bar_gpu, size_t bar_size);

// Generate and submit a PCI MMIO bridge command
// This function handles the ring buffer management, command structure
// population, and memory ordering for PCI MMIO bridge operations.
//
// @param shadowBufferVirt Shadow buffer pointer (must point to ring_meta)
// @param targetBdf Target device BDF (0xBBDD format)
// @param targetBar Target BAR number (typically 0)
// @param offset Offset within BAR
// @param value Value to write (or read result)
// @param command Command type (PCI_MMIO_BRIDGE_CMD_WRITE or READ)
// @param size Transfer size in bytes (1, 2, 4, or 8)
//
// @note This function is callable from both host and device code
// @note Memory fences are executed to ensure proper ordering
__host__ __device__ void genPciMmioBridgeCmd(void* shadowBufferVirt,
                                             uint16_t targetBdf,
                                             uint8_t targetBar, uint32_t offset,
                                             uint64_t value, uint8_t command,
                                             uint8_t size);

#endif // XIO_H
