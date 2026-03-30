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

#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <linux/ioctl.h>

// Forward declaration for CLI11
namespace CLI {
class App;
}

#include "xio-endpoint-includes-gen.h"
#include "xio-endpoint-registry.h"

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

// ---------------------------------------------------------
// Kernel module IOCTL interface
// (merged from rocm-xio-kmod.h)
// ---------------------------------------------------------

#define ROCM_XIO_IOC_MAGIC 'R'

#define ROCM_XIO_FLAG_EMULATED (1 << 0)
#define ROCM_XIO_FLAG_PASSTHROUGH (1 << 1)

struct rocm_axiio_vram_req {
  int dmabuf_fd;
  uint16_t nvme_bdf;
  uint32_t flags;
  uint64_t phys_addr;
  uint64_t size;
};

struct rocm_axiio_register_queue_addr_req {
  uint64_t virt_addr;
  uint64_t phys_addr;
  uint64_t size;
  uint64_t prp2;
  uint16_t nvme_bdf;
  uint8_t queue_type;
  uint8_t reserved[5];
};

struct rocm_axiio_register_buffer_req {
  int dmabuf_fd;
  uint64_t virt_addr;
  uint64_t phys_addr;
  uint64_t size;
  uint16_t nvme_bdf;
  uint32_t flags;
};

struct rocm_axiio_mmio_bridge_shadow_req {
  uint16_t bridge_bdf;
  uint64_t shadow_gpa;
  uint64_t shadow_size;
};

#define ROCM_XIO_GET_VRAM_PHYS_ADDR                                            \
  _IOWR(ROCM_XIO_IOC_MAGIC, 1, struct rocm_axiio_vram_req)
#define ROCM_XIO_REGISTER_QUEUE_ADDR                                           \
  _IOW(ROCM_XIO_IOC_MAGIC, 6, struct rocm_axiio_register_queue_addr_req)
#define ROCM_XIO_REGISTER_BUFFER                                               \
  _IOW(ROCM_XIO_IOC_MAGIC, 8, struct rocm_axiio_register_buffer_req)
#define ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER                                 \
  _IOWR(ROCM_XIO_IOC_MAGIC, 10, struct rocm_axiio_mmio_bridge_shadow_req)

struct rocm_axiio_alloc_contig_req {
  uint64_t size;
  uint16_t nvme_bdf;
  uint64_t phys_addr;
  uint32_t mmap_offset;
};

struct rocm_axiio_free_contig_req {
  uint32_t mmap_offset;
};

#define ROCM_XIO_ALLOC_CONTIG_QUEUE                                            \
  _IOWR(ROCM_XIO_IOC_MAGIC, 11, struct rocm_axiio_alloc_contig_req)
#define ROCM_XIO_FREE_CONTIG_QUEUE                                             \
  _IOW(ROCM_XIO_IOC_MAGIC, 12, struct rocm_axiio_free_contig_req)

// Memory mode flags (bits in memoryMode field)
#define XIO_MEM_MODE_SQ_DEVICE 0x1
#define XIO_MEM_MODE_CQ_DEVICE 0x2
#define XIO_MEM_MODE_DOORBELL_DEVICE 0x4
#define XIO_MEM_MODE_DATA_DEVICE 0x8

// Device memory allocation flags for allocDeviceMemory()
#define XIO_DEVICE_MEM_FINE_GRAINED 0x0
#define XIO_DEVICE_MEM_COARSE_GRAINED 0x1
#define XIO_DEVICE_MEM_UNCACHED 0x2
#define XIO_DEVICE_MEM_VMEM 0x4
#define XIO_DEVICE_MEM_HIP 0x8

// Host memory allocation flags for allocHostMemory()
#define XIO_HOST_MEM_MAPPED 0x0
#define XIO_HOST_MEM_COHERENT 0x1
#define XIO_HOST_MEM_PINNED 0x2
#define XIO_HOST_MEM_PLAIN 0x4

// PCI MMIO Bridge command types
#define PCI_MMIO_BRIDGE_CMD_NOP 0
#define PCI_MMIO_BRIDGE_CMD_WRITE 1
#define PCI_MMIO_BRIDGE_CMD_READ 2

