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

#include "rocm-xio-uapi.h"
#include "xio-endpoint-includes-gen.h"
#include "xio-endpoint-registry.h"
#include "xio-export.h"

// ROCm-XIO kernel module device path (same as kernel uapi header convention)
#ifndef ROCM_XIO_DEVICE_PATH
#define ROCM_XIO_DEVICE_PATH "/dev/rocm-xio"
#endif

/**
 * @brief Log HIP failures to stderr (does not return or alter control flow).
 *
 * @internal Legacy diagnostic macro.  Prefer checking hipError_t and
 *           propagating errors per project style (see STYLEGUIDE.md).
 * @see XIO_HIP_TRY for a discardable-result wrapper.
 */
#define HIP_CHECK(expression)                                                  \
  do {                                                                         \
    const hipError_t status = (expression);                                    \
    if (status != hipSuccess) {                                                \
      std::cerr << "HIP error " << status << ": " << hipGetErrorString(status) \
                << " at " << __FILE__ << ":" << __LINE__ << std::endl;         \
    }                                                                          \
  } while (0)

/**
 * @brief Evaluate a HIP call and return its status (for explicit checking).
 */
#define XIO_HIP_TRY(expression)                                                \
  (__extension__({                                                             \
    hipError_t _xio_hip_status = (expression);                                 \
    _xio_hip_status;                                                           \
  }))

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
#define XIO_HOST_MEM_DEFAULT 0x8

// PCI MMIO Bridge command types
#define PCI_MMIO_BRIDGE_CMD_NOP 0
#define PCI_MMIO_BRIDGE_CMD_WRITE 1
#define PCI_MMIO_BRIDGE_CMD_READ 2

// PCI MMIO Bridge status codes
#define PCI_MMIO_BRIDGE_STATUS_PENDING 0
#define PCI_MMIO_BRIDGE_STATUS_COMPLETE 1
#define PCI_MMIO_BRIDGE_STATUS_ERROR 2

#include "xio-endpoint-core.h"

// Export free functions and types declared below when building
// librocm-xio.so (-fvisibility=hidden); xio-tester and other
// consumers link against these symbols.
#if defined(ROCM_XIO_BUILDING_LIBRARY) && defined(ROCM_XIO_SHARED)
#pragma GCC visibility push(default)
#endif