// PCI MMIO Bridge status codes
#define PCI_MMIO_BRIDGE_STATUS_PENDING 0
#define PCI_MMIO_BRIDGE_STATUS_COMPLETE 1
#define PCI_MMIO_BRIDGE_STATUS_ERROR 2

namespace xio {

/**
 * @brief Timing statistics for less-timing mode.
 *
 * Tracks min, max, sum, and count of IO completion times.
 */
struct XioTimingStats {
  unsigned long long int minDuration = ULLONG_MAX;
  unsigned long long int maxDuration = 0;
  unsigned long long int sumDuration = 0;
  unsigned long long int count = 0;
};

/**
 * @brief Base configuration structure for all endpoints.
 *
 * Contains common testing parameters that apply to all
 * endpoints. Endpoints can extend this with their own
 * configuration structures via the endpointConfig pointer.
 */
struct XioEndpointConfig {
  unsigned iterations = 128;
  unsigned numThreads = 1;
  long long delayNs = 0;
  unsigned memoryMode = 0;
  bool verbose = false;
  bool pciMmioBridge = false;

  unsigned long long int* startTimes = nullptr;
  unsigned long long int* endTimes = nullptr;
  XioTimingStats* timingStats = nullptr;

  void* submissionQueue = nullptr;
  void* completionQueue = nullptr;
  volatile bool* stopRequested = nullptr;
  void* endpointConfig = nullptr;

  XioEndpointConfig() = default;
  XioEndpointConfig(unsigned iter, unsigned threads = 1)
    : iterations(iter), numThreads(threads) {
  }
};

/**
 * @brief Base class for all endpoint implementations.
 *
 * Uses polymorphism to eliminate switch statements and
 * function pointers.
 */
class XioEndpoint {
public:
  virtual ~XioEndpoint() = default;

  /** @brief Get the endpoint type identifier. */
  __host__ virtual EndpointType getType() const = 0;

  /** @brief Get the endpoint name string. */
  __host__ virtual const char* getName() const = 0;

  /** @brief Get a human-readable description. */
  __host__ virtual const char* getDescription() const = 0;

  /** @brief Get submission queue entry size in bytes. */
  __host__ virtual size_t getSubmissionQueueEntrySize() const = 0;

  /** @brief Get completion queue entry size in bytes. */
  __host__ virtual size_t getCompletionQueueEntrySize() const = 0;

  /**
   * @brief Get number of submission queue entries.
   * @param config Base endpoint configuration.
   * @return Number of entries (default: numThreads).
   */
  __host__ virtual size_t getSubmissionQueueLength(
    const XioEndpointConfig* config) const;

  /**
   * @brief Get number of completion queue entries.
   * @param config Base endpoint configuration.
   * @return Number of entries (default: numThreads).
   */
  __host__ virtual size_t getCompletionQueueLength(
    const XioEndpointConfig* config) const;

  /**
   * @brief Run the endpoint test.
   * @param config Endpoint configuration.
   * @return hipSuccess on success, error code on failure.
   */
  __host__ virtual hipError_t run(XioEndpointConfig* config) = 0;

  /**
   * @brief Configure endpoint-specific CLI options.
   * @param app CLI11 application to add options to.
   */
  __host__ virtual void configureCliOptions(CLI::App& app);

  /**
   * @brief Initialize endpoint-specific configuration.
   * @return Pointer to config object, or nullptr.
   */
  __host__ virtual void* initializeEndpointConfig();

  /**
   * @brief Apply common config to endpoint config.
   * @param endpointConfig Endpoint-specific config pointer.
   * @param baseConfig Base configuration.
   */
  __host__ virtual void applyCommonConfig(void* endpointConfig,
                                          const XioEndpointConfig* baseConfig);

  /**
   * @brief Validate endpoint-specific configuration.
   * @param endpointConfig Endpoint config to validate.
   * @return Empty string if valid, error message otherwise.
   */
  __host__ virtual std::string validateConfig(void* endpointConfig);

  /**
   * @brief Get iteration count for this endpoint.
   * @param endpointConfig Endpoint config pointer.
   * @return Number of iterations to run.
   */
  __host__ virtual unsigned getIterations(void* endpointConfig) const;

  /**
   * @brief Check if endpoint is in emulate mode.
   * @return true if emulate mode is enabled.
   */
  __host__ virtual bool isEmulateMode() const;

  /**
   * @brief Get doorbell queue length.
   * @return Doorbell queue length, or 0 if disabled.
   */
  __host__ virtual unsigned getDoorbellQueueLength() const;
};

/**
 * @brief Create an endpoint instance by type enum.
 * @param type Endpoint type identifier.
 * @return Unique pointer to the created endpoint.
 */
__host__ std::unique_ptr<XioEndpoint> createEndpoint(EndpointType type);

/**
 * @brief Create an endpoint instance by name string.
 * @param endpointName Name of the endpoint.
 * @return Unique pointer to the created endpoint.
 */
__host__ std::unique_ptr<XioEndpoint> createEndpoint(
  const std::string& endpointName);

/**
 * @brief Print information about all available GPU devices.
 */
void printDeviceInfo();

/**
 * @brief Get the model name string for a GPU device.
 * @param deviceId HIP device identifier.
 * @return Model name string.
 */
std::string getModelName(int deviceId);

/**
 * @brief Print detailed GPU device properties.
 * @param deviceId HIP device identifier.
 */
void printGpuDeviceDetails(int deviceId);

/**
 * @brief Print timing statistics from duration data.
 * @param durations Vector of durations in nanoseconds.
 * @param totalIterations Total iteration count (0 to omit).
 * @param numThreads Thread count (0 to omit).
 * @param readIterations Read count (0 to omit).
 * @param writeIterations Write count (0 to omit).
 * @param verifiedReadsCount Verified reads (0 to omit).
 */
void printStatistics(const std::vector<double>& durations,
                     unsigned totalIterations = 0, unsigned numThreads = 0,
                     unsigned readIterations = 0, unsigned writeIterations = 0,
                     unsigned verifiedReadsCount = 0);

/**
 * @brief Print a histogram and statistics from durations.
 * @param durations Vector of durations in nanoseconds.
 * @param nIterations Number of iterations for binning.
 * @param numThreads Thread count (0 to omit).
 * @param readIterations Read count (0 to omit).
 * @param writeIterations Write count (0 to omit).
 * @param verifiedReadsCount Verified reads (0 to omit).
 */
void printHistogram(const std::vector<double>& durations, unsigned nIterations,
                    unsigned numThreads = 0, unsigned readIterations = 0,
                    unsigned writeIterations = 0,
                    unsigned verifiedReadsCount = 0);

/**
 * @brief Allocate queue memory (device or host).
 * @param size Size of queue in bytes.
 * @param isDeviceMemory true for hipMalloc, false for
 *                       hipHostMalloc.
 * @param queueName Name for error messages.
 * @param ptr Output pointer to allocated memory.
 * @return hipSuccess on success.
 */
hipError_t allocateQueue(size_t size, bool isDeviceMemory,
                         const char* queueName, void** ptr);

/**
 * @brief Free queue memory.
 * @param ptr Pointer to free.
 * @param isDeviceMemory true if allocated with hipMalloc.
 * @param queueName Name for error messages.
 */
void freeQueue(void* ptr, bool isDeviceMemory, const char* queueName);

/**
 * @brief Reallocate host queue with coherent memory.
 *
 * Critical for gfx900 (MI250) where GPU writes must be
 * immediately visible to PCIe devices.
 *
 * @param ptr Pointer to current allocation (updated on
 *            success).
 * @param size Size of queue in bytes.
 * @param queueName Name for error messages.
 * @return true if reallocated to coherent memory.
 */
bool reallocateQueue(void** ptr, size_t size, const char* queueName);

/**
 * @brief Get GPU-accessible pointer for a queue.
 * @param host_ptr Host-accessible pointer.
 * @param is_device true if device memory.
 * @param queue_name Name for logging.
 * @return GPU-accessible pointer, or NULL on failure.
 */
void* getGpuPointer(void* host_ptr, bool is_device, const char* queue_name);

/**
 * @brief Allocate a data buffer (device or host).
 * @param size Buffer size in bytes.
 * @param memoryMode Memory mode flags.
 * @param ptr Output pointer.
 * @return hipSuccess on success.
 */
hipError_t allocateDataBuffer(size_t size, unsigned memoryMode, void** ptr);

/**
 * @brief Free a data buffer.
 * @param ptr Pointer to free.
 * @param memoryMode Memory mode used at allocation time.
 */
void freeDataBuffer(void* ptr, unsigned memoryMode);

/**
 * @brief Allocate GPU device memory.
 *
 * Selects a backend based on flags:
 *  - FINE_GRAINED / COARSE_GRAINED: HSA region alloc.
 *  - HIP: hipMalloc (DMA-BUF exportable).
 *  - UNCACHED: hipExtMallocWithFlags (uncached).
 *  - VMEM: HIP VMM (reserve + map + access).
 *
 * @param size Size in bytes.
 * @param ptr Output pointer.
 * @param label Label for logging.
 * @param flags XIO_DEVICE_MEM_* flags (default:
 *              fine-grained).
 * @param gpuId GPU device ID (only used for VMEM path,
 *              default: 0).
 * @return HSA status code.
 */
hsa_status_t allocDeviceMemory(size_t size, void** ptr, const char* label,
                               unsigned flags = XIO_DEVICE_MEM_FINE_GRAINED,
                               int gpuId = 0);

/**
 * @brief Free device memory allocated by
 *        allocDeviceMemory().
 * @param ptr Pointer to free.
 * @param flags Flags used at allocation time.
 */
void freeDeviceMemory(void* ptr, unsigned flags);

/**
 * @brief Allocate host memory with consistent semantics.
 * @param size Size in bytes.
 * @param ptr Output pointer.
 * @param label Label for logging.
 * @param flags XIO_HOST_MEM_* flags (default: mapped).
 * @return hipSuccess on success.
 */
hipError_t allocHostMemory(size_t size, void** ptr, const char* label,
                           unsigned flags = XIO_HOST_MEM_MAPPED);

/**
 * @brief Free host memory allocated by
 *        allocHostMemory().
 * @param ptr Pointer to free.
 * @param flags Flags used at allocation time.
 */
void freeHostMemory(void* ptr, unsigned flags);

/**
 * @brief Export memory as DMA-BUF.
 *
 * Uses hsa_amd_portable_export_dmabuf (v1) when flags
 * are zero, and hsa_amd_portable_export_dmabuf_v2 when
 * explicit flags are requested (ROCm 7.1+).
 *
 * @param ptr Pointer to export.
 * @param size Size in bytes.
 * @param fd_out Output dmabuf file descriptor.
 * @param offset_out Output offset within dmabuf.
 * @param flags hsa_amd_dma_buf_mapping_type_t flags
 *              (default: NONE).
 * @return HSA status code.
 */
hsa_status_t exportDmabuf(const void* ptr, size_t size, int* fd_out,
                          uint64_t* offset_out, uint64_t flags = 0);

/**
 * @brief Close a dmabuf file descriptor.
 *
 * Calls hsa_amd_portable_close_dmabuf (ROCm 7.1+).
 *
 * @param fd dmabuf file descriptor to close.
 * @return HSA status code.
 */
hsa_status_t closeDmabuf(int fd);

/**
 * @brief Extract endpoint name from CLI arguments.
 * @param argc Argument count.
 * @param argv Argument values.
 * @return Endpoint name, or empty string if not found.
 */
__host__ std::string extractEndpointName(int argc, char** argv);

/**
 * @brief Detect PCI MMIO bridge BDF by scanning PCI sysfs.
 *
 * Looks for Vendor ID 0x1b36 and Device ID 0x0015. Errors
 * out if zero or more than one bridge is found.
 *
 * @param bdf_out Output BDF in 0xBBDD format.
 * @return 0 on success, negative error code on failure.
 */
__host__ int detectPciMmioBridgeBdf(uint16_t* bdf_out);

/**
 * @brief Detect PCI BDF from a device file path.
 * @param device_path Device path (e.g., "/dev/nvme0").
 * @param bdf_out Output BDF in 0xBBDD format.
 * @return 0 on success, negative error code on failure.
 */
__host__ int detectBdfFromDevice(const char* device_path, uint16_t* bdf_out);

/**
 * @brief Detect if an NVMe controller is emulated.
 *
 * Checks Vendor ID against QEMU's 0x1b36.
 *
 * @param device_path Device path (e.g., "/dev/nvme0").
 * @param is_emulated_out Output: true if emulated.
 * @return 0 on success, negative error code on failure.
 */
__host__ int detectEmulatedNvme(const char* device_path, bool* is_emulated_out);

/**
 * @brief Check if the rocm-xio kernel module is loaded.
 * @return true if module is loaded.
 */
__host__ bool checkKernelModuleLoaded();

/**
 * @brief Load the rocm-xio kernel module via modprobe.
 * @return 0 on success, negative error code on failure.
 */
__host__ int loadKernelModule();

/**
 * @brief Ensure the rocm-xio device node exists.
 * @return 0 on success, negative error code on failure.
 * @note Requires root to create the node.
 */
__host__ int ensureDeviceNode();

/**
 * @brief Open a device with retry and exponential backoff.
 *
 * Retries only on EAGAIN/EWOULDBLOCK errors.
 *
 * @param device_path Path to device file.
 * @param flags Open flags (e.g., O_RDWR).
 * @param device_name Human-readable name (can be NULL).
 * @param max_retries Maximum retry attempts (default: 5).
 * @param initial_delay_ms Initial retry delay in ms
 *                         (default: 100).
 * @return File descriptor on success, -1 on failure.
 */
__host__ int openDeviceWithRetry(const char* device_path, int flags,
                                 const char* device_name, int max_retries,
                                 int initial_delay_ms);

/**
 * @brief Export VRAM as DMA-BUF and register with the
 *        kernel module.
 *
 * @param vram_ptr Pointer to VRAM buffer.
 * @param size Buffer size in bytes.
 * @param nvme_bdf NVMe controller BDF (0xBBDD format).
 * @param kernel_module_device Kernel module device path.
 * @param phys_addr_out Output physical/DMA address.
 * @param is_emulated true for emulated NVMe.
 * @return 0 on success, negative error code on failure.
 *
 * @note Requires ROCm 5.3+ with dmabuf support, kernel
 *       CONFIG_DMABUF_MOVE_NOTIFY and CONFIG_PCI_P2PDMA.
 */
__host__ int exportRegVramBuf(void* vram_ptr, size_t size, uint16_t nvme_bdf,
                              const char* kernel_module_device,
                              uint64_t* phys_addr_out, bool is_emulated);

/**
 * @brief Buffer allocation result structure.
 */
struct xioBufferInfo {
  void* hostPtr;
  void* gpuPtr;
  uint64_t dmaAddr;
  bool isDeviceMemory;
};

/**
 * @brief Allocate a GPU-accessible buffer for DMA.
 *
 * Allocates device or host memory based on memoryMode
 * bit 3 and sets it up for GPU access and DMA operations.
 *
 * @param size Buffer size in bytes.
 * @param memoryMode Memory mode flags (bit 3 = device).
 * @param targetBdf Target BDF for DMA-BUF registration.
 * @param devicePath Path for emulation detection.
 * @param bufferInfo Output buffer information.
 * @return hipSuccess on success, error code on failure.
 */
__host__ hipError_t allocateGpuAccessibleBuffer(
  size_t size, unsigned memoryMode, uint16_t targetBdf, const char* devicePath,
  struct xioBufferInfo* bufferInfo);

/**
 * @brief Free a GPU-accessible buffer.
 * @param bufferInfo Buffer info from
 *                   allocateGpuAccessibleBuffer.
 */
__host__ void freeGpuAccessibleBuffer(struct xioBufferInfo* bufferInfo);

/**
 * @brief Validate that a pointer is GPU-accessible.
 * @param ptr Pointer to validate (nullptr returns true).
 * @param name Descriptive name for error messages.
 * @param disableOnFailure true to print error, false for
 *                         warning.
 * @return true if GPU-accessible (or nullptr).
 */
__host__ bool validateGpuPointer(void* ptr, const char* name,
                                 bool disableOnFailure);

/**
 * @brief Get physical address via /proc/self/pagemap.
 *
 * @param virt_addr Virtual address to translate.
 * @return Physical address on success, 0 on failure.
 *
 * @note Requires CAP_SYS_ADMIN or root. May not work with
 *       IOMMU. For VRAM, use the overloaded version.
 */
__host__ uint64_t getPhysAddr(void* virt_addr);

/**
 * @brief Get physical address for a buffer.
 *
 * For device memory: exports as DMA-BUF and registers with
 * the kernel module.
 * For host memory: uses /proc/self/pagemap.
 *
 * @param buffer_ptr Buffer virtual address.
 * @param size Buffer size in bytes.
 * @param is_device true for device memory (VRAM).
 * @param nvme_bdf NVMe controller BDF.
 * @param kernel_module_device Kernel module device path.
 * @param is_emulated true if NVMe is emulated.
 * @param buffer_name Name for logging.
 * @return Physical address on success, 0 on failure.
 */
__host__ uint64_t getPhysAddr(void* buffer_ptr, size_t size, bool is_device,
                              uint16_t nvme_bdf,
                              const char* kernel_module_device,
                              bool is_emulated, const char* buffer_name);

/**
 * @brief Get physical addresses for each page of a buffer.
 *
 * Uses /proc/self/pagemap to resolve physical addresses.
 * Only works for host memory; device memory uses DMA-BUF.
 *
 * @param virt_addr Page-aligned virtual address.
 * @param size Size of the buffer in bytes.
 * @param phys_out Output array for physical addresses.
 * @param max_pages Maximum entries in phys_out.
 * @return Number of pages on success, negative on failure.
 */
__host__ int getPagePhysAddrs(void* virt_addr, size_t size, uint64_t* phys_out,
                              size_t max_pages);

/**
 * @brief Register a queue address with the kernel module.
 *
 * Registers virtual and physical addresses for kprobe
 * injection into NVMe CREATE_SQ/CREATE_CQ commands.
 *
 * @param kmod_fd File descriptor for kernel module device.
 * @param virt_addr Virtual address of the queue.
 * @param phys_addr Physical address of the queue.
 * @param size Size of the queue in bytes.
 * @param queue_type 0 for SQ, 1 for CQ.
 * @param nvme_bdf NVMe controller BDF.
 * @param prp2 PRP2 address for multi-page queues.
 * @param queue_name Name for logging.
 * @return 0 on success, negative error code on failure.
 */
int kmodRegQueue(int kmod_fd, void* virt_addr, uint64_t phys_addr, size_t size,
                 uint8_t queue_type, uint16_t nvme_bdf, uint64_t prp2,
                 const char* queue_name);

/**
 * @brief Queue setup structure for unified initialization.
 */
struct xioQueueSetup {
  void* virt;
  void* gpu;
  uint64_t phys;
  bool uses_coherent;
  void* prp_list;
  uint64_t prp_list_phys;
  uint64_t prp2;
  bool uses_contig;
  uint32_t contig_id;
};

/**
 * @brief Set up a queue for GPU and PCIe access.
 *
 * Performs allocation, coherent reallocation, HIP
 * registration, GPU pointer acquisition, and physical
 * address resolution.
 *
 * @param size Queue size in bytes.
 * @param is_device true for device memory.
 * @param nvme_bdf NVMe controller BDF.
 * @param kernel_module_device Kernel module device path.
 * @param is_emulated true if NVMe is emulated.
 * @param queue_name Name for logging.
 * @param setup Output structure with pointers/handles.
 * @return 0 on success, negative error code on failure.
 */
__host__ int setupQueueForGpu(size_t size, bool is_device, uint16_t nvme_bdf,
                              const char* kernel_module_device,
                              bool is_emulated, const char* queue_name,
                              struct xioQueueSetup* setup);

/**
 * @brief Build a PRP list for a multi-page queue (PC=0).
 *
 * For queues spanning >1 host memory page, resolves
 * per-page physical addresses and builds a PRP list
 * buffer. Sets setup->prp2, setup->prp_list, and
 * setup->prp_list_phys. No-op for single-page queues.
 *
 * @param setup Queue setup (must have virt allocated).
 * @param queue_size Queue size in bytes.
 * @param is_device true for device memory.
 * @param queue_name Name for logging.
 * @return 0 on success, negative error code on failure.
 */
__host__ int buildQueuePrpList(struct xioQueueSetup* setup, size_t queue_size,
                               bool is_device, const char* queue_name);

/**
 * @brief Allocate contiguous DMA memory via kernel module.
 *
 * Uses dma_alloc_coherent in the kernel module to obtain
 * physically contiguous memory for CQR=1 controllers.
 * Maps the result into userspace and registers with HIP
 * for GPU access (same pattern as mapPciBar).
 *
 * @param size Queue size in bytes.
 * @param nvme_bdf NVMe controller BDF (0xBBDD format).
 * @param queue_name Name for logging.
 * @param setup Output structure with pointers/handles.
 * @param kernel_module_device Kernel module device path
 *        (defaults to ROCM_XIO_DEVICE_PATH).
 * @return 0 on success, negative error code on failure.
 */
__host__ int setupContigQueueForGpu(
  size_t size, uint16_t nvme_bdf, const char* queue_name,
  struct xioQueueSetup* setup,
  const char* kernel_module_device = ROCM_XIO_DEVICE_PATH);

/**
 * @brief Free contiguous DMA queue memory.
 *
 * Unregisters from HIP, unmaps from userspace, and
 * releases the kernel module allocation.
 *
 * @param setup Queue setup from setupContigQueueForGpu.
 * @param size Queue size in bytes.
 * @param queue_name Name for logging.
 */
__host__ void freeContigQueue(struct xioQueueSetup* setup, size_t size,
                              const char* queue_name);

/**
 * @brief Register memory with HIP for GPU access.
 * @param host_ptr Host-accessible pointer.
 * @param size Size in bytes.
 * @param name Name for logging.
 * @param gpu_ptr_out Output GPU-accessible pointer.
 * @return 0 on success, negative error code on failure.
 */
__host__ int registerMemoryForGpu(void* host_ptr, size_t size, const char* name,
                                  void** gpu_ptr_out);

/**
 * @brief Ring a doorbell register via direct MMIO write.
 *
 * Uses __threadfence_system() for portable cross-device
 * ordering.  For MMIO coherence debugging on RDNA GPUs,
 * see ringDoorbellFenced() which adds ISA-level cache
 * invalidations inspired by from-germany coherence testing.
 *
 * When XIO_DOORBELL_FENCE_AGGRESSIVE is defined at compile
 * time, this function delegates to ringDoorbellFenced().
 *
 * @param doorbell_addr GPU-accessible doorbell pointer.
 * @param value Value to write (typically queue tail).
 */
__host__ __device__ static inline void ringDoorbell(
  volatile uint32_t* doorbell_addr, uint32_t value);

/**
 * @brief Ring a doorbell with aggressive ISA-level fencing.
 *
 * On RDNA GPUs (gfx10xx / gfx11xx), emits explicit
 * s_waitcnt + s_waitcnt_vscnt drains, a global_store_dword
 * with GLC|SLC|DLC flags to bypass caches, and full GL0/GL1
 * cache invalidation.  On CDNA GPUs this falls back to the
 * same __threadfence_system() path as ringDoorbell().
 *
 * Use this variant when debugging doorbell ordering issues
 * on consumer RDNA hardware.
 *
 * @param doorbell_addr GPU-accessible doorbell pointer.
 * @param value Value to write (typically queue tail).
 */
__host__ __device__ static inline void ringDoorbellFenced(
  volatile uint32_t* doorbell_addr, uint32_t value) {
#ifdef __HIP_DEVICE_COMPILE__
#if __gfx1010__ || __gfx1030__ || __gfx1031__ || __gfx1032__ || __gfx1100__ || \
  __gfx1101__ || __gfx1102__ || __gfx1200__ || __gfx1201__
  asm volatile("s_waitcnt lgkmcnt(0) vmcnt(0) \n"
               "s_waitcnt_vscnt null, 0x0 \n"
               "global_store_dword %0, %1, off glc slc dlc \n"
               "s_waitcnt lgkmcnt(0) vmcnt(0) \n"
               "s_waitcnt_vscnt null, 0x0 \n"
               "buffer_gl1_inv \n"
               "buffer_gl0_inv \n" ::"v"(doorbell_addr),
               "v"(value)
               : "memory");
  __threadfence_system();
#else
  __threadfence_system();
  *doorbell_addr = value;
  __threadfence_system();
#endif
#else
  *doorbell_addr = value;
#endif
}

__host__ __device__ static inline void ringDoorbell(
  volatile uint32_t* doorbell_addr, uint32_t value) {
#ifdef XIO_DOORBELL_FENCE_AGGRESSIVE
  ringDoorbellFenced(doorbell_addr, value);
#else
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif
  *doorbell_addr = value;
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif
#endif
}

/**
 * @brief Ring a doorbell at a base+offset address.
 * @param base_addr Base address (e.g., BAR0).
 * @param offset Byte offset to the doorbell register.
 * @param value Value to write.
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

/**
 * @brief Ring a doorbell at base+offset with aggressive
 *        ISA-level fencing.
 * @param base_addr Base address (e.g., BAR0).
 * @param offset Byte offset to the doorbell register.
 * @param value Value to write.
 */
__host__ __device__ static inline void ringDoorbellFenced(void* base_addr,
                                                          uint32_t offset,
                                                          uint32_t value) {
  if (base_addr != nullptr) {
    volatile uint32_t* doorbell_reg = reinterpret_cast<volatile uint32_t*>(
      static_cast<volatile char*>(base_addr) + offset);
    ringDoorbellFenced(doorbell_reg, value);
  }
}

/**
 * @brief PCI MMIO Bridge ring metadata
 *        (matches QEMU device).
 */
struct pci_mmio_bridge_ring_meta {
  uint32_t producer_idx;
  uint32_t consumer_idx;
  uint32_t queue_depth;
  uint32_t reserved;
} __attribute__((packed));

/**
 * @brief PCI MMIO Bridge command structure
 *        (matches QEMU device).
 */
struct pci_mmio_bridge_command {
  uint16_t target_bdf;
  uint8_t target_bar;
  uint8_t reserved1;
  uint32_t offset;
  uint64_t value;
  uint8_t command;
  uint8_t size;
  uint8_t status;
  uint8_t reserved2;
  uint32_t sequence;
} __attribute__((packed));

/**
 * @brief Map PCI MMIO bridge shadow buffer via kmod.
 * @param bridge_bdf Bridge BDF in 0xBBDD format.
 * @param virt_addr Output mapped virtual address.
 * @return 0 on success, negative error code on failure.
 */
__host__ int mapMmioBridgeShadowBuffer(uint16_t bridge_bdf, void** virt_addr);

/**
 * @brief Register shadow buffer for GPU access.
 * @param shadow_virt Host virtual address of shadow buffer.
 * @param shadow_size Shadow buffer size in bytes.
 * @param gpu_ptr_out Output GPU-accessible pointer.
 * @return 0 on success, negative error code on failure.
 */
__host__ int registerMmioBridgeShadowBufferForGpu(void* shadow_virt,
                                                  size_t shadow_size,
                                                  void** gpu_ptr_out);

/**
 * @brief Map a PCI BAR for GPU access.
 * @param pci_bdf PCI device BDF in 0xBBDD format.
 * @param bar BAR number (0-5).
 * @param bar_cpu Output CPU-accessible BAR pointer.
 * @param bar_gpu Output GPU-accessible BAR pointer.
 * @param bar_size Size to map (defaults to 8192 if 0).
 * @return 0 on success, negative error code on failure.
 */
__host__ int mapPciBar(uint16_t pci_bdf, uint8_t bar, void** bar_cpu,
                       void** bar_gpu, size_t bar_size);

/**
 * @brief Read the CQR bit from the NVMe CAP register.
 *
 * CQR (Contiguous Queues Required) indicates whether the
 * controller requires physically contiguous I/O queues.
 * Reads via sysfs BAR0 resource mmap.
 *
 * @param pci_bdf NVMe controller BDF (0xBBDD format).
 * @param cqr_out Output: true if contiguous required.
 * @return 0 on success, negative error code on failure.
 */
__host__ int readNvmeCapCqr(uint16_t pci_bdf, bool* cqr_out);

/**
 * @brief Generate and submit a PCI MMIO bridge command.
 *
 * Handles ring buffer management, command structure
 * population, and memory ordering.
 *
 * @param shadowBufferVirt Shadow buffer pointer.
 * @param targetBdf Target device BDF (0xBBDD format).
 * @param targetBar Target BAR number.
 * @param offset Offset within BAR.
 * @param value Value to write (or read result).
 * @param command Command type (PCI_MMIO_BRIDGE_CMD_*).
 * @param size Transfer size in bytes (1, 2, 4, or 8).
 */
__host__ __device__ void genPciMmioBridgeCmd(void* shadowBufferVirt,
                                             uint16_t targetBdf,
                                             uint8_t targetBar, uint32_t offset,
                                             uint64_t value, uint8_t command,
                                             uint8_t size);

} // namespace xio

#endif // XIO_H