namespace xio {

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
 * @param verifyPass Verified iterations passed (0 to omit).
 * @param verifyFail Verified iterations failed (0 to omit).
 */
void printStatistics(const std::vector<double>& durations,
                     unsigned totalIterations = 0, unsigned numThreads = 0,
                     unsigned readIterations = 0, unsigned writeIterations = 0,
                     unsigned verifiedReadsCount = 0, unsigned verifyPass = 0,
                     unsigned verifyFail = 0);

/**
 * @brief Print a histogram and statistics from durations.
 * @param durations Vector of durations in nanoseconds.
 * @param nIterations Number of iterations for binning.
 * @param numThreads Thread count (0 to omit).
 * @param readIterations Read count (0 to omit).
 * @param writeIterations Write count (0 to omit).
 * @param verifiedReadsCount Verified reads (0 to omit).
 * @param verifyPass Verified iterations passed (0 to omit).
 * @param verifyFail Verified iterations failed (0 to omit).
 */
void printHistogram(const std::vector<double>& durations, unsigned nIterations,
                    unsigned numThreads = 0, unsigned readIterations = 0,
                    unsigned writeIterations = 0,
                    unsigned verifiedReadsCount = 0, unsigned verifyPass = 0,
                    unsigned verifyFail = 0);

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
 * @brief Allocate a mirrored host+device memory pair.
 *
 * Allocates host memory with XIO_HOST_MEM_PLAIN and device
 * memory with XIO_DEVICE_MEM_HIP. The caller can construct
 * objects into *host_ptr, then call hipMemcpy to sync to
 * *device_ptr.
 *
 * @param size Size in bytes.
 * @param host_ptr Output host pointer.
 * @param device_ptr Output device pointer.
 * @param label Label for logging.
 * @return hipSuccess on success.
 */
hipError_t allocDeviceMemoryPair(size_t size, void** host_ptr,
                                 void** device_ptr, const char* label);

/**
 * @brief Free a mirrored host+device pair.
 * @param host_ptr Host pointer (freed with freeHostMemory).
 * @param device_ptr Device pointer (freed with
 *                   freeDeviceMemory).
 */
void freeDeviceMemoryPair(void* host_ptr, void* device_ptr);

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
  uint64_t* pagePhysAddrs;
  uint32_t numPages;
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
 * @brief Write a queue entry to device-visible memory
 *        using wide (8-byte) stores.
 *
 * Copies @p Size bytes from a locally-built queue entry
 * at @p src to a volatile destination slot at @p dst
 * using `uint64_t`-width stores.  The compiler fully
 * unrolls the copy into exactly `Size / 8` store
 * instructions, eliminating loop overhead.
 *
 * Use this for all SQE, WQE, and command writes to
 * submission queues, send queues, or command rings
 * regardless of endpoint type.
 *
 * @tparam Size   Number of bytes to copy.  Must be a
 *                compile-time constant, a multiple of 8,
 *                and in the range (0, 256].
 * @tparam Fence  When @c true, a `__threadfence_system()`
 *                is emitted after the last store to
 *                guarantee system-wide visibility before
 *                a subsequent doorbell write.  Defaults
 *                to @c false so that callers batching
 *                multiple entries can defer the fence.
 *
 * @param[in]  src  Pointer to the locally-built entry.
 *                  Must be at least 8-byte aligned.
 * @param[out] dst  Volatile pointer to the destination
 *                  queue slot.  Must be at least 8-byte
 *                  aligned.
 *
 * @note Both @p src and @p dst must be 8-byte aligned.
 *       All queue slot allocators in rocm-xio satisfy
 *       this (NVMe SQE slots are 64 B, RDMA WQE slots
 *       are >= 16 B, PCI MMIO bridge slots are at a
 *       16 B-aligned base).
 * @note On host builds the fence is a no-op; volatile
 *       store semantics still provide correct MMIO
 *       ordering.
 *
 * @par Example
 * @code
 * nvme_sqe sqeLocal = {};
 * // ... fill sqeLocal ...
 * xio::XioComEnqueue<sizeof(nvme_sqe)>(
 *     &sqeLocal, &sqeAddr[sq_tail]);
 * // fence deferred to ringDoorbell
 * @endcode
 *
 * @see XioComDequeue  For the corresponding read path.
 * @see ringDoorbell   Typically called after one or more
 *                     XioComEnqueue calls.
 */
template <uint32_t Size, bool Fence = false>
__host__ __device__ static inline void XioComEnqueue(const void* src,
                                                     volatile void* dst) {
  static_assert(Size % sizeof(uint64_t) == 0, "Size must be a multiple of 8");
  static_assert(Size > 0 && Size <= 256, "Size out of expected range");
  const uint64_t* s = reinterpret_cast<const uint64_t*>(src);
  constexpr uint32_t N = Size / sizeof(uint64_t);
  if constexpr (Size % 16 == 0) {
    using u64x2 __attribute__((vector_size(16))) = uint64_t;
    volatile u64x2* d = reinterpret_cast<volatile u64x2*>(dst);
#pragma unroll
    for (uint32_t i = 0; i < N / 2; i++) {
      d[i] = u64x2{s[2 * i], s[2 * i + 1]};
    }
  } else {
    volatile uint64_t* d = reinterpret_cast<volatile uint64_t*>(dst);
#pragma unroll
    for (uint32_t i = 0; i < N; i++) {
      d[i] = s[i];
    }
  }
#ifdef __HIP_DEVICE_COMPILE__
  if constexpr (Fence)
    __threadfence_system();
#endif
}

/**
 * @brief Read a queue entry from device-visible memory
 *        using wide (8-byte) loads.
 *
 * Copies @p Size bytes from a volatile source queue
 * slot at @p src into a local struct at @p dst using
 * `uint64_t`-width loads.  The compiler fully unrolls
 * the copy into exactly `Size / 8` load instructions.
 *
 * Use this for all CQE and completion-queue reads
 * regardless of endpoint type.
 *
 * @tparam Size  Number of bytes to copy.  Must be a
 *               compile-time constant, a multiple of 8,
 *               and in the range (0, 256].
 *
 * @param[in]  src  Volatile pointer to the source queue
 *                  slot.  Must be at least 8-byte
 *                  aligned.
 * @param[out] dst  Pointer to the local destination
 *                  struct.  Must be at least 8-byte
 *                  aligned.
 *
 * @note The caller is responsible for any ordering
 *       required after the read (e.g. checking a phase
 *       bit before consuming the entry).
 *
 * @par Example
 * @code
 * nvme_cqe cqeLocal;
 * xio::XioComDequeue<sizeof(nvme_cqe)>(
 *     &cqeAddr[cq_head], &cqeLocal);
 * if (NVME_CQE_STATUS_PHASE(cqeLocal.status)
 *     == expected_phase) { ... }
 * @endcode
 *
 * @see XioComEnqueue  For the corresponding write path.
 */
template <uint32_t Size>
__host__ __device__ static inline void XioComDequeue(volatile const void* src,
                                                     void* dst) {
  static_assert(Size % sizeof(uint64_t) == 0, "Size must be a multiple of 8");
  static_assert(Size > 0 && Size <= 256, "Size out of expected range");
  volatile const uint64_t* s = reinterpret_cast<volatile const uint64_t*>(src);
  uint64_t* d = reinterpret_cast<uint64_t*>(dst);
  constexpr uint32_t N = Size / sizeof(uint64_t);
#pragma unroll
  for (uint32_t i = 0; i < N; i++) {
    d[i] = s[i];
  }
}

/**
 * @brief Write a doorbell register using an atomic store
 *        with system-scope release ordering.
 *
 * Drains all prior memory operations with a single
 * `__threadfence_system()`, then performs a
 * `__hip_atomic_store` with `__ATOMIC_RELEASE` and
 * `__HIP_MEMORY_SCOPE_SYSTEM`.  The atomic store
 * implicitly provides post-store ordering, eliminating
 * the need for a second fence after the write.
 *
 * Supports 32-bit (NVMe, ERNIC) and 64-bit (BNXT, MLX5,
 * IONIC) doorbell widths via the @p T template parameter.
 *
 * On host builds, falls back to a plain volatile store
 * (sufficient for MMIO ordering on x86).
 *
 * @tparam T  Doorbell value type (`uint32_t` or
 *            `uint64_t`).
 *
 * @param[out] addr   Pointer to the doorbell register.
 *                    Must be naturally aligned for @p T.
 * @param[in]  value  Value to write (e.g. queue tail,
 *                    encoded DB header).
 *
 * @see ringDoorbell       Uses this for NVMe doorbells.
 * @see XioComEnqueue      Typically called before this to
 *                         write SQE/WQE data.
 */
template <typename T>
__host__ __device__ static inline void XioComDoorbell(T* addr, T value) {
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
  __hip_atomic_store(addr, value, __ATOMIC_RELEASE, __HIP_MEMORY_SCOPE_SYSTEM);
#else
  *reinterpret_cast<volatile T*>(addr) = value;
#endif
}

/**
 * @brief Ring a doorbell register via direct MMIO write.
 *
 * Uses XioComDoorbell for a single pre-fence + atomic
 * store.  For MMIO coherence debugging on RDNA GPUs,
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
 * On RDNA 2/3 GPUs (gfx10xx / gfx11xx), emits explicit
 * s_waitcnt + s_waitcnt_vscnt drains, a global_store_dword
 * with GLC|SLC|DLC flags to bypass caches, and full GL0/GL1
 * cache invalidation.
 *
 * On RDNA 4 GPUs (gfx12xx), uses the restructured GFX12
 * wait instructions (s_wait_kmcnt, s_wait_loadcnt,
 * s_wait_storecnt) and global_store_b32 with SCOPE_SYS.
 *
 * On CDNA GPUs this falls back to the same
 * __threadfence_system() path as ringDoorbell().
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
#if __gfx1200__ || __gfx1201__
  asm volatile("s_wait_kmcnt 0x0 \n"
               "s_wait_loadcnt 0x0 \n"
               "s_wait_storecnt 0x0 \n"
               "global_store_b32 %0, %1, off scope:SCOPE_SYS \n"
               "s_wait_kmcnt 0x0 \n"
               "s_wait_loadcnt 0x0 \n"
               "s_wait_storecnt 0x0 \n" ::"v"(doorbell_addr),
               "v"(value)
               : "memory");
  __threadfence_system();
#elif __gfx1010__ || __gfx1030__ || __gfx1031__ || __gfx1032__ ||              \
  __gfx1100__ || __gfx1101__ || __gfx1102__
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
  XioComDoorbell(const_cast<uint32_t*>(doorbell_addr), value);
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

#if defined(ROCM_XIO_BUILDING_LIBRARY) && defined(ROCM_XIO_SHARED)
#pragma GCC visibility pop
#endif

#endif // XIO_H
